import Foundation
import Security

/// Isolated boundary for Apple's undocumented free Personal Team protocol.
/// No UI, setup coordinator, or Xcode backend should construct private Apple
/// requests directly. A production implementation must remain replaceable and
/// physically qualified before `isPhysicallyQualified` can become true.
public enum ApplePersonalTeamExperimental {}

public enum AppleAuthorizationMethodCategory: String, Codable, Sendable {
    case privateGrandSlamSRP = "PRIVATE_GRANDSLAM_SRP"
    case appStoreConnectAPIKey = "APP_STORE_CONNECT_API_KEY"
    case xcodeStoredAccount = "XCODE_STORED_ACCOUNT"
}

public enum AppleAuthorizationStage: String, Codable, Equatable, Sendable {
    case notStarted = "NOT_STARTED"
    case startingAuthentication = "STARTING_AUTHENTICATION"
    case challengeReceived = "CHALLENGE_RECEIVED"
    case credentialsVerified = "CREDENTIALS_VERIFIED"
    case verificationRequired = "VERIFICATION_REQUIRED"
    case verificationSubmitted = "VERIFICATION_SUBMITTED"
    case authorized = "AUTHORIZED"
    case sessionEstablished = "SESSION_ESTABLISHED"
    case sessionExpired = "SESSION_EXPIRED"
    case failed = "FAILED"

    /// Compatibility spelling retained for manifests written by the first POC.
    public static var authenticating: Self { .startingAuthentication }
}

public enum AppleVerificationMethod: String, Codable, Equatable, Sendable {
    case trustedDevice = "TRUSTED_DEVICE"
    case sms = "SMS"
}

public struct AppleVerificationChallenge: Codable, Equatable, Sendable {
    public let method: AppleVerificationMethod
    public let safeDestinationHint: String?

    public init(method: AppleVerificationMethod, safeDestinationHint: String? = nil) {
        self.method = method
        self.safeDestinationHint = safeDestinationHint
    }
}

public struct AppleAuthorizationSummary: Codable, Equatable, Sendable {
    public let method: AppleAuthorizationMethodCategory
    public let stage: AppleAuthorizationStage
    public let sessionValid: Bool
    public let clientIdentityVersion: String?
    public let expiresAt: Date?
    public let safeErrorCode: String?

    public init(
        method: AppleAuthorizationMethodCategory,
        stage: AppleAuthorizationStage,
        sessionValid: Bool,
        clientIdentityVersion: String? = nil,
        expiresAt: Date? = nil,
        safeErrorCode: String? = nil
    ) {
        self.method = method
        self.stage = stage
        self.sessionValid = sessionValid
        self.clientIdentityVersion = clientIdentityVersion
        self.expiresAt = expiresAt
        self.safeErrorCode = safeErrorCode
    }
}

public struct AppleAuthorizationSessionMetadata: Codable, Equatable, Sendable {
    public let accountFingerprint: String
    public let clientIdentityVersion: String
    public let createdAt: Date
    public let lastValidatedAt: Date?
    public let expiresAt: Date?

    public init(
        accountFingerprint: String,
        clientIdentityVersion: String,
        createdAt: Date,
        lastValidatedAt: Date? = nil,
        expiresAt: Date?
    ) {
        self.accountFingerprint = accountFingerprint
        self.clientIdentityVersion = clientIdentityVersion
        self.createdAt = createdAt
        self.lastValidatedAt = lastValidatedAt
        self.expiresAt = expiresAt
    }
}

/// Sensitive session bytes plus safe metadata. This type is intentionally not
/// Codable or printable. Only the Keychain store may persist its payload.
public final class AppleAuthorizationSession: @unchecked Sendable {
    public let metadata: AppleAuthorizationSessionMetadata
    private let payload: SensitiveInput

    public init(metadata: AppleAuthorizationSessionMetadata, opaquePayload: Data) {
        self.metadata = metadata
        payload = SensitiveInput(data: opaquePayload)
    }

    public func withOpaquePayload<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try payload.withUnsafeBytes(body)
    }

    public func clear() { payload.clear() }
}

public protocol AppleAuthorizationSessionStoring: Sendable {
    func load() throws -> AppleAuthorizationSession?
    func loadMetadata() throws -> AppleAuthorizationSessionMetadata?
    func save(_ session: AppleAuthorizationSession) throws
    func remove() throws
}

public final class KeychainAppleAuthorizationSessionStore: AppleAuthorizationSessionStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.iossim.mac.apple-authorization",
        account: String = "personal-team-session"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> AppleAuthorizationSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ExperimentalBackendError.unavailable
        }
        let envelope = try PropertyListDecoder().decode(KeychainEnvelope.self, from: data)
        return AppleAuthorizationSession(metadata: envelope.metadata, opaquePayload: envelope.payload)
    }

    public func loadMetadata() throws -> AppleAuthorizationSessionMetadata? {
        guard let session = try load() else { return nil }
        defer { session.clear() }
        return session.metadata
    }

    public func save(_ session: AppleAuthorizationSession) throws {
        var payload = session.withOpaquePayload { Data($0) }
        defer { payload.resetBytes(in: 0..<payload.count) }
        let encoded = try PropertyListEncoder().encode(
            KeychainEnvelope(metadata: session.metadata, payload: payload)
        )
        let query = baseQuery()
        let replacement: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, replacement as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            replacement.forEach { attributes[$0.key] = $0.value }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ExperimentalBackendError.unavailable }
    }

    public func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExperimentalBackendError.unavailable
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private struct KeychainEnvelope: Codable {
        let metadata: AppleAuthorizationSessionMetadata
        let payload: Data
    }
}

/// Best-effort wipeable input. SwiftUI necessarily begins with a `String`; the
/// view clears it immediately after converting to this buffer. The buffer is
/// never Codable, printable, logged, or written to preferences.
public final class SensitiveInput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data

    public init(_ value: String) {
        bytes = Data(value.utf8)
    }

    init(data: Data) {
        bytes = data
    }

    deinit { clear() }

    public var isEmpty: Bool {
        lock.withLock { bytes.isEmpty }
    }

    public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try lock.withLock { try bytes.withUnsafeBytes(body) }
    }

    public func clear() {
        lock.withLock {
            bytes.resetBytes(in: 0..<bytes.count)
            bytes.removeAll(keepingCapacity: false)
        }
    }
}

public struct ExperimentalAppleTeam: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isPersonalTeam: Bool
    public let isPaidDeveloperTeam: Bool

    public init(id: String, name: String, isPersonalTeam: Bool, isPaidDeveloperTeam: Bool) {
        self.id = id
        self.name = name
        self.isPersonalTeam = isPersonalTeam
        self.isPaidDeveloperTeam = isPaidDeveloperTeam
    }
}

public struct ExperimentalSigningIdentity: Equatable, Sendable {
    public let certificateFingerprint: String
    public let certificateExpiration: Date
    public let privateKeyPersistentReference: Data
    /// Non-secret identifier for the permanent IOSSim-owned Keychain key.
    public let keyApplicationTagIdentifier: String?
    /// True when this identity is staged and must not replace the active
    /// IOSSim-managed identity until installation has been verified.
    public let pendingPromotion: Bool
    public let reused: Bool

    public init(
        certificateFingerprint: String,
        certificateExpiration: Date,
        privateKeyPersistentReference: Data,
        keyApplicationTagIdentifier: String? = nil,
        pendingPromotion: Bool = false,
        reused: Bool
    ) {
        self.certificateFingerprint = certificateFingerprint
        self.certificateExpiration = certificateExpiration
        self.privateKeyPersistentReference = privateKeyPersistentReference
        self.keyApplicationTagIdentifier = keyApplicationTagIdentifier
        self.pendingPromotion = pendingPromotion
        self.reused = reused
    }
}

public struct ExperimentalProfile: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let certificateFingerprint: String
    public let provisionedDeviceIdentifiers: Set<String>
    public let applicationIdentifierEntitlement: String
    public let applicationIdentifierPrefix: String
    public let getTaskAllow: Bool
    public let profileType: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let profileData: Data

    public init(
        bundleIdentifier: String,
        teamIdentifier: String,
        certificateFingerprint: String,
        provisionedDeviceIdentifiers: Set<String>,
        applicationIdentifierEntitlement: String,
        applicationIdentifierPrefix: String? = nil,
        getTaskAllow: Bool = true,
        profileType: String = "development",
        issuedAt: Date,
        expiresAt: Date,
        profileData: Data
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.certificateFingerprint = certificateFingerprint
        self.provisionedDeviceIdentifiers = provisionedDeviceIdentifiers
        self.applicationIdentifierEntitlement = applicationIdentifierEntitlement
        self.applicationIdentifierPrefix = applicationIdentifierPrefix ?? teamIdentifier
        self.getTaskAllow = getTaskAllow
        self.profileType = profileType
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.profileData = profileData
    }
}

public struct ExperimentalInstallInventory: Codable, Equatable, Sendable {
    public let derivedMainCount: Int
    public let derivedRunnerCount: Int
    public let canonicalRunnerCount: Int
    public let witnessCount: Int

    public init(
        derivedMainCount: Int,
        derivedRunnerCount: Int,
        canonicalRunnerCount: Int,
        witnessCount: Int
    ) {
        self.derivedMainCount = derivedMainCount
        self.derivedRunnerCount = derivedRunnerCount
        self.canonicalRunnerCount = canonicalRunnerCount
        self.witnessCount = witnessCount
    }

    public var isExpected: Bool {
        derivedMainCount == 1 && derivedRunnerCount == 1
            && canonicalRunnerCount == 0 && witnessCount == 0
    }
}

public enum ExperimentalAuthorizationResult: Sendable {
    case verificationRequired(AppleVerificationChallenge)
    case authorized([ExperimentalAppleTeam])
}

public struct ExperimentalProvisioningRequest: Equatable, Sendable {
    public enum DeviceIdentifierSource: String, Codable, Equatable, Sendable {
        case physicalUDID = "physicalUDID"
        case coreDeviceIdentifier = "coreDeviceIdentifier"
        case other
    }

    /// CoreDevice/device-transport selector. This is not necessarily the UDID
    /// accepted by Apple Developer Services.
    public let selectedDeviceIdentifier: String
    /// Hardware registration identifier used by Developer Services and
    /// ProvisionedDevices profile validation.
    public let selectedDeviceRegistrationIdentifier: String
    public let deviceIdentifierSource: DeviceIdentifierSource
    public let selectedDeviceName: String
    public let operation: ConsumerProvisioningOperation

    public init(
        selectedDeviceIdentifier: String,
        selectedDeviceRegistrationIdentifier: String? = nil,
        deviceIdentifierSource: DeviceIdentifierSource = .other,
        selectedDeviceName: String,
        operation: ConsumerProvisioningOperation
    ) {
        self.selectedDeviceIdentifier = selectedDeviceIdentifier
        self.selectedDeviceRegistrationIdentifier = selectedDeviceRegistrationIdentifier
            ?? selectedDeviceIdentifier
        self.deviceIdentifierSource = deviceIdentifierSource
        self.selectedDeviceName = selectedDeviceName
        self.operation = operation
    }
}

public struct ExperimentalProvisioningReceipt: Equatable, Sendable {
    public let team: ExperimentalAppleTeam
    public let identity: ExperimentalSigningIdentity
    public let derivedIdentifiers: PersonalTeamBundleIdentifierSet
    public let profiles: [ExperimentalProfile]
    public let inventory: ExperimentalInstallInventory
    public let pairingVerified: Bool

    public init(
        team: ExperimentalAppleTeam,
        identity: ExperimentalSigningIdentity,
        derivedIdentifiers: PersonalTeamBundleIdentifierSet,
        profiles: [ExperimentalProfile],
        inventory: ExperimentalInstallInventory,
        pairingVerified: Bool
    ) {
        self.team = team
        self.identity = identity
        self.derivedIdentifiers = derivedIdentifiers
        self.profiles = profiles
        self.inventory = inventory
        self.pairingVerified = pairingVerified
    }
}

public protocol ApplePersonalTeamService: Sendable {
    var method: AppleAuthorizationMethodCategory { get }
    var clientIdentityVersion: String { get }
    var isPhysicallyQualified: Bool { get }

    func resumeSession() async throws -> [ExperimentalAppleTeam]?
    func beginAuthorization(account: String, password: SensitiveInput) async throws -> ExperimentalAuthorizationResult
    func submitVerification(code: SensitiveInput) async throws -> ExperimentalAuthorizationResult
    func invalidateSession() async
    func repairSigningIdentityAccess(team: ExperimentalAppleTeam) async throws
    func prepareIdentity(team: ExperimentalAppleTeam) async throws -> ExperimentalSigningIdentity
    func registerDevice(_ request: ExperimentalProvisioningRequest, team: ExperimentalAppleTeam) async throws
    func registerIdentifiers(_ identifiers: PersonalTeamBundleIdentifierSet, team: ExperimentalAppleTeam) async throws
    func obtainProfiles(
        identifiers: PersonalTeamBundleIdentifierSet,
        identity: ExperimentalSigningIdentity,
        request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam
    ) async throws -> [ExperimentalProfile]
    func signArtifacts(
        identifiers: PersonalTeamBundleIdentifierSet,
        identity: ExperimentalSigningIdentity,
        profiles: [ExperimentalProfile]
    ) async throws
    func installArtifacts(
        identifiers: PersonalTeamBundleIdentifierSet,
        request: ExperimentalProvisioningRequest
    ) async throws -> ExperimentalInstallInventory
    func preparePairing(for request: ExperimentalProvisioningRequest) async throws -> Bool
}

/// Source compatibility for development fixtures while product code uses the
/// responsibility-based service name.
public typealias ExperimentalPersonalTeamBackend = ApplePersonalTeamService

public enum ExperimentalBackendError: Error, Equatable, Sendable {
    case badPassword
    case verificationExpired
    case sessionExpired
    case noTeam
    case certificateLimit
    case missingPrivateKey
    case deviceLimit
    case deviceNameRequired
    case invalidDeviceIdentifier
    case invalidTeam
    case appIDLimit
    case appIDCollision
    case invalidProfile
    case signingFailure
    case nestedSigningFailure
    case installationFailure
    case inventoryMismatch
    case pairingFailure
    case responseChanged
    case rateLimited
    case unavailable
    case serviceUnavailable
    case networkFailure
    case localAnisetteUnavailable
    case srpAuthFailed
    case authenticationRejected
    case authenticationProtocolMismatch
    case verificationRejected
    case xcodeScopedTokenFailed
    case developerServicesFailed
    case personalTeamAmbiguous
    case certificateRequestFailed
    case deviceRegistrationFailed
    case appIDRegistrationFailed
    case profileRequestFailed
    case responseTooLarge
    case redirectRejected
    case adapterDisabled

    public var safeCode: String {
        switch self {
        case .badPassword, .authenticationRejected: return "APPLE_AUTH_REJECTED"
        case .verificationExpired: return "APPLE_2FA_EXPIRED"
        case .verificationRejected: return "APPLE_2FA_REJECTED"
        case .sessionExpired: return "APPLE_SESSION_REJECTED"
        case .noTeam: return "PERSONAL_TEAM_NOT_FOUND"
        case .personalTeamAmbiguous: return "PERSONAL_TEAM_AMBIGUOUS"
        case .certificateLimit: return "CERTIFICATE_LIMIT_REACHED"
        case .certificateRequestFailed: return "CERTIFICATE_REQUEST_FAILED"
        case .deviceLimit: return "DEVICE_LIMIT_REACHED"
        case .deviceNameRequired: return "DEVICE_NAME_REQUIRED"
        case .invalidDeviceIdentifier: return "INVALID_DEVICE_IDENTIFIER"
        case .invalidTeam: return "INVALID_TEAM"
        case .deviceRegistrationFailed: return "DEVICE_REGISTRATION_FAILED"
        case .appIDLimit: return "APP_ID_LIMIT_REACHED"
        case .appIDCollision: return "APP_ID_COLLISION"
        case .appIDRegistrationFailed: return "APP_ID_REGISTRATION_FAILED"
        case .invalidProfile: return "PROFILE_VALIDATION_FAILED"
        case .profileRequestFailed: return "PROFILE_REQUEST_FAILED"
        case .networkFailure: return "APPLE_AUTH_NETWORK_FAILURE"
        case .localAnisetteUnavailable: return "LOCAL_ANISETTE_UNAVAILABLE"
        case .srpAuthFailed: return "SRP_AUTH_FAILED"
        case .authenticationProtocolMismatch, .responseChanged: return "APPLE_AUTH_PROTOCOL_MISMATCH"
        case .xcodeScopedTokenFailed: return "XCODE_SCOPED_TOKEN_FAILED"
        case .developerServicesFailed: return "DEVELOPER_SERVICES_FAILED"
        case .rateLimited: return "APPLE_SERVICE_RATE_LIMITED"
        case .serviceUnavailable: return "APPLE_SERVICE_UNAVAILABLE"
        case .responseTooLarge: return "APPLE_RESPONSE_TOO_LARGE"
        case .redirectRejected: return "APPLE_REDIRECT_REJECTED"
        case .adapterDisabled: return "APPLE_PRIVATE_ADAPTER_DISABLED"
        default: return String(describing: self).uppercased()
        }
    }
}

public enum ApplePersonalTeamCheckpoint: String, Codable, CaseIterable, Sendable {
    case authStarted = "APPLE_AUTH_STARTED"
    case authChallengeReceived = "APPLE_AUTH_CHALLENGE_RECEIVED"
    case authPasswordAccepted = "APPLE_AUTH_PASSWORD_ACCEPTED"
    case twoFactorRequired = "APPLE_2FA_REQUIRED"
    case twoFactorAccepted = "APPLE_2FA_ACCEPTED"
    case sessionReady = "APPLE_SESSION_READY"
    case personalTeamFound = "PERSONAL_TEAM_FOUND"
    case signingIdentityLookupStarted = "SIGNING_IDENTITY_LOOKUP_STARTED"
    case managedIdentityMetadataFound = "MANAGED_IDENTITY_METADATA_FOUND"
    case managedIdentityMetadataMissing = "MANAGED_IDENTITY_METADATA_MISSING"
    case privateKeyLookupStarted = "PRIVATE_KEY_LOOKUP_STARTED"
    case privateKeyFound = "PRIVATE_KEY_FOUND"
    case privateKeyMissing = "PRIVATE_KEY_MISSING"
    case certificateFound = "CERTIFICATE_FOUND"
    case certificatePublicKeyMatch = "CERTIFICATE_PUBLIC_KEY_MATCH"
    case managedIdentityStale = "MANAGED_IDENTITY_STALE"
    case managedIdentityRecoveryStarted = "MANAGED_IDENTITY_RECOVERY_STARTED"
    case keypairCreated = "KEYPAIR_CREATED"
    case csrCreated = "CSR_CREATED"
    case developmentCertificateCreated = "DEVELOPMENT_CERTIFICATE_CREATED"
    case managedIdentityRecoverySucceeded = "MANAGED_IDENTITY_RECOVERY_SUCCEEDED"
    case signingKeyUsabilityVerified = "SIGNING_KEY_USABILITY_VERIFIED"
    case signingKeyUsabilityFailed = "SIGNING_KEY_USABILITY_FAILED"
    case provisioningPreparationContinued = "PROVISIONING_PREPARATION_CONTINUED"
    case signingIdentityReused = "SIGNING_IDENTITY_REUSED"
    case signingIdentityCreated = "SIGNING_IDENTITY_CREATED"
    case deviceRegistrationCheckStarted = "DEVICE_REGISTRATION_CHECK_STARTED"
    case registeredDeviceListReceived = "REGISTERED_DEVICE_LIST_RECEIVED"
    case registeredDeviceMatchResult = "REGISTERED_DEVICE_MATCH_RESULT"
    case deviceAlreadyRegistered = "DEVICE_ALREADY_REGISTERED"
    case deviceRegistrationRequired = "DEVICE_REGISTRATION_REQUIRED"
    case deviceRegistrationRequestPrepared = "DEVICE_REGISTRATION_REQUEST_PREPARED"
    case deviceRegistrationRequestSent = "DEVICE_REGISTRATION_REQUEST_SENT"
    case deviceRegistrationResponseReceived = "DEVICE_REGISTRATION_RESPONSE_RECEIVED"
    case deviceRegistrationReconciliationStarted = "DEVICE_REGISTRATION_RECONCILIATION_STARTED"
    case deviceRegistrationSucceeded = "DEVICE_REGISTRATION_SUCCEEDED"
    case deviceRegistrationRejected = "DEVICE_REGISTRATION_REJECTED"
    case provisioningDeviceReady = "PROVISIONING_DEVICE_READY"
    case deviceRegistered = "DEVICE_REGISTERED"
    case mainIDReady = "MAIN_ID_READY"
    case uiTestIDReady = "UITEST_ID_READY"
    case runnerIDReady = "RUNNER_ID_READY"
    case mainProfileReady = "MAIN_PROFILE_READY"
    case runnerProfileReady = "RUNNER_PROFILE_READY"
    case provisioningReady = "PROVISIONING_READY"
}

public struct ExperimentalProvisioningPreparation: Sendable {
    public let team: ExperimentalAppleTeam
    public let identity: ExperimentalSigningIdentity
    public let derivedIdentifiers: PersonalTeamBundleIdentifierSet
    public let profiles: [ExperimentalProfile]
}

public struct ExperimentalRepairObservation: Equatable, Sendable {
    public let authSessionValid: Bool
    public let profilesValid: Bool
    public let mainInstalled: Bool
    public let runnerInstalled: Bool
    public let pairingVerified: Bool

    public init(
        authSessionValid: Bool,
        profilesValid: Bool,
        mainInstalled: Bool,
        runnerInstalled: Bool,
        pairingVerified: Bool
    ) {
        self.authSessionValid = authSessionValid
        self.profilesValid = profilesValid
        self.mainInstalled = mainInstalled
        self.runnerInstalled = runnerInstalled
        self.pairingVerified = pairingVerified
    }
}

public enum ExperimentalRepairAction: String, Equatable, Sendable {
    case reauthorize
    case refreshProfiles
    case reinstallMain
    case reinstallRunner
    case repairPairing
    case none
}

public enum ExperimentalRepairPlanner {
    /// Returns the narrowest prerequisite-respecting repair. It deliberately
    /// does not erase valid settings, identities, or pairing state.
    public static func nextAction(for state: ExperimentalRepairObservation) -> ExperimentalRepairAction {
        if !state.authSessionValid { return .reauthorize }
        if !state.profilesValid { return .refreshProfiles }
        if !state.mainInstalled { return .reinstallMain }
        if !state.runnerInstalled { return .reinstallRunner }
        if !state.pairingVerified { return .repairPairing }
        return .none
    }
}

public actor ExperimentalConsumerProvisioningCoordinator {
    public private(set) var authorization = AppleAuthorizationSummary(
        method: .privateGrandSlamSRP,
        stage: .notStarted,
        sessionValid: false
    )
    public private(set) var teams: [ExperimentalAppleTeam] = []
    private let backend: any ApplePersonalTeamService
    private var authorizationGeneration: UInt64 = 0

    public init(backend: any ApplePersonalTeamService) {
        self.backend = backend
        authorization = AppleAuthorizationSummary(
            method: backend.method,
            stage: .notStarted,
            sessionValid: false,
            clientIdentityVersion: backend.clientIdentityVersion
        )
    }

    public var isPhysicallyQualified: Bool { backend.isPhysicallyQualified }

    @discardableResult
    public func resume() async throws -> Bool {
        let generation = nextAuthorizationGeneration()
        do {
            guard let resumed = try await backend.resumeSession() else { return false }
            try requireCurrentAuthorizationGeneration(generation)
            teams = try Self.validateTeams(resumed)
            authorization = summary(stage: .authorized, valid: true)
            return true
        } catch ExperimentalBackendError.sessionExpired {
            try requireCurrentAuthorizationGeneration(generation)
            authorization = summary(stage: .sessionExpired, valid: false, code: "SESSION_EXPIRED")
            return false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try requireCurrentAuthorizationGeneration(generation)
            authorization = summary(stage: .failed, valid: false, code: Self.safeCode(error))
            throw error
        }
    }

    public func begin(account: String, password: SensitiveInput) async throws -> AppleVerificationChallenge? {
        let generation = nextAuthorizationGeneration()
        authorization = summary(stage: .startingAuthentication, valid: false)
        defer { password.clear() }
        do {
            let result = try await backend.beginAuthorization(account: account, password: password)
            try requireCurrentAuthorizationGeneration(generation)
            return try applyAuthorizationResult(result)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try requireCurrentAuthorizationGeneration(generation)
            authorization = summary(stage: .failed, valid: false, code: Self.safeCode(error))
            throw error
        }
    }

    public func verify(code: SensitiveInput) async throws -> AppleVerificationChallenge? {
        let generation = nextAuthorizationGeneration()
        authorization = summary(stage: .verificationSubmitted, valid: false)
        defer { code.clear() }
        do {
            let result = try await backend.submitVerification(code: code)
            try requireCurrentAuthorizationGeneration(generation)
            return try applyAuthorizationResult(result)
        } catch ExperimentalBackendError.verificationExpired {
            try requireCurrentAuthorizationGeneration(generation)
            authorization = summary(stage: .verificationRequired, valid: false, code: "VERIFICATION_EXPIRED")
            throw ExperimentalBackendError.verificationExpired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try requireCurrentAuthorizationGeneration(generation)
            authorization = summary(stage: .failed, valid: false, code: Self.safeCode(error))
            throw error
        }
    }

    public func provision(_ request: ExperimentalProvisioningRequest) async throws -> ExperimentalProvisioningReceipt {
        let prepared = try await prepareProvisioning(request)
        try await backend.signArtifacts(
            identifiers: prepared.derivedIdentifiers,
            identity: prepared.identity,
            profiles: prepared.profiles
        )
        let inventory = try await backend.installArtifacts(
            identifiers: prepared.derivedIdentifiers,
            request: request
        )
        guard inventory.isExpected else { throw ExperimentalBackendError.inventoryMismatch }
        let pairingVerified = try await backend.preparePairing(for: request)
        guard pairingVerified else { throw ExperimentalBackendError.pairingFailure }
        return ExperimentalProvisioningReceipt(
            team: prepared.team,
            identity: prepared.identity,
            derivedIdentifiers: prepared.derivedIdentifiers,
            profiles: prepared.profiles,
            inventory: inventory,
            pairingVerified: pairingVerified
        )
    }

    /// Live P0-P7 checkpoint. Signing, installation, and pairing are kept out
    /// of this method so the experimental RC cannot imply those gates passed.
    public func prepareProvisioning(
        _ request: ExperimentalProvisioningRequest
    ) async throws -> ExperimentalProvisioningPreparation {
        guard authorization.sessionValid else { throw ExperimentalBackendError.sessionExpired }
        let team = try Self.preferredTeam(from: teams)
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: team.id)
        let identity = try await backend.prepareIdentity(team: team)
        try await backend.registerDevice(request, team: team)
        try await backend.registerIdentifiers(identifiers, team: team)
        let profiles = try await backend.obtainProfiles(
            identifiers: identifiers,
            identity: identity,
            request: request,
            team: team
        )
        try Self.validateProfiles(
            profiles,
            identifiers: identifiers,
            teamIdentifier: team.id,
            certificateFingerprint: identity.certificateFingerprint,
            selectedDeviceIdentifier: request.selectedDeviceRegistrationIdentifier,
            now: Date()
        )
        return ExperimentalProvisioningPreparation(
            team: team,
            identity: identity,
            derivedIdentifiers: identifiers,
            profiles: profiles
        )
    }

    /// Re-applies IOSSim's noninteractive signing policy before cached
    /// provisioning artifacts cross into the packaged provisioner process.
    public func repairSigningIdentityAccess(team: ExperimentalAppleTeam) async throws {
        try await backend.repairSigningIdentityAccess(team: team)
    }

    public func invalidate() async {
        _ = nextAuthorizationGeneration()
        teams = []
        authorization = summary(stage: .notStarted, valid: false)
        await backend.invalidateSession()
    }

    private func nextAuthorizationGeneration() -> UInt64 {
        authorizationGeneration &+= 1
        return authorizationGeneration
    }

    private func requireCurrentAuthorizationGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == authorizationGeneration else { throw CancellationError() }
    }

    private func applyAuthorizationResult(_ result: ExperimentalAuthorizationResult) throws -> AppleVerificationChallenge? {
        switch result {
        case .verificationRequired(let challenge):
            authorization = summary(stage: .verificationRequired, valid: false)
            return challenge
        case .authorized(let discovered):
            teams = try Self.validateTeams(discovered)
            authorization = summary(stage: .authorized, valid: true)
            return nil
        }
    }

    private func summary(stage: AppleAuthorizationStage, valid: Bool, code: String? = nil) -> AppleAuthorizationSummary {
        AppleAuthorizationSummary(
            method: backend.method,
            stage: stage,
            sessionValid: valid,
            clientIdentityVersion: backend.clientIdentityVersion,
            safeErrorCode: code
        )
    }

    public static func preferredTeam(from teams: [ExperimentalAppleTeam]) throws -> ExperimentalAppleTeam {
        let personal = teams.filter(\.isPersonalTeam)
        if personal.count == 1, let onlyPersonal = personal.first { return onlyPersonal }
        if teams.count == 1, let only = teams.first { return only }
        throw ExperimentalBackendError.noTeam
    }

    public static func validateTeams(_ teams: [ExperimentalAppleTeam]) throws -> [ExperimentalAppleTeam] {
        guard !teams.isEmpty else { throw ExperimentalBackendError.noTeam }
        let pattern = try NSRegularExpression(pattern: "^[A-Z0-9]{5,16}$")
        var seen: Set<String> = []
        for team in teams {
            let range = NSRange(team.id.startIndex..<team.id.endIndex, in: team.id)
            guard pattern.firstMatch(in: team.id, range: range)?.range == range,
                  !team.name.isEmpty,
                  seen.insert(team.id).inserted else {
                throw ExperimentalBackendError.responseChanged
            }
        }
        return teams
    }

    public static func validateProfiles(
        _ profiles: [ExperimentalProfile],
        identifiers: PersonalTeamBundleIdentifierSet,
        teamIdentifier: String,
        certificateFingerprint: String,
        selectedDeviceIdentifier: String,
        now: Date
    ) throws {
        let required = Set([identifiers.main, identifiers.runner])
        guard Set(profiles.map(\.bundleIdentifier)) == required else {
            throw ExperimentalBackendError.invalidProfile
        }
        guard profiles.allSatisfy({
            $0.teamIdentifier == teamIdentifier
                && $0.certificateFingerprint == certificateFingerprint
                && $0.provisionedDeviceIdentifiers.contains(selectedDeviceIdentifier)
                && $0.applicationIdentifierEntitlement == "\(teamIdentifier).\($0.bundleIdentifier)"
                && $0.applicationIdentifierPrefix == teamIdentifier
                && $0.getTaskAllow
                && $0.profileType == "development"
                && $0.issuedAt <= now
                && $0.expiresAt > now
                && !$0.profileData.isEmpty
        }) else { throw ExperimentalBackendError.invalidProfile }
    }

    private static func safeCode(_ error: Error) -> String {
        (error as? ExperimentalBackendError)?.safeCode ?? "PRIVATE_PROTOCOL_FAILURE"
    }
}

public struct UnavailableExperimentalPersonalTeamBackend: ExperimentalPersonalTeamBackend {
    public let method = AppleAuthorizationMethodCategory.privateGrandSlamSRP
    public let clientIdentityVersion = "UNQUALIFIED"
    public let isPhysicallyQualified = false

    public init() {}

    public func resumeSession() async throws -> [ExperimentalAppleTeam]? { nil }
    public func beginAuthorization(account: String, password: SensitiveInput) async throws -> ExperimentalAuthorizationResult {
        throw ExperimentalBackendError.unavailable
    }
    public func submitVerification(code: SensitiveInput) async throws -> ExperimentalAuthorizationResult {
        throw ExperimentalBackendError.unavailable
    }
    public func invalidateSession() async {}
    public func repairSigningIdentityAccess(team: ExperimentalAppleTeam) async throws { throw ExperimentalBackendError.unavailable }
    public func prepareIdentity(team: ExperimentalAppleTeam) async throws -> ExperimentalSigningIdentity { throw ExperimentalBackendError.unavailable }
    public func registerDevice(_ request: ExperimentalProvisioningRequest, team: ExperimentalAppleTeam) async throws { throw ExperimentalBackendError.unavailable }
    public func registerIdentifiers(_ identifiers: PersonalTeamBundleIdentifierSet, team: ExperimentalAppleTeam) async throws { throw ExperimentalBackendError.unavailable }
    public func obtainProfiles(identifiers: PersonalTeamBundleIdentifierSet, identity: ExperimentalSigningIdentity, request: ExperimentalProvisioningRequest, team: ExperimentalAppleTeam) async throws -> [ExperimentalProfile] { throw ExperimentalBackendError.unavailable }
    public func signArtifacts(identifiers: PersonalTeamBundleIdentifierSet, identity: ExperimentalSigningIdentity, profiles: [ExperimentalProfile]) async throws { throw ExperimentalBackendError.unavailable }
    public func installArtifacts(identifiers: PersonalTeamBundleIdentifierSet, request: ExperimentalProvisioningRequest) async throws -> ExperimentalInstallInventory { throw ExperimentalBackendError.unavailable }
    public func preparePairing(for request: ExperimentalProvisioningRequest) async throws -> Bool { throw ExperimentalBackendError.unavailable }
}

public struct PrivateAppleProtocolAdapter: Equatable, Sendable {
    public static let researched2026 = PrivateAppleProtocolAdapter(
        version: "research-2026-09-akd",
        grandSlamService: URL(string: "https://gsa.apple.com/grandslam/GsService2")!,
        trustedDeviceVerification: URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!,
        verificationValidation: URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!,
        developerServicesBase: URL(string: "https://developerservices2.apple.com/services/QH65B2/")!,
        xcodeTokenAudience: "com.apple.gs.xcode.auth",
        xcodeClientIdentifier: "XABBG36SBA",
        xcodeVersionHeader: "16.4 (16F6)",
        xcodeBundleVersion: "23792"
    )

    public let version: String
    public let grandSlamService: URL
    public let trustedDeviceVerification: URL
    public let verificationValidation: URL
    public let developerServicesBase: URL
    public let xcodeTokenAudience: String
    public let xcodeClientIdentifier: String
    public let xcodeVersionHeader: String
    public let xcodeBundleVersion: String

    public func developerURL(operation: String) throws -> URL {
        guard operation.range(of: "^[A-Za-z]+(?:/[A-Za-z]+)?$", options: .regularExpression) != nil,
              let url = URL(string: operation + ".action", relativeTo: developerServicesBase)?.absoluteURL else {
            throw ExperimentalBackendError.responseChanged
        }
        return url
    }

    public func validateResponse(
        url: URL,
        statusCode: Int,
        contentType: String?,
        body: Data,
        maximumBytes: Int = 8 * 1_024 * 1_024
    ) throws {
        guard url.scheme == "https",
              ["gsa.apple.com", "developerservices2.apple.com"].contains(url.host),
              (200..<300).contains(statusCode),
              body.count <= maximumBytes,
              !body.isEmpty else {
            if statusCode == 429 { throw ExperimentalBackendError.rateLimited }
            throw ExperimentalBackendError.responseChanged
        }
        let normalized = contentType?.lowercased() ?? ""
        guard normalized.contains("plist") || normalized.contains("json")
            || normalized.contains("octet-stream") else {
            throw ExperimentalBackendError.responseChanged
        }
    }
}

public struct PrivateAppleProvisioningAdapterPolicy: Equatable, Sendable {
    public let enabled: Bool
    public let allowedAdapterVersions: Set<String>

    public init(enabled: Bool, allowedAdapterVersions: Set<String>) {
        self.enabled = enabled
        self.allowedAdapterVersions = allowedAdapterVersions
    }

    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PrivateAppleProvisioningAdapterPolicy {
        let disabled = ["1", "true", "yes"].contains(
            environment["VEYA_DISABLE_PRIVATE_APPLE_PROVISIONING"]?.lowercased() ?? ""
        )
        return PrivateAppleProvisioningAdapterPolicy(
            enabled: !disabled,
            allowedAdapterVersions: [PrivateAppleProtocolAdapter.researched2026.version]
        )
    }

    public func permits(adapterVersion: String) -> Bool {
        enabled && allowedAdapterVersions.contains(adapterVersion)
    }
}

/// Domain-facing, kill-switchable boundary for the version-bound private
/// Apple protocol implementation. Setup/UI code receives only typed service
/// operations and outcomes through this adapter.
public actor VersionedPrivateAppleProvisioningAdapter: ApplePersonalTeamService {
    public nonisolated let method: AppleAuthorizationMethodCategory
    public nonisolated let clientIdentityVersion: String
    public nonisolated let isPhysicallyQualified: Bool

    private let service: any ApplePersonalTeamService
    private let policy: PrivateAppleProvisioningAdapterPolicy

    public init(
        service: any ApplePersonalTeamService,
        policy: PrivateAppleProvisioningAdapterPolicy = .current()
    ) {
        self.service = service
        self.policy = policy
        method = service.method
        clientIdentityVersion = service.clientIdentityVersion
        isPhysicallyQualified = service.isPhysicallyQualified
            && policy.permits(adapterVersion: service.clientIdentityVersion)
    }

    private func requireAvailable() throws {
        guard policy.enabled else { throw ExperimentalBackendError.adapterDisabled }
        guard policy.allowedAdapterVersions.contains(clientIdentityVersion) else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
    }

    public func resumeSession() async throws -> [ExperimentalAppleTeam]? {
        try requireAvailable()
        return try await service.resumeSession()
    }

    public func beginAuthorization(
        account: String,
        password: SensitiveInput
    ) async throws -> ExperimentalAuthorizationResult {
        try requireAvailable()
        return try await service.beginAuthorization(account: account, password: password)
    }

    public func submitVerification(code: SensitiveInput) async throws -> ExperimentalAuthorizationResult {
        try requireAvailable()
        return try await service.submitVerification(code: code)
    }

    public func invalidateSession() async {
        await service.invalidateSession()
    }

    public func repairSigningIdentityAccess(team: ExperimentalAppleTeam) async throws {
        try requireAvailable()
        try await service.repairSigningIdentityAccess(team: team)
    }

    public func prepareIdentity(team: ExperimentalAppleTeam) async throws -> ExperimentalSigningIdentity {
        try requireAvailable()
        return try await service.prepareIdentity(team: team)
    }

    public func registerDevice(
        _ request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam
    ) async throws {
        try requireAvailable()
        try await service.registerDevice(request, team: team)
    }

    public func registerIdentifiers(
        _ identifiers: PersonalTeamBundleIdentifierSet,
        team: ExperimentalAppleTeam
    ) async throws {
        try requireAvailable()
        try await service.registerIdentifiers(identifiers, team: team)
    }

    public func obtainProfiles(
        identifiers: PersonalTeamBundleIdentifierSet,
        identity: ExperimentalSigningIdentity,
        request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam
    ) async throws -> [ExperimentalProfile] {
        try requireAvailable()
        return try await service.obtainProfiles(
            identifiers: identifiers,
            identity: identity,
            request: request,
            team: team
        )
    }

    public func signArtifacts(
        identifiers: PersonalTeamBundleIdentifierSet,
        identity: ExperimentalSigningIdentity,
        profiles: [ExperimentalProfile]
    ) async throws {
        try requireAvailable()
        try await service.signArtifacts(identifiers: identifiers, identity: identity, profiles: profiles)
    }

    public func installArtifacts(
        identifiers: PersonalTeamBundleIdentifierSet,
        request: ExperimentalProvisioningRequest
    ) async throws -> ExperimentalInstallInventory {
        try requireAvailable()
        return try await service.installArtifacts(identifiers: identifiers, request: request)
    }

    public func preparePairing(for request: ExperimentalProvisioningRequest) async throws -> Bool {
        try requireAvailable()
        return try await service.preparePairing(for: request)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
