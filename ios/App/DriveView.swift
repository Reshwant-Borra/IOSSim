import CoreLocation
import MapKit
import SwiftUI

enum POCAppDependencies {
  static let recorder = SessionDiagnosticRecorder.shared
  static let store = KeychainRPPairingStore()
  static let tunnelClient = IdeviceOnDeviceTunnelClient(
    recorder: recorder,
    pairingStore: store
  )
  static let pairingInbox = AutomaticPairingInboxProcessor(primaryStore: store)
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
  static let connectionStatus = ConnectionStatusModel(
    runner: runner, coordinator: locationCoordinator)

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
  @Published var status = "Ready."
  /// Exact technical detail (error domain/code/operation) for the most
  /// recent failure, kept separate from `status` so Drive Diagnostics can
  /// show the raw underlying error while the normal Drive screen only ever
  /// shows `status`'s human-readable text.
  @Published var lastTechnicalError: String?
  @Published var speedMPH = 35.0
  @Published var updateCadence = DriveUpdateCadence.defaultCadence
  @Published var outputMode: DriveLocationOutputMode {
    didSet {
      outputSelectionStore.save(outputMode)
    }
  }
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
  @Published var activeOutputMode: DriveLocationOutputMode?
  @Published var activeUpdateCadence: DriveUpdateCadence?
  @Published var fallbackNotice: String?

  private let searchProvider = MapKitSearchProvider()
  private let routeProvider = MapKitRouteProvider()
  private let locationProvider = CurrentLocationProvider()
  private let coordinator = POCAppDependencies.locationCoordinator
  private let background = DriveBackgroundManager(recorder: POCAppDependencies.recorder)
  private let verifier = CoreLocationVerifier()
  private let clock = ContinuousDriveClock()
  private let outputSelectionStore: DriveOutputSelectionStore
  private var controller: DriveSessionController?
  private var scheduler: DriveScheduler?
  private var activeTransport: DriveLocationTransport?
  private var diagnostics = DriveDiagnostics(recorder: POCAppDependencies.recorder)
  private var startCoordinate: CLLocationCoordinate2D?
  private var destinationCoordinate: CLLocationCoordinate2D?
  private var refreshLoopStarted = false
  private var lastAuthoritativePosition: DrivePosition?
  private var didFallbackTransportThisSession = false
  private var didFallbackCadenceThisSession = false
  private var transitionInProgress = false
  private var clearRequested = false

  init(outputSelectionStore: DriveOutputSelectionStore = DriveOutputSelectionStore()) {
    self.outputSelectionStore = outputSelectionStore
    self.outputMode = outputSelectionStore.loadMigratingIfNeeded()
    verifier.setRawCallbackHandler { [weak self] callback in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let generation = await self.coordinator.currentConnectionGeneration()
        await self.diagnostics.recordRawLocationCallback(
          callback,
          applicationLifecycleState: self.background.applicationLifecycleState(),
          backgroundSessionActive: self.background.isBackgroundSessionActive(),
          connectionGeneration: generation
        )
      }
    }
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
      if snapshot.state == .completedHolding {
        scheduler?.stop()
        scheduler = nil
        background.end(reason: "drive destination holding")
        background.setDiagnostics(nil)
        verifier.stop()
        if status != "Arrived — Holding Location" {
          status = "Arrived — Holding Location"
        }
      } else if snapshot.state == .holding, status != "Holding Location" {
        status = "Holding Location"
      }
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
    status = "Ready."
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
        let result = try await routeProvider.route(
          origin: startCoordinate, destination: destinationCoordinate)
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
        guard activeTransport == nil, scheduler == nil,
          state != .driving, state != .paused, state != .holding, state != .completedHolding
        else {
          throw POCError(
            .invalidDriveState,
            "Stop the current Drive session before starting another transport.")
        }
        guard let result = routeResult else {
          throw POCError(.invalidRoute, "Generate a route before starting Drive Mode.")
        }
        let activeController = DriveSessionController()
        activeController.prepareRoute(result.driveRoute, speedMPH: speedMPH)
        try activeController.startDrive(now: clock.nowSeconds())
        controller = activeController
        lastAuthoritativePosition = nil
        didFallbackTransportThisSession = false
        didFallbackCadenceThisSession = false
        transitionInProgress = false
        clearRequested = false
        fallbackNotice = nil
        let normalOutputMode = DriveLocationOutputMode.defaultMode
        let normalUpdateCadence = DriveUpdateCadence.defaultCadence
        outputMode = normalOutputMode
        updateCadence = normalUpdateCadence
        diagnostics = DriveDiagnostics(recorder: POCAppDependencies.recorder)
        await diagnostics.start(
          sessionID: activeController.sessionID,
          writerID: activeController.writerID,
          route: result.driveRoute.resampler,
          selectedSpeedMps: DriveSpeed.metersPerSecond(fromMPH: speedMPH),
          updateCadence: normalUpdateCadence,
          outputMode: normalOutputMode
        )
        await diagnostics.recordState(
          "transport_primary_selected",
          message: "primary drive transport selected",
          metadata: [
            "event": "TRANSPORT_PRIMARY_SELECTED",
            "active_transport": normalOutputMode.displayName,
            "active_cadence": normalUpdateCadence.diagnosticName,
          ])
        await diagnostics.recordState(
          "cadence_primary_selected",
          message: "primary drive cadence selected",
          metadata: [
            "event": "CADENCE_PRIMARY_SELECTED",
            "active_transport": normalOutputMode.displayName,
            "active_cadence": normalUpdateCadence.diagnosticName,
          ])
        background.setDiagnostics(diagnostics)
        background.begin()
        verifier.setRequestedCoordinate(
          latitude: result.driveRoute.origin.latitude,
          longitude: result.driveRoute.origin.longitude
        )
        verifier.start(backgroundCapable: true)
        do {
          try await startTransportAndScheduler(
            controller: activeController,
            mode: normalOutputMode,
            cadence: normalUpdateCadence,
            initialCoordinate: result.driveRoute.origin
          )
        } catch {
          guard normalOutputMode == .richXCUILocationExperimental,
            try await startDVTAfterRichStartupFailure(
              error: error,
              controller: activeController,
              initialCoordinate: result.driveRoute.origin
            )
          else {
            throw error
          }
        }
        status = "Drive started."
        await diagnostics.recordState("driving", message: "drive started")
        await refresh()
      } catch {
        scheduler?.stop()
        await scheduler?.waitUntilStopped()
        scheduler = nil
        if let controller {
          let writerID = controller.writerID
          controller.stop(clearSimulation: true)
          if let activeTransport {
            try? await activeTransport.stop(writerID: writerID, clearLocation: true)
          } else {
            try? await coordinator.stopSimulation(writerID: writerID, clearLocation: true)
          }
        }
        if let result = routeResult {
          let previewController = DriveSessionController()
          previewController.prepareRoute(result.driveRoute, speedMPH: speedMPH)
          controller = previewController
          state = .routeReady
          currentCoordinateText = Self.coordinate(result.driveRoute.origin)
          expectedProgressText = meters(0)
        } else {
          controller = nil
          state = .idle
        }
        activeTransport = nil
        activeOutputMode = nil
        activeUpdateCadence = nil
        lastAuthoritativePosition = nil
        background.end(reason: "drive start failed")
        background.setDiagnostics(nil)
        verifier.stop()
        fail(error, operation: "startDrive")
        await diagnostics.recordState(
          "start_failed",
          message: "drive start failed",
          metadata: [
            "output_mode": outputMode.rawValue,
            "transport": outputMode.developerDetail,
            "error": String(describing: error),
          ])
        await refresh()
      }
    }
  }

  func selectOutputMode(_ mode: DriveLocationOutputMode) {
    guard activeTransport == nil, scheduler == nil,
      state != .driving, state != .paused, state != .holding, state != .completedHolding
    else {
      fail(
        POCError(
          .invalidDriveState,
          "Stop the current Drive session before changing Drive output."),
        operation: "selectOutputMode"
      )
      return
    }
    outputMode = mode
    status = "Drive output set to \(mode.displayName)."
  }

  private func startTransportAndScheduler(
    controller: DriveSessionController,
    mode: DriveLocationOutputMode,
    cadence: DriveUpdateCadence,
    initialCoordinate: CLLocationCoordinate2D
  ) async throws {
    let transport = makeTransport(for: mode)
    try await transport.start(
      DriveLocationTransportStartContext(
        sessionID: controller.sessionID,
        writerID: controller.writerID,
        initialCoordinate: initialCoordinate
      ))
    activeTransport = transport
    activeOutputMode = mode
    activeUpdateCadence = cadence
    let newScheduler = makeScheduler(
      controller: controller,
      transport: transport,
      cadence: cadence
    )
    scheduler = newScheduler
    newScheduler.start()
  }

  private func startDVTAfterRichStartupFailure(
    error: Error,
    controller: DriveSessionController,
    initialCoordinate: CLLocationCoordinate2D
  ) async throws -> Bool {
    guard !didFallbackTransportThisSession else { return false }
    guard !clearRequested else { return false }
    didFallbackTransportThisSession = true
    let transitionStart = ProcessInfo.processInfo.systemUptime
    let position = controller.expectedPosition(now: clock.nowSeconds())
      ?? DrivePosition(
        coordinate: initialCoordinate,
        expectedDistanceMeters: 0,
        activeElapsedSeconds: 0,
        completed: false
      )
    controller.pauseForTransition(position: position, now: clock.nowSeconds())
    await diagnostics.recordState(
      "transport_fallback_triggered",
      message: "Rich Drive startup failed; falling back to DVT Compatibility",
      metadata: fallbackMetadata(
        event: "TRANSPORT_FALLBACK_TRIGGERED",
        reason: String(describing: error),
        position: position,
        oldWriterStopped: false
      )
    )

    var oldWriterStopped = true
    if let activeTransport {
      do {
        try await activeTransport.stop(writerID: controller.writerID, clearLocation: false)
      } catch {
        oldWriterStopped = false
        await diagnostics.recordState(
          "transport_fallback_teardown_warning",
          message: "Rich Drive startup fallback teardown reported an error",
          metadata: ["error": String(describing: error)]
        )
      }
      self.activeTransport = nil
    } else {
      try? await coordinator.stopSimulation(writerID: controller.writerID, clearLocation: false)
    }

    do {
      guard !clearRequested else { return false }
      let dvt = makeTransport(for: .dvtBaseline)
      try await dvt.start(
        DriveLocationTransportStartContext(
          sessionID: controller.sessionID,
          writerID: controller.writerID,
          initialCoordinate: position.coordinate
        ))
      activeTransport = dvt
      activeOutputMode = .dvtBaseline
      activeUpdateCadence = updateCadence
      fallbackNotice = "Rich Drive unavailable. Using DVT Compatibility."
      try await writeAuthoritativePosition(
        position,
        speedMetersPerSecond: controller.snapshot(now: clock.nowSeconds()).speedMetersPerSecond,
        transport: dvt,
        reason: "transport_startup_fallback_takeover"
      )
      controller.resume(now: clock.nowSeconds())
      let newScheduler = makeScheduler(controller: controller, transport: dvt, cadence: updateCadence)
      scheduler = newScheduler
      newScheduler.start()
      await diagnostics.recordState(
        "transport_fallback_completed",
        message: "DVT Compatibility took over after Rich Drive startup failure",
        metadata: fallbackMetadata(
          event: "TRANSPORT_FALLBACK_COMPLETED",
          reason: String(describing: error),
          position: position,
          oldWriterStopped: oldWriterStopped
        ).merging([
          "transition_duration_ms": String(format: "%.3f", max(0, ProcessInfo.processInfo.systemUptime - transitionStart) * 1000),
          "fallback_transport": DriveLocationOutputMode.dvtBaseline.displayName,
        ]) { _, new in new }
      )
      return true
    } catch {
      activeTransport = nil
      activeOutputMode = nil
      activeUpdateCadence = nil
      await diagnostics.recordState(
        "transport_fallback_failed",
        message: "DVT Compatibility failed to take over after Rich Drive startup failure",
        metadata: fallbackMetadata(
          event: "TRANSPORT_FALLBACK_FAILED",
          reason: String(describing: error),
          position: position,
          oldWriterStopped: oldWriterStopped
        )
      )
      throw error
    }
  }

  private func makeScheduler(
    controller: DriveSessionController,
    transport: DriveLocationTransport,
    cadence: DriveUpdateCadence
  ) -> DriveScheduler {
    DriveScheduler(
      controller: controller,
      locationTransport: transport,
      diagnostics: diagnostics,
      clock: clock,
      updateCadence: cadence,
      observedProvider: { [weak verifier] in verifier?.latestObservation() },
      lifecycleProvider: { [background] in background.applicationLifecycleState() },
      backgroundActiveProvider: { [background] in background.isBackgroundSessionActive() },
      onAuthoritativePosition: { [weak self] position, _, _ in
        Task { @MainActor [weak self] in
          self?.lastAuthoritativePosition = position
        }
      },
      onTransportFallbackNeeded: { [weak self] request in
        Task { @MainActor [weak self] in
          await self?.handleTransportFallback(request)
        }
      },
      onCadenceFallbackNeeded: { [weak self] request in
        Task { @MainActor [weak self] in
          await self?.handleCadenceFallback(request)
        }
      }
    )
  }

  private func handleTransportFallback(_ request: DriveTransportFallbackRequest) async {
    guard !transitionInProgress, !didFallbackTransportThisSession,
      !clearRequested,
      activeOutputMode == .richXCUILocationExperimental,
      let controller,
      let oldTransport = activeTransport
    else { return }
    transitionInProgress = true
    didFallbackTransportThisSession = true
    let transitionStart = ProcessInfo.processInfo.systemUptime

    scheduler?.stop()
    await scheduler?.waitUntilStopped()
    scheduler = nil
    controller.pauseForTransition(position: request.position, now: clock.nowSeconds())

    await diagnostics.recordState(
      "transport_fallback_triggered",
      message: "Rich Drive became unavailable; falling back to DVT Compatibility",
      metadata: fallbackMetadata(
        event: "TRANSPORT_FALLBACK_TRIGGERED",
        reason: request.reason,
        position: request.position,
        oldWriterStopped: false
      ).merging([
        "first_error": request.errorDescription ?? request.reason,
        "failing_transport": request.transportName,
      ]) { _, new in new }
    )

    var oldWriterStopped = false
    do {
      activeTransport = nil
      try await oldTransport.stop(writerID: controller.writerID, clearLocation: false)
      oldWriterStopped = true
      guard !clearRequested else {
        transitionInProgress = false
        return
      }

      let dvt = makeTransport(for: .dvtBaseline)
      try await dvt.start(
        DriveLocationTransportStartContext(
          sessionID: controller.sessionID,
          writerID: controller.writerID,
          initialCoordinate: request.position.coordinate
        ))
      activeTransport = dvt
      activeOutputMode = .dvtBaseline
      activeUpdateCadence = activeUpdateCadence ?? updateCadence
      fallbackNotice = "Rich Drive unavailable. Using DVT Compatibility."
      try await writeAuthoritativePosition(
        request.position,
        speedMetersPerSecond: controller.snapshot(now: clock.nowSeconds()).speedMetersPerSecond,
        transport: dvt,
        reason: "transport_runtime_fallback_takeover"
      )
      controller.resume(now: clock.nowSeconds())
      let newScheduler = makeScheduler(
        controller: controller,
        transport: dvt,
        cadence: activeUpdateCadence ?? updateCadence
      )
      scheduler = newScheduler
      newScheduler.start()
      transitionInProgress = false
      await diagnostics.recordState(
        "transport_fallback_completed",
        message: "DVT Compatibility took over from Rich Drive",
        metadata: fallbackMetadata(
          event: "TRANSPORT_FALLBACK_COMPLETED",
          reason: request.reason,
          position: request.position,
          oldWriterStopped: oldWriterStopped
        ).merging([
          "transition_duration_ms": String(format: "%.3f", max(0, ProcessInfo.processInfo.systemUptime - transitionStart) * 1000),
          "fallback_transport": DriveLocationOutputMode.dvtBaseline.displayName,
          "successful_dvt_takeover": "true",
        ]) { _, new in new }
      )
      await refresh()
    } catch {
      transitionInProgress = false
      activeTransport = nil
      activeOutputMode = nil
      activeUpdateCadence = nil
      background.end(reason: "transport fallback failed")
      background.setDiagnostics(nil)
      verifier.stop()
      fail(error, operation: "transportFallback")
      await diagnostics.recordState(
        "transport_fallback_failed",
        message: "DVT Compatibility failed to take over from Rich Drive",
        metadata: fallbackMetadata(
          event: "TRANSPORT_FALLBACK_FAILED",
          reason: String(describing: error),
          position: request.position,
          oldWriterStopped: oldWriterStopped
        )
      )
      await refresh()
    }
  }

  private func handleCadenceFallback(_ request: DriveCadenceFallbackRequest) async {
    guard !transitionInProgress, !didFallbackCadenceThisSession,
      !clearRequested,
      request.activeCadence == .smooth2Hz,
      let controller,
      let transport = activeTransport
    else { return }
    transitionInProgress = true
    didFallbackCadenceThisSession = true
    let transitionStart = ProcessInfo.processInfo.systemUptime

    scheduler?.stop()
    await scheduler?.waitUntilStopped()
    scheduler = nil
    controller.pauseForTransition(position: request.position, now: clock.nowSeconds())
    await diagnostics.recordState(
      "cadence_fallback_triggered",
      message: "Smooth 2 Hz became unhealthy; falling back to Baseline 1 Hz Compatibility",
      metadata: fallbackMetadata(
        event: "CADENCE_FALLBACK_TRIGGERED",
        reason: request.reason,
        position: request.position,
        oldWriterStopped: true
      ).merging([
        "previous_cadence": request.activeCadence.diagnosticName,
        "fallback_cadence": DriveUpdateCadence.baseline1Hz.diagnosticName,
        "active_transport": request.transportName,
      ]) { _, new in new }
    )

    activeUpdateCadence = .baseline1Hz
    fallbackNotice = "\(fallbackNotice.map { "\($0) " } ?? "")Using Baseline 1 Hz Compatibility."
    guard !clearRequested else {
      transitionInProgress = false
      return
    }
    try? await writeAuthoritativePosition(
      request.position,
      speedMetersPerSecond: controller.snapshot(now: clock.nowSeconds()).speedMetersPerSecond,
      transport: transport,
      reason: "cadence_fallback_segment_start"
    )
    controller.resume(now: clock.nowSeconds())
    let newScheduler = makeScheduler(controller: controller, transport: transport, cadence: .baseline1Hz)
    scheduler = newScheduler
    newScheduler.start()
    transitionInProgress = false
    await diagnostics.recordState(
      "cadence_fallback_completed",
      message: "Baseline 1 Hz Compatibility resumed from the current route position",
      metadata: fallbackMetadata(
        event: "CADENCE_FALLBACK_COMPLETED",
        reason: request.reason,
        position: request.position,
        oldWriterStopped: true
      ).merging([
        "transition_duration_ms": String(format: "%.3f", max(0, ProcessInfo.processInfo.systemUptime - transitionStart) * 1000),
        "active_cadence": DriveUpdateCadence.baseline1Hz.diagnosticName,
      ]) { _, new in new }
    )
    await refresh()
  }

  private func writeAuthoritativePosition(
    _ position: DrivePosition,
    speedMetersPerSecond: Double,
    transport: DriveLocationTransport,
    reason: String
  ) async throws {
    guard let route = controller?.routeResampler(), let controller else { return }
    let sample = RichDriveSampleBuilder.sample(
      position: position,
      route: route,
      speedMetersPerSecond: speedMetersPerSecond,
      previousCourseDegrees: nil
    )
    let requestTime = ProcessInfo.processInfo.systemUptime
    let context = DriveTraceContext(
      tickTraceID: "\(controller.sessionID.uuidString):\(reason)",
      driveSessionID: controller.sessionID.uuidString,
      tickSequence: 0,
      requestSequence: 0,
      updateRequestMonotonicTime: requestTime,
      expectedRouteDistanceMeters: position.expectedDistanceMeters,
      previousExpectedRouteDistanceMeters: nil,
      expectedCoordinate: position.coordinate,
      selectedSpeedMetersPerSecond: speedMetersPerSecond,
      lifecycleState: background.applicationLifecycleState()
    )
    let result = try await transport.set(
      sample: sample,
      writerID: controller.writerID,
      mode: .drive(sessionID: controller.sessionID, current: SimulatedCoordinate(position.coordinate)),
      traceContext: context,
      diagnostics: diagnostics
    )
    lastAuthoritativePosition = position
    await diagnostics.recordRichDriveTransportSet(context: context, sample: sample, result: result)
  }

  private func fallbackMetadata(
    event: String,
    reason: String,
    position: DrivePosition,
    oldWriterStopped: Bool
  ) -> [String: String] {
    [
      "event": event,
      "fallback_reason": reason,
      "route_progress_m": String(format: "%.3f", position.expectedDistanceMeters),
      "latitude": String(format: "%.6f", position.coordinate.latitude),
      "longitude": String(format: "%.6f", position.coordinate.longitude),
      "active_transport": activeOutputMode?.displayName ?? outputMode.displayName,
      "active_cadence": (activeUpdateCadence ?? updateCadence).diagnosticName,
      "old_writer_confirmed_stopped": "\(oldWriterStopped)",
      "timestamp": ISO8601DateFormatter().string(from: Date()),
    ]
  }

  func pause() {
    guard let controller else { return }
    guard controller.currentState() == .driving else { return }
    _ = controller.pause(now: clock.nowSeconds())
    state = controller.currentState()
    Task {
      await diagnostics.recordState("paused", message: "drive paused")
      await refresh()
    }
  }

  func resume() {
    guard let controller else { return }
    let previousState = controller.currentState()
    guard previousState == .paused || previousState == .holding else { return }
    controller.resume(now: clock.nowSeconds())
    state = controller.currentState()
    if previousState == .holding, let activeTransport, scheduler == nil {
      background.setDiagnostics(diagnostics)
      background.begin()
      if let position = controller.expectedPosition(now: clock.nowSeconds()) {
        verifier.setRequestedCoordinate(
          latitude: position.coordinate.latitude,
          longitude: position.coordinate.longitude
        )
      }
      verifier.start(backgroundCapable: true)
      let newScheduler = makeScheduler(
        controller: controller,
        transport: activeTransport,
        cadence: activeUpdateCadence ?? updateCadence
      )
      scheduler = newScheduler
      newScheduler.start()
    }
    Task {
      await diagnostics.recordState("driving", message: "drive resumed")
      await refresh()
    }
  }

  func stopAndHold() {
    Task {
      guard let controller, let activeTransport else { return }
      scheduler?.stop()
      await scheduler?.waitUntilStopped()
      scheduler = nil
      let position = lastAuthoritativePosition
        ?? controller.holdCurrent(now: clock.nowSeconds())
      guard let position else { return }
      controller.hold(position: position)
      do {
        try await writeAuthoritativePosition(
          position,
          speedMetersPerSecond: 0,
          transport: activeTransport,
          reason: "stop_and_hold"
        )
        status = "Holding Location"
        state = controller.currentState()
        background.end(reason: "drive stop and hold")
        background.setDiagnostics(nil)
        verifier.stop()
        await diagnostics.recordState(
          "holding",
          message: "drive stopped and current simulated coordinate is held",
          metadata: fallbackMetadata(
            event: "DRIVE_STOP_AND_HOLD",
            reason: "user_requested_stop_and_hold",
            position: position,
            oldWriterStopped: false
          ))
      } catch {
        fail(error, operation: "stopAndHold")
      }
      await refresh()
    }
  }

  func clearSimulation() {
    Task {
      let activeController = controller
      let writerID = activeController?.writerID
      clearRequested = true
      scheduler?.stop()
      await scheduler?.waitUntilStopped()
      scheduler = nil
      activeController?.stop(clearSimulation: true)

      var clearSucceeded = true
      do {
        if let activeTransport, let writerID {
          try await activeTransport.stop(writerID: writerID, clearLocation: true)
        } else if let writerID {
          try await coordinator.stopSimulation(writerID: writerID, clearLocation: true)
        }
      } catch let error as POCError where error.code == .staleWriter {
        clearSucceeded = true
      } catch {
        clearSucceeded = false
        fail(error, operation: "clearSimulation")
      }

      activeTransport = nil
      activeOutputMode = nil
      activeUpdateCadence = nil
      lastAuthoritativePosition = nil
      fallbackNotice = nil
      transitionInProgress = false
      background.end(reason: "drive clear simulation")
      background.setDiagnostics(nil)
      verifier.stop()
      if clearSucceeded {
        status = "Simulation cleared. Real Core Location can resume."
      }
      await diagnostics.recordState(
        "stopped",
        message: "drive simulation explicitly cleared",
        metadata: [
          "event": "DRIVE_CLEAR_SIMULATION",
          "clear_succeeded": "\(clearSucceeded)",
          "active_transport": activeOutputMode?.displayName ?? "none",
          "active_cadence": activeUpdateCadence?.diagnosticName ?? "none",
        ])
      _ = await diagnostics.finalizeSummary()
      state = activeController?.currentState() ?? .stopped
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

  var activeModeText: String {
    "\(activeOutputMode?.displayName ?? outputMode.displayName) - \((activeUpdateCadence ?? updateCadence).displayName)"
  }

  var isFallbackActive: Bool {
    activeOutputMode == .dvtBaseline && outputMode == .richXCUILocationExperimental
      || activeUpdateCadence == .baseline1Hz && updateCadence == .smooth2Hz
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
    lastTechnicalError =
      "operation=\(operation) domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)"
  }

  private func display(_ error: Error) -> String {
    if let error = error as? POCError {
      return HumanReadableError.describe(code: error.code.rawValue, detail: error.message)
    }
    let nsError = error as NSError
    if nsError.domain == kCLErrorDomain {
      switch CLError.Code(rawValue: nsError.code) {
      case .denied:
        return
          "Location access is off for IOSSim. Enable it in Settings > Privacy > Location Services."
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

  private func makeTransport(for mode: DriveLocationOutputMode) -> DriveLocationTransport {
    switch mode {
    case .dvtBaseline:
      return DVTDriveLocationTransport(locationCoordinator: coordinator)
    case .richXCUILocationExperimental:
      return LatestSampleDriveLocationTransport(
        base: XCTestRichDriveLocationTransport(
          locationCoordinator: coordinator,
          runnerClient: POCAppDependencies.tunnelClient
        )
      )
    }
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
        case .driving, .paused, .holding, .completedHolding:
          activeDriveCard
        }
        Spacer()
      }
      .padding()
    }
    .navigationTitle("Drive")
    .navigationBarTitleDisplayMode(.inline)
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
        Label(
          model.startQuery.isEmpty ? "Current Location" : model.startQuery,
          systemImage: "circle.fill"
        )
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

      if model.status.hasPrefix("FAIL") {
        Label(model.status, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.red)
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
          .fill(model.state == .paused ? Color.orange : model.state == .driving ? Color.green : Color.blue)
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
      VStack(spacing: 10) {
        if model.state == .paused {
          Button {
            model.resume()
          } label: {
            Label("Resume", systemImage: "play.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
        } else if model.state == .holding {
          Button {
            model.resume()
          } label: {
            Label("Resume Drive", systemImage: "play.fill")
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

        if model.state == .driving || model.state == .paused {
          Button {
            model.stopAndHold()
          } label: {
            Label("Stop & Hold", systemImage: "pause.circle.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
        }

        Button(role: .destructive) {
          model.clearSimulation()
        } label: {
          Label("Clear Simulation", systemImage: "xmark.circle.fill")
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
    case .holding: return "Holding Location"
    case .completedHolding: return "Arrived — Holding Location"
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
        LabeledContent("Drive Output", value: model.outputMode.displayName)
        LabeledContent("Transport Detail", value: model.outputMode.developerDetail)
        LabeledContent("Playback Cadence", value: model.updateCadence.displayName)
        LabeledContent("Active Mode", value: model.activeModeText)
        if let fallbackNotice = model.fallbackNotice {
          LabeledContent("Fallback", value: fallbackNotice)
        }
        LabeledContent("Estimated step", value: model.expectedDistancePerUpdateText)
      }

      Section("Rich Drive Requirements") {
        Text("Developer Mode, LocalDevVPN, saved RPPairing, a preinstalled signed XCTest runner, and developer-service availability are required for Rich Drive.")
          .font(.caption)
      }

      Section("Debug Metrics") {
        LabeledContent("Lifecycle", value: model.liveMetrics.lifecycleState)
        LabeledContent("Scheduler interval", value: ms(model.liveMetrics.lastSchedulerIntervalMs))
        LabeledContent("Scheduler jitter", value: ms(model.liveMetrics.lastSchedulerJitterMs))
        LabeledContent("DVT set latency", value: ms(model.liveMetrics.lastDVTSetLatencyMs))
        LabeledContent("CL latency", value: ms(model.liveMetrics.lastCoreLocationLatencyMs))
        LabeledContent("Selected speed", value: mps(model.liveMetrics.selectedSpeedMps))
        LabeledContent("CLLocation.speed", value: mps(model.liveMetrics.lastCLLocationSpeedMps))
        LabeledContent(
          "Observed geometric speed", value: mps(model.liveMetrics.lastObservedGeometricSpeedMps))
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
        Button("STOP & HOLD") { model.stopAndHold() }
        Button("CLEAR SIMULATION", role: .destructive) { model.clearSimulation() }
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
