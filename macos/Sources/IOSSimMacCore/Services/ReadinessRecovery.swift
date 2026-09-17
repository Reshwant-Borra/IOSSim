import Foundation

public enum ReadinessDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case host, device, appleAccount, signing, installation, developerSupport, pairing, vpnTunnel, runtime, userIntent
}

public enum ReadinessStateKind: String, Codable, Equatable, Sendable {
    case unknown, checking, ready, userActionRequired, transientFailure, repairable, blocked, unsupported, expired, stale
}

public struct ReadinessReason: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code; self.message = message; self.retryable = retryable
    }
}

public struct ReadinessDomainStatus: Codable, Equatable, Sendable {
    public let state: ReadinessStateKind
    public let reason: ReadinessReason?
    public init(_ state: ReadinessStateKind, reason: ReadinessReason? = nil) { self.state = state; self.reason = reason }
}

public enum RecoveryAction: Codable, Equatable, Sendable {
    case none
    case askUser(action: String)
    case retryTransport(maxAttempts: Int, backoffSeconds: [Double])
    case repairPairing
    case renewSigning
    case prepareDeveloperSupport
    case reinstallOwnedArtifacts
    case rerunRuntimeProof
}

public struct RecoveryPlan: Codable, Equatable, Sendable {
    public let actions: [RecoveryAction]
    public init(actions: [RecoveryAction] = []) { self.actions = actions }
}

public struct ReadinessSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let domains: [ReadinessDomain: ReadinessDomainStatus]
    public let recovery: RecoveryPlan
    public init(generatedAt: Date = .now, domains: [ReadinessDomain: ReadinessDomainStatus], recovery: RecoveryPlan) {
        self.generatedAt = generatedAt; self.domains = domains; self.recovery = recovery
    }
    public subscript(_ domain: ReadinessDomain) -> ReadinessDomainStatus { domains[domain] ?? .init(.unknown) }
}

public protocol ReadinessProbe: Sendable {
    func checkDomains() async -> [ReadinessDomain: ReadinessDomainStatus]
}

public struct StaticReadinessProbe: ReadinessProbe {
    private let values: [ReadinessDomain: ReadinessDomainStatus]
    public init(_ values: [ReadinessDomain: ReadinessDomainStatus]) { self.values = values }
    public func checkDomains() async -> [ReadinessDomain: ReadinessDomainStatus] { values }
}

public actor ReadinessCoordinator {
    private var lastSnapshot: ReadinessSnapshot?
    public init() {}

    public func evaluate(using probe: any ReadinessProbe) async -> ReadinessSnapshot {
        let values = await probe.checkDomains()
        let recovery = Self.plan(for: values)
        let snapshot = ReadinessSnapshot(domains: values, recovery: recovery)
        lastSnapshot = snapshot
        return snapshot
    }

    public func snapshot() -> ReadinessSnapshot? { lastSnapshot }

    public static func plan(for values: [ReadinessDomain: ReadinessDomainStatus]) -> RecoveryPlan {
        func state(_ domain: ReadinessDomain) -> ReadinessStateKind { values[domain]?.state ?? .unknown }
        if state(.device) == .userActionRequired || state(.device) == .blocked {
            return RecoveryPlan(actions: [.askUser(action: values[.device]?.reason?.code ?? "unlock_or_trust_device")])
        }
        if state(.appleAccount) == .userActionRequired || state(.appleAccount) == .expired {
            return RecoveryPlan(actions: [.askUser(action: values[.appleAccount]?.reason?.code ?? "reauthorize_apple_account")])
        }
        if state(.signing) == .expired || state(.signing) == .stale {
            return RecoveryPlan(actions: [.renewSigning])
        }
        if state(.installation) == .repairable || state(.installation) == .stale {
            return RecoveryPlan(actions: [.reinstallOwnedArtifacts])
        }
        if state(.developerSupport) == .repairable || state(.developerSupport) == .stale {
            return RecoveryPlan(actions: [.prepareDeveloperSupport])
        }
        if state(.pairing) == .repairable || state(.pairing) == .stale {
            return RecoveryPlan(actions: [.repairPairing])
        }
        if state(.vpnTunnel) == .userActionRequired {
            return RecoveryPlan(actions: [.askUser(action: values[.vpnTunnel]?.reason?.code ?? "start_or_approve_vpn")])
        }
        if state(.vpnTunnel) == .transientFailure {
            return RecoveryPlan(actions: [.retryTransport(maxAttempts: 3, backoffSeconds: [1, 2, 4])])
        }
        if state(.runtime) == .stale || state(.runtime) == .repairable {
            return RecoveryPlan(actions: [.rerunRuntimeProof])
        }
        if state(.runtime) == .transientFailure {
            return RecoveryPlan(actions: [.retryTransport(maxAttempts: 3, backoffSeconds: [0.5, 1, 2])])
        }
        return RecoveryPlan()
    }
}

public enum SetupRepairScope: String, Codable, Equatable, Sendable {
    case none = "NONE"
    case waitForDevice = "WAIT_FOR_DEVICE"
    case reauthorizeAppleAccount = "REAUTHORIZE_APPLE_ACCOUNT"
    case renewSigning = "RENEW_SIGNING"
    case reinstallMain = "REINSTALL_MAIN"
    case reinstallRunner = "REINSTALL_RUNNER"
    case reinstallOwnedArtifacts = "REINSTALL_OWNED_ARTIFACTS"
    case prepareDeveloperSupport = "PREPARE_DEVELOPER_SUPPORT"
    case repairPairing = "REPAIR_PAIRING"
    case startOrApproveVPN = "START_OR_APPROVE_VPN"
    case rerunRuntimeProof = "RERUN_RUNTIME_PROOF"
}

public struct SetupReconciliationInput: Equatable, Sendable {
    public var deviceAvailable = true
    public var appleSessionValid = true
    public var signingCurrent = true
    public var releaseCurrent = true
    public var mainInstalled = true
    public var runnerInstalled = true
    public var developerSupportCurrent = true
    public var pairingOperational = true
    public var vpnReady = true
    public var runtimeProofCurrent = true

    public init() {}

    public var smallestRepair: SetupRepairScope {
        if !deviceAvailable { return .waitForDevice }
        if !appleSessionValid { return .reauthorizeAppleAccount }
        if !signingCurrent { return .renewSigning }
        if !releaseCurrent { return .reinstallOwnedArtifacts }
        if !mainInstalled && !runnerInstalled { return .reinstallOwnedArtifacts }
        if !mainInstalled { return .reinstallMain }
        if !runnerInstalled { return .reinstallRunner }
        if !developerSupportCurrent { return .prepareDeveloperSupport }
        if !pairingOperational { return .repairPairing }
        if !vpnReady { return .startOrApproveVPN }
        if !runtimeProofCurrent { return .rerunRuntimeProof }
        return .none
    }
}

/// Safe, resumable setup journal. Its schema has no fields capable of holding
/// passwords, tokens, pairing bytes, or signing keys.
public struct SetupJournalEntry: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let selectedDeviceUDID: String?
    public let completedStages: [String]
    public let artifactVersions: [String: String]
    public let bundleIdentifiers: [String]
    public let profileExpiry: Date?
    public let currentStage: String?
    public let lastSafeErrorCode: String?
    public let userAction: String?
    public let updatedAt: Date
    public init(selectedDeviceUDID: String? = nil, completedStages: [String] = [], artifactVersions: [String: String] = [:],
                bundleIdentifiers: [String] = [], profileExpiry: Date? = nil, currentStage: String? = nil,
                lastSafeErrorCode: String? = nil, userAction: String? = nil, updatedAt: Date = .now) {
        self.schemaVersion = 1; self.selectedDeviceUDID = selectedDeviceUDID; self.completedStages = completedStages
        self.artifactVersions = artifactVersions; self.bundleIdentifiers = bundleIdentifiers; self.profileExpiry = profileExpiry
        self.currentStage = currentStage; self.lastSafeErrorCode = lastSafeErrorCode; self.userAction = userAction; self.updatedAt = updatedAt
    }
}

public actor SetupJournalStore {
    private let url: URL
    private let fileManager: FileManager
    public init(url: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.url = url ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("IOSSim/setup-journal.json")
    }
    public func load() throws -> SetupJournalEntry? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let entry = try JSONDecoder().decode(SetupJournalEntry.self, from: Data(contentsOf: url))
        guard entry.schemaVersion == 1 else { throw NSError(domain: "IOSSim.SetupJournal", code: 1) }
        return entry
    }
    public func save(_ entry: SetupJournalEntry) throws {
        let forbidden = ["password", "token", "cookie", "private_key", "2fa", "pairingdata"]
        let encoded = try JSONEncoder().encode(entry)
        let text = String(decoding: encoded, as: UTF8.self).lowercased()
        guard !forbidden.contains(where: text.contains) else { throw NSError(domain: "IOSSim.SetupJournal", code: 2) }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoded.write(to: url, options: [.atomic]); try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
