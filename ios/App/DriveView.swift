import CoreLocation
import MapKit
import SwiftUI

enum POCAppDependencies {
    static let recorder = SessionDiagnosticRecorder.shared
    static let store = KeychainRPPairingStore()
    static let tunnelClient = IdeviceOnDeviceTunnelClient(recorder: recorder)
    static let locationCoordinator = LocationCoordinator(
        pairingStore: store,
        tunnelClient: tunnelClient,
        recorder: recorder
    )

    @MainActor
    static let runner = OnDeviceDVTExperimentRunner(
        pairingStore: store,
        tunnelClient: tunnelClient,
        locationCoordinator: locationCoordinator,
        recorder: recorder
    )

    /// Owned once for the app's lifetime so an active Drive session (its scheduler,
    /// controller, background manager, and verifier) is never torn down by navigation
    /// or tab switches. Views must reference this shared instance rather than
    /// constructing their own `DriveViewModel()`.
    @MainActor
    static let driveModel = DriveViewModel()

    /// Shared product-facing readiness state (Pairing/LocalDevVPN/Endpoint/Session),
    /// observed by Location, Drive, Settings, and Setup so they agree on whether the
    /// app is ready without each re-running diagnostics independently.
    @MainActor
    static let connectionStatus = ConnectionStatusModel(runner: runner, coordinator: locationCoordinator)

    @MainActor
    static let favoritesStore = FavoritesStore()

    @MainActor
    static let recentsStore = RecentsStore()

    @MainActor
    static let router = AppRouter()
}

@MainActor
final class DriveViewModel: ObservableObject {
    @Published var startQuery = ""
    @Published var destinationQuery = ""
    @Published var startCoordinateText = "UNKNOWN"
    @Published var destinationCoordinateText = "UNKNOWN"
    @Published var status = "Ready. Experimental testing feature."
    /// Exact technical detail (error domain/code/operation) for the most
    /// recent failure, kept separate from `status` so Drive Diagnostics can
    /// show the raw underlying error while the normal Drive screen only ever
    /// shows `status`'s human-readable text.
    @Published var lastTechnicalError: String?
    @Published var speedMPH = 35.0
    @Published var updateCadence = DriveUpdateCadence.baseline1Hz
    @Published var state = DriveSessionState.idle
    @Published var connectionState = LocationCoordinatorConnectionState.disconnected
    @Published var connectionGeneration = 0
    @Published var routeDistanceText = "UNKNOWN"
    @Published var expectedTravelTimeText = "UNKNOWN"
    @Published var expectedProgressText = "UNKNOWN"
    @Published var currentCoordinateText = "UNKNOWN"
    @Published var exportURLs: [URL] = []
    @Published var routeResult: MapKitRouteResult?
    @Published var breadcrumbs: [CLLocationCoordinate2D] = []
    @Published var liveMetrics = DriveLiveMetrics.empty

    private let searchProvider = MapKitSearchProvider()
    private let routeProvider = MapKitRouteProvider()
    private let locationProvider = CurrentLocationProvider()
    private let coordinator = POCAppDependencies.locationCoordinator
    private let background = DriveBackgroundManager(recorder: POCAppDependencies.recorder)
    private let verifier = CoreLocationVerifier()
    private let clock = ContinuousDriveClock()
    private var controller: DriveSessionController?
    private var scheduler: DriveScheduler?
    private var diagnostics = DriveDiagnostics(recorder: POCAppDependencies.recorder)
    private var startCoordinate: CLLocationCoordinate2D?
    private var destinationCoordinate: CLLocationCoordinate2D?
    private var refreshLoopStarted = false

    init() {
        verifier.setObservationHandler { [weak self] observation in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let generation = await self.coordinator.currentConnectionGeneration()
                await self.diagnostics.recordObservation(
                    observation,
                    applicationLifecycleState: self.background.applicationLifecycleState(),
                    backgroundSessionActive: self.background.isBackgroundSessionActive(),
                    connectionGeneration: generation
                )
            }
        }
    }

    func startRefreshLoop() {
        guard !refreshLoopStarted else { return }
        refreshLoopStarted = true
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refresh() async {
        let coordinatorSnapshot = await coordinator.snapshot()
        connectionState = coordinatorSnapshot.connectionState
        connectionGeneration = coordinatorSnapshot.connectionGeneration
        if let controller {
            let snapshot = controller.snapshot(now: clock.nowSeconds())
            state = snapshot.state
            routeDistanceText = meters(snapshot.routeDistanceMeters)
            expectedTravelTimeText = duration(snapshot.expectedTravelTime)
            expectedProgressText = meters(snapshot.currentExpectedDistanceMeters)
            currentCoordinateText = coordinate(snapshot.currentLatitude, snapshot.currentLongitude)
        }
        exportURLs = await diagnostics.exportURLs()
        liveMetrics = await diagnostics.liveMetrics()
    }

    func recordScenePhase(_ phase: String) {
        background.recordLifecycle("scene_\(phase)")
        Task {
            let generation = await coordinator.currentConnectionGeneration()
            await diagnostics.recordLifecycle(
                "scene_\(phase)",
                schedulerState: state.rawValue,
                backgroundSessionActive: background.isBackgroundSessionActive(),
                connectionGeneration: generation
            )
        }
    }

    func useCurrentAsStart() {
        Task {
            do {
                status = "Requesting current Core Location..."
                let coordinate = try await locationProvider.requestCurrentCoordinate()
                startCoordinate = coordinate
                startCoordinateText = Self.coordinate(coordinate)
                startQuery = startCoordinateText
                status = "Start set to current observed location."
            } catch {
                fail(error, operation: "useCurrentAsStart")
            }
        }
    }

    func resolveStart() {
        Task {
            do {
                let coordinate = try await searchProvider.coordinate(for: startQuery)
                startCoordinate = coordinate
                startCoordinateText = Self.coordinate(coordinate)
                status = "Start resolved."
            } catch {
                fail(error, operation: "resolveStart")
            }
        }
    }

    /// Sets the start directly from an already-resolved place (search
    /// suggestion, favorite, or recent), bypassing text search. Mirrors
    /// `setDestination`; does not touch the engine.
    func setStart(_ place: ResolvedPlace) {
        startCoordinate = place.coordinate
        startCoordinateText = Self.coordinate(place.coordinate)
        startQuery = place.name
    }

    /// Discards an in-progress route preview and returns to route setup.
    /// Only ever touches the preview `controller` created by `generateRoute()`
    /// for distance/ETA display — a real drive is a separate controller
    /// created fresh by `startDrive()`, so this can never interrupt an active
    /// Drive session.
    func editRoute() {
        controller = nil
        routeResult = nil
        state = .idle
        routeDistanceText = "UNKNOWN"
        expectedTravelTimeText = "UNKNOWN"
        expectedProgressText = "UNKNOWN"
        breadcrumbs = []
        status = "Ready. Experimental testing feature."
    }

    /// Sets the destination directly from an already-resolved place (e.g. a
    /// "Drive Here" handoff from the Location tab or a favorite), bypassing
    /// text search. Does not touch the engine — it only populates the same
    /// destinationCoordinate/destinationQuery fields generateRoute() already
    /// reads.
    func setDestination(_ place: ResolvedPlace) {
        destinationCoordinate = place.coordinate
        destinationCoordinateText = Self.coordinate(place.coordinate)
        destinationQuery = place.name
        status = "Destination set to \(place.name). Choose a start, then generate a route."
    }

    func resolveDestination() {
        Task {
            do {
                let coordinate = try await searchProvider.coordinate(for: destinationQuery)
                destinationCoordinate = coordinate
                destinationCoordinateText = Self.coordinate(coordinate)
                status = "Destination resolved."
            } catch {
                fail(error, operation: "resolveDestination")
            }
        }
    }

    func generateRoute() {
        Task {
            do {
                if startCoordinate == nil, !startQuery.isEmpty {
                    startCoordinate = try await searchProvider.coordinate(for: startQuery)
                }
                if destinationCoordinate == nil, !destinationQuery.isEmpty {
                    destinationCoordinate = try await searchProvider.coordinate(for: destinationQuery)
                }
                guard let startCoordinate, let destinationCoordinate else {
                    throw POCError(.invalidRoute, "Select both a start and destination.")
                }
                status = "Generating automobile route with MapKit..."
                let result = try await routeProvider.route(origin: startCoordinate, destination: destinationCoordinate)
                routeResult = result
                controller = DriveSessionController()
                controller?.prepareRoute(result.driveRoute, speedMPH: speedMPH)
                state = .routeReady
                routeDistanceText = meters(result.driveRoute.routeDistanceMeters)
                expectedTravelTimeText = duration(result.driveRoute.expectedTravelTime)
                expectedProgressText = meters(0)
                currentCoordinateText = Self.coordinate(startCoordinate)
                breadcrumbs = [startCoordinate]
                status = "Route ready. Review preview, choose speed, then Start Drive."
            } catch {
                fail(error, operation: "generateRoute")
            }
        }
    }

    func startDrive() {
        Task {
            do {
                guard let result = routeResult else {
                    throw POCError(.invalidRoute, "Generate a route before starting Drive Mode.")
                }
                let activeController = DriveSessionController()
                activeController.prepareRoute(result.driveRoute, speedMPH: speedMPH)
                try activeController.startDrive(now: clock.nowSeconds())
                controller = activeController
                diagnostics = DriveDiagnostics(recorder: POCAppDependencies.recorder)
                await diagnostics.start(
                    sessionID: activeController.sessionID,
                    writerID: activeController.writerID,
                    route: result.driveRoute.resampler,
                    selectedSpeedMps: DriveSpeed.metersPerSecond(fromMPH: speedMPH),
                    updateCadence: updateCadence
                )
                background.setDiagnostics(diagnostics)
                background.begin()
                verifier.setRequestedCoordinate(
                    latitude: result.driveRoute.origin.latitude,
                    longitude: result.driveRoute.origin.longitude
                )
                verifier.start(backgroundCapable: true)
                try await coordinator.startSimulation(
                    writerID: activeController.writerID,
                    mode: .drive(sessionID: activeController.sessionID, current: SimulatedCoordinate(result.driveRoute.origin))
                )
                scheduler = DriveScheduler(
                    controller: activeController,
                    locationCoordinator: coordinator,
                    diagnostics: diagnostics,
                    clock: clock,
                    updateCadence: updateCadence,
                    observedProvider: { [weak verifier] in verifier?.latestObservation() },
                    lifecycleProvider: { [background] in background.applicationLifecycleState() },
                    backgroundActiveProvider: { [background] in background.isBackgroundSessionActive() }
                )
                scheduler?.start()
                status = "Drive Mode started. Destination will hold until Stop/Clear."
                await diagnostics.recordState("driving", message: "drive started")
                await refresh()
            } catch {
                fail(error, operation: "startDrive")
            }
        }
    }

    func pause() {
        guard let controller else { return }
        _ = controller.pause(now: clock.nowSeconds())
        state = controller.currentState()
        Task {
            await diagnostics.recordState("paused", message: "drive paused")
            await refresh()
        }
    }

    func resume() {
        guard let controller else { return }
        controller.resume(now: clock.nowSeconds())
        state = controller.currentState()
        Task {
            await diagnostics.recordState("driving", message: "drive resumed")
            await refresh()
        }
    }

    func stopAndClear() {
        Task {
            guard let controller else { return }
            let writerID = controller.writerID
            scheduler?.stop()
            await scheduler?.waitUntilStopped()
            scheduler = nil
            controller.stop(clearSimulation: true)
            do {
                try await coordinator.stopSimulation(writerID: writerID, clearLocation: true)
                status = "Drive stopped and simulation cleared."
            } catch {
                fail(error, operation: "stopAndClear")
            }
            background.end(reason: "drive stop clear")
            background.setDiagnostics(nil)
            verifier.stop()
            await diagnostics.recordState("stopped", message: "explicit stop and clear")
            _ = await diagnostics.finalizeSummary()
            await refresh()
        }
    }

    func updateBreadcrumb() {
        guard let controller,
              let position = controller.expectedPosition(now: clock.nowSeconds())
        else { return }
        breadcrumbs.append(position.coordinate)
        if breadcrumbs.count > 300 {
            breadcrumbs.removeFirst(breadcrumbs.count - 300)
        }
    }

    private func meters(_ value: Double?) -> String {
        guard let value else { return "UNKNOWN" }
        return String(format: "%.0f m", value)
    }

    private func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "UNKNOWN" }
        let minutes = Int((value / 60).rounded())
        return "\(minutes) min"
    }

    var expectedDistancePerUpdateText: String {
        let meters = updateCadence.expectedDistancePerUpdateMeters(
            speedMetersPerSecond: DriveSpeed.metersPerSecond(fromMPH: speedMPH)
        )
        return String(format: "~%.1f m/update", meters)
    }

    private func coordinate(_ latitude: Double?, _ longitude: Double?) -> String {
        guard let latitude, let longitude else { return "UNKNOWN" }
        return String(format: "%.6f, %.6f", latitude, longitude)
    }

    private static func coordinate(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    /// Sets `status` to a clean, human-facing message and `lastTechnicalError`
    /// to the exact underlying error (domain/code/description) plus which
    /// operation threw it. Normal Drive UI only ever reads `status`; Drive
    /// Diagnostics reads both, so the raw `kCLErrorDomain`/`MKErrorDomain`
    /// text a user should never see (e.g. `Error Domain=kCLErrorDomain
    /// Code=8 "(null)"`) stays available to developers without leaking into
    /// the product UI.
    private func fail(_ error: Error, operation: String) {
        status = "FAIL: \(display(error))"
        let nsError = error as NSError
        lastTechnicalError = "operation=\(operation) domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)"
    }

    private func display(_ error: Error) -> String {
        if let error = error as? POCError {
            return HumanReadableError.describe(code: error.code.rawValue, detail: error.message)
        }
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain {
            switch CLError.Code(rawValue: nsError.code) {
            case .denied:
                return "Location access is off for IOSSim. Enable it in Settings > Privacy > Location Services."
            case .geocodeFoundNoResult, .geocodeFoundPartialResult:
                return "Couldn't find that location. Try another search."
            case .network:
                return "Couldn't reach location services. Check your connection and try again."
            default:
                return "Couldn't determine your current location. Try again."
            }
        }
        return "Something went wrong. Try again."
    }
}

struct DriveView: View {
    // Shared, app-lifetime instance (see POCAppDependencies.driveModel) so switching
    // tabs or pushing/popping navigation never stops an active Drive session.
    @ObservedObject private var model = POCAppDependencies.driveModel
    @StateObject private var startSearch = PlaceSearchService()
    @StateObject private var destinationSearch = PlaceSearchService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            DriveMapPreview(route: model.routeResult, breadcrumbs: model.breadcrumbs)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 8) {
                switch model.state {
                case .idle, .stopped:
                    routeSetupCard
                case .routeReady:
                    routeReviewCard
                case .driving, .paused, .completedHolding:
                    activeDriveCard
                }
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Drive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    DriveDiagnosticsView(model: model)
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .accessibilityLabel("Drive Diagnostics")
            }
        }
        .task {
            model.startRefreshLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            model.recordScenePhase(String(describing: phase))
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.updateBreadcrumb()
        }
    }

    private var routeSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drive")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Start")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.useCurrentAsStart()
                } label: {
                    Label("Current Location", systemImage: "location.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                PlaceSearchField(
                    placeholder: "Or search for a start location",
                    text: $model.startQuery,
                    search: startSearch,
                    onSelect: { model.setStart($0) }
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PlaceSearchField(
                    placeholder: "Search for a destination",
                    text: $model.destinationQuery,
                    search: destinationSearch,
                    onSelect: { model.setDestination($0) }
                )
            }

            if model.status.hasPrefix("FAIL") {
                Label(model.status, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                model.generateRoute()
            } label: {
                Text("Preview Route")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var routeReviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(model.startQuery.isEmpty ? "Current Location" : model.startQuery, systemImage: "circle.fill")
                    .font(.subheadline)
                Label(model.destinationQuery, systemImage: "mappin")
                    .font(.subheadline)
            }

            HStack {
                LabeledContent("Distance", value: model.routeDistanceText)
                Spacer()
                LabeledContent("ETA", value: model.expectedTravelTimeText)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Speed: \(Int(model.speedMPH)) mph")
                    .font(.subheadline)
                Slider(value: $model.speedMPH, in: DriveSpeed.minimumMPH...DriveSpeed.maximumMPH, step: 5)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Playback Cadence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Playback Cadence", selection: $model.updateCadence) {
                    ForEach(DriveUpdateCadence.allCases) { cadence in
                        Text(cadence.displayName).tag(cadence)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Estimated step", value: model.expectedDistancePerUpdateText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Change Route") {
                    model.editRoute()
                }
                .buttonStyle(.bordered)

                Button {
                    model.startDrive()
                } label: {
                    Text("Start Drive")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var activeDriveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(model.state == .paused ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(driveStateLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(model.speedMPH)) mph")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("\(model.expectedProgressText) of \(model.routeDistanceText)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if model.state == .paused {
                    Button {
                        model.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if model.state == .driving {
                    Button {
                        model.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    model.stopAndClear()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var driveStateLabel: String {
        switch model.state {
        case .driving: return "Driving"
        case .paused: return "Paused"
        case .completedHolding: return "Arrived"
        default: return model.state.rawValue
        }
    }
}

/// Full diagnostic detail for Drive, unchanged in substance from the original
/// developer console — only re-homed under Settings -> Developer so the
/// normal Drive screen stays uncluttered. All instrumentation is preserved.
struct DriveDiagnosticsView: View {
    @ObservedObject var model: DriveViewModel
    @State private var exporting = false

    var body: some View {
        List {
            Section("Status") {
                Text(model.status)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            if let lastTechnicalError = model.lastTechnicalError {
                Section("Technical Error") {
                    Text(lastTechnicalError)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("Drive State") {
                LabeledContent("State", value: model.state.rawValue)
                LabeledContent("Connection", value: model.connectionState.rawValue)
                LabeledContent("Generation", value: "\(model.connectionGeneration)")
                LabeledContent("Route distance", value: model.routeDistanceText)
                LabeledContent("MapKit ETA", value: model.expectedTravelTimeText)
                LabeledContent("Progress", value: model.expectedProgressText)
                LabeledContent("Coordinate", value: model.currentCoordinateText)
                LabeledContent("Playback Cadence", value: model.updateCadence.displayName)
                LabeledContent("Estimated step", value: model.expectedDistancePerUpdateText)
            }

            Section("Debug Metrics") {
                LabeledContent("Lifecycle", value: model.liveMetrics.lifecycleState)
                LabeledContent("Scheduler interval", value: ms(model.liveMetrics.lastSchedulerIntervalMs))
                LabeledContent("Scheduler jitter", value: ms(model.liveMetrics.lastSchedulerJitterMs))
                LabeledContent("DVT set latency", value: ms(model.liveMetrics.lastDVTSetLatencyMs))
                LabeledContent("CL latency", value: ms(model.liveMetrics.lastCoreLocationLatencyMs))
                LabeledContent("Selected speed", value: mps(model.liveMetrics.selectedSpeedMps))
                LabeledContent("CLLocation.speed", value: mps(model.liveMetrics.lastCLLocationSpeedMps))
                LabeledContent("Observed geometric speed", value: mps(model.liveMetrics.lastObservedGeometricSpeedMps))
                LabeledContent("Generation", value: "\(model.liveMetrics.connectionGeneration)")
                LabeledContent("Scheduler stalls", value: "\(model.liveMetrics.schedulerStallCount)")
                LabeledContent("DVT stalls", value: "\(model.liveMetrics.dvtSetStallCount)")
                LabeledContent("CL stalls", value: "\(model.liveMetrics.coreLocationObservationStallCount)")
                LabeledContent("Bursts", value: "\(model.liveMetrics.burstyProgressCount)")
                LabeledContent("Snap-backs", value: "\(model.liveMetrics.snapBackCount)")
            }

            Section("Manual Controls") {
                Button("START DRIVE") { model.startDrive() }
                Button("PAUSE") { model.pause() }
                Button("RESUME") { model.resume() }
                Button("STOP / CLEAR SIMULATION", role: .destructive) { model.stopAndClear() }
            }

            Section("Export") {
                Button("EXPORT DRIVE DIAGNOSTICS") {
                    exporting = true
                }
            }
        }
        .navigationTitle("Drive Diagnostics")
        .sheet(isPresented: $exporting) {
            ShareSheet(activityItems: model.exportURLs)
        }
    }
}

private func ms(_ value: Double?) -> String {
    guard let value else { return "UNKNOWN" }
    return String(format: "%.0f ms", value)
}

private func mps(_ value: Double?) -> String {
    guard let value else { return "UNKNOWN" }
    return String(format: "%.2f m/s", value)
}

private struct DriveMapPreview: View {
    let route: MapKitRouteResult?
    let breadcrumbs: [CLLocationCoordinate2D]

    var body: some View {
        Map {
            if let route {
                Marker("Start", coordinate: route.driveRoute.origin)
                Marker("Destination", coordinate: route.driveRoute.destination)
                MapPolyline(route.polyline)
                    .stroke(.blue, lineWidth: 4)
            }
            if breadcrumbs.count >= 2 {
                MapPolyline(coordinates: breadcrumbs)
                    .stroke(.orange, lineWidth: 3)
            }
            if let current = breadcrumbs.last {
                Marker("Current", systemImage: "location.fill", coordinate: current)
            }
        }
    }
}
