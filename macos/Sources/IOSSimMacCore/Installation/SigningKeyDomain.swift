import Foundation

/// `.signingKey` domain service for the canonical engine: observes, creates candidates, and proves
/// keys through `VeyaSigningKeyStore`. It never promotes or advances stages itself.
public struct SigningKeyDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain = .signingKey
    private let store: VeyaSigningKeyStore
    private let now: @Sendable () -> Date

    public init(store: VeyaSigningKeyStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        if let candidate = journal.candidateResource(for: domain) {
            if let failure = await verification(candidate, installationID: journal.installationID) {
                return try observation(for: failure, resource: candidate.identity)
            }
            let proved = journal.evidence.contains {
                candidate.evidenceIDs.contains($0.id) && $0.generation == candidate.generation
            }
            return try DomainObservation(
                domain: domain,
                state: proved ? .candidateProved : .candidateUnproved,
                resource: candidate.identity,
                ownership: .privateKeyControl,
                capturedAt: now()
            )
        }
        guard let active = journal.activeResource(for: domain) else {
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now())
        }
        if let failure = await verification(active, installationID: journal.installationID) {
            return try observation(for: failure, resource: active.identity)
        }
        return try DomainObservation(
            domain: domain,
            state: .satisfied,
            resource: active.identity,
            ownership: .privateKeyControl,
            capturedAt: now()
        )
    }

    public func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        switch context.planned.kind {
        case .proveCandidate, .promoteCandidate:
            guard let candidate = context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
            return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: candidate.generation, candidate: candidate)
        case .createCandidate, .replaceCandidate:
            let key = try await store.createCandidate(installationID: context.installationID)
            let record = try ResourceRecord(
                id: key.keyID,
                identity: ResourceIdentity(domain: domain, resourceID: key.keyID, digest: key.publicKeySHA256),
                lifecycle: .candidate,
                generation: context.planned.generation,
                ownership: .privateKeyControl,
                createdAt: key.createdAt,
                observedAt: now(),
                relativeLocation: store.relativeLocation(keyID: key.keyID),
                metadata: [
                    "algorithm": key.algorithm,
                    "ciphertextSHA256": key.ciphertextSHA256,
                    "envelopeVersion": String(key.envelopeVersion),
                ]
            )
            return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
        case .revokeOwnedCertificate:
            throw InstallationStateFailure.transitionUnavailable(domain)
        }
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        guard let candidate = receipt.candidate ?? context.candidate, let publicHash = candidate.identity.digest else {
            throw InstallationStateFailure.candidateMissing(domain)
        }
        let verified = try await store.verify(
            keyID: candidate.identity.resourceID,
            installationID: context.installationID,
            expectedPublicKeySHA256: publicHash
        )
        return try Evidence(
            id: VeyaSigningKeyStore.sha256(Data("signing-key-proof|\(verified.keyID)|\(candidate.generation.rawValue)|\(verified.ciphertextSHA256)".utf8)),
            kind: "signingKeySignVerifyProbe",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now(),
            provenance: "veya-signing-key-store",
            attributes: ["publicKeySHA256": verified.publicKeySHA256]
        )
    }

    /// nil when the key decrypts, matches its public key, and passes the sign/verify probe.
    private func verification(_ record: ResourceRecord, installationID: UUID) async -> VeyaFailure? {
        guard let publicHash = record.identity.digest else { return SigningKeyFailure.publicKeyMismatch }
        do {
            try await store.verify(keyID: record.identity.resourceID, installationID: installationID, expectedPublicKeySHA256: publicHash)
            return nil
        } catch let failure as VeyaFailure {
            return failure
        } catch {
            return SigningKeyFailure.corruptEnvelope
        }
    }

    private func observation(for failure: VeyaFailure, resource: ResourceIdentity) throws -> DomainObservation {
        switch failure.code {
        case SigningKeyFailure.interactionRequired.code, SigningKeyFailure.wrappingStoreUnavailable.code:
            // Access failures are not key failures: replacing the key would fail the same way.
            return try DomainObservation(domain: domain, state: .terminalFailure, resource: resource, capturedAt: now(), failure: failure)
        case SigningKeyFailure.keychainFailure.code:
            return try DomainObservation(domain: domain, state: .retryableFailure, resource: resource, capturedAt: now(), failure: failure)
        default:
            // Missing wrapper/ciphertext, GCM failure, corruption, unsafe file, or mismatch: never repaired in
            // place; the planner replaces the key with a new candidate.
            return try DomainObservation(
                domain: domain, state: .invalid, resource: resource, ownership: .privateKeyControl,
                capturedAt: now(), safeReason: failure.code
            )
        }
    }
}
