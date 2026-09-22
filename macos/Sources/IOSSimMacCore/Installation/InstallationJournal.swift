import Foundation

public struct InstallationLease: Codable, Equatable, Sendable {
    public let runID: RunID
    public let ownerProcessID: Int32
    public let acquiredAt: Date
    public var expiresAt: Date

    public func isExpired(at date: Date) -> Bool { expiresAt <= date }
}

public struct JournalTransition: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case planned
        case executing
        case proving
        case proved
        case failed
    }

    public let id: UUID
    public let runID: RunID
    public let domain: InstallationDomain
    public let operation: String
    public var phase: Phase
    public let generation: Generation
    public let idempotencyKey: String
    public let startedAt: Date
    /// Optional for schema-1 journals written before recovery semantics were recorded.
    public var recovery: TransitionRecovery? = nil
}

public struct MigrationLedger: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case notStarted
        case inventoried
        case importedCandidates
        case candidatesProven
        case newActive
        case legacyWritesDisabled
        case complete
    }

    public var phase: Phase
    public var items: [String: String]

    public init(phase: Phase = .notStarted, items: [String: String] = [:]) {
        self.phase = phase
        self.items = items
    }
}

public struct JournalRecovery: Codable, Equatable, Sendable {
    public var required: Bool
    public var reason: String?
    public var recoveredFromRevision: UInt64?

    public init(required: Bool = false, reason: String? = nil, recoveredFromRevision: UInt64? = nil) {
        self.required = required
        self.reason = reason
        self.recoveredFromRevision = recoveredFromRevision
    }
}

public struct SafeCheckpoint: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let generation: Generation
    public let digest: String
}

public struct InstallationJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let installationID: UUID
    public var revision: UInt64
    public var generation: Generation
    public var lease: InstallationLease?
    public var active: [String: ResourceRecord]
    public var candidates: [String: ResourceRecord]
    public var retiring: [String: [ResourceRecord]]
    public var transition: JournalTransition?
    public var evidence: [Evidence]
    public var migration: MigrationLedger
    public var recovery: JournalRecovery
    public var lastSafeCheckpoint: SafeCheckpoint?
    public var updatedAt: Date

    public init(installationID: UUID = UUID(), now: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.installationID = installationID
        self.revision = 0
        self.generation = .initial
        self.lease = nil
        self.active = [:]
        self.candidates = [:]
        self.retiring = [:]
        self.transition = nil
        self.evidence = []
        self.migration = MigrationLedger()
        self.recovery = JournalRecovery()
        self.lastSafeCheckpoint = nil
        self.updatedAt = now
    }

    public func activeResource(for domain: InstallationDomain) -> ResourceRecord? {
        active[domain.rawValue]
    }

    public func candidateResource(for domain: InstallationDomain) -> ResourceRecord? {
        candidates[domain.rawValue]
    }
}

public enum JournalWritePoint: String, Codable, Sendable {
    case afterTemporaryFileSyncBeforeRename
    case afterRenameBeforeDirectorySync
    case beforePostWriteVerification
}

