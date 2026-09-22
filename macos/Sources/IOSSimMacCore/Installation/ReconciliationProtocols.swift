import Foundation

public protocol InstallationObserver: Sendable {
    var domain: InstallationDomain { get }
    func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation
}

public protocol InstallationTransition: Sendable {
    var domain: InstallationDomain { get }
    func execute(_ context: TransitionContext) async throws -> TransitionReceipt
    func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence
}

public protocol ReconciliationSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousClockSleeper: ReconciliationSleeping {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
