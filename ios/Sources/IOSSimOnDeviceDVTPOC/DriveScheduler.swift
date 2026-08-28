import CoreLocation
import Foundation

public final class DriveScheduler: @unchecked Sendable {
    private let controller: DriveSessionController
    private let locationCoordinator: LocationCoordinator
    private let diagnostics: DriveDiagnostics
    private let clock: DriveClock
    private let updateCadence: DriveUpdateCadence
    private let cadenceSeconds: TimeInterval
    private let observedProvider: @Sendable () -> LocationObservation?
    private let lifecycleProvider: @Sendable () -> String
    private let backgroundActiveProvider: @Sendable () -> Bool

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var sequenceNumber = 0
    private var tickNumber = 0
    private var firstTickClockTime: TimeInterval?
    private var previousActualTickOffset: TimeInterval?
    private var previousExpectedDistanceForDiagnostics: CLLocationDistance?
    private var previousExpectedCoordinateForDiagnostics: CLLocationCoordinate2D?

    public init(
        controller: DriveSessionController,
        locationCoordinator: LocationCoordinator,
        diagnostics: DriveDiagnostics,
        clock: DriveClock = ContinuousDriveClock(),
        updateCadence: DriveUpdateCadence = .baseline1Hz,
        observedProvider: @escaping @Sendable () -> LocationObservation? = { nil },
        lifecycleProvider: @escaping @Sendable () -> String = { "unknown" },
        backgroundActiveProvider: @escaping @Sendable () -> Bool = { false }
    ) {
        self.controller = controller
        self.locationCoordinator = locationCoordinator
        self.diagnostics = diagnostics
        self.clock = clock
        self.updateCadence = updateCadence
        self.cadenceSeconds = updateCadence.intervalSeconds
        self.observedProvider = observedProvider
        self.lifecycleProvider = lifecycleProvider
        self.backgroundActiveProvider = backgroundActiveProvider
    }

    public func start() {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            return
        }
        task = Task { [weak self] in
            await self?.run()
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    public func waitUntilStopped() async {
        let running = currentTask()
        await running?.value
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func run() async {
        await locationCoordinator.setReconnectRestoreProvider(writerID: controller.writerID) { [controller, clock] in
            guard let position = controller.expectedPosition(now: clock.nowSeconds()) else { return nil }
            return SimulatedCoordinate(position.coordinate)
        }

        var scheduleStart = clock.nowSeconds()
        var deadlineSequence = 0
        var wasRunnable = false

        while !Task.isCancelled {
            let state = controller.currentState()
            guard state == .driving || state == .completedHolding else {
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
                _ = controller.completeHolding(now: now)
                await diagnostics.recordState("completed_holding", message: "route completed; destination held until explicit stop")
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
        let coordinate = position.coordinate
        let lifecycleState = lifecycleProvider()
        let generation = await locationCoordinator.currentConnectionGeneration()
        let start = firstTickClockTime ?? scheduleStart
        firstTickClockTime = start
        let actualTickOffset = max(0, now - start)
        let previousActualOffset = previousActualTickOffset
        let previousExpectedDistance = previousExpectedDistanceForDiagnostics
        let previousExpectedCoordinate = previousExpectedCoordinateForDiagnostics
        let tickTraceID = "\(controller.sessionID.uuidString):tick:\(tickNumber)"
        let snapshot = controller.snapshot(now: now)
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
        await diagnostics.recordCoordinatorUpdateRequested(
            context: traceContext,
            writerID: controller.writerID,
            connectionGeneration: generation
        )
        do {
            try await locationCoordinator.updateLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                writerID: controller.writerID,
                mode: .drive(sessionID: controller.sessionID, current: SimulatedCoordinate(coordinate)),
                traceContext: traceContext,
                driveDiagnostics: diagnostics
            )
            let updatedGeneration = await locationCoordinator.currentConnectionGeneration()
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
            await diagnostics.recordState(
                "update_failed",
                message: "drive update failed",
                metadata: ["error": String(describing: error)]
            )
            await locationCoordinator.reconnectIfNeeded()
        }
    }
}
