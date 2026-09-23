import Foundation
import Security

// M6 routing: the Apple account, Personal Team, development certificate and development profiles as
// canonical engine domains. The helper never performs interactive sign-in; a missing or expired
// session is a user action. Certificates are reconciled only through `CertificateReconciler`
// (SPKI ownership, 2 issues / 1 revoke), and the public DER / profiles are content files under the
// Veya state root referenced from the journal.

/// Apple Developer Services operations used by Installation V2. Production: `LiveApplePersonalTeamBackend`.
public protocol AppleDeveloperServices: Sendable {
    /// Resumes the stored (v2) session if needed and returns the single Personal Team.
    func currentPersonalTeam() async throws -> ExperimentalAppleTeam
    func listDevelopmentCertificates(teamID: String) async throws -> [AppleCertificateObservation]
    /// Nil when Apple accepted the CSR but returned no parseable certificate (resolved by inventory).
    func submitDevelopmentCSR(teamID: String, csrPEM: String) async throws -> AppleCertificateObservation?
    func revokeDevelopmentCertificate(teamID: String, serial: String) async throws
    func ensureDeviceRegistered(team: ExperimentalAppleTeam, udid: String, name: String) async throws
    func ensureAppIdentifiers(_ identifiers: PersonalTeamBundleIdentifierSet, team: ExperimentalAppleTeam) async throws
    func downloadDevelopmentProfile(teamID: String, bundleIdentifier: String) async throws -> Data
}

public enum AppleDomainFailure {
    static func make(_ namespace: InstallationFailureNamespace, _ number: Int, _ operation: String, _ message: String,
                     retryable: Bool = false) -> VeyaFailure {
        // Constant, validated inputs; construction cannot fail.
        try! VeyaFailure(namespace: namespace, number: number, operation: operation, safeMessage: message,
                         retryable: retryable, underlyingSubsystem: "appleDeveloperServices")
    }
    public static let signInAction = "Sign in to your Apple Account in Veya, then continue in Veya."
    public static let selectDeviceAction = "Connect your iPhone, unlock it, and select it, then continue in Veya."
    public static let sessionExpired = try! VeyaFailure(
        namespace: .authorization, number: 30, operation: "request", safeMessage: "Your Apple sign-in has expired.",
        userAction: signInAction, underlyingSubsystem: "appleDeveloperServices")
    public static let unreachable = make(.authorization, 31, "request", "Apple Developer Services could not be reached.", retryable: true)
    public static let protocolChanged = make(.authorization, 32, "request", "Apple changed a developer service response. Update Veya.")
    public static let rateLimited = make(.authorization, 33, "request", "Apple asked Veya to wait before trying again.", retryable: true)
    public static let noPersonalTeam = make(.team, 30, "resolve", "This Apple Account has no Personal Team.")
    public static let teamAmbiguous = make(.team, 31, "resolve", "This Apple Account has more than one Personal Team.")
    public static let teamChanged = make(.team, 32, "resolve", "The signed-in Apple Account is not the one Veya's certificate belongs to.")
    public static let certificateRequestFailed = make(.certificate, 44, "issue", "Apple did not issue a development certificate.", retryable: true)
    public static let revocationFailed = make(.certificate, 45, "revoke", "Apple rejected the certificate revocation.")
    public static let certificateMissing = make(.certificate, 47, "plan", "No proven development certificate is available.")
    public static let deviceLimit = make(.profile, 30, "registerDevice", "Your Apple Account has reached its device limit. Remove an unused device in your Apple Account, then retry.")
    public static let deviceRegistrationFailed = make(.profile, 31, "registerDevice", "Apple did not register this iPhone.", retryable: true)
    public static let appIDLimit = make(.profile, 32, "registerAppID", "Your Apple Account has reached its App ID limit. Wait for older App IDs to expire (up to 7 days), then retry.")
    public static let appIDFailed = make(.profile, 33, "registerAppID", "Apple did not register Veya's app identifiers.", retryable: true)
    public static let profileRequestFailed = make(.profile, 34, "issue", "Apple did not issue a provisioning profile.", retryable: true)
    public static let profileInvalid = make(.profile, 35, "validate", "Apple returned a provisioning profile that does not match this certificate, iPhone, or app.")
    public static let profileMissing = make(.profile, 36, "plan", "No proven provisioning profiles are available.")

    /// Typed, user-safe failure for a backend error. Session loss is not a failure: callers map it to sign-in.
    static func map(_ error: Error) -> Error {
        guard let backend = error as? ExperimentalBackendError else { return error }
        switch backend {
        case .networkFailure, .serviceUnavailable, .developerServicesFailed, .redirectRejected: return unreachable
        case .rateLimited: return rateLimited
        case .responseChanged, .authenticationProtocolMismatch, .responseTooLarge, .adapterDisabled: return protocolChanged
        case .noTeam: return noPersonalTeam
        case .personalTeamAmbiguous: return teamAmbiguous
        case .invalidTeam: return teamChanged
        case .certificateLimit: return CertificateFailure.capacityRequiresUser
        case .certificateRequestFailed: return certificateRequestFailed
        case .certificateRevocationFailed, .certificateCapacityNotReleased: return revocationFailed
        case .deviceLimit: return deviceLimit
        case .deviceNameRequired, .invalidDeviceIdentifier, .deviceRegistrationFailed: return deviceRegistrationFailed
        case .appIDLimit: return appIDLimit
        case .appIDCollision, .appIDRegistrationFailed: return appIDFailed
        case .invalidProfile: return profileInvalid
        case .profileRequestFailed: return profileRequestFailed
        default: return error
        }
    }

    static func requiresSignIn(_ error: Error) -> Bool {
        guard let backend = error as? ExperimentalBackendError else { return false }
        return [.sessionExpired, .badPassword, .authenticationRejected, .verificationExpired, .srpAuthFailed,
                .verificationRejected, .xcodeScopedTokenFailed].contains(backend)
    }
}

/// One Apple session per helper run: the team is resolved once and reused by every domain.
public actor AppleAccountContext {
    public nonisolated let services: any AppleDeveloperServices
    private var cached: ExperimentalAppleTeam?

    public init(services: any AppleDeveloperServices) {
        self.services = services
    }

    public func team() async throws -> ExperimentalAppleTeam {
        if let cached { return cached }
        let team = try await services.currentPersonalTeam()
        cached = team
        return team
    }
}

/// `.authorization` and `.team`: observation only. Veya never signs in on the user's behalf.
public struct AppleAccountDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain
    private let account: AppleAccountContext
    private let now: @Sendable () -> Date

    public init(domain: InstallationDomain, account: AppleAccountContext, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(domain == .authorization || domain == .team)
        self.domain = domain
        self.account = account
        self.now = now
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        do {
            let team = try await account.team()
            let resource = domain == .team
                ? try ResourceIdentity(domain: domain, resourceID: team.id)
                : try ResourceIdentity(domain: domain, resourceID: "apple-session")
            return try DomainObservation(domain: domain, state: .satisfied, resource: resource, capturedAt: now())
        } catch where AppleDomainFailure.requiresSignIn(error) {
            return try DomainObservation(domain: domain, state: .waitingForUser, capturedAt: now(),
                                         userAction: AppleDomainFailure.signInAction)
        } catch ExperimentalBackendError.noTeam where domain == .authorization {
            // The session itself is valid; `.team` reports the missing Personal Team.
            return try DomainObservation(domain: domain, state: .satisfied,
                                         resource: try ResourceIdentity(domain: domain, resourceID: "apple-session"), capturedAt: now())
        } catch {
            let failure = AppleDomainFailure.map(error) as? VeyaFailure ?? AppleDomainFailure.unreachable
            return try DomainObservation(domain: domain, state: failure.retryable ? .retryableFailure : .terminalFailure,
                                         capturedAt: now(), failure: failure)
        }
    }

    public func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        throw InstallationStateFailure.transitionUnavailable(domain)
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        throw InstallationStateFailure.transitionUnavailable(domain)
    }
}

/// Public content (certificate DER, profiles) under the Veya state root: `0700` directories, `0600` files,
/// atomic replace, and digest-checked reads.
enum StateContentFiles {
    static func write(_ data: Data, relative: String, root: URL) throws {
        try InstallationSafeValue.validateRelativePath(relative)
        let url = root.appendingPathComponent(relative)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PayloadFailure.stagingUnsafe
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw PayloadFailure.stagingUnsafe
        }
    }

    /// Removes entries of `directory` (e.g. `staging`) that no active, candidate or retained retiring record
    /// of `domain` references. Called only from a transition, i.e. while this run holds the journal lease.
    /// Retiring records keep their content until the journal drops them (rollback evidence).
    static func collectUnreferenced(_ directory: String, domain: InstallationDomain, journal: InstallationJournal, root: URL) {
        let records = [journal.activeResource(for: domain), journal.candidateResource(for: domain)].compactMap { $0 }
            + (journal.retiring[domain.rawValue] ?? [])
        let referenced = Set(records.compactMap { $0.relativeLocation?.split(separator: "/").dropFirst().first.map(String.init) })
        let url = root.appendingPathComponent(directory, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for entry in entries where !referenced.contains(entry) {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(entry))
        }
    }

    /// Nil unless the file exists, is a regular file inside the root, and matches `digest`.
    static func read(relative: String?, root: URL, digest: String?) -> Data? {
        guard let relative, (try? InstallationSafeValue.validateRelativePath(relative)) != nil else { return nil }
        let url = root.appendingPathComponent(relative)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url) else { return nil }
        if let digest, VeyaSigningKeyStore.sha256(data) != digest { return nil }
        return data
    }
}

extension VeyaSigningKeyStore {
    /// PEM CSR for a stored key. The private key exists only inside the closure-scoped buffer and an
    /// in-memory `SecKey`; nothing is added to any Keychain.
    func certificateSigningRequest(keyID: String, installationID: UUID) throws -> String {
        try withUnlockedPKCS8(keyID: keyID, installationID: installationID) { buffer in
            var pkcs8 = Array(buffer)
            defer { Self.zero(&pkcs8) }
            var pkcs1 = try RSAKeyDER.pkcs1(fromPKCS8: pkcs8)
            defer { Self.zero(&pkcs1) }
            var data = Data(pkcs1)
            defer { data.resetBytes(in: 0..<data.count) }
            guard let key = SecKeyCreateWithData(data as CFData, [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 2_048,
            ] as CFDictionary, nil) else {
                throw SigningKeyFailure.corruptEnvelope
            }
            return try createCertificateSigningRequest(key: key)
        }
    }
}

/// `AppleCertificateService` for one team; CSRs come from this installation's key store.
struct TeamCertificateService: AppleCertificateService {
    let services: any AppleDeveloperServices
    let teamID: String
    let csr: @Sendable (String) async throws -> String

    func listDevelopmentCertificates() async throws -> [AppleCertificateObservation] {
        try await services.listDevelopmentCertificates(teamID: teamID)
    }

    func issueCertificate(forSPKI spkiSHA256: String) async throws -> AppleCertificateObservation {
        let pem = try await csr(spkiSHA256)
        if let issued = try await services.submitDevelopmentCSR(teamID: teamID, csrPEM: pem) { return issued }
        // Accepted without a usable certificate in the response: resolve by SPKI, never by a blind reissue.
        if let match = try await listDevelopmentCertificates().first(where: { $0.spkiSHA256 == spkiSHA256 }) { return match }
        throw AppleDomainFailure.certificateRequestFailed
    }

    func revoke(_ certificate: OwnedObsoleteCertificate) async throws {
        try await services.revokeDevelopmentCertificate(teamID: teamID, serial: certificate.serial)
    }
}

public struct CertificateDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain = .certificate
    /// Certificates are re-checked against Apple's inventory at least this often (revocation elsewhere).
    public static let proofLifetime: TimeInterval = 24 * 3600
    private let rootURL: URL
    private let repository: InstallationJournalRepository
    private let account: AppleAccountContext
    private let keyStore: VeyaSigningKeyStore
    /// Engine retries of one transition share its issue/revoke budget (spec 07 totals).
    private let ledger = CertificateBudgetLedger()
    private let now: @Sendable () -> Date

    public init(rootURL: URL, repository: InstallationJournalRepository, account: AppleAccountContext,
                keyStore: VeyaSigningKeyStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootURL = rootURL
        self.repository = repository
        self.account = account
        self.keyStore = keyStore
        self.now = now
    }

    /// The DER of the journal's active certificate, if present and intact.
    static func activeDER(journal: InstallationJournal, root: URL) -> Data? {
        guard let record = journal.activeResource(for: .certificate) else { return nil }
        return StateContentFiles.read(relative: record.relativeLocation, root: root, digest: record.identity.digest)
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        let signingSPKI = CertificateKeyFacts(journal: journal).signingKeySPKI
        func usable(_ record: ResourceRecord) -> DomainObservationState {
            guard let der = StateContentFiles.read(relative: record.relativeLocation, root: rootURL, digest: record.identity.digest),
                  let parsed = AppleCertificateObservation(serial: record.identity.resourceID, der: der) else { return .invalid }
            // New key, or inside the renewal window: replaced (a still-valid active keeps signing meanwhile).
            guard parsed.spkiSHA256 == signingSPKI,
                  parsed.expiresAt.timeIntervalSince(now()) >= CertificatePlanner.minimumRemainingValidity else { return .stale }
            return .satisfied
        }
        if let candidate = journal.candidateResource(for: domain) {
            let state = usable(candidate)
            guard state == .satisfied else {
                return try DomainObservation(domain: domain, state: .invalid, resource: candidate.identity, capturedAt: now())
            }
            let proved = journal.evidence.contains { candidate.evidenceIDs.contains($0.id) && $0.generation == candidate.generation }
            return try DomainObservation(domain: domain, state: proved ? .candidateProved : .candidateUnproved,
                                         resource: candidate.identity, ownership: .privateKeyControl, capturedAt: now())
        }
        guard let active = journal.activeResource(for: domain) else {
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now())
        }
        let state = usable(active)
        let proof = journal.evidence.last { active.evidenceIDs.contains($0.id) }
        return try DomainObservation(domain: domain, state: state, resource: active.identity, ownership: .privateKeyControl,
                                     capturedAt: now(), validUntil: state == .satisfied ? proof?.validUntil : nil)
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
        let journal = try await repository.load()
        StateContentFiles.collectUnreferenced("certificates", domain: domain, journal: journal, root: rootURL)
        let keys = CertificateKeyFacts(journal: journal)
        let keyRecords = [journal.candidateResource(for: .signingKey), journal.activeResource(for: .signingKey)].compactMap { $0 }
        let team: ExperimentalAppleTeam
        do { team = try await account.team() } catch { throw Self.typed(error) }
        let store = keyStore
        let installationID = context.installationID
        let service = TeamCertificateService(services: account.services, teamID: team.id) { spki in
            guard let record = keyRecords.first(where: { $0.identity.digest == spki }) else { throw CertificateFailure.noSigningKey }
            return try await store.certificateSigningRequest(keyID: record.identity.resourceID, installationID: installationID)
        }
        let certificate: AppleCertificateObservation
        do {
            let key = context.planned.idempotencyKey
            let ledger = ledger
            certificate = try await CertificateReconciler(
                service: service, revocationAllowed: context.maximumPermission >= .destructiveOwned
            ).reconcile(keys: keys, budget: await ledger.budget(for: key),
                        spent: { await ledger.record($0, for: key) }, now: now)
        } catch {
            throw Self.typed(error)
        }
        guard let der = certificate.der else { throw CertificateFailure.issuedCertificateMismatch }
        let relative = "certificates/\(certificate.derSHA256.dropFirst(7)).cer"
        try StateContentFiles.write(der, relative: relative, root: rootURL)
        let record = try ResourceRecord(
            id: "certificate-\(context.planned.generation.rawValue)",
            identity: ResourceIdentity(domain: domain, resourceID: certificate.serial, digest: certificate.derSHA256),
            lifecycle: .candidate,
            generation: context.planned.generation,
            ownership: .privateKeyControl,
            createdAt: now(),
            observedAt: now(),
            expiresAt: certificate.expiresAt,
            relativeLocation: relative,
            metadata: ["teamIdentifier": team.id, "spkiSHA256": certificate.spkiSHA256]
        )
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        guard let candidate = receipt.candidate ?? context.candidate,
              let teamID = candidate.metadata["teamIdentifier"] else {
            throw InstallationStateFailure.candidateMissing(domain)
        }
        // Independent proof: Apple's current inventory lists exactly this DER for the key we control.
        let inventory: [AppleCertificateObservation]
        do { inventory = try await account.services.listDevelopmentCertificates(teamID: teamID) } catch { throw Self.typed(error) }
        let signingSPKI = CertificateKeyFacts(journal: try await repository.load()).signingKeySPKI
        guard let listed = inventory.first(where: { $0.serial == candidate.identity.resourceID }),
              listed.derSHA256 == candidate.identity.digest, listed.spkiSHA256 == signingSPKI,
              listed.expiresAt.timeIntervalSince(now()) >= CertificatePlanner.minimumRemainingValidity else {
            throw CertificateFailure.issuedCertificateMismatch
        }
        let renewAt = listed.expiresAt.addingTimeInterval(-CertificatePlanner.minimumRemainingValidity)
        return try Evidence(
            id: VeyaSigningKeyStore.sha256(Data("certificate-proof|\(candidate.id)|\(candidate.generation.rawValue)|\(listed.derSHA256)".utf8)),
            kind: "appleInventorySPKIMatch",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now(),
            validUntil: min(now().addingTimeInterval(Self.proofLifetime), renewAt),
            provenance: "apple-developer-services",
            attributes: ["spkiSHA256": listed.spkiSHA256]
        )
    }

    static func typed(_ error: Error) -> Error {
        AppleDomainFailure.requiresSignIn(error) ? AppleDomainFailure.sessionExpired : AppleDomainFailure.map(error)
    }
}

/// The selected physical device as Apple Developer Services knows it.
public struct DeviceRegistrationTarget: Equatable, Sendable {
    public let udid: String
    public let name: String
    public init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }
    var digest: String { VeyaSigningKeyStore.sha256(Data("device|\(udid)".utf8)) }
}

/// `.profile`: development profiles for the main app and the XCTest runner, bound to the active
/// certificate, the selected iPhone and the team's derived bundle identifiers.
public struct ProfileDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain = .profile
    /// Free-team profiles last 7 days; they are replaced this long before expiry.
    public static let renewalWindow: TimeInterval = 48 * 3600
    private let rootURL: URL
    private let repository: InstallationJournalRepository
    private let account: AppleAccountContext
    private let device: @Sendable () async throws -> DeviceRegistrationTarget?
    private let validate: @Sendable (Data, String, String, String, Data, Date) throws -> Date
    private let now: @Sendable () -> Date

    /// `validate(profile, bundleID, teamID, udid, certificateDER, now)` returns the expiry or throws.
    public init(rootURL: URL, repository: InstallationJournalRepository, account: AppleAccountContext,
                device: @escaping @Sendable () async throws -> DeviceRegistrationTarget?,
                validate: @escaping @Sendable (Data, String, String, String, Data, Date) throws -> Date = ProfileDomain.validateOffline,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootURL = rootURL
        self.repository = repository
        self.account = account
        self.device = device
        self.validate = validate
        self.now = now
    }

    public static let validateOffline: @Sendable (Data, String, String, String, Data, Date) throws -> Date = { data, bundle, team, udid, der, now in
        try validateDevelopmentProfile(data, bundleIdentifier: bundle, teamIdentifier: team, deviceUDID: udid,
                                       certificateDER: der, now: now).expiresAt
    }

    static let roles = ["main", "runner"]

    /// Main app and runner profiles of a record, keyed by bundle identifier, if intact.
    static func profiles(of record: ResourceRecord, root: URL) -> [String: Data]? {
        guard let directory = record.relativeLocation else { return nil }
        var result: [String: Data] = [:]
        for role in roles {
            guard let bundle = record.metadata["bundle.\(role)"],
                  let data = StateContentFiles.read(relative: "\(directory)/\(role).mobileprovision", root: root,
                                                    digest: record.metadata["sha256.\(role)"]) else { return nil }
            result[bundle] = data
        }
        return result
    }

    private struct Binding {
        let team: String
        let certificateDER: Data
        let certificateDigest: String
        let device: DeviceRegistrationTarget
        let identifiers: PersonalTeamBundleIdentifierSet
        /// Role → bundle identifier, in `ProfileDomain.roles` order.
        var bundles: [(role: String, bundle: String)] { [("main", identifiers.main), ("runner", identifiers.runner)] }
    }

    /// Nil when the certificate or device is not available yet.
    private func binding(journal: InstallationJournal) async throws -> Binding? {
        guard let certificate = journal.activeResource(for: .certificate), let team = certificate.metadata["teamIdentifier"],
              let digest = certificate.identity.digest,
              let der = CertificateDomain.activeDER(journal: journal, root: rootURL),
              let target = try await device() else { return nil }
        return Binding(team: team, certificateDER: der, certificateDigest: digest, device: target,
                       identifiers: try PersonalTeamBundleIdentifierSet(teamIdentifier: team))
    }

    /// Earliest expiry if every profile validates against `binding`; nil otherwise.
    private func validatedExpiry(_ record: ResourceRecord, _ binding: Binding) -> Date? {
        guard record.metadata["certificate"] == binding.certificateDigest, record.metadata["device"] == binding.device.digest,
              let profiles = Self.profiles(of: record, root: rootURL), Set(profiles.keys) == Set(binding.bundles.map(\.bundle)) else { return nil }
        var earliest = Date.distantFuture
        for (bundle, data) in profiles {
            guard let expiry = try? validate(data, bundle, binding.team, binding.device.udid, binding.certificateDER, now()) else { return nil }
            earliest = min(earliest, expiry)
        }
        return earliest
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        guard let binding = try await binding(journal: journal) else {
            // Planner order reaches `.profile` only after `.certificate`; the missing input is the device.
            return try DomainObservation(domain: domain, state: .waitingForUser, capturedAt: now(),
                                         userAction: AppleDomainFailure.selectDeviceAction)
        }
        if let candidate = journal.candidateResource(for: domain) {
            guard validatedExpiry(candidate, binding) != nil else {
                return try DomainObservation(domain: domain, state: .invalid, resource: candidate.identity, capturedAt: now())
            }
            let proved = journal.evidence.contains { candidate.evidenceIDs.contains($0.id) && $0.generation == candidate.generation }
            return try DomainObservation(domain: domain, state: proved ? .candidateProved : .candidateUnproved,
                                         resource: candidate.identity, ownership: .privateKeyControl, capturedAt: now())
        }
        guard let active = journal.activeResource(for: domain) else {
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now())
        }
        // New certificate, another iPhone, or inside the renewal window: replace.
        guard let expiry = validatedExpiry(active, binding),
              expiry.timeIntervalSince(now()) >= Self.renewalWindow else {
            return try DomainObservation(domain: domain, state: .stale, resource: active.identity, capturedAt: now())
        }
        return try DomainObservation(domain: domain, state: .satisfied, resource: active.identity, ownership: .privateKeyControl,
                                     capturedAt: now(), validUntil: expiry.addingTimeInterval(-Self.renewalWindow))
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
        let journal = try await repository.load()
        StateContentFiles.collectUnreferenced("profiles", domain: domain, journal: journal, root: rootURL)
        guard let binding = try await binding(journal: journal) else { throw AppleDomainFailure.certificateMissing }
        let services = account.services
        var metadata = ["teamIdentifier": binding.team, "certificate": binding.certificateDigest, "device": binding.device.digest]
        let directory = "profiles/\(context.planned.generation.rawValue)"
        var parts: [String] = []
        do {
            let team = try await account.team()
            guard team.id == binding.team else { throw AppleDomainFailure.teamChanged }
            try await services.ensureDeviceRegistered(team: team, udid: binding.device.udid, name: binding.device.name)
            try await services.ensureAppIdentifiers(binding.identifiers, team: team)
            for (role, bundle) in binding.bundles {
                let profile = try await services.downloadDevelopmentProfile(teamID: team.id, bundleIdentifier: bundle)
                // Never stage a profile that does not match the exact certificate/device/bundle/team.
                guard (try? validate(profile, bundle, binding.team, binding.device.udid, binding.certificateDER, now())) != nil else {
                    throw AppleDomainFailure.profileInvalid
                }
                try StateContentFiles.write(profile, relative: "\(directory)/\(role).mobileprovision", root: rootURL)
                let digest = VeyaSigningKeyStore.sha256(profile)
                metadata["bundle.\(role)"] = bundle
                metadata["sha256.\(role)"] = digest
                parts.append("\(bundle)=\(digest)")
            }
        } catch {
            throw CertificateDomain.typed(error)
        }
        let record = try ResourceRecord(
            id: "profile-\(context.planned.generation.rawValue)",
            identity: ResourceIdentity(domain: domain, resourceID: "development-profiles",
                                       digest: VeyaSigningKeyStore.sha256(Data(parts.sorted().joined(separator: "\n").utf8))),
            lifecycle: .candidate,
            generation: context.planned.generation,
            ownership: .privateKeyControl,
            createdAt: now(),
            observedAt: now(),
            relativeLocation: directory,
            metadata: metadata
        )
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        guard let candidate = receipt.candidate ?? context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
        guard let binding = try await binding(journal: try await repository.load()),
              let expiry = validatedExpiry(candidate, binding),
              expiry.timeIntervalSince(now()) >= Self.renewalWindow else {
            throw AppleDomainFailure.profileInvalid
        }
        return try Evidence(
            id: VeyaSigningKeyStore.sha256(Data("profile-proof|\(candidate.id)|\(candidate.generation.rawValue)|\(candidate.identity.digest ?? "-")".utf8)),
            kind: "profileCMSBindingValidation",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now(),
            validUntil: expiry.addingTimeInterval(-Self.renewalWindow),
            provenance: "cms-offline-validation"
        )
    }
}
