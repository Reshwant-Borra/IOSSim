import CoreLocation
import Foundation

public final class DriveScheduler: @unchecked Sendable {
  private let controller: DriveSessionController
  private let locationTransport: DriveLocationTransport
  private let diagnostics: DriveDiagnostics
  private let clock: DriveClock
  private let updateCadence: DriveUpdateCadence
  private let cadenceSeconds: TimeInterval
  private let observedProvider: @Sendable () -> LocationObservation?
  private let lifecycleProvider: @Sendable () -> String
  private let backgroundActiveProvider: @Sendable () -> Bool
  private let onAuthoritativePosition: @Sendable (DrivePosition, RichDriveSample, DriveLocationTransportSetResult) async -> Void
  private let onTransportFallbackNeeded: @Sendable (DriveTransportFallbackRequest) -> Void
  private let onCadenceFallbackNeeded: @Sendable (DriveCadenceFallbackRequest) -> Void

  private let lock = NSLock()
  private var task: RunningTask?
  private var sequenceNumber = 0
  private var tickNumber = 0
  private var firstTickClockTime: TimeInterval?
  private var previousActualTickOffset: TimeInterval?
  private var previousExpectedDistanceForDiagnostics: CLLocationDistance?
  private var previousExpectedCoordinateForDiagnostics: CLLocationCoordinate2D?
  private var previousRichCourseDegrees: Double?
  private var transportHealth = DriveTransportHealthPolicy()
  private var cadenceHealth = DriveCadenceHealthPolicy()
  private var fallbackRequested = false

  public init(
    controller: DriveSessionController,
    locationCoordinator: LocationCoordinator,
    diagnostics: DriveDiagnostics,
    clock: DriveClock = ContinuousDriveClock(),
    updateCadence: DriveUpdateCadence = .baseline1Hz,
    observedProvider: @escaping @Sendable () -> LocationObservation? = { nil },
    lifecycleProvider: @escaping @Sendable () -> String = { "unknown" },
    backgroundActiveProvider: @escaping @Sendable () -> Bool = { false },
    onAuthoritativePosition: @escaping @Sendable (DrivePosition, RichDriveSample, DriveLocationTransportSetResult) async -> Void = { _, _, _ in },
    onTransportFallbackNeeded: @escaping @Sendable (DriveTransportFallbackRequest) -> Void = { _ in },
    onCadenceFallbackNeeded: @escaping @Sendable (DriveCadenceFallbackRequest) -> Void = { _ in }
  ) {
    self.controller = controller
    self.locationTransport = DVTDriveLocationTransport(locationCoordinator: locationCoordinator)
    self.diagnostics = diagnostics
    self.clock = clock
    self.updateCadence = updateCadence
    self.cadenceSeconds = updateCadence.intervalSeconds
    self.observedProvider = observedProvider
    self.lifecycleProvider = lifecycleProvider
    self.backgroundActiveProvider = backgroundActiveProvider
    self.onAuthoritativePosition = onAuthoritativePosition
    self.onTransportFallbackNeeded = onTransportFallbackNeeded
    self.onCadenceFallbackNeeded = onCadenceFallbackNeeded
  }

  public init(
    controller: DriveSessionController,
    locationTransport: DriveLocationTransport,
    diagnostics: DriveDiagnostics,
    clock: DriveClock = ContinuousDriveClock(),
    updateCadence: DriveUpdateCadence = .baseline1Hz,
    observedProvider: @escaping @Sendable () -> LocationObservation? = { nil },
    lifecycleProvider: @escaping @Sendable () -> String = { "unknown" },
    backgroundActiveProvider: @escaping @Sendable () -> Bool = { false },
    onAuthoritativePosition: @escaping @Sendable (DrivePosition, RichDriveSample, DriveLocationTransportSetResult) async -> Void = { _, _, _ in },
    onTransportFallbackNeeded: @escaping @Sendable (DriveTransportFallbackRequest) -> Void = { _ in },
    onCadenceFallbackNeeded: @escaping @Sendable (DriveCadenceFallbackRequest) -> Void = { _ in }
  ) {
    self.controller = controller
    self.locationTransport = locationTransport
    self.diagnostics = diagnostics
    self.clock = clock
    self.updateCadence = updateCadence
    self.cadenceSeconds = updateCadence.intervalSeconds
    self.observedProvider = observedProvider
    self.lifecycleProvider = lifecycleProvider
    self.backgroundActiveProvider = backgroundActiveProvider
    self.onAuthoritativePosition = onAuthoritativePosition
    self.onTransportFallbackNeeded = onTransportFallbackNeeded
    self.onCadenceFallbackNeeded = onCadenceFallbackNeeded
  }

  public func start() {
    let taskID = UUID()
    let newTask = Task { [weak self] in
      await self?.run()
      self?.markTaskFinished(id: taskID)
    }
    lock.lock()
    guard task == nil else {
      lock.unlock()
      newTask.cancel()
      return
    }
    task = RunningTask(id: taskID, task: newTask)
    lock.unlock()
  }

  public func stop() {
    lock.lock()
    task?.task.cancel()
    lock.unlock()
  }

  public func waitUntilStopped() async {
    let running = currentTask()
    await running?.task.value
    if let running {
      clearTaskIfCurrent(id: running.id)
    }
  }

  private func currentTask() -> RunningTask? {
    lock.lock()
    defer { lock.unlock() }
    return task
  }

  private func markTaskFinished(id: UUID) {
    clearTaskIfCurrent(id: id)
  }

  private func clearTaskIfCurrent(id: UUID) {
    lock.lock()
    if task?.id == id {
      task = nil
    }
    lock.unlock()
  }

  private func run() async {
    await locationTransport.setReconnectRestoreProvider(writerID: controller.writerID) {
      [weak self, controller, clock] in
      guard let self,
        let route = controller.routeResampler(),
        let position = controller.expectedPosition(now: clock.nowSeconds())
      else { return nil }
      let snapshot = controller.snapshot(now: clock.nowSeconds())
      return self.richSample(
        position: position, route: route, speedMetersPerSecond: snapshot.speedMetersPerSecond)
    }

    var scheduleStart = clock.nowSeconds()
    var deadlineSequence = 0
    var wasRunnable = false

    while !Task.isCancelled {
      let state = controller.currentState()
      guard state == .driving else {
        wasRunnable = false
        resetSchedulerSegment()
        do {
          try await clock.sleep(until: clock.nowSeconds() + cadenceSeconds)
        } catch {
          break
        }
        continue
      }

      if !wasRunnable {
        scheduleStart = clock.nowSeconds()
        deadlineSequence = 0
        wasRunnable = true
        resetSchedulerSegment()
      }

      let deadline = DriveSchedulerTimeline.deadline(
        start: scheduleStart,
        sequence: deadlineSequence,
        intervalSeconds: cadenceSeconds
      )
      do {
        try await clock.sleep(until: deadline)
      } catch {
        break
      }

      let now = clock.nowSeconds()
      guard let position = controller.expectedPosition(now: now) else {
        wasRunnable = false
        continue
      }

      let expectedTickOffset = DriveSchedulerTimeline.deadlineOffset(
        sequence: deadlineSequence,
        intervalSeconds: cadenceSeconds
      )
      let missedDeadlines = DriveSchedulerTimeline.missedDeadlineCount(
        start: scheduleStart,
        intervalSeconds: cadenceSeconds,
        now: now,
        scheduledSequence: deadlineSequence
      )
      await send(
        position: position,
        now: now,
        scheduleStart: scheduleStart,
        expectedTickOffset: expectedTickOffset,
        missedDeadlines: missedDeadlines
      )

      if position.completed, controller.currentState() == .driving {
        let heldPosition = controller.completeHolding(now: now) ?? position
        await sendHeldDestination(position: heldPosition, now: now)
        await diagnostics.recordState(
          "completed_holding",
          message: "route completed; destination held until explicit clear",
          metadata: [
            "event": "DRIVE_DESTINATION_HELD",
            "active_transport": locationTransport.transportName,
            "active_cadence": updateCadence.diagnosticName,
            "route_progress_m": String(format: "%.3f", heldPosition.expectedDistanceMeters),
            "latitude": String(format: "%.6f", heldPosition.coordinate.latitude),
            "longitude": String(format: "%.6f", heldPosition.coordinate.longitude),
          ])
        break
      }

      deadlineSequence = DriveSchedulerTimeline.nextFutureSequence(
        start: scheduleStart,
        intervalSeconds: cadenceSeconds,
        now: clock.nowSeconds(),
        minimumSequence: deadlineSequence + 1
      )
    }
  }

  private func resetSchedulerSegment() {
    firstTickClockTime = nil
    previousActualTickOffset = nil
  }

  private func send(
    position: DrivePosition,
    now: TimeInterval,
    scheduleStart: TimeInterval,
    expectedTickOffset: TimeInterval,
    missedDeadlines: Int
  ) async {
    sequenceNumber += 1
    tickNumber += 1
    guard !Task.isCancelled else { return }
    let coordinate = position.coordinate
    let lifecycleState = lifecycleProvider()
    let generation = await locationTransport.currentConnectionGeneration()
    let start = firstTickClockTime ?? scheduleStart
    firstTickClockTime = start
    let actualTickOffset = max(0, now - start)
    let previousActualOffset = previousActualTickOffset
    let previousExpectedDistance = previousExpectedDistanceForDiagnostics
    let previousExpectedCoordinate = previousExpectedCoordinateForDiagnostics
    let tickTraceID = "\(controller.sessionID.uuidString):tick:\(tickNumber)"
    let snapshot = controller.snapshot(now: now)
    guard let route = controller.routeResampler() else {
      await diagnostics.recordState(
        "update_failed", message: "drive update failed: missing route resampler")
      return
    }
    let richSample = richSample(
      position: position,
      route: route,
      speedMetersPerSecond: snapshot.speedMetersPerSecond
    )
    let requestTime = ProcessInfo.processInfo.systemUptime
    let traceContext = DriveTraceContext(
      tickTraceID: tickTraceID,
      driveSessionID: controller.sessionID.uuidString,
      tickSequence: tickNumber,
      requestSequence: sequenceNumber,
      updateRequestMonotonicTime: requestTime,
      expectedRouteDistanceMeters: position.expectedDistanceMeters,
      previousExpectedRouteDistanceMeters: previousExpectedDistance,
      expectedCoordinate: coordinate,
      selectedSpeedMetersPerSecond: snapshot.speedMetersPerSecond,
      lifecycleState: lifecycleState
    )
    await diagnostics.recordSchedulerTick(
      tickTraceID: tickTraceID,
      tickSequence: tickNumber,
      monotonicTimestamp: requestTime,
      expectedTickOffset: expectedTickOffset,
      actualTickOffset: actualTickOffset,
      previousActualTickOffset: previousActualOffset,
      activeElapsedSeconds: position.activeElapsedSeconds,
      expectedRouteDistanceMeters: position.expectedDistanceMeters,
      previousExpectedRouteDistanceMeters: previousExpectedDistance,
      selectedSpeedMetersPerSecond: snapshot.speedMetersPerSecond,
      expectedCoordinate: coordinate,
      previousExpectedCoordinate: previousExpectedCoordinate,
      lifecycleState: lifecycleState,
      connectionGeneration: generation,
      updateCadence: updateCadence,
      missedDeadlineCount: missedDeadlines
    )
    guard !Task.isCancelled else { return }
    await diagnostics.recordCoordinatorUpdateRequested(
      context: traceContext,
      writerID: controller.writerID,
      connectionGeneration: generation
    )
    do {
      guard !Task.isCancelled else { return }
      let transportResult = try await locationTransport.submit(
        sample: richSample,
        writerID: controller.writerID,
        mode: .drive(sessionID: controller.sessionID, current: SimulatedCoordinate(coordinate)),
        traceContext: traceContext,
        diagnostics: diagnostics
      )
      guard !Task.isCancelled else { return }
      if transportResult.authoritative {
        await onAuthoritativePosition(position, richSample, transportResult)
        await diagnostics.recordRichDriveTransportSet(
          context: traceContext,
          sample: richSample,
          result: transportResult
        )
      }
      if !position.completed, locationTransport.transportName
        == DriveLocationOutputMode.richXCUILocationExperimental.displayName,
        let reason = transportHealth.recordSuccess(result: transportResult)
      {
        requestTransportFallback(
          reason: reason,
          errorDescription: nil,
          position: position
        )
        return
      }
      if !position.completed, let reason = cadenceHealth.record(
        sample: DriveCadenceHealthSample(
          missedDeadlineCount: missedDeadlines,
          ackLatencyMs: locationTransport.transportName
            == DriveLocationOutputMode.richXCUILocationExperimental.displayName
            ? transportResult.ackLatencyMs : nil,
          droppedOrReplacedSamples: transportResult.droppedOrReplacedSamples
        ),
        cadence: updateCadence
      ) {
        requestCadenceFallback(reason: reason, position: position)
        return
      }
      let updatedGeneration = await locationTransport.currentConnectionGeneration()
      await diagnostics.recordRequestedUpdate(
        sequenceNumber: sequenceNumber,
        tickNumber: tickNumber,
        monotonicElapsedTime: position.activeElapsedSeconds,
        connectionGeneration: updatedGeneration,
        expectedRouteDistanceMeters: position.expectedDistanceMeters,
        expectedCoordinate: coordinate,
        requestedCoordinate: coordinate,
        calculatedRouteSpeedMetersPerSecond: snapshot.speedMetersPerSecond,
        observed: observedProvider(),
        applicationLifecycleState: lifecycleState,
        backgroundSessionActive: backgroundActiveProvider(),
        tickTraceID: tickTraceID
      )
      await diagnostics.recordHeartbeat(
        expectedRouteDistance: position.expectedDistanceMeters,
        lifecycleState: lifecycleState,
        connectionGeneration: updatedGeneration
      )
      previousActualTickOffset = actualTickOffset
      previousExpectedDistanceForDiagnostics = position.expectedDistanceMeters
      previousExpectedCoordinateForDiagnostics = coordinate
    } catch {
      guard !Task.isCancelled else { return }
      await diagnostics.recordState(
        "update_failed",
        message: "drive update failed",
        metadata: ["error": String(describing: error)]
      )
      if locationTransport.transportName
        == DriveLocationOutputMode.richXCUILocationExperimental.displayName,
        let reason = transportHealth.recordFailure(error)
      {
        requestTransportFallback(
          reason: reason,
          errorDescription: String(describing: error),
          position: position
        )
        return
      }
      await locationTransport.reconnectIfNeeded()
    }
  }

  private func sendHeldDestination(position: DrivePosition, now: TimeInterval) async {
    guard !Task.isCancelled else { return }
    guard let route = controller.routeResampler() else { return }
    let heldSample = RichDriveSampleBuilder.sample(
      position: position,
      route: route,
      speedMetersPerSecond: 0,
      previousCourseDegrees: previousRichCourseDegrees
    )
    let requestTime = ProcessInfo.processInfo.systemUptime
    let traceContext = DriveTraceContext(
      tickTraceID: "\(controller.sessionID.uuidString):destination-held",
      driveSessionID: controller.sessionID.uuidString,
      tickSequence: tickNumber,
      requestSequence: sequenceNumber + 1,
      updateRequestMonotonicTime: requestTime,
      expectedRouteDistanceMeters: position.expectedDistanceMeters,
      previousExpectedRouteDistanceMeters: previousExpectedDistanceForDiagnostics,
      expectedCoordinate: position.coordinate,
      selectedSpeedMetersPerSecond: 0,
      lifecycleState: lifecycleProvider()
    )
    do {
      guard !Task.isCancelled else { return }
      let result = try await locationTransport.set(
        sample: heldSample,
        writerID: controller.writerID,
        mode: .drive(sessionID: controller.sessionID, current: SimulatedCoordinate(position.coordinate)),
        traceContext: traceContext,
        diagnostics: diagnostics
      )
      guard !Task.isCancelled else { return }
      await onAuthoritativePosition(position, heldSample, result)
      await diagnostics.recordRichDriveTransportSet(context: traceContext, sample: heldSample, result: result)
    } catch {
      await diagnostics.recordState(
        "destination_hold_update_failed",
        message: "stationary destination hold update failed",
        metadata: ["error": String(describing: error)]
      )
    }
  }

  private func requestTransportFallback(
    reason: String,
    errorDescription: String?,
    position: DrivePosition
  ) {
    guard !fallbackRequested else { return }
    fallbackRequested = true
    onTransportFallbackNeeded(
      DriveTransportFallbackRequest(
        reason: reason,
        errorDescription: errorDescription,
        position: position,
        transportName: locationTransport.transportName,
        routeProgressMeters: position.expectedDistanceMeters
      ))
  }

  private func requestCadenceFallback(reason: String, position: DrivePosition) {
    guard !fallbackRequested, updateCadence == .smooth2Hz else { return }
    fallbackRequested = true
    onCadenceFallbackNeeded(
      DriveCadenceFallbackRequest(
        reason: reason,
        position: position,
        activeCadence: updateCadence,
        transportName: locationTransport.transportName,
        routeProgressMeters: position.expectedDistanceMeters
      ))
  }

  private func richSample(
    position: DrivePosition,
    route: RouteResampler,
    speedMetersPerSecond: Double
  ) -> RichDriveSample {
    let sample = RichDriveSampleBuilder.sample(
      position: position,
      route: route,
      speedMetersPerSecond: speedMetersPerSecond,
      previousCourseDegrees: previousRichCourseDegrees
    )
    previousRichCourseDegrees = sample.courseDegrees
    return sample
  }
}

private struct RunningTask: Sendable {
  let id: UUID
  let task: Task<Void, Never>
}
