import CoreLocation
import Foundation

public enum DriveSessionState: String, Codable, Equatable, Sendable {
    case idle
    case routeReady
    case driving
    case paused
    case holding
    case completedHolding
    case stopped
}

public struct DriveRoute: Sendable {
    public let origin: CLLocationCoordinate2D
    public let destination: CLLocationCoordinate2D
    public let resampler: RouteResampler
    public let routeDistanceMeters: CLLocationDistance
    public let expectedTravelTime: TimeInterval

    public init(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        resampler: RouteResampler,
        routeDistanceMeters: CLLocationDistance? = nil,
        expectedTravelTime: TimeInterval = 0
    ) {
        self.origin = origin
        self.destination = destination
        self.resampler = resampler
        self.routeDistanceMeters = routeDistanceMeters ?? resampler.totalDistanceMeters
        self.expectedTravelTime = expectedTravelTime
    }
}

public struct DrivePosition: Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let expectedDistanceMeters: CLLocationDistance
    public let activeElapsedSeconds: TimeInterval
    public let completed: Bool

    public init(
        coordinate: CLLocationCoordinate2D,
        expectedDistanceMeters: CLLocationDistance,
        activeElapsedSeconds: TimeInterval,
        completed: Bool
    ) {
        self.coordinate = coordinate
        self.expectedDistanceMeters = expectedDistanceMeters
        self.activeElapsedSeconds = activeElapsedSeconds
        self.completed = completed
    }
}

public final class DriveSessionController: @unchecked Sendable {
    public let sessionID: UUID
    public let writerID: String

    private let lock = NSLock()
    private var route: DriveRoute?
    private var state: DriveSessionState = .idle
    private var speedMetersPerSecond: Double = DriveSpeed.metersPerSecond(fromMPH: 35)
    private var selectedSpeedMPH: Double = 35
    private var driveStartInstant: TimeInterval?
    private var accumulatedPausedDuration: TimeInterval = 0
    private var pauseStartedInstant: TimeInterval?
    private var pausedPosition: DrivePosition?
    private var previousExpectedDistance: CLLocationDistance = 0

    public init(sessionID: UUID = UUID(), writerID: String? = nil) {
        self.sessionID = sessionID
        self.writerID = writerID ?? "drive:\(sessionID.uuidString)"
    }

    public func prepareRoute(_ route: DriveRoute, speedMPH: Double) {
        lock.lock()
        self.route = route
        selectedSpeedMPH = min(max(speedMPH, DriveSpeed.minimumMPH), DriveSpeed.maximumMPH)
        speedMetersPerSecond = DriveSpeed.metersPerSecond(fromMPH: selectedSpeedMPH)
        state = .routeReady
        driveStartInstant = nil
        accumulatedPausedDuration = 0
        pauseStartedInstant = nil
        previousExpectedDistance = 0
        pausedPosition = DrivePosition(
            coordinate: route.origin,
            expectedDistanceMeters: 0,
            activeElapsedSeconds: 0,
            completed: false
        )
        lock.unlock()
    }

    public func startDrive(now: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        guard route != nil else {
            throw POCError(.invalidRoute, "Prepare a route before starting Drive Mode.")
        }
        guard state == .routeReady || state == .stopped else {
            throw POCError(.invalidDriveState, "Drive Mode cannot start from state \(state.rawValue).")
        }
        state = .driving
        driveStartInstant = now
        accumulatedPausedDuration = 0
        pauseStartedInstant = nil
        previousExpectedDistance = 0
    }

    public func pause(now: TimeInterval) -> DrivePosition? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .driving else { return pausedPosition }
        let position = expectedPositionLocked(now: now)
        pausedPosition = position
        pauseStartedInstant = now
        state = .paused
        return position
    }

    public func resume(now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if state == .paused, let pauseStartedInstant {
            accumulatedPausedDuration += max(0, now - pauseStartedInstant)
        } else if state == .holding {
            let activeElapsedAtHold = speedMetersPerSecond > 0
                ? previousExpectedDistance / speedMetersPerSecond
                : 0
            driveStartInstant = now - activeElapsedAtHold
            accumulatedPausedDuration = 0
        } else {
            return
        }
        pauseStartedInstant = nil
        state = .driving
    }

    public func holdCurrent(now: TimeInterval) -> DrivePosition? {
        lock.lock()
        defer { lock.unlock() }
        guard route != nil else { return nil }
        let position = expectedPositionLocked(now: now)
        pausedPosition = position
        driveStartInstant = nil
        pauseStartedInstant = nil
        accumulatedPausedDuration = 0
        state = .holding
        return position
    }

    public func hold(position: DrivePosition) {
        lock.lock()
        pausedPosition = position
        previousExpectedDistance = position.expectedDistanceMeters
        driveStartInstant = nil
        pauseStartedInstant = nil
        accumulatedPausedDuration = 0
        state = position.completed ? .completedHolding : .holding
        lock.unlock()
    }

    public func pauseForTransition(position: DrivePosition, now: TimeInterval) {
        lock.lock()
        pausedPosition = position
        previousExpectedDistance = position.expectedDistanceMeters
        pauseStartedInstant = now
        state = .paused
        lock.unlock()
    }

    public func completeHolding(now: TimeInterval) -> DrivePosition? {
        lock.lock()
        defer { lock.unlock() }
        guard let route else { return nil }
        let position = DrivePosition(
            coordinate: route.destination,
            expectedDistanceMeters: route.routeDistanceMeters,
            activeElapsedSeconds: activeElapsedLocked(now: now),
            completed: true
        )
        pausedPosition = position
        previousExpectedDistance = route.routeDistanceMeters
        state = .completedHolding
        return position
    }

    public func stop(clearSimulation: Bool) {
        lock.lock()
        state = .stopped
        driveStartInstant = nil
        pauseStartedInstant = nil
        accumulatedPausedDuration = 0
        if clearSimulation {
            pausedPosition = nil
            previousExpectedDistance = 0
        }
        lock.unlock()
    }

    public func expectedPosition(now: TimeInterval) -> DrivePosition? {
        lock.lock()
        defer { lock.unlock() }
        return expectedPositionLocked(now: now)
    }

    public func snapshot(now: TimeInterval) -> DriveSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let position = expectedPositionLocked(now: now)
        return DriveSessionSnapshot(
            sessionID: sessionID.uuidString,
            writerID: writerID,
            state: state,
            selectedSpeedMPH: selectedSpeedMPH,
            speedMetersPerSecond: speedMetersPerSecond,
            routeDistanceMeters: route?.routeDistanceMeters,
            expectedTravelTime: route?.expectedTravelTime,
            currentExpectedDistanceMeters: position?.expectedDistanceMeters,
            currentLatitude: position?.coordinate.latitude,
            currentLongitude: position?.coordinate.longitude
        )
    }

    public func routeResampler() -> RouteResampler? {
        lock.lock()
        defer { lock.unlock() }
        return route?.resampler
    }

    public func currentState() -> DriveSessionState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func currentRouteDistance() -> CLLocationDistance? {
        lock.lock()
        defer { lock.unlock() }
        return route?.routeDistanceMeters
    }

    private func expectedPositionLocked(now: TimeInterval) -> DrivePosition? {
        guard let route else { return nil }
        switch state {
        case .idle, .routeReady, .stopped:
            return pausedPosition
        case .paused, .holding, .completedHolding:
            return pausedPosition
        case .driving:
            let activeElapsed = activeElapsedLocked(now: now)
            let rawDistance = speedMetersPerSecond * activeElapsed
            let clamped = min(max(0, rawDistance), route.routeDistanceMeters)
            let monotonicDistance = max(previousExpectedDistance, clamped)
            let finalDistance = min(monotonicDistance, route.routeDistanceMeters)
            previousExpectedDistance = finalDistance
            let coordinate = route.resampler.coordinate(atDistance: finalDistance)
            let completed = finalDistance >= route.routeDistanceMeters
            let position = DrivePosition(
                coordinate: coordinate,
                expectedDistanceMeters: finalDistance,
                activeElapsedSeconds: activeElapsed,
                completed: completed
            )
            pausedPosition = position
            return position
        }
    }

    private func activeElapsedLocked(now: TimeInterval) -> TimeInterval {
        guard let driveStartInstant else { return 0 }
        let paused = state == .paused ? max(0, now - (pauseStartedInstant ?? now)) : 0
        return max(0, now - driveStartInstant - accumulatedPausedDuration - paused)
    }
}

public struct DriveSessionSnapshot: Codable, Equatable, Sendable {
    public let sessionID: String
    public let writerID: String
    public let state: DriveSessionState
    public let selectedSpeedMPH: Double
    public let speedMetersPerSecond: Double
    public let routeDistanceMeters: CLLocationDistance?
    public let expectedTravelTime: TimeInterval?
    public let currentExpectedDistanceMeters: CLLocationDistance?
    public let currentLatitude: Double?
    public let currentLongitude: Double?
}
