import CryptoKit
import Foundation
import Security

// M8 IOSSim → Veya migration (specs 06/16). Legacy state is read-only evidence. Nothing is imported:
// the legacy signing key sat in a keychain whose password was a plaintext file beside it, so its
// confidentiality cannot be established, and Veya always creates a new key candidate. No legacy
// item is written, repaired, ACL-edited, exported, or deleted here; the snapshot never triggers UI.

public struct LegacyItem: Equatable, Sendable {
    public enum Classification: String, Sendable { case absent, present, promptRequired, unreadable }
    public enum Disposition: String, Sendable {
        /// Never imported; a new Veya key/certificate replaces it.
        case replaceWithNewKey
        /// Plaintext-equivalent secret material; retired only by explicit cleanup policy.
        case retireOnCleanup
        /// Consumed by its v2 owner (auth v2 re-seals then deletes v1 files).
        case ownedByV2Store
        /// Historical evidence; never authority for ownership or readiness.
        case evidenceOnly
    }
    public let name: String
    public let classification: Classification
    public let disposition: Disposition
    /// Content digest for non-secret evidence files; nil for secret-bearing or absent items.
    public let digest: String?

    public var ledgerValue: String {
        [classification.rawValue, disposition.rawValue, digest ?? "-"].joined(separator: "|")
    }
}

public protocol LegacyInventoryReading: Sendable {
    func inventory() -> [LegacyItem]
}

public struct LocalLegacyInventoryReader: LegacyInventoryReading {
    private let home: URL
    private let loginKeychainServices: [String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                loginKeychainServices: [String] = ["com.iossim.mac.personal-team-signing", "com.iossim.mac.apple-authorization"]) {
        self.home = home
        self.loginKeychainServices = loginKeychainServices
    }

    public func inventory() -> [LegacyItem] {
        let support = home.appendingPathComponent("Library/Application Support/IOSSim", isDirectory: true)
        let keychains = home.appendingPathComponent("Library/Keychains", isDirectory: true)
        var items: [LegacyItem] = []
        func file(_ name: String, _ url: URL, _ disposition: LegacyItem.Disposition, hash: Bool) {
            let present = FileManager.default.fileExists(atPath: url.path)
            let digest = present && hash ? (try? Data(contentsOf: url)).map(VeyaSigningKeyStore.sha256) : nil
            items.append(.init(name: name, classification: present ? .present : .absent, disposition: disposition, digest: digest))
        }
        file("file.signing-keychain", keychains.appendingPathComponent("Veya-Signing.keychain-db"), .replaceWithNewKey, hash: false)
        file("file.signing-keychain-secret", support.appendingPathComponent("signing-keychain.secret"), .retireOnCleanup, hash: false)
        file("file.signing-metadata-v1", support.appendingPathComponent("signing-metadata-v1"), .evidenceOnly, hash: false)
        file("file.authorization-v1-session", support.appendingPathComponent("authorization-session.enc"), .ownedByV2Store, hash: false)
        file("file.authorization-v1-keychain", keychains.appendingPathComponent("Veya-Authorization.keychain-db"), .ownedByV2Store, hash: false)
        for evidence in ["provisioning-state.json", "setup-journal.json", "native-provisioning-artifacts.json", "provisioning-events.jsonl"] {
            file("file.\(evidence)", support.appendingPathComponent(evidence), .evidenceOnly, hash: true)
        }
        for service in loginKeychainServices {
            items.append(.init(name: "login-keychain.\(service)", classification: loginKeychainPresence(service: service),
                               disposition: service.hasSuffix("apple-authorization") ? .ownedByV2Store : .replaceWithNewKey,
                               digest: nil))
        }
        return items
    }

    /// Attribute-only, UI-suppressed lookup: never returns item data and never prompts.
    private func loginKeychainPresence(service: String) -> LegacyItem.Classification {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        case errSecInteractionNotAllowed, errSecAuthFailed: return .promptRequired
        default: return .unreadable
        }
    }
}

/// `.migration` domain: one read-only legacy snapshot, recorded in the journal's migration ledger.
public struct MigrationDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain = .migration
    private let reader: any LegacyInventoryReading
    private let repository: InstallationJournalRepository
    private let now: @Sendable () -> Date

    public init(reader: any LegacyInventoryReading = LocalLegacyInventoryReader(),
                repository: InstallationJournalRepository, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.repository = repository
        self.now = now
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        if let candidate = journal.candidateResource(for: domain) {
            let proved = journal.evidence.contains { candidate.evidenceIDs.contains($0.id) && $0.generation == candidate.generation }
            return try DomainObservation(domain: domain, state: proved ? .candidateProved : .candidateUnproved,
                                         resource: candidate.identity, ownership: .historicalReceipt, capturedAt: now())
        }
        guard journal.migration.phase != .notStarted, let active = journal.activeResource(for: domain) else {
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now())
        }
        return try DomainObservation(domain: domain, state: .satisfied, resource: active.identity,
                                     ownership: .historicalReceipt, capturedAt: now())
    }

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
        let items = Dictionary(uniqueKeysWithValues: reader.inventory().map { ($0.name, $0.ledgerValue) })
        _ = try await repository.updateMigration(runID: context.runID, phase: .inventoried, items: items)
        let record = try ResourceRecord(
            id: "migration-\(context.planned.generation.rawValue)",
            identity: ResourceIdentity(domain: domain, resourceID: "legacy-snapshot", digest: Self.digest(items)),
            lifecycle: .candidate,
            generation: context.planned.generation,
            ownership: .historicalReceipt,
            createdAt: now(),
            observedAt: now()
        )
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        guard let candidate = receipt.candidate ?? context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
        let journal = try await repository.load()
        guard journal.migration.phase == .inventoried, Self.digest(journal.migration.items) == candidate.identity.digest else {
            throw InstallationStateFailure.candidateUnproved(domain)
        }
        return try Evidence(
            id: VeyaSigningKeyStore.sha256(Data("migration-proof|\(candidate.id)|\(candidate.generation.rawValue)".utf8)),
            kind: "legacyInventorySnapshot",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now(),
            provenance: "veya-migration-reader",
            attributes: ["items": String(journal.migration.items.count)]
        )
    }

    static func digest(_ items: [String: String]) -> String {
        VeyaSigningKeyStore.sha256(Data(items.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").utf8))
    }
}
