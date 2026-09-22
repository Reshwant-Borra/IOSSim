import Foundation

public enum InstallationEventResult: String, Codable, Sendable {
    case started
    case succeeded
    case failed
    case waitingForUser
    case candidateCreated
    case candidateProved
    case promoted
    case retired
}

public struct InstallationEvent: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let runID: RunID
    public let stage: InstallationDomain
    public let operation: String
    public let generation: Generation
    public let attempt: Int
    public let lifecycle: ResourceLifecycle?
    public let result: InstallationEventResult
    public let errorCode: String?
    public let retryable: Bool
    public let userAction: String?
    public let durationMilliseconds: UInt64?
    public let evidenceReference: String?
    public let timestamp: Date
}

public protocol InstallationEventSink: Sendable {
    func record(_ event: InstallationEvent) async
}

public actor InMemoryInstallationEventSink: InstallationEventSink {
    public private(set) var events: [InstallationEvent] = []

    public init() {}

    public func record(_ event: InstallationEvent) {
        events.append(event)
    }
}

