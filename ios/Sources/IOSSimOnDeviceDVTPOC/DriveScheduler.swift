import CoreLocation
import Foundation

public final class DriveScheduler: @unchecked Sendable {
    private let controller: DriveSessionController
    private let locationCoordinator: LocationCoordinator
    private let diagnostics: DriveDiagnostics
    private let clock: DriveClock
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
        cadenceSeconds: TimeInterval = 1,
        observedProvider: @escaping @Sendable () -> LocationObservation? = { nil },
        lifecycleProvider: @escaping @Sendable () -> String = { "unknown" },
        backgroundActiveProvider: @escaping @Sendable () -> Bool = { false }
    ) {
        self.controller = controller
        self.locationCoordinator = locationCoordinator
        self.diagnostics = diagnostics
        self.clock = clock
        self.cadenceSeconds = cadenceSeconds
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

        while !Task.isCancelled {
            let now = clock.nowSeconds()
            guard let position = controller.expectedPosition(now: now) else {
                try? await clock.sleep(seconds: cadenceSeconds)
                continue
            }

            if controller.currentState() == .driving || controller.currentState() == .completedHolding {
                await send(position: position, now: now)
            }

            if position.completed, controller.currentState() == .driving {
                _ = controller.completeHolding(now: now)
                await diagnostics.recordState("completed_holding", message: "route completed; destination held until explicit stop")
                break
            }

            do {
                try await clock.sleep(seconds: cadenceSeconds)
            } catch {
                break
            }
        }
    }

    private func send(position: DrivePosition, now: TimeInterval) async {
        sequenceNumber += 1
        tickNumber += 1
        let coordinate = position.coordinate
        let lifecycleState = lifecycleProvider()
        let generation = await locationCoordinator.currentConnectionGeneration()
        let start = firstTickClockTime ?? now
        firstTickClockTime = start
        let actualTickOffset = max(0, now - start)
        let expectedTickOffset = Double(max(0, tickNumber - 1)) * cadenceSeconds
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
            targetIntervalSeconds: cadenceSeconds
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
