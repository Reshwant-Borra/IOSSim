import Foundation

public protocol DriveClock: Sendable {
    func nowSeconds() -> TimeInterval
    func sleep(seconds: TimeInterval) async throws
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
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await clock.sleep(for: .nanoseconds(Int64(min(nanoseconds, UInt64(Int64.max)))))
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
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
}

public enum DriveSpeed {
    public static let minimumMPH: Double = 15
    public static let maximumMPH: Double = 70

    public static func metersPerSecond(fromMPH mph: Double) -> Double {
        min(max(mph, minimumMPH), maximumMPH) * 0.44704
    }
}

