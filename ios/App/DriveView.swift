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
}

@MainActor
final class DriveViewModel: ObservableObject {
    @Published var startQuery = ""
    @Published var destinationQuery = ""
    @Published var startCoordinateText = "UNKNOWN"
    @Published var destinationCoordinateText = "UNKNOWN"
    @Published var status = "Ready. Experimental testing feature."
    @Published var speedMPH = 35.0
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

    private let searchProvider = MapKitSearchProvider()
    private let routeProvider = MapKitRouteProvider()
    private let locationProvider = OneShotLocationProvider()
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
    }

    func recordScenePhase(_ phase: String) {
        background.recordLifecycle("scene_\(phase)")
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
                status = "FAIL: \(display(error))"
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
                status = "FAIL: \(display(error))"
            }
        }
    }

    func resolveDestination() {
        Task {
            do {
                let coordinate = try await searchProvider.coordinate(for: destinationQuery)
                destinationCoordinate = coordinate
                destinationCoordinateText = Self.coordinate(coordinate)
                status = "Destination resolved."
            } catch {
                status = "FAIL: \(display(error))"
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
                status = "FAIL: \(display(error))"
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
                    route: result.driveRoute.resampler
                )
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
                    observedProvider: { [weak verifier] in verifier?.latestObservation() },
                    lifecycleProvider: { [background] in background.applicationLifecycleState() },
                    backgroundActiveProvider: { [background] in background.isBackgroundSessionActive() }
                )
                scheduler?.start()
                status = "Drive Mode started. Destination will hold until Stop/Clear."
                await diagnostics.recordState("driving", message: "drive started")
                await refresh()
            } catch {
                status = "FAIL: \(display(error))"
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
                status = "FAIL: \(display(error))"
            }
            background.end(reason: "drive stop clear")
            verifier.stop()
            await diagnostics.recordState("stopped", message: "explicit stop and clear")
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

    private func coordinate(_ latitude: Double?, _ longitude: Double?) -> String {
        guard let latitude, let longitude else { return "UNKNOWN" }
        return String(format: "%.6f, %.6f", latitude, longitude)
    }

    private static func coordinate(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    private func display(_ error: Error) -> String {
        if let error = error as? POCError {
            return "\(error.code.rawValue): \(error.message)"
        }
        return String(describing: error)
    }
}

struct DriveView: View {
    @StateObject private var model = DriveViewModel()
    @State private var exporting = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section("Experimental / Testing Feature") {
                Text("Drive Mode is isolated from the primary static-location workflow and is for controlled developer-owned device testing.")
                    .font(.caption)
                Text(model.status)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Section("Route") {
                TextField("Start location or lat,lon", text: $model.startQuery)
                    .textInputAutocapitalization(.words)
                HStack {
                    Button("USE CURRENT") { model.useCurrentAsStart() }
                    Button("RESOLVE START") { model.resolveStart() }
                }
                Text(model.startCoordinateText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                TextField("Destination or lat,lon", text: $model.destinationQuery)
                    .textInputAutocapitalization(.words)
                Button("RESOLVE DESTINATION") { model.resolveDestination() }
                Text(model.destinationCoordinateText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                Button("GENERATE DRIVING ROUTE") { model.generateRoute() }
            }

            Section("Preview") {
                DriveMapPreview(route: model.routeResult, breadcrumbs: model.breadcrumbs)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                LabeledContent("Route distance", value: model.routeDistanceText)
                LabeledContent("MapKit ETA", value: model.expectedTravelTimeText)
            }

            Section("Speed") {
                Slider(value: $model.speedMPH, in: DriveSpeed.minimumMPH...DriveSpeed.maximumMPH, step: 5)
                LabeledContent("Selected", value: "\(Int(model.speedMPH)) mph")
            }

            Section("Drive State") {
                LabeledContent("State", value: model.state.rawValue)
                LabeledContent("Connection", value: model.connectionState.rawValue)
                LabeledContent("Generation", value: "\(model.connectionGeneration)")
                LabeledContent("Progress", value: model.expectedProgressText)
                LabeledContent("Coordinate", value: model.currentCoordinateText)
            }

            Section("Controls") {
                Button("START DRIVE") { model.startDrive() }
                Button("PAUSE") { model.pause() }
                Button("RESUME") { model.resume() }
                Button("STOP / CLEAR SIMULATION", role: .destructive) { model.stopAndClear() }
                Button("EXPORT DRIVE DIAGNOSTICS") {
                    exporting = true
                }
            }
        }
        .navigationTitle("Drive Simulation")
        .task {
            model.startRefreshLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            model.recordScenePhase(String(describing: phase))
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.updateBreadcrumb()
        }
        .sheet(isPresented: $exporting) {
            ShareSheet(activityItems: model.exportURLs)
        }
    }
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

private final class OneShotLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.activityType = .automotiveNavigation
        #endif
    }

    func requestCurrentCoordinate() async throws -> CLLocationCoordinate2D {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

