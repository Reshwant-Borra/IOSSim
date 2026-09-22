import Foundation

// M10 runtime readiness (spec 14). READY is the `.runtime` domain being satisfied, and that requires a
// proof object that is (a) fresh (default TTL 10 minutes), (b) produced on the current device connection
// generation, and (c) bound to the exact active application, developer support, pairing and VPN records.
// Stored or cached state alone can never make it satisfied: any upstream change makes it stale.

public struct RuntimeProofResult: Equatable, Sendable {
    /// Digest of the validated phone receipt (full chain incl. nonce write, observation, clear, cleanup).
    public let receiptDigest: String
    public let completedAt: Date
    public init(receiptDigest: String, completedAt: Date) {
        self.receiptDigest = receiptDigest
        self.completedAt = completedAt
    }
}

public protocol RuntimeProving: Sendable {
    /// Runs the complete bounded proof chain; throws a typed failure (e.g. cleanup failure) otherwise.
    func proveRuntime(binding: String, scope: InstallationScope) async throws -> RuntimeProofResult
}

public struct RuntimeReadinessDomain: InstallationObserver, InstallationTransition {
    public static let upstream: [InstallationDomain] = [.application, .developerSupport, .pairing, .vpn]
    public let domain: InstallationDomain = .runtime
    private let repository: InstallationJournalRepository
    private let prover: any RuntimeProving
    private let timeToLive: TimeInterval
    private let now: @Sendable () -> Date

    public init(repository: InstallationJournalRepository, prover: any RuntimeProving, timeToLive: TimeInterval = 600,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository
        self.prover = prover
        self.timeToLive = timeToLive
        self.now = now
    }

    /// Nil when any upstream domain has no active record: nothing to bind a proof to.
    static func binding(journal: InstallationJournal, scope: InstallationScope) -> String? {
        var parts: [String] = []
        for upstream in upstream {
            guard let active = journal.activeResource(for: upstream) else { return nil }
            parts.append("\(upstream.rawValue)=\(active.identity.resourceID)@\(active.identity.digest ?? "-")")
        }
        parts.append("device=\(scope.selectedDeviceIDHash ?? "-")")
        parts.append("connection=\(scope.connectionGeneration.map(String.init) ?? "-")")
        return VeyaSigningKeyStore.sha256(Data(parts.joined(separator: "\n").utf8))
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        let generation = scope.connectionGeneration
        guard let binding = Self.binding(journal: journal, scope: scope) else {
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now(), connectionGeneration: generation)
        }
        let current = try ResourceIdentity(domain: domain, resourceID: "runtime-proof", digest: binding)
        if let candidate = journal.candidateResource(for: domain) {
            guard candidate.identity == current else {
                return try DomainObservation(domain: domain, state: .invalid, resource: candidate.identity,
                                             capturedAt: now(), connectionGeneration: generation)
            }
            let proof = journal.evidence.last { candidate.evidenceIDs.contains($0.id) && $0.generation == candidate.generation }
            return try DomainObservation(domain: domain, state: proof == nil ? .candidateUnproved : .candidateProved,
                                         resource: candidate.identity, ownership: .activePayloadCorroboration,
                                         capturedAt: now(), validUntil: proof?.validUntil, connectionGeneration: generation)
        }
        guard let active = journal.activeResource(for: domain) else {
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now(), connectionGeneration: generation)
        }
        let proof = journal.evidence.last { active.evidenceIDs.contains($0.id) && $0.kind == Self.evidenceKind }
        // Upstream replacement, reconnect, or device change: the previous proof describes another system.
        guard active.identity == current, let validUntil = proof?.validUntil else {
            return try DomainObservation(domain: domain, state: .stale, resource: active.identity,
                                         capturedAt: now(), connectionGeneration: generation)
        }
        return try DomainObservation(domain: domain, state: .satisfied, resource: active.identity,
                                     ownership: .activePayloadCorroboration, capturedAt: now(),
                                     validUntil: validUntil, connectionGeneration: generation)
    }

    static let evidenceKind = "runtimeFullChainProof"

    public func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        switch context.planned.kind {
        case .proveCandidate, .promoteCandidate:
            guard let candidate = context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
            return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: candidate.generation, candidate: candidate)
        case .revokeOwnedCertificate:
            throw InstallationStateFailure.transitionUnavailable(domain)
        case .createCandidate, .replaceCandidate:
            break
        }
        // The candidate only names what will be proven; the proof itself runs in `prove`.
        let journal = try await repository.load()
        guard let binding = Self.binding(journal: journal, scope: context.scope) else {
            throw InstallationStateFailure.candidateUnproved(domain)
        }
        let record = try ResourceRecord(
            id: "runtime-\(context.planned.generation.rawValue)",
            identity: ResourceIdentity(domain: domain, resourceID: "runtime-proof", digest: binding),
            lifecycle: .candidate, generation: context.planned.generation, ownership: .activePayloadCorroboration,
            createdAt: now(), observedAt: now()
        )
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        guard let candidate = receipt.candidate ?? context.candidate, let binding = candidate.identity.digest else {
            throw InstallationStateFailure.candidateMissing(domain)
        }
        let started = now()
        let result = try await prover.proveRuntime(binding: binding, scope: context.scope)
        guard result.completedAt >= started.addingTimeInterval(-5), result.completedAt <= now().addingTimeInterval(5) else {
            throw RichRuntimeProofFailure.receiptInvalid
        }
        return try Evidence(
            id: VeyaSigningKeyStore.sha256(Data("runtime-proof|\(candidate.id)|\(candidate.generation.rawValue)|\(result.receiptDigest)".utf8)),
            kind: Self.evidenceKind,
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: result.completedAt,
            validUntil: result.completedAt.addingTimeInterval(timeToLive),
            connectionGeneration: context.scope.connectionGeneration,
            provenance: "rich-runtime-inbox",
            attributes: ["receipt": result.receiptDigest]
        )
    }
}
