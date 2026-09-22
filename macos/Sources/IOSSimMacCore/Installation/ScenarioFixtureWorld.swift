#if VEYA_QUALIFICATION
import Foundation

/// Simulated external world for qualification scenarios. It stands in for Apple/device/local
/// boundaries only: observations and side effects. Planning, journal, proof binding, promotion,
/// and READY are all decided by the production engine. Compiled only into qualification builds.
actor ScenarioWorld {
    private let url: URL
    private var state: ScenarioWorldState

    init(stateRoot: URL) throws {
        url = stateRoot.appendingPathComponent(ScenarioWorldFile.fileName)
        if let data = try? Data(contentsOf: url) {
            state = try JSONDecoder().decode(ScenarioWorldState.self, from: data)
        } else {
            state = ScenarioWorldState()
        }
    }

    var clockOffsetSeconds: Int { state.clockOffsetSeconds }

    func prepare(completedUserActions: [InstallationDomain], advanceClockSeconds: Int) throws {
        for domain in completedUserActions {
            state.domains[domain.rawValue, default: .init()].userActionCompleted = true
        }
        state.clockOffsetSeconds += max(0, advanceClockSeconds)
        try save()
    }

    /// Records a boundary call and returns its 1-based ordinal across the scenario.
    func recordCall(_ domain: InstallationDomain, _ operation: ScenarioBoundaryOperation) throws -> Int {
        state.domains[domain.rawValue, default: .init()].calls[operation.rawValue, default: 0] += 1
        try save()
        return state.domains[domain.rawValue]?.calls[operation.rawValue] ?? 0
    }

    func domain(_ domain: InstallationDomain) -> ScenarioWorldState.Domain {
        state.domains[domain.rawValue] ?? .init()
    }

    /// Creates the external resource if absent (idempotent; a resumed operation adopts it).
    func ensureResource(_ domain: InstallationDomain, id: String) throws {
        var value = state.domains[domain.rawValue] ?? .init()
        if !value.resources.contains(id) {
            value.resources.append(id)
            value.effects += 1
            value.calls["effect", default: 0] += 1
        }
        state.domains[domain.rawValue] = value
        try save()
    }

    func recordProof(_ domain: InstallationDomain, id: String, connection: UInt64?) throws {
        state.domains[domain.rawValue, default: .init()].proofs[id] = connection.map(Int64.init) ?? -1
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

struct ScenarioFixtureDomain: InstallationObserver, InstallationTransition {
    let fixture: ScenarioDomainFixture
    let injections: [ScenarioInjection]
    let world: ScenarioWorld
    let now: @Sendable () -> Date
    let crash: @Sendable () -> Never

    var domain: InstallationDomain { fixture.domain }

    func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        let ordinal = try await world.recordCall(domain, .observe)
        switch injection(.observe, ordinal) {
        case .retryableFailure?:
            return try DomainObservation(domain: domain, state: .retryableFailure, capturedAt: now(), failure: failure(retryable: true))
        case .terminalFailure?:
            return try DomainObservation(domain: domain, state: .terminalFailure, capturedAt: now(), failure: failure(retryable: false))
        case .crashBefore?, .crashAfter?:
            crash()
        case nil:
            break
        }
        let external = await world.domain(domain)
        if let candidate = journal.candidateResource(for: domain) {
            guard external.resources.contains(candidate.identity.resourceID) else {
                return try DomainObservation(domain: domain, state: .invalid, resource: candidate.identity, capturedAt: now())
            }
            let proof = external.proofs[candidate.identity.resourceID]
            return try DomainObservation(
                domain: domain,
                state: proof == nil ? .candidateUnproved : .candidateProved,
                resource: candidate.identity,
                ownership: candidate.ownership,
                capturedAt: now(),
                connectionGeneration: proof.flatMap { $0 < 0 ? nil : UInt64($0) }
            )
        }
        if let active = journal.activeResource(for: domain) {
            guard external.resources.contains(active.identity.resourceID) else {
                return try DomainObservation(domain: domain, state: .invalid, resource: active.identity, capturedAt: now())
            }
            let proof = external.proofs[active.identity.resourceID]
            return try DomainObservation(
                domain: domain,
                state: .satisfied,
                resource: active.identity,
                ownership: active.ownership,
                capturedAt: now(),
                connectionGeneration: proof.flatMap { $0 < 0 ? nil : UInt64($0) }
            )
        }
        switch fixture.initial {
        case .waitingForUser where external.userActionCompleted:
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now())
        case .waitingForUser:
            return try DomainObservation(
                domain: domain,
                state: .waitingForUser,
                capturedAt: now(),
                userAction: fixture.userAction ?? "Complete the Apple-controlled action on the iPhone."
            )
        case .retryableFailure, .terminalFailure:
            return try DomainObservation(
                domain: domain,
                state: fixture.initial,
                capturedAt: now(),
                failure: failure(retryable: fixture.initial == .retryableFailure)
            )
        case .satisfied:
            return try DomainObservation(
                domain: domain,
                state: .satisfied,
                resource: ResourceIdentity(domain: domain, resourceID: "preexisting-\(domain.rawValue)"),
                ownership: .historicalReceipt,
                capturedAt: now()
            )
        default:
            return try DomainObservation(domain: domain, state: fixture.initial, capturedAt: now())
        }
    }

    func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        let ordinal = try await world.recordCall(domain, .execute)
        let action = injection(.execute, ordinal)
        switch action {
        case .retryableFailure?: throw try failure(retryable: true)
        case .terminalFailure?: throw try failure(retryable: false)
        case .crashBefore?: crash()
        case .crashAfter?, nil: break
        }
        let record: ResourceRecord
        switch context.planned.kind {
        case .proveCandidate, .promoteCandidate:
            guard let candidate = context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
            record = candidate
        case .createCandidate, .replaceCandidate, .revokeOwnedCertificate:
            let resourceID = "\(domain.rawValue)-g\(context.planned.generation.rawValue)"
            try await world.ensureResource(domain, id: resourceID)
            record = try ResourceRecord(
                id: "record-\(resourceID)",
                identity: ResourceIdentity(domain: domain, resourceID: resourceID, digest: ScenarioDigest.sha256(Data(resourceID.utf8))),
                lifecycle: .candidate,
                generation: context.planned.generation,
                ownership: .privateKeyControl,
                createdAt: now(),
                observedAt: now()
            )
        }
        if action == .crashAfter { crash() }
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
    }

    func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        let ordinal = try await world.recordCall(domain, .prove)
        let action = injection(.prove, ordinal)
        switch action {
        case .retryableFailure?: throw try failure(retryable: true)
        case .terminalFailure?: throw try failure(retryable: false)
        case .crashBefore?: crash()
        case .crashAfter?, nil: break
        }
        guard let candidate = receipt.candidate ?? context.candidate,
              await world.domain(domain).resources.contains(candidate.identity.resourceID) else {
            throw InstallationStateFailure.candidateMissing(domain)
        }
        let connection = fixture.connectionBound ? context.scope.connectionGeneration : nil
        try await world.recordProof(domain, id: candidate.identity.resourceID, connection: connection)
        if action == .crashAfter { crash() }
        let material = "proof|\(candidate.identity.resourceID)|\(candidate.generation.rawValue)|\(connection.map(String.init) ?? "-")"
        return try Evidence(
            id: ScenarioDigest.sha256(Data(material.utf8)),
            kind: "scenarioBoundaryProof",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now(),
            connectionGeneration: connection,
            provenance: "scenario-fixture"
        )
    }

    private func injection(_ operation: ScenarioBoundaryOperation, _ ordinal: Int) -> ScenarioInjectionAction? {
        injections.first { $0.domain == domain && $0.operation == operation && $0.ordinal == ordinal }?.action
    }

    private func failure(retryable: Bool) throws -> VeyaFailure {
        try VeyaFailure(
            namespace: domain.failureNamespace,
            number: retryable ? 90 : 91,
            operation: "scenarioBoundary",
            safeMessage: retryable ? "Simulated retryable boundary failure." : "Simulated terminal boundary failure.",
            retryable: retryable,
            underlyingSubsystem: domain.rawValue
        )
    }
}

public enum ScenarioComposition {
    public static let injectedCrashExitCode: Int32 = 86

    /// Production engine composed over the simulated world described by the scenario fixture.
    public static func make(binding: ScenarioBinding, crash: @escaping @Sendable () -> Never) async throws -> EngineComposition {
        let fixtureURL = URL(fileURLWithPath: binding.fixturePath)
        let (fixture, digest) = try ScenarioFixture.load(fixtureURL)
        guard digest == binding.fixtureDigest else { throw QualificationRefusal.fixtureDigestMismatch }
        let root = URL(fileURLWithPath: binding.stateRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let world = try ScenarioWorld(stateRoot: root)
        try await world.prepare(completedUserActions: binding.completedUserActions, advanceClockSeconds: binding.advanceClockSeconds)
        let start = Date(timeIntervalSince1970: TimeInterval(fixture.clockStartMilliseconds) / 1000)
        let clock = start.addingTimeInterval(TimeInterval(await world.clockOffsetSeconds))
        let now: @Sendable () -> Date = { clock }
        let ids = ScenarioIDSource(seed: binding.seed)
        let domains = fixture.domains.map {
            ScenarioFixtureDomain(fixture: $0, injections: fixture.injections, world: world, now: now, crash: crash)
        }
        return EngineComposition(
            repository: InstallationJournalRepository(rootURL: root.appendingPathComponent("journal", isDirectory: true), now: now),
            observers: domains,
            transitions: domains,
            now: now,
            makeID: { ids.next() },
            identity: EngineIdentity(packaged: false, qualificationBuild: true)
        )
    }
}

private final class ScenarioIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private let seed: String
    private var counter = 0

    init(seed: String) { self.seed = seed }

    func next() -> UUID {
        lock.withLock {
            counter += 1
            return ScenarioDigest.uuid(seed: seed, counter: counter)
        }
    }
}
#endif

extension InstallationDomain {
    var failureNamespace: InstallationFailureNamespace {
        switch self {
        case .artifact: return .artifact
        case .authorization: return .authorization
        case .team: return .team
        case .signingKey: return .key
        case .certificate: return .certificate
        case .profile: return .profile
        case .payload: return .signing
        case .application: return .install
        case .developerSupport: return .developerSupport
        case .pairing: return .pairing
        case .vpn: return .vpn
        case .runtime: return .runtime
        case .migration: return .migration
        }
    }
}
