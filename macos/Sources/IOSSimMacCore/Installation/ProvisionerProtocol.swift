import CryptoKit
import Foundation

/// Versioned request/response protocol between clients (Veya UI, `VeyaQualify`) and the packaged
/// `IOSSimProvisioner`, which is the only process that runs `VeyaReconciliationEngine`.
public enum ProvisionerEngineProtocol {
    public static let version = 1
    public static let helperCommand = "engine"
}

public enum EngineCommand: String, Codable, Sendable, CaseIterable {
    case inspect
    case plan
    case reconcile
    case verify
    case resume
}

extension InstallationDomain {
    /// Product dependency order. A stage's prerequisites are every domain before it.
    public static let reconciliationOrder: [InstallationDomain] = [
        .artifact, .migration, .authorization, .team, .signingKey, .certificate, .profile,
        .payload, .application, .developerSupport, .vpn, .pairing, .runtime,
    ]
    // VPN precedes pairing: the phone-side LocalDevVPN check never reads RPPairing, and the planner stops at the
    // first unsatisfied domain, so pairing-first hid the LocalDevVPN install/approval prompt behind pairing.

    /// Direct prerequisites. A signing key needs no Apple account; a certificate needs both.
    public var prerequisites: [InstallationDomain] {
        switch self {
        case .artifact, .migration: return []
        case .signingKey: return [.migration]
        case .authorization: return [.artifact]
        case .team: return [.authorization]
        case .certificate: return [.team, .signingKey]
        case .profile: return [.certificate]
        case .payload: return [.artifact, .profile]
        case .application: return [.payload]
        case .developerSupport: return [.artifact]
        case .pairing: return [.application]
        case .vpn: return [.application]
        case .runtime: return [.application, .developerSupport, .pairing, .vpn]
        }
    }

    /// The domain and every transitive prerequisite, in reconciliation order.
    public var closure: [InstallationDomain] {
        var needed: Set<InstallationDomain> = [self]
        var frontier = [self]
        while let next = frontier.popLast() {
            for prerequisite in next.prerequisites where needed.insert(prerequisite).inserted {
                frontier.append(prerequisite)
            }
        }
        return Self.reconciliationOrder.filter(needed.contains)
    }
}

/// Explicit grant of mutation authority. Without one, the engine may only inspect.
public struct CapabilityManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let allowedDomains: [InstallationDomain]
    public let maximumPermission: ReconciliationPermission
    public let maximumTransitions: Int

    public init(
        allowedDomains: [InstallationDomain],
        maximumPermission: ReconciliationPermission = .safeRepair,
        maximumTransitions: Int = 16
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.allowedDomains = Array(Set(allowedDomains)).sorted { $0.rawValue < $1.rawValue }
        self.maximumPermission = maximumPermission
        self.maximumTransitions = maximumTransitions
    }

    public static let inspectOnly = CapabilityManifest(allowedDomains: [], maximumPermission: .inspect, maximumTransitions: 1)

    public func policy() throws -> ReconciliationPolicy {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw InstallationStateFailure.unsupportedSchema(schemaVersion)
        }
        return try ReconciliationPolicy(
            maximumPermission: maximumPermission,
            allowedDomains: allowedDomains,
            maximumTransitions: maximumTransitions
        )
    }
}

public enum DesiredStateDeriver {
    /// Desired READY state, optionally restricted to `stage` and its prerequisites. Stage restriction
    /// narrows the production planner's input; it never selects a different engine.
    ///
    /// For a stage-restricted qualification run, prerequisites that have no composed observer yet are
    /// excluded and returned as skipped. An unrestricted (product READY) request excludes nothing: an
    /// unobservable domain blocks READY.
    public static func ready(
        stage: InstallationDomain? = nil,
        observable: Set<InstallationDomain>? = nil
    ) throws -> (desired: DesiredInstallationState, skipped: [InstallationDomain]) {
        guard let stage else {
            let all = InstallationDomain.reconciliationOrder
            return (try DesiredInstallationState(requirements: all.map { DesiredDomainState(domain: $0) }), [])
        }
        let closure = stage.closure
        let skipped = observable.map { set in closure.filter { $0 != stage && !set.contains($0) } } ?? []
        let required = closure.filter { !skipped.contains($0) }
        return (try DesiredInstallationState(requirements: required.map { DesiredDomainState(domain: $0) }), skipped)
    }
}

public struct EngineRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let command: EngineCommand
    public let stage: InstallationDomain?
    public let runID: RunID?
    public let capabilities: CapabilityManifest?
    public let connectionGeneration: UInt64?
    /// The iPhone this run targets (device-bound domains). Nil: device domains wait for a selection.
    public let device: EngineDeviceSelection?
    /// Qualification builds only: fixture scenario binding. Release helpers refuse it.
    public let scenario: ScenarioBinding?
    /// Qualification builds only: run the production composition against an isolated state root
    /// instead of the user's Application Support. Release helpers refuse it.
    public let isolatedStateRoot: String?

    public init(
        command: EngineCommand,
        stage: InstallationDomain? = nil,
        runID: RunID? = nil,
        capabilities: CapabilityManifest? = nil,
        connectionGeneration: UInt64? = nil,
        device: EngineDeviceSelection? = nil,
        scenario: ScenarioBinding? = nil,
        isolatedStateRoot: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.command = command
        self.stage = stage
        self.runID = runID
        self.capabilities = capabilities
        self.connectionGeneration = connectionGeneration
        self.device = device
        self.scenario = scenario
        self.isolatedStateRoot = isolatedStateRoot
    }
}

public struct ScenarioBinding: Codable, Equatable, Sendable {
    /// Absolute path to a scenario fixture JSON file.
    public let fixturePath: String
    /// SHA-256 of the fixture bytes; the helper refuses a fixture whose bytes differ.
    public let fixtureDigest: String
    /// Isolated directory holding the scenario journal and simulated external world.
    public let stateRoot: String
    /// Seed for deterministic run/transition/event identifiers of this step.
    public let seed: String
    /// Simulated Apple-controlled user actions completed before this command (e.g. Trust tapped).
    public let completedUserActions: [InstallationDomain]
    /// Simulated wall-clock advance applied before this command (e.g. to expire a dead run's lease).
    public let advanceClockSeconds: Int

    public init(
        fixturePath: String,
        fixtureDigest: String,
        stateRoot: String,
        seed: String,
        completedUserActions: [InstallationDomain] = [],
        advanceClockSeconds: Int = 0
    ) {
        self.fixturePath = fixturePath
        self.fixtureDigest = fixtureDigest
        self.stateRoot = stateRoot
        self.seed = seed
        self.completedUserActions = completedUserActions
        self.advanceClockSeconds = advanceClockSeconds
    }
}

/// Stable process exit classes shared by the helper protocol and `VeyaQualify`.
public enum QualificationExitCode: Int32, Codable, Sendable {
    case success = 0
    case userAction = 2
    case retryableExternal = 3
    case assertionFailed = 4
    case productFailure = 5
    case refused = 6
    case usage = 64
    case internalProtocol = 70
}

public struct EngineIdentity: Codable, Equatable, Sendable {
    public let engineProtocolVersion: Int
    public let journalSchemaVersion: Int
    public let packaged: Bool
    public let qualificationBuild: Bool
    public let hostArchitecture: String

    public init(packaged: Bool, qualificationBuild: Bool) {
        engineProtocolVersion = ProvisionerEngineProtocol.version
        journalSchemaVersion = InstallationJournal.currentSchemaVersion
        self.packaged = packaged
        self.qualificationBuild = qualificationBuild
        #if arch(arm64)
        hostArchitecture = "arm64"
        #else
        hostArchitecture = "x86_64"
        #endif
    }
}

public struct SkippedProof: Codable, Equatable, Sendable {
    public let domain: InstallationDomain
    public let reason: String
}

public struct EngineFailureSummary: Codable, Equatable, Sendable {
    public let code: String
    public let safeMessage: String
    public let domain: InstallationDomain?
}

/// One versioned result per engine command. Contains identities, observations, planned/executed
/// transitions, evidence references, first failure, and a digest of the redacted event stream.
public struct QualificationResult: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let command: EngineCommand
    public let exitCode: QualificationExitCode
    public let status: String
    public let runID: RunID?
    public let identity: EngineIdentity
    public let revision: UInt64?
    public let generation: Generation?
    public let observations: [DomainObservation]
    public let plan: ReconciliationPlan?
    public let transitionsCompleted: Int
    public let events: [InstallationEvent]
    public let eventDigest: String
    public let evidenceReferences: [String]
    public let userAction: String?
    public let firstFailure: EngineFailureSummary?
    public let skippedProofs: [SkippedProof]

    public init(
        command: EngineCommand,
        exitCode: QualificationExitCode,
        status: String,
        runID: RunID?,
        identity: EngineIdentity,
        snapshot: InstallationSnapshot?,
        plan: ReconciliationPlan? = nil,
        transitionsCompleted: Int = 0,
        events: [InstallationEvent] = [],
        evidenceReferences: [String] = [],
        userAction: String? = nil,
        firstFailure: EngineFailureSummary? = nil,
        skippedProofs: [SkippedProof] = []
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.command = command
        self.exitCode = exitCode
        self.status = status
        self.runID = runID
        self.identity = identity
        revision = snapshot?.revision
        generation = snapshot?.generation
        observations = snapshot?.observations ?? []
        self.plan = plan
        self.transitionsCompleted = transitionsCompleted
        self.events = events
        eventDigest = "sha256:" + SHA256.hash(data: try QualificationResult.encoder().encode(events))
            .map { String(format: "%02x", $0) }.joined()
        self.evidenceReferences = evidenceReferences
        self.userAction = userAction
        self.firstFailure = firstFailure
        self.skippedProofs = skippedProofs
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// Composition of the one production engine for a given helper invocation.
public struct EngineComposition: Sendable {
    public let repository: InstallationJournalRepository
    public let observers: [any InstallationObserver]
    public let transitions: [any InstallationTransition]
    public let now: @Sendable () -> Date
    public let makeID: @Sendable () -> UUID
    public let identity: EngineIdentity

    public init(
        repository: InstallationJournalRepository,
        observers: [any InstallationObserver],
        transitions: [any InstallationTransition],
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        identity: EngineIdentity
    ) {
        self.repository = repository
        self.observers = observers
        self.transitions = transitions
        self.now = now
        self.makeID = makeID
        self.identity = identity
    }
}

/// The helper-side dispatcher. Every client command funnels into `VeyaReconciliationEngine`.
public enum EngineHost {
    public static func handle(_ request: EngineRequest, composition: EngineComposition) async -> QualificationResult {
        do {
            return try await dispatch(request, composition: composition)
        } catch {
            return failureResult(request, error: error, identity: composition.identity)
        }
    }

    private static func dispatch(_ request: EngineRequest, composition: EngineComposition) async throws -> QualificationResult {
        guard request.schemaVersion == EngineRequest.currentSchemaVersion else {
            throw InstallationStateFailure.unsupportedSchema(request.schemaVersion)
        }
        let events = InMemoryInstallationEventSink()
        let engine = try VeyaReconciliationEngine(
            journalRepository: composition.repository,
            observers: composition.observers,
            transitions: composition.transitions,
            eventSink: events,
            now: composition.now,
            makeID: composition.makeID
        )
        let observed = Set(composition.observers.map(\.domain))
        let (desired, skippedPrerequisites) = try DesiredStateDeriver.ready(stage: request.stage, observable: observed)
        let scope = try InstallationScope(
            domains: desired.requirements.map(\.domain),
            selectedDeviceIDHash: request.device?.idHash,
            connectionGeneration: request.connectionGeneration
        )
        let skipped = skippedPrerequisites
            .map { SkippedProof(domain: $0, reason: "Prerequisite has no composed observer; excluded from this stage run.") }
            + desired.requirements.map(\.domain).filter { !observed.contains($0) }
            .map { SkippedProof(domain: $0, reason: "No production observer is composed for this domain.") }

        switch request.command {
        case .inspect:
            let snapshot = try await engine.inspect(scope)
            return try QualificationResult(
                command: .inspect, exitCode: .success, status: "inspected", runID: nil,
                identity: composition.identity, snapshot: snapshot, skippedProofs: skipped
            )
        case .plan:
            let snapshot = try await engine.inspect(scope)
            let policy = try (request.capabilities ?? .inspectOnly).policy()
            let plan = try ReconciliationPlanner().plan(snapshot: snapshot, desired: desired, policy: policy)
            return try QualificationResult(
                command: .plan, exitCode: exitCode(for: plan.disposition), status: plan.disposition.rawValue,
                runID: nil, identity: composition.identity, snapshot: snapshot, plan: plan,
                userAction: plan.userAction, firstFailure: summary(plan.failure, domain: plan.domain),
                skippedProofs: skipped
            )
        case .verify:
            guard let domain = request.stage else { throw InstallationStateFailure.unsafeValue("verify domain") }
            let snapshot = try await engine.inspect(try InstallationScope(
                domains: [domain],
                selectedDeviceIDHash: request.device?.idHash,
                connectionGeneration: request.connectionGeneration
            ))
            let plan = try ReconciliationPlanner().plan(
                snapshot: snapshot,
                desired: DesiredInstallationState(requirements: [DesiredDomainState(domain: domain)]),
                policy: CapabilityManifest.inspectOnly.policy()
            )
            let verified = plan.disposition == .ready && snapshot.observation(for: domain) != nil
            let code: QualificationExitCode = verified ? .success
                : plan.disposition == .userActionRequired ? .userAction : .productFailure
            return try QualificationResult(
                command: .verify, exitCode: code, status: verified ? "verified" : "notVerified",
                runID: nil, identity: composition.identity, snapshot: snapshot, plan: plan,
                userAction: plan.userAction, firstFailure: summary(plan.failure, domain: plan.domain),
                skippedProofs: observed.contains(domain) ? [] : skipped.filter { $0.domain == domain }
            )
        case .reconcile, .resume:
            guard let capabilities = request.capabilities else {
                throw QualificationRefusal.capabilityManifestRequired
            }
            if request.command == .resume, request.runID == nil {
                throw InstallationStateFailure.unsafeValue("resume run")
            }
            let runID = request.runID ?? RunID(rawValue: composition.makeID())
            let outcome = try await engine.reconcile(
                scope: scope,
                to: desired,
                policy: capabilities.policy(),
                runID: runID
            )
            let recorded = await events.events
            let journal = try await composition.repository.load()
            let refused = outcome.status == .blocked && outcome.failure?.code == Self.policyDenialCode
            return try QualificationResult(
                command: request.command, exitCode: refused ? .refused : exitCode(for: outcome.status),
                status: outcome.status.rawValue,
                runID: runID, identity: composition.identity, snapshot: outcome.snapshot,
                transitionsCompleted: outcome.transitionsCompleted, events: recorded,
                evidenceReferences: journal.evidence.map(\.id).sorted(),
                userAction: outcome.userAction,
                firstFailure: summary(outcome.failure, domain: nil),
                skippedProofs: skipped
            )
        }
    }

    static let policyDenialCode = "VEYA-STATE-012"

    static func exitCode(for disposition: ReconciliationDisposition) -> QualificationExitCode {
        switch disposition {
        case .ready, .transitionRequired: return .success
        case .userActionRequired: return .userAction
        case .retryableWait: return .retryableExternal
        case .blocked: return .refused
        }
    }

    static func exitCode(for status: ReconciliationOutcomeStatus) -> QualificationExitCode {
        switch status {
        case .ready, .advanced: return .success
        case .userActionRequired: return .userAction
        case .retryableWait: return .retryableExternal
        case .blocked: return .productFailure
        case .cancelled: return .productFailure
        }
    }

    private static func summary(_ failure: VeyaFailure?, domain: InstallationDomain?) -> EngineFailureSummary? {
        failure.map { EngineFailureSummary(code: $0.code, safeMessage: $0.safeMessage, domain: domain) }
    }

    public static func failureResult(_ request: EngineRequest, error: Error, identity: EngineIdentity) -> QualificationResult {
        let failure: EngineFailureSummary
        let code: QualificationExitCode
        switch error {
        case let refusal as QualificationRefusal:
            failure = EngineFailureSummary(code: refusal.code, safeMessage: refusal.safeMessage, domain: nil)
            code = .refused
        case let value as VeyaFailure:
            failure = EngineFailureSummary(code: value.code, safeMessage: value.safeMessage, domain: nil)
            // A transition that stopped on a legitimate user action (install/approve/trust) is not a product failure.
            code = value.userAction != nil ? .userAction : value.retryable ? .retryableExternal : .productFailure
        case let value as InstallationStateFailure:
            failure = EngineFailureSummary(code: value.code, safeMessage: "Installation state operation failed.", domain: nil)
            code = value.code.hasPrefix("VEYA-SEC") ? .refused : .productFailure
        default:
            failure = EngineFailureSummary(code: "VEYA-STATE-099", safeMessage: "Unexpected engine failure.", domain: nil)
            code = .internalProtocol
        }
        // Constructing a result from fixed safe values cannot fail; fall back defensively.
        let userAction = (error as? VeyaFailure)?.userAction
        return (try? QualificationResult(
            command: request.command, exitCode: code, status: userAction == nil ? "failed" : "userActionRequired",
            runID: request.runID, identity: identity, snapshot: nil, userAction: userAction, firstFailure: failure
        ))!
    }
}

public enum QualificationRefusal: Error, Equatable, Sendable {
    case capabilityManifestRequired
    case scenarioUnavailableInRelease
    case fixtureDigestMismatch
    case isolatedRootUnavailableInRelease

    public var code: String {
        switch self {
        case .capabilityManifestRequired: return "VEYA-SEC-010"
        case .scenarioUnavailableInRelease: return "VEYA-SEC-011"
        case .fixtureDigestMismatch: return "VEYA-SEC-012"
        case .isolatedRootUnavailableInRelease: return "VEYA-SEC-013"
        }
    }

    public var safeMessage: String {
        switch self {
        case .capabilityManifestRequired: return "Mutating commands require an explicit capability manifest."
        case .scenarioUnavailableInRelease: return "Scenario fixtures are unavailable in release helpers."
        case .fixtureDigestMismatch: return "The scenario fixture does not match its recorded digest."
        case .isolatedRootUnavailableInRelease: return "Isolated state roots are unavailable in release helpers."
        }
    }
}
