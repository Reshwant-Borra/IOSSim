import Foundation
import Security

// M6 certificate reconciliation (spec 07). Ownership is cryptographic only: a certificate belongs to
// this Veya installation iff its SubjectPublicKeyInfo digest equals a public-key digest this
// installation's key store generated. Names, machine markers, serials in metadata, team membership
// and recency never authorize a revocation. Revocation takes an `OwnedObsoleteCertificate`, which only
// `CertificatePlanner` can construct, so revoking an unknown certificate is not expressible.

public enum CertificateFailure {
    static func make(_ number: Int, _ operation: String, _ message: String, retryable: Bool = false) -> VeyaFailure {
        // Constant, validated inputs; construction cannot fail.
        try! VeyaFailure(namespace: .certificate, number: number, operation: operation, safeMessage: message,
                         retryable: retryable, underlyingSubsystem: "certificateReconciliation")
    }

    public static let inventoryContradiction = make(40, "observe", "Apple returned a contradictory certificate inventory.", retryable: true)
    public static let issueBudgetExhausted = make(41, "issue", "Certificate issuance did not succeed within its attempt limit.", retryable: true)
    public static let issuedCertificateMismatch = make(42, "issue", "Apple returned a certificate that does not match Veya's signing key.")
    public static let noSigningKey = make(43, "plan", "No Veya signing key is available to certify.")
    /// User-safe capacity guidance: nothing Veya can prove it owns may be revoked.
    public static let capacityRequiresUser = make(46, "reclaim", "Your Apple Account has reached its development certificate limit. Revoke an unused certificate in your Apple Account, then retry.")
}

/// Normalized Apple inventory entry. `spkiSHA256` is derived from the DER, never taken from Apple text.
public struct AppleCertificateObservation: Equatable, Sendable {
    public let serial: String
    public let derSHA256: String
    public let spkiSHA256: String
    public let expiresAt: Date
    /// The Apple-issued DER itself (public); nil only in planner-level fixtures.
    public let der: Data?

    public init(serial: String, derSHA256: String, spkiSHA256: String, expiresAt: Date, der: Data? = nil) {
        self.serial = serial
        self.derSHA256 = derSHA256
        self.spkiSHA256 = spkiSHA256
        self.expiresAt = expiresAt
        self.der = der
    }

    /// Parses Apple-issued DER; returns nil for anything that is not an RSA-2048 certificate.
    public init?(serial: String, der: Data) {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let key = SecCertificateCopyKey(certificate),
              SecKeyGetBlockSize(key) * 8 == 2048,
              let pkcs1 = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let notAfter = Self.notAfter(certificate) else { return nil }
        self.init(
            serial: serial,
            derSHA256: VeyaSigningKeyStore.sha256(der),
            spkiSHA256: VeyaSigningKeyStore.sha256(Data(RSAKeyDER.spki(pkcs1Public: Array(pkcs1)))),
            expiresAt: notAfter,
            der: der
        )
    }

    private static func notAfter(_ certificate: SecCertificate) -> Date? {
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, &error)
                as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}

/// Public-key facts from this installation's key store and journal.
public struct CertificateKeyFacts: Equatable, Sendable {
    /// The key the next signing will use (candidate if one exists, else active).
    public let signingKeySPKI: String?
    /// Every other public-key digest this installation generated and still references (active/candidate).
    public let referencedKeySPKIs: Set<String>
    /// Digests of keys this installation generated and has retired. Only these can make a certificate reclaimable.
    public let retiredKeySPKIs: Set<String>

    public init(signingKeySPKI: String?, referencedKeySPKIs: Set<String> = [], retiredKeySPKIs: Set<String> = []) {
        self.signingKeySPKI = signingKeySPKI
        self.referencedKeySPKIs = referencedKeySPKIs
        self.retiredKeySPKIs = retiredKeySPKIs
    }
}

extension CertificateKeyFacts {
    /// Derived from the journal's `.signingKey` records, whose identity digest is the key's SPKI SHA-256.
    /// Retiring records are never dropped from the journal, so retired digests remain provable.
    public init(journal: InstallationJournal) {
        let domain = InstallationDomain.signingKey
        let candidate = journal.candidateResource(for: domain)?.identity.digest
        let active = journal.activeResource(for: domain)?.identity.digest
        let referenced = Set([candidate, active].compactMap { $0 })
        let retired = Set((journal.retiring[domain.rawValue] ?? []).compactMap { $0.identity.digest })
        self.init(signingKeySPKI: candidate ?? active, referencedKeySPKIs: referenced,
                  retiredKeySPKIs: retired.subtracting(referenced))
    }
}

/// Constructible only by `CertificatePlanner`: SPKI proven to be a retired key of this installation.
public struct OwnedObsoleteCertificate: Equatable, Sendable {
    public let serial: String
    public let spkiSHA256: String
    fileprivate init(_ observation: AppleCertificateObservation) {
        serial = observation.serial
        spkiSHA256 = observation.spkiSHA256
    }
}

public enum CertificateDecision: Equatable, Sendable {
    case reuse(serial: String)
    case issue(forSPKI: String)
    case revoke(OwnedObsoleteCertificate)
    case fail(VeyaFailure)
}

public struct CertificateBudget: Equatable, Sendable {
    public static let maxIssueAttempts = 2
    public static let maxRevocations = 1
    public var issueAttempts = 0
    public var revocations = 0
    /// Set when Apple rejected issuance for capacity (7460) and the inventory has been refreshed since.
    public var capacityRejected = false
    public init() {}
}

public enum CertificatePlanner {
    /// Personal Team certificates are replaced before this much validity remains.
    public static let minimumRemainingValidity: TimeInterval = 72 * 3600

    public static func decide(
        inventory: [AppleCertificateObservation],
        keys: CertificateKeyFacts,
        budget: CertificateBudget,
        now: Date
    ) -> CertificateDecision {
        var bySerial: [String: AppleCertificateObservation] = [:]
        for entry in inventory {
            if let existing = bySerial[entry.serial], existing != entry {
                return .fail(CertificateFailure.inventoryContradiction)
            }
            bySerial[entry.serial] = entry
        }
        guard let signingSPKI = keys.signingKeySPKI else { return .fail(CertificateFailure.noSigningKey) }

        let usable = bySerial.values
            .filter { $0.spkiSHA256 == signingSPKI && $0.expiresAt.timeIntervalSince(now) >= minimumRemainingValidity }
            .max { ($0.expiresAt, $0.serial) < ($1.expiresAt, $1.serial) }
        if let usable { return .reuse(serial: usable.serial) }

        guard budget.capacityRejected else {
            return budget.issueAttempts < CertificateBudget.maxIssueAttempts
                ? .issue(forSPKI: signingSPKI) : .fail(CertificateFailure.issueBudgetExhausted)
        }
        if budget.revocations >= CertificateBudget.maxRevocations {
            // Already reclaimed once; the single retry after it is the last issuance.
            return budget.issueAttempts < CertificateBudget.maxIssueAttempts
                ? .issue(forSPKI: signingSPKI) : .fail(CertificateFailure.capacityRequiresUser)
        }
        let reclaimable = bySerial.values
            .filter {
                keys.retiredKeySPKIs.contains($0.spkiSHA256)
                    && $0.spkiSHA256 != signingSPKI
                    && !keys.referencedKeySPKIs.contains($0.spkiSHA256)
            }
            .min { ($0.expiresAt, $0.serial) < ($1.expiresAt, $1.serial) }
        guard let reclaimable else { return .fail(CertificateFailure.capacityRequiresUser) }
        return .revoke(OwnedObsoleteCertificate(reclaimable))
    }
}

/// Apple Developer Services certificate operations. Implementations never log key or session material.
public protocol AppleCertificateService: Sendable {
    func listDevelopmentCertificates() async throws -> [AppleCertificateObservation]
    /// Submits a CSR for the key with `spkiSHA256`. Throws `AppleCertificateServiceError.capacityReached`
    /// for Apple result 7460.
    func issueCertificate(forSPKI spkiSHA256: String) async throws -> AppleCertificateObservation
    func revoke(_ certificate: OwnedObsoleteCertificate) async throws
}

/// Certificate budgets per transition (idempotency key) for the life of the helper process.
public actor CertificateBudgetLedger {
    private var budgets: [String: CertificateBudget] = [:]
    public init() {}
    public func budget(for key: String) -> CertificateBudget { budgets[key] ?? CertificateBudget() }
    public func record(_ budget: CertificateBudget, for key: String) { budgets[key] = budget }
}

public enum AppleCertificateServiceError: Error, Equatable, Sendable {
    case capacityReached
}

/// Drives the planner against Apple with the spec's hard limits: at most two issue attempts, one
/// revocation, and an inventory refresh before every capacity or post-mutation decision.
public struct CertificateReconciler: Sendable {
    public let service: any AppleCertificateService
    /// Spec 07: automatic revocation of an owned obsolete certificate needs `destructiveOwned` policy.
    public let revocationAllowed: Bool
    public init(service: any AppleCertificateService, revocationAllowed: Bool = true) {
        self.service = service
        self.revocationAllowed = revocationAllowed
    }

    /// `budget` starts from what earlier attempts of the same transition already spent; `spent` is told
    /// before every Apple mutation, so engine retries can never exceed the spec's limits in total.
    public func reconcile(keys: CertificateKeyFacts, budget initial: CertificateBudget = CertificateBudget(),
                          spent: @Sendable (CertificateBudget) async -> Void = { _ in },
                          now: @Sendable () -> Date = { Date() }) async throws -> AppleCertificateObservation {
        var budget = initial
        var inventory = try await service.listDevelopmentCertificates()
        // Bound: 2 issues + 1 revoke + their refreshes cannot exceed this many decisions.
        for _ in 0..<(CertificateBudget.maxIssueAttempts + CertificateBudget.maxRevocations + 1) {
            switch CertificatePlanner.decide(inventory: inventory, keys: keys, budget: budget, now: now()) {
            case .reuse(let serial):
                guard let match = inventory.first(where: { $0.serial == serial }) else { throw CertificateFailure.inventoryContradiction }
                return match
            case .issue(let spki):
                budget.issueAttempts += 1
                await spent(budget)
                do {
                    let issued = try await service.issueCertificate(forSPKI: spki)
                    guard issued.spkiSHA256 == spki else { throw CertificateFailure.issuedCertificateMismatch }
                    return issued
                } catch AppleCertificateServiceError.capacityReached {
                    budget.capacityRejected = true
                    await spent(budget)
                    inventory = try await service.listDevelopmentCertificates()
                }
            case .revoke(let owned):
                guard revocationAllowed else { throw CertificateFailure.capacityRequiresUser }
                budget.revocations += 1
                await spent(budget)
                try await service.revoke(owned)
                inventory = try await service.listDevelopmentCertificates()
            case .fail(let failure):
                throw failure
            }
        }
        throw CertificateFailure.issueBudgetExhausted
    }
}
