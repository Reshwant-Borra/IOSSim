import Foundation

public protocol DriveClock: Sendable {
    func nowSeconds() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
    func sleep(until deadlineSeconds: TimeInterval) async throws
}

public struct ContinuousDriveClock: DriveClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public func nowSeconds() -> TimeInterval {
        Self.seconds(from: origin.duration(to: clock.now))
    }

    public func sleep(seconds: TimeInterval) async throws {
        try await clock.sleep(for: Self.duration(from: seconds))
    }

    public func sleep(until deadlineSeconds: TimeInterval) async throws {
        let deadline = origin.advanced(by: Self.duration(from: deadlineSeconds))
        try await clock.sleep(until: deadline)
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func duration(from seconds: TimeInterval) -> Duration {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        return .nanoseconds(Int64(min(nanoseconds, UInt64(Int64.max))))
    }
}

public final class ManualDriveClock: DriveClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    public init(start: TimeInterval = 0) {
        value = start
    }

    public func nowSeconds() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }

    public func sleep(seconds: TimeInterval) async throws {
        advance(by: seconds)
    }

    public func sleep(until deadlineSeconds: TimeInterval) async throws {
        advance(to: deadlineSeconds)
    }

    public func advance(to deadlineSeconds: TimeInterval) {
        lock.lock()
        value = max(value, deadlineSeconds)
        lock.unlock()
    }
}

public enum DriveUpdateCadence: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case baseline1Hz
    case smooth2Hz

    public var id: String { rawValue }

    public static let defaultCadence: DriveUpdateCadence = .smooth2Hz

    public var displayName: String {
        switch self {
        case .baseline1Hz:
            return "Baseline 1 Hz Compatibility"
        case .smooth2Hz:
            return "Smooth 2 Hz"
        }
    }

    public var diagnosticName: String {
        switch self {
        case .baseline1Hz:
            return "baseline_1hz"
        case .smooth2Hz:
            return "smooth_2hz"
        }
    }

    public var intervalSeconds: TimeInterval {
        switch self {
        case .baseline1Hz:
            return 1
        case .smooth2Hz:
            return 0.5
        }
    }

    public var targetIntervalMs: Double {
        intervalSeconds * 1000
    }

    public var effectiveUpdateFrequencyHz: Double {
        1 / intervalSeconds
    }

    public func expectedDistancePerUpdateMeters(speedMetersPerSecond: Double) -> Double {
        speedMetersPerSecond * intervalSeconds
    }
}

public struct DriveTransportHealthPolicy: Sendable {
    public static let richConsecutiveFailureLimit = 2
    public static let richMissingAckLimit = 3

    private var consecutiveFailures = 0
    private var consecutiveMissingAcks = 0

    public init() {}

    public mutating func recordSuccess(result: DriveLocationTransportSetResult) -> String? {
        consecutiveFailures = 0
        if result.sendMonotonicTime != nil && result.ackMonotonicTime == nil {
            consecutiveMissingAcks += 1
        } else {
            consecutiveMissingAcks = 0
        }
        guard consecutiveMissingAcks >= Self.richMissingAckLimit else { return nil }
        return "Rich Drive did not acknowledge \(consecutiveMissingAcks) consecutive location updates."
    }

    public mutating func recordFailure(_ error: Error) -> String? {
        consecutiveFailures += 1
        consecutiveMissingAcks = 0
        guard consecutiveFailures >= Self.richConsecutiveFailureLimit else { return nil }
        return "Rich Drive failed \(consecutiveFailures) consecutive location updates: \(String(describing: error))"
    }
}

public struct DriveCadenceHealthSample: Sendable {
    public let missedDeadlineCount: Int
    public let ackLatencyMs: Double?
    public let droppedOrReplacedSamples: Int

    public init(
        missedDeadlineCount: Int,
        ackLatencyMs: Double?,
        droppedOrReplacedSamples: Int
    ) {
        self.missedDeadlineCount = missedDeadlineCount
        self.ackLatencyMs = ackLatencyMs
        self.droppedOrReplacedSamples = droppedOrReplacedSamples
    }
}

public struct DriveCadenceHealthPolicy: Sendable {
    public static let evaluationWindow = 8
    public static let unhealthyMissedDeadlineTotal = 3
    public static let unhealthyDroppedOrReplacedTotal = 3
    public static let unhealthyAckLatencyFractionOfInterval = 0.8
    public static let unhealthyAckPressureCount = 4

    private var samples: [DriveCadenceHealthSample] = []

    public init() {}

    public mutating func record(
        sample: DriveCadenceHealthSample,
        cadence: DriveUpdateCadence
    ) -> String? {
        guard cadence == .smooth2Hz else { return nil }
        samples.append(sample)
        if samples.count > Self.evaluationWindow {
            samples.removeFirst(samples.count - Self.evaluationWindow)
        }
        guard samples.count == Self.evaluationWindow else { return nil }

        let missedDeadlines = samples.reduce(0) { $0 + max(0, $1.missedDeadlineCount) }
        if missedDeadlines >= Self.unhealthyMissedDeadlineTotal {
            return "Smooth 2 Hz missed \(missedDeadlines) scheduler deadlines in the recent window."
        }

        let dropped = samples.reduce(0) { $0 + max(0, $1.droppedOrReplacedSamples) }
        if dropped >= Self.unhealthyDroppedOrReplacedTotal {
            return "Smooth 2 Hz replaced \(dropped) pending transport samples in the recent window."
        }

        let ackPressureThreshold = cadence.targetIntervalMs * Self.unhealthyAckLatencyFractionOfInterval
        let pressuredAcks = samples.filter { ($0.ackLatencyMs ?? 0) >= ackPressureThreshold }.count
        if pressuredAcks >= Self.unhealthyAckPressureCount {
            return "Smooth 2 Hz transport ACK latency approached the update interval \(pressuredAcks) times in the recent window."
        }

        return nil
    }
}

public enum DriveSchedulerTimeline {
    public static func deadlineOffset(sequence: Int, intervalSeconds: TimeInterval) -> TimeInterval {
        Double(max(0, sequence)) * max(0, intervalSeconds)
    }

    public static func deadline(start: TimeInterval, sequence: Int, intervalSeconds: TimeInterval) -> TimeInterval {
        start + deadlineOffset(sequence: sequence, intervalSeconds: intervalSeconds)
    }

    public static func nextFutureSequence(
        start: TimeInterval,
        intervalSeconds: TimeInterval,
        now: TimeInterval,
        minimumSequence: Int
    ) -> Int {
        guard intervalSeconds > 0 else { return max(0, minimumSequence) }
        let elapsed = max(0, now - start)
        let firstFuture = Int(floor(elapsed / intervalSeconds)) + 1
        return max(max(0, minimumSequence), firstFuture)
    }

    public static func missedDeadlineCount(
        start: TimeInterval,
        intervalSeconds: TimeInterval,
        now: TimeInterval,
        scheduledSequence: Int
    ) -> Int {
        guard intervalSeconds > 0 else { return 0 }
        let elapsed = max(0, now - start)
        let expiredSequence = Int(floor(elapsed / intervalSeconds))
        return max(0, expiredSequence - scheduledSequence)
    }
}

public enum DriveSpeed {
    public static let minimumMPH: Double = 15
    public static let maximumMPH: Double = 70

    public static func metersPerSecond(fromMPH mph: Double) -> Double {
        min(max(mph, minimumMPH), maximumMPH) * 0.44704
    }
}
