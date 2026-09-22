import CryptoKit
import Foundation

public struct InstallationScope: Codable, Equatable, Sendable {
    public let domains: [InstallationDomain]
    public let selectedDeviceIDHash: String?
    public let connectionGeneration: UInt64?

    public init(
        domains: [InstallationDomain] = InstallationDomain.allCases,
        selectedDeviceIDHash: String? = nil,
        connectionGeneration: UInt64? = nil
    ) throws {
        if let selectedDeviceIDHash { try InstallationSafeValue.validateDigest(selectedDeviceIDHash) }
        self.domains = Array(Set(domains)).sorted { $0.rawValue < $1.rawValue }
        self.selectedDeviceIDHash = selectedDeviceIDHash
        self.connectionGeneration = connectionGeneration
    }
}

public enum DomainObservationState: String, Codable, CaseIterable, Sendable {
    case satisfied
    case missing
    case stale
    case invalid
    case candidateUnproved
    case candidateProved
    case waitingForUser
    case retryableFailure
    case terminalFailure
}

public struct DomainObservation: Codable, Equatable, Sendable {
    public let domain: InstallationDomain
    public let state: DomainObservationState
    public let resource: ResourceIdentity?
    public let ownership: OwnershipLevel
    public let capturedAt: Date
    public let validUntil: Date?
    public let connectionGeneration: UInt64?
    public let safeReason: String?
    public let userAction: String?
    public let failure: VeyaFailure?

    public init(
        domain: InstallationDomain,
        state: DomainObservationState,
        resource: ResourceIdentity? = nil,
        ownership: OwnershipLevel = .unknown,
        capturedAt: Date,
        validUntil: Date? = nil,
        connectionGeneration: UInt64? = nil,
        safeReason: String? = nil,
        userAction: String? = nil,
        failure: VeyaFailure? = nil
    ) throws {
        if let safeReason {
            try InstallationSafeValue.validate(safeReason, field: "observation reason", maximumLength: 256)
        }
        if let userAction {
            try InstallationSafeValue.validate(userAction, field: "observation user action", maximumLength: 256)
        }
        if state == .waitingForUser, userAction == nil {
            throw InstallationStateFailure.unsafeValue("missing user action")
        }
        if [.retryableFailure, .terminalFailure].contains(state), failure == nil {
            throw InstallationStateFailure.unsafeValue("missing observation failure")
        }
        self.domain = domain
        self.state = state
        self.resource = resource
        self.ownership = ownership
        self.capturedAt = capturedAt
        self.validUntil = validUntil
        self.connectionGeneration = connectionGeneration
        self.safeReason = safeReason
        self.userAction = userAction
        self.failure = failure
    }

    public func isFresh(at date: Date) -> Bool {
        validUntil.map { $0 > date } ?? true
    }

    /// Connection-bound observations (non-nil generation) are only valid for the connection that produced them.
    public func isConnectionCurrent(_ current: UInt64?) -> Bool {
        connectionGeneration.map { $0 == current } ?? true
    }
}

public struct InstallationSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let installationID: UUID
    public let revision: UInt64
    public let generation: Generation
    public let capturedAt: Date
    public let connectionGeneration: UInt64?
    public let observations: [DomainObservation]

    public init(
        journal: InstallationJournal,
        observations: [DomainObservation],
        capturedAt: Date,
        connectionGeneration: UInt64? = nil
    ) throws {
        let uniqueDomains = Set(observations.map(\.domain))
        guard uniqueDomains.count == observations.count else {
            throw InstallationStateFailure.unsafeValue("duplicate observation")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.installationID = journal.installationID
        self.revision = journal.revision
        self.generation = journal.generation
        self.capturedAt = capturedAt
        self.connectionGeneration = connectionGeneration
        self.observations = observations.sorted { $0.domain.rawValue < $1.domain.rawValue }
    }

    public func observation(for domain: InstallationDomain) -> DomainObservation? {
        observations.first { $0.domain == domain }
    }
}

public struct DesiredDomainState: Codable, Equatable, Sendable {
    public let domain: InstallationDomain
    public let target: ResourceIdentity?
    public let required: Bool

    public init(domain: InstallationDomain, target: ResourceIdentity? = nil, required: Bool = true) {
        self.domain = domain
        self.target = target
        self.required = required
    }
}

public struct DesiredInstallationState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let requirements: [DesiredDomainState]
    public let digest: String

    public init(requirements: [DesiredDomainState]) throws {
        let domains = requirements.map(\.domain)
        guard Set(domains).count == domains.count else {
            throw InstallationStateFailure.unsafeValue("duplicate desired domain")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.requirements = requirements
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(requirements)
        self.digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ReconciliationPermission: Int, Codable, Comparable, Sendable {
    case inspect = 0
    case safeRepair = 1
    case interactive = 2
    case destructiveOwned = 3

    public static func < (lhs: ReconciliationPermission, rhs: ReconciliationPermission) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ReconciliationPolicy: Codable, Equatable, Sendable {
    public let maximumPermission: ReconciliationPermission
    public let allowedDomains: [InstallationDomain]
    public let maximumTransitions: Int
    public let localRetryLimit: Int
    public let remoteRetryLimit: Int

    public init(
        maximumPermission: ReconciliationPermission = .safeRepair,
        allowedDomains: [InstallationDomain] = InstallationDomain.allCases,
        maximumTransitions: Int = 1,
        localRetryLimit: Int = 2,
        remoteRetryLimit: Int = 4
    ) throws {
        guard (1...64).contains(maximumTransitions), (0...4).contains(localRetryLimit),
              (0...8).contains(remoteRetryLimit) else {
            throw InstallationStateFailure.unsafeValue("reconciliation limits")
        }
        self.maximumPermission = maximumPermission
        self.allowedDomains = Array(Set(allowedDomains)).sorted { $0.rawValue < $1.rawValue }
        self.maximumTransitions = maximumTransitions
        self.localRetryLimit = localRetryLimit
        self.remoteRetryLimit = remoteRetryLimit
    }
}

public enum TransitionKind: String, Codable, Sendable {
    case createCandidate
    case replaceCandidate
    case proveCandidate
    case promoteCandidate
    case revokeOwnedCertificate
}

/// Irreversible side effects outside Veya's own files. These are never "rolled back";
/// after interruption they are reconciled by re-observing the external inventory.
public enum IrreversibleEffect: String, Codable, CaseIterable, Sendable {
    case appleCertificateIssued
    case appleCertificateRevoked
    case appleProfileIssued
    case deviceApplicationReplaced
    case deviceDeveloperImageMounted
    case devicePairingRecordDelivered
    case deviceVPNConfigurationChanged
}

public enum InterruptionReconciliation: String, Codable, Sendable {
    case reobserveAppleInventory
    case reobserveDeviceInventory
}

public enum RollbackAction: String, Codable, Sendable {
    /// Candidate is Veya-local; discarding it leaves the active resource untouched.
    case discardCandidate
    /// Promotion retains the previous active record as `retiring` until it is retired.
    case restorePreviousActive
    /// Proof is read-only; nothing to undo.
    case noSideEffect
}

public enum TransitionRecovery: Codable, Equatable, Sendable {
    case rollback(RollbackAction)
    case irreversible(IrreversibleEffect, reconcile: InterruptionReconciliation)

    /// Exhaustive by construction: adding a `TransitionKind` or `InstallationDomain` fails to compile
    /// until its recovery semantics are declared here.
    public static func required(domain: InstallationDomain, kind: TransitionKind) -> TransitionRecovery {
        switch kind {
        case .proveCandidate:
            return .rollback(.noSideEffect)
        case .promoteCandidate:
            return .rollback(.restorePreviousActive)
        case .revokeOwnedCertificate:
            return .irreversible(.appleCertificateRevoked, reconcile: .reobserveAppleInventory)
        case .createCandidate, .replaceCandidate:
            switch domain {
            case .artifact, .authorization, .team, .signingKey, .payload, .runtime, .migration:
                return .rollback(.discardCandidate)
            case .certificate:
                return .irreversible(.appleCertificateIssued, reconcile: .reobserveAppleInventory)
            case .profile:
                return .irreversible(.appleProfileIssued, reconcile: .reobserveAppleInventory)
            case .application:
                return .irreversible(.deviceApplicationReplaced, reconcile: .reobserveDeviceInventory)
            case .developerSupport:
                return .irreversible(.deviceDeveloperImageMounted, reconcile: .reobserveDeviceInventory)
            case .pairing:
                return .irreversible(.devicePairingRecordDelivered, reconcile: .reobserveDeviceInventory)
            case .vpn:
                return .irreversible(.deviceVPNConfigurationChanged, reconcile: .reobserveDeviceInventory)
            }
        }
    }
}

public struct PlannedTransition: Codable, Equatable, Sendable {
    public let domain: InstallationDomain
    public let kind: TransitionKind
    public let permission: ReconciliationPermission
    public let generation: Generation
    public let target: ResourceIdentity?
    public let idempotencyKey: String
    public let recovery: TransitionRecovery

    public init(
        domain: InstallationDomain,
        kind: TransitionKind,
        permission: ReconciliationPermission,
        generation: Generation,
        target: ResourceIdentity?,
        desiredDigest: String
    ) throws {
        try InstallationSafeValue.validateDigest(desiredDigest)
        let material = [
            domain.rawValue,
            kind.rawValue,
            String(generation.rawValue),
            target?.resourceID ?? "none",
            target?.digest ?? "none",
            desiredDigest,
        ].joined(separator: "|")
        self.domain = domain
        self.kind = kind
        self.permission = permission
        self.generation = generation
        self.target = target
        self.recovery = TransitionRecovery.required(domain: domain, kind: kind)
        self.idempotencyKey = "sha256:" + SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public enum ReconciliationDisposition: String, Codable, Sendable {
    case transitionRequired
    case ready
    case userActionRequired
    case retryableWait
    case blocked
}

public struct ReconciliationPlan: Codable, Equatable, Sendable {
    public let snapshotRevision: UInt64
    public let disposition: ReconciliationDisposition
    /// Domain that determined a non-ready disposition (the first unsatisfied requirement).
    public let domain: InstallationDomain?
    public let transitions: [PlannedTransition]
    public let userAction: String?
    public let failure: VeyaFailure?

    public init(
        snapshotRevision: UInt64,
        disposition: ReconciliationDisposition,
        domain: InstallationDomain? = nil,
        transitions: [PlannedTransition] = [],
        userAction: String? = nil,
        failure: VeyaFailure? = nil
    ) {
        self.snapshotRevision = snapshotRevision
        self.disposition = disposition
        self.domain = domain ?? transitions.first?.domain
        self.transitions = transitions
        self.userAction = userAction
        self.failure = failure
    }
}

public struct TransitionReceipt: Codable, Equatable, Sendable {
    public let operation: String
    public let generation: Generation
    public let candidate: ResourceRecord?
    public let attributes: [String: String]

    public init(
        operation: String,
        generation: Generation,
        candidate: ResourceRecord? = nil,
        attributes: [String: String] = [:]
    ) throws {
        try InstallationSafeValue.validate(operation, field: "transition operation", maximumLength: 96)
        try InstallationSafeValue.validate(attributes: attributes)
        self.operation = operation
        self.generation = generation
        self.candidate = candidate
        self.attributes = attributes
    }
}

public struct TransitionContext: Sendable {
    public let runID: RunID
    public let installationID: UUID
    public let scope: InstallationScope
    public let desired: DesiredInstallationState
    public let planned: PlannedTransition
    public let attempt: Int
    /// The journal candidate for the planned domain when the transition started, if any.
    public let candidate: ResourceRecord?
    /// The run's permission ceiling. Irreversible owned cleanup (certificate revocation) needs `destructiveOwned`.
    public var maximumPermission: ReconciliationPermission = .safeRepair
}

public enum ReconciliationOutcomeStatus: String, Codable, Sendable {
    case advanced
    case ready
    case userActionRequired
    case retryableWait
    case blocked
    case cancelled
}

public struct ReconciliationOutcome: Codable, Equatable, Sendable {
    public let runID: RunID
    public let status: ReconciliationOutcomeStatus
    public let snapshot: InstallationSnapshot
    public let transitionsCompleted: Int
    public let userAction: String?
    public let failure: VeyaFailure?
}
