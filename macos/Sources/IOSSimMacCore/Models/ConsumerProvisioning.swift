import Foundation

public enum ConsumerProvisioningStage: String, Codable, CaseIterable, Equatable, Sendable {
    case idle = "IDLE"
    case checkingMac = "CHECKING_MAC"
    case checkingXcodeSupport = "CHECKING_XCODE_SUPPORT"
    case discoveringDevices = "DISCOVERING_DEVICES"
    case waitingForDeviceSelection = "WAITING_FOR_DEVICE_SELECTION"
    case checkingDevice = "CHECKING_DEVICE"
    case checkingDeveloperMode = "CHECKING_DEVELOPER_MODE"
    case discoveringAppleAccounts = "DISCOVERING_APPLE_ACCOUNTS"
    case waitingForTeamSelection = "WAITING_FOR_TEAM_SELECTION"
    case validatingTeam = "VALIDATING_TEAM"
    case preparedNativeContextReused = "PREPARED_NATIVE_CONTEXT_REUSED"
    case preparingIdentities = "PREPARING_IDENTITIES"
    case profileCertificatePresent = "PROFILE_CERTIFICATE_PRESENT"
    case keychainCertificateFound = "KEYCHAIN_CERTIFICATE_FOUND"
    case keychainPrivateKeyFound = "KEYCHAIN_PRIVATE_KEY_FOUND"
    case certificatePublicKeyMatch = "CERTIFICATE_PUBLIC_KEY_MATCH"
    case keychainIdentityFound = "KEYCHAIN_IDENTITY_FOUND"
    case secIdentityResolutionSucceeded = "SECIDENTITY_RESOLUTION_SUCCEEDED"
    case codesignIdentityVisible = "CODESIGN_IDENTITY_VISIBLE"
    case codesignSignTestSucceeded = "CODESIGN_SIGN_TEST_SUCCEEDED"
    case signingIdentityResolved = "SIGNING_IDENTITY_RESOLVED"
    case preparingArtifacts = "PREPARING_ARTIFACTS"
    case signingNestedComponents = "SIGNING_NESTED_COMPONENTS"
    case signingMain = "SIGNING_MAIN"
    case signingRunner = "SIGNING_RUNNER"
    case verifyingSignatures = "VERIFYING_SIGNATURES"
    case artifactValidationComplete = "ARTIFACT_VALIDATION_COMPLETE"
    case installCommandsPrepared = "INSTALL_COMMANDS_PREPARED"
    case runtimeConfigurationPrepared = "RUNTIME_CONFIGURATION_PREPARED"
    case waitingForDevice = "WAITING_FOR_DEVICE"
    case installingMain = "INSTALLING_MAIN"
    case mainInstallCommandSucceeded = "MAIN_INSTALL_COMMAND_SUCCEEDED"
    case installingRunner = "INSTALLING_RUNNER"
    case runnerInstallCommandSucceeded = "RUNNER_INSTALL_COMMAND_SUCCEEDED"
    case verifyingInstallation = "VERIFYING_INSTALLATION"
    case installInventoryRefresh = "INSTALL_INVENTORY_REFRESH"
    case installInventoryPending = "INSTALL_INVENTORY_PENDING"
    case installationVerified = "INSTALLATION_VERIFIED"
    case developerServicesReconciliationStarted = "DEVELOPER_SERVICES_RECONCILIATION_STARTED"
    case coreDeviceProxyReady = "COREDEVICE_PROXY_READY"
    case softwareTunnelReady = "SOFTWARE_TUNNEL_READY"
    case ddiNotRequired = "DDI_NOT_REQUIRED"
    case ddiRequired = "DDI_REQUIRED"
    case ddiAcquisitionStarted = "DDI_ACQUISITION_STARTED"
    case ddiAcquisitionSucceeded = "DDI_ACQUISITION_SUCCEEDED"
    case ddiPersonalizationStarted = "DDI_PERSONALIZATION_STARTED"
    case ddiPersonalizationSucceeded = "DDI_PERSONALIZATION_SUCCEEDED"
    case ddiMountStarted = "DDI_MOUNT_STARTED"
    case ddiMountSucceeded = "DDI_MOUNT_SUCCEEDED"
    case rsdReady = "RSD_READY"
    case remoteXPCReady = "REMOTEXPC_READY"
    case appServiceReady = "APPSERVICE_READY"
    case mainNativeLaunchStarted = "MAIN_NATIVE_LAUNCH_STARTED"
    case mainNativeLaunchSucceeded = "MAIN_NATIVE_LAUNCH_SUCCEEDED"
    case runtimeConfigurationReconciliationStarted = "RUNTIME_CONFIG_RECONCILIATION_STARTED"
    case houseArrestReady = "HOUSE_ARREST_READY"
    case tryAgainRequested = "TRY_AGAIN_REQUESTED"
    case physicalReconciliationStarted = "PHYSICAL_RECONCILIATION_STARTED"
    case physicalReconciliationResult = "PHYSICAL_RECONCILIATION_RESULT"
    case componentInstallSkipped = "COMPONENT_INSTALL_SKIPPED"
    case developerProfileTrustRequired = "DEVELOPER_PROFILE_TRUST_REQUIRED"
    case verifyingDeveloperProfileTrust = "VERIFYING_DEVELOPER_PROFILE_TRUST"
    case developerProfileTrusted = "DEVELOPER_PROFILE_TRUSTED"
    case writingRuntimeConfiguration = "WRITING_RUNTIME_CONFIGURATION"
    case runtimeConfigurationWritten = "RUNTIME_CONFIGURATION_WRITTEN"
    case verifyingRuntimeConfiguration = "VERIFYING_RUNTIME_CONFIGURATION"
    case runtimeConfigurationVerified = "RUNTIME_CONFIGURATION_VERIFIED"
    case pairingReconciliationStarted = "PAIRING_RECONCILIATION_STARTED"
    case pairingCreated = "PAIRING_CREATED"
    case pairingReused = "PAIRING_REUSED"
    case pairingDeliveryStarted = "PAIRING_DELIVERY_STARTED"
    case pairingDeliverySucceeded = "PAIRING_DELIVERY_SUCCEEDED"
    case pairingReceiptVerified = "PAIRING_RECEIPT_VERIFIED"
    case localDevVPNReadinessStarted = "LOCALDEVVPN_READINESS_STARTED"
    case localDevVPNLaunchStarted = "LOCALDEVVPN_LAUNCH_STARTED"
    case localDevVPNLaunchSucceeded = "LOCALDEVVPN_LAUNCH_SUCCEEDED"
    case localDevVPNUserActionRequired = "LOCALDEVVPN_USER_ACTION_REQUIRED"
    case localDevVPNReady = "LOCALDEVVPN_READY"
    case setupReadyForRuntime = "SETUP_READY_FOR_RUNTIME"
    case checkingProfileExpiration = "CHECKING_PROFILE_EXPIRATION"
    case waitingForIPhoneSetup = "WAITING_FOR_IPHONE_SETUP"
    case verifyingRuntimeReadiness = "VERIFYING_RUNTIME_READINESS"
    case complete = "COMPLETE"
    case failed = "FAILED"

    public var userTitle: String {
        switch self {
        case .idle: return "Ready to begin"
        case .checkingMac, .checkingXcodeSupport: return "Checking this Mac"
        case .discoveringDevices, .waitingForDeviceSelection: return "Finding your iPhone"
        case .checkingDevice, .checkingDeveloperMode: return "Preparing your iPhone"
        case .discoveringAppleAccounts, .waitingForTeamSelection, .validatingTeam: return "Checking Apple signing"
        case .preparedNativeContextReused, .preparingIdentities, .profileCertificatePresent,
             .keychainCertificateFound, .keychainPrivateKeyFound, .certificatePublicKeyMatch,
             .keychainIdentityFound, .secIdentityResolutionSucceeded, .codesignIdentityVisible,
             .codesignSignTestSucceeded, .signingIdentityResolved, .preparingArtifacts,
             .installCommandsPrepared, .runtimeConfigurationPrepared, .waitingForDevice:
            return "Preparing Veya"
        case .signingNestedComponents, .signingMain, .signingRunner: return "Signing Veya"
        case .verifyingSignatures, .artifactValidationComplete: return "Verifying signed components"
        case .installingMain, .mainInstallCommandSucceeded: return "Installing Veya"
        case .installingRunner, .runnerInstallCommandSucceeded: return "Installing support components"
        case .verifyingInstallation, .installInventoryRefresh, .installInventoryPending,
             .installationVerified, .tryAgainRequested, .physicalReconciliationStarted,
             .physicalReconciliationResult, .componentInstallSkipped: return "Checking installation"
        case .developerServicesReconciliationStarted, .coreDeviceProxyReady, .softwareTunnelReady,
             .ddiNotRequired, .ddiRequired, .ddiAcquisitionStarted,
             .ddiAcquisitionSucceeded, .ddiPersonalizationStarted, .ddiPersonalizationSucceeded,
             .ddiMountStarted, .ddiMountSucceeded, .rsdReady, .remoteXPCReady,
             .appServiceReady:
            return "Preparing iPhone developer services"
        case .developerProfileTrustRequired: return "Trust Veya on your iPhone"
        case .verifyingDeveloperProfileTrust, .developerProfileTrusted,
             .mainNativeLaunchStarted, .mainNativeLaunchSucceeded,
             .runtimeConfigurationReconciliationStarted, .houseArrestReady,
             .writingRuntimeConfiguration, .runtimeConfigurationWritten,
             .verifyingRuntimeConfiguration, .runtimeConfigurationVerified:
            return "Finishing setup"
        case .pairingReconciliationStarted, .pairingCreated, .pairingReused,
             .pairingDeliveryStarted, .pairingDeliverySucceeded, .pairingReceiptVerified:
            return "Preparing secure device connection"
        case .localDevVPNReadinessStarted, .localDevVPNLaunchStarted,
             .localDevVPNLaunchSucceeded, .localDevVPNReady:
            return "Starting LocalDevVPN"
        case .localDevVPNUserActionRequired:
            return "Finish LocalDevVPN on your iPhone"
        case .setupReadyForRuntime: return "Setup complete"
        case .checkingProfileExpiration: return "Checking refresh schedule"
        case .waitingForIPhoneSetup: return "Finish setup on your iPhone"
        case .verifyingRuntimeReadiness: return "Checking Veya readiness"
        case .complete: return "Veya is ready"
        case .failed: return "Setup needs attention"
        }
    }
}

public enum ConsumerProvisioningErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case xcodeMissing = "XCODE_MISSING"
    case developerToolsUnavailable = "DEVELOPER_TOOLS_UNAVAILABLE"
    case noIPhoneFound = "NO_IPHONE_FOUND"
    case deviceSelectionRequired = "DEVICE_SELECTION_REQUIRED"
    case deviceUnavailable = "DEVICE_UNAVAILABLE"
    case deviceLocked = "DEVICE_LOCKED"
    case computerTrustRequired = "COMPUTER_TRUST_REQUIRED"
    case developerProfileTrustRequired = "DEVELOPER_PROFILE_TRUST_REQUIRED"
    case developerProfileTrustVerificationFailed = "DEVELOPER_PROFILE_TRUST_VERIFICATION_FAILED"
    case developerModeRequired = "DEVELOPER_MODE_REQUIRED"
    case developerModeOff = "DEVELOPER_MODE_OFF"
    case appleAccountMissing = "APPLE_ACCOUNT_MISSING"
    case personalTeamUnavailable = "PERSONAL_TEAM_UNAVAILABLE"
    case teamSelectionRequired = "TEAM_SELECTION_REQUIRED"
    case signingIdentityMissing = "SIGNING_IDENTITY_MISSING"
    case signingPrivateKeyNotFound = "SIGNING_PRIVATE_KEY_NOT_FOUND"
    case signingCertificateNotFound = "SIGNING_CERTIFICATE_NOT_FOUND"
    case signingCertificateKeyMismatch = "SIGNING_CERTIFICATE_KEY_MISMATCH"
    case signingIdentityNotFound = "SIGNING_IDENTITY_NOT_FOUND"
    case signingKeyAccessDenied = "SIGNING_KEY_ACCESS_DENIED"
    case signingKeychainUnavailable = "SIGNING_KEYCHAIN_UNAVAILABLE"
    case signingACLRepairFailed = "SIGNING_ACL_REPAIR_FAILED"
    case signingProbeFailed = "SIGNING_PROBE_FAILED"
    case signingIdentityAccessDenied = "SIGNING_IDENTITY_ACCESS_DENIED"
    case signOperationFailed = "SIGN_OPERATION_FAILED"
    case nestedSigningFailed = "NESTED_SIGNING_FAILED"
    case signatureVerificationFailed = "SIGNATURE_VERIFICATION_FAILED"
    case entitlementMismatch = "ENTITLEMENT_MISMATCH"
    case profileCertificateMismatch = "PROFILE_CERTIFICATE_MISMATCH"
    case accountTeamMismatch = "ACCOUNT_TEAM_MISMATCH"
    case profileUnavailable = "PROFILE_UNAVAILABLE"
    case bundleIDRegistrationFailure = "BUNDLE_ID_REGISTRATION_FAILURE"
    case installedIdentityMigrationRequired = "INSTALLED_IDENTITY_MIGRATION_REQUIRED"
    case crossTeamUpgradeBlocked = "CROSS_TEAM_UPGRADE_BLOCKED"
    case mainSigningFailure = "MAIN_SIGNING_FAILURE"
    case runnerSigningFailure = "RUNNER_SIGNING_FAILURE"
    case runnerNestedSignatureFailure = "RUNNER_NESTED_SIGNATURE_FAILURE"
    case mainInstallFailure = "MAIN_INSTALL_FAILURE"
    case runnerInstallFailure = "RUNNER_INSTALL_FAILURE"
    case installCommandFailed = "INSTALL_COMMAND_FAILED"
    case installInventoryPending = "INSTALL_INVENTORY_PENDING"
    case installVerificationFailed = "INSTALL_VERIFICATION_FAILED"
    case runnerMappingMissing = "RUNNER_MAPPING_MISSING"
    case runnerNotInstalled = "RUNNER_NOT_INSTALLED"
    case duplicateRunner = "DUPLICATE_RUNNER"
    case staleRuntimeSession = "STALE_RUNTIME_SESSION"
    case profileExpired = "PROFILE_EXPIRED"
    case profileNearExpiry = "PROFILE_NEAR_EXPIRY"
    case deviceNotIncluded = "DEVICE_NOT_INCLUDED"
    case runtimeVerificationFailed = "RUNTIME_VERIFICATION_FAILED"
    case runtimeProofFailed = "RUNTIME_PROOF_FAILED"
    case runtimeConfigurationWriteFailed = "RUNTIME_CONFIGURATION_WRITE_FAILED"
    case runtimeConfigurationReadbackFailed = "RUNTIME_CONFIGURATION_READBACK_FAILED"
    case nativeLaunchUnavailable = "NATIVE_LAUNCH_UNAVAILABLE"
    case deviceResolutionFailed = "DEVICE_RESOLUTION_FAILED"
    case coreDeviceProxyFailed = "COREDEVICE_PROXY_FAILED"
    case softwareTunnelFailed = "SOFTWARE_TUNNEL_FAILED"
    case rsdUnavailable = "RSD_UNAVAILABLE"
    case remoteXPCFailed = "REMOTEXPC_FAILED"
    case appServiceUnavailable = "APPSERVICE_UNAVAILABLE"
    case featureUnavailable = "FEATURE_UNAVAILABLE"
    case applicationNotFound = "APPLICATION_NOT_FOUND"
    case ddiRequired = "DDI_REQUIRED"
    case ddiPersonalizationFailed = "DDI_PERSONALIZATION_FAILED"
    case ddiMountFailed = "DDI_MOUNT_FAILED"
    case developerServicesNotReady = "DEVELOPER_SERVICES_NOT_READY"
    case launchRejected = "LAUNCH_REJECTED"
    case nativeProtocolError = "PROTOCOL_ERROR"
    case houseArrestUnavailable = "HOUSE_ARREST_UNAVAILABLE"
    case remotePairingFailed = "REMOTE_PAIRING_FAILED"
    case pairingDeliveryFailed = "PAIRING_DELIVERY_FAILED"
    case pairingReceiptFailed = "PAIRING_RECEIPT_FAILED"
    case localDevVPNMissing = "LOCALDEVVPN_MISSING"
    case localDevVPNUserActionRequired = "LOCALDEVVPN_USER_ACTION_REQUIRED"
    case localDevVPNReadinessFailed = "LOCALDEVVPN_READINESS_FAILED"
    case nativeContainerReadFailed = "NATIVE_CONTAINER_READ_FAILED"
    case staleTeamState = "STALE_TEAM_STATE"
    case crossTeamInstallConflict = "CROSS_TEAM_INSTALL_CONFLICT"
    case artifactInvalid = "ARTIFACT_INVALID"
    case manifestCorrupt = "MANIFEST_CORRUPT"
    case operationInProgress = "OPERATION_IN_PROGRESS"
    case unsupported = "UNSUPPORTED"
    case unknown = "UNKNOWN"
}

public struct ConsumerProvisioningFailure: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let code: ConsumerProvisioningErrorCode
    public let stage: ConsumerProvisioningStage
    public let userMessage: String
    public let remediation: String
    public let developerDetail: String

    public init(
        code: ConsumerProvisioningErrorCode,
        stage: ConsumerProvisioningStage,
        userMessage: String,
        remediation: String,
        developerDetail: String
    ) {
        self.code = code
        self.stage = stage
        self.userMessage = userMessage
        self.remediation = remediation
        self.developerDetail = Redactor.redact(developerDetail)
    }

    public var description: String {
        "\(diagnosticDescriptor.code) [\(code.rawValue)]: \(developerDetail)"
    }
}

public struct PersonalTeamCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id: String { teamIdentifier }
    public let teamIdentifier: String
    public let accountDisplayName: String?
    public let teamDisplayName: String?
    public let signingIdentityCommonName: String
    public let signingIdentityFingerprint: String
    public let certificateSubjectTeamIdentifier: String
    public let profileTeamIdentifiers: [String]
    public let matchingProfileCount: Int
    public let selectedDeviceIncluded: Bool?
    public let personalTeam: Bool

    public init(
        teamIdentifier: String,
        accountDisplayName: String? = nil,
        teamDisplayName: String? = nil,
        signingIdentityCommonName: String,
        signingIdentityFingerprint: String,
        certificateSubjectTeamIdentifier: String,
        profileTeamIdentifiers: [String] = [],
        matchingProfileCount: Int = 0,
        selectedDeviceIncluded: Bool? = nil,
        personalTeam: Bool
    ) {
        self.teamIdentifier = teamIdentifier
        self.accountDisplayName = accountDisplayName
        self.teamDisplayName = teamDisplayName
        self.signingIdentityCommonName = signingIdentityCommonName
        self.signingIdentityFingerprint = signingIdentityFingerprint
        self.certificateSubjectTeamIdentifier = certificateSubjectTeamIdentifier
        self.profileTeamIdentifiers = profileTeamIdentifiers.sorted()
        self.matchingProfileCount = matchingProfileCount
        self.selectedDeviceIncluded = selectedDeviceIncluded
        self.personalTeam = personalTeam
    }

    public var userDisplayName: String {
        teamDisplayName ?? accountDisplayName ?? "Personal Team"
    }
}

public enum ConsumerProvisioningOperation: String, Codable, Equatable, Sendable {
    case install = "INSTALL"
    case refresh = "REFRESH"
    case repair = "REPAIR"
}

public enum ConsumerReconciliationTrigger: String, Codable, Equatable, Sendable {
    case setupStart = "SETUP_START"
    case tryAgain = "TRY_AGAIN"
    case resumeBoundary = "RESUME_BOUNDARY"
}

enum ConsumerInstalledIdentityPolicy {
    static func isIOSSimOwnedMain(_ bundleIdentifier: String) -> Bool {
        if bundleIdentifier == ProtectedSourceBundleIdentifiers.default.main { return true }
        return hasDerivedIdentityShape(bundleIdentifier, suffix: ".on-device-dvt-poc")
    }

    static func isIOSSimOwnedRunner(_ bundleIdentifier: String) -> Bool {
        if bundleIdentifier == ProtectedSourceBundleIdentifiers.default.runner { return true }
        return hasDerivedIdentityShape(bundleIdentifier, suffix: ".location-control-uitests.xctrunner")
    }

    static func isIOSSimOwnedMainOrRunner(_ bundleIdentifier: String) -> Bool {
        isIOSSimOwnedMain(bundleIdentifier) || isIOSSimOwnedRunner(bundleIdentifier)
    }

    private static func hasDerivedIdentityShape(_ bundleIdentifier: String, suffix: String) -> Bool {
        let prefix = "com.personalteam.iossim.t"
        guard bundleIdentifier.hasPrefix(prefix), bundleIdentifier.hasSuffix(suffix) else { return false }
        let start = bundleIdentifier.index(bundleIdentifier.startIndex, offsetBy: prefix.count)
        let end = bundleIdentifier.index(bundleIdentifier.endIndex, offsetBy: -suffix.count)
        let hash = bundleIdentifier[start..<end]
        return hash.count == 12 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public struct ConsumerProvisioningRequest: Codable, Equatable, Sendable {
    public let operation: ConsumerProvisioningOperation
    public let selectedDeviceIdentifier: String
    public let selectedTeamIdentifier: String
    public let allowFreshInstallAfterCrossTeamConflict: Bool
    public let backend: ConsumerProvisioningBackendIdentifier
    public let generation: UInt64?
    public let reconciliationTrigger: ConsumerReconciliationTrigger?

    public init(
        operation: ConsumerProvisioningOperation,
        selectedDeviceIdentifier: String,
        selectedTeamIdentifier: String,
        allowFreshInstallAfterCrossTeamConflict: Bool = false,
        backend: ConsumerProvisioningBackendIdentifier = .nativePersonalTeam,
        generation: UInt64? = nil,
        reconciliationTrigger: ConsumerReconciliationTrigger? = nil
    ) {
        self.operation = operation
        self.selectedDeviceIdentifier = selectedDeviceIdentifier
        self.selectedTeamIdentifier = selectedTeamIdentifier
        self.allowFreshInstallAfterCrossTeamConflict = allowFreshInstallAfterCrossTeamConflict
        self.backend = backend
        self.generation = generation
        self.reconciliationTrigger = reconciliationTrigger
    }
}

public struct ConsumerProfileState: Codable, Equatable, Sendable {
    public let artifact: String
    public let teamIdentifier: String
    public let bundleIdentifier: String
    public let creationDate: Date?
    public let expirationDate: Date?
    public let remainingValidity: TimeInterval?
    public let selectedDeviceIncluded: Bool
    public let personalTeam: Bool
    public let profileIdentifier: String?
    public let profileFingerprint: String?
    public let refreshRecommended: Bool

    public init(
        artifact: String,
        teamIdentifier: String,
        bundleIdentifier: String,
        creationDate: Date?,
        expirationDate: Date?,
        remainingValidity: TimeInterval?,
        selectedDeviceIncluded: Bool,
        personalTeam: Bool,
        profileIdentifier: String?,
        profileFingerprint: String?,
        refreshRecommended: Bool
    ) {
        self.artifact = artifact
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.remainingValidity = remainingValidity
        self.selectedDeviceIncluded = selectedDeviceIncluded
        self.personalTeam = personalTeam
        self.profileIdentifier = profileIdentifier
        self.profileFingerprint = profileFingerprint
        self.refreshRecommended = refreshRecommended
    }
}

public enum RuntimeSetupStatus: String, Codable, Equatable, Sendable {
    case unknown = "UNKNOWN"
    case userActionRequired = "USER_ACTION_REQUIRED"
    case ready = "READY"
    case needsAttention = "NEEDS_ATTENTION"
}

public enum ConsumerSetupCheckpoint: String, Codable, Equatable, Sendable, CaseIterable {
    case installCommandsSucceeded = "INSTALL_COMMANDS_SUCCEEDED"
    case installationVerified = "INSTALLATION_VERIFIED"
    case developerProfileTrustRequired = "DEVELOPER_PROFILE_TRUST_REQUIRED"
    case runtimeConfigurationWritten = "RUNTIME_CONFIGURATION_WRITTEN"
    case runtimeConfigurationVerified = "RUNTIME_CONFIGURATION_VERIFIED"
    case remotePairingVerified = "REMOTE_PAIRING_VERIFIED"
    case localDevVPNReady = "LOCALDEVVPN_READY"
    case setupReadyForRuntime = "SETUP_READY_FOR_RUNTIME"
    /// Legacy schema-1/2 value. It proved runtime mapping only, never pairing.
    case complete = "COMPLETE"

    public var installationIsVerified: Bool {
        self != .installCommandsSucceeded
    }

    public var runtimeConfigurationIsVerified: Bool {
        [.runtimeConfigurationVerified, .remotePairingVerified, .localDevVPNReady, .setupReadyForRuntime, .complete].contains(self)
    }

    public var remotePairingIsVerified: Bool {
        self == .remotePairingVerified || self == .localDevVPNReady || self == .setupReadyForRuntime
    }

    public var localDevVPNIsVerified: Bool {
        self == .localDevVPNReady || self == .setupReadyForRuntime
    }

    public var setupIsReadyForRuntime: Bool {
        self == .setupReadyForRuntime
    }
}

public enum DeveloperProfileTrustStatus: String, Codable, Equatable, Sendable {
    case unknown = "UNKNOWN"
    case required = "REQUIRED"
    case trusted = "TRUSTED"
}

/// One authoritative view of the selected device's post-install application
/// inventory. Presence is exact-bundle based; stale/canonical apps never count
/// as the current Personal Team main or runner.
public struct InstallationInventoryResult: Codable, Equatable, Sendable {
    public let selectedDeviceMatches: Bool
    public let inventoryAvailable: Bool
    public let mainPresent: Bool
    public let runnerPresent: Bool
    public let mainBundleIDMatches: Bool
    public let runnerBundleIDMatches: Bool
    public let expectedTeamContext: Bool
    public let staleIOSSimArtifactsPresent: Bool
    public let retryCount: Int
    public let elapsedMilliseconds: Int
    public let safeReason: String

    public init(
        selectedDeviceMatches: Bool,
        inventoryAvailable: Bool,
        mainPresent: Bool,
        runnerPresent: Bool,
        mainBundleIDMatches: Bool,
        runnerBundleIDMatches: Bool,
        expectedTeamContext: Bool,
        staleIOSSimArtifactsPresent: Bool,
        retryCount: Int,
        elapsedMilliseconds: Int,
        safeReason: String
    ) {
        self.selectedDeviceMatches = selectedDeviceMatches
        self.inventoryAvailable = inventoryAvailable
        self.mainPresent = mainPresent
        self.runnerPresent = runnerPresent
        self.mainBundleIDMatches = mainBundleIDMatches
        self.runnerBundleIDMatches = runnerBundleIDMatches
        self.expectedTeamContext = expectedTeamContext
        self.staleIOSSimArtifactsPresent = staleIOSSimArtifactsPresent
        self.retryCount = retryCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.safeReason = safeReason
    }

    public var verified: Bool {
        selectedDeviceMatches && inventoryAvailable && mainPresent && runnerPresent
            && mainBundleIDMatches && runnerBundleIDMatches && expectedTeamContext
    }
}

public struct ConsumerProvisioningManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let deviceIdentifierSafe: String
    public let deviceIdentifierHash: String
    public let deviceName: String?
    public let deviceModel: String?
    public let deviceOSVersion: String?
    public let teamID: String
    public let sourceMainBundleID: String
    public let installedMainBundleID: String
    public let sourceUITestBundleID: String
    public let installedUITestBundleID: String
    public let sourceRunnerBundleID: String
    public let installedRunnerBundleID: String
    public let mainProfile: ConsumerProfileState
    public let runnerProfile: ConsumerProfileState
    public let lastInstallDate: Date
    public let lastRefreshAttempt: Date?
    public let lastRefreshSuccess: Date?
    public let runtimeSetupStatus: RuntimeSetupStatus
    public let lastRuntimeHealthCheck: Date?
    public let appVersion: String
    public let provisionerVersion: String
    public let trueRenewalPhysicallyValidated: Bool
    /// Optional for backward compatibility with physically proven schema-v1
    /// manifests written before setup checkpoints were introduced.
    public let setupCheckpoint: ConsumerSetupCheckpoint?
    public let installationInventory: InstallationInventoryResult?
    public let developerProfileTrustStatus: DeveloperProfileTrustStatus?
    public let operationGeneration: UInt64?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        deviceIdentifierSafe: String,
        deviceIdentifierHash: String,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        deviceOSVersion: String? = nil,
        teamID: String,
        sourceMainBundleID: String,
        installedMainBundleID: String,
        sourceUITestBundleID: String,
        installedUITestBundleID: String,
        sourceRunnerBundleID: String,
        installedRunnerBundleID: String,
        mainProfile: ConsumerProfileState,
        runnerProfile: ConsumerProfileState,
        lastInstallDate: Date,
        lastRefreshAttempt: Date? = nil,
        lastRefreshSuccess: Date? = nil,
        runtimeSetupStatus: RuntimeSetupStatus = .userActionRequired,
        lastRuntimeHealthCheck: Date? = nil,
        appVersion: String,
        provisionerVersion: String,
        trueRenewalPhysicallyValidated: Bool = false,
        setupCheckpoint: ConsumerSetupCheckpoint? = nil,
        installationInventory: InstallationInventoryResult? = nil,
        developerProfileTrustStatus: DeveloperProfileTrustStatus? = nil,
        operationGeneration: UInt64? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.deviceIdentifierSafe = deviceIdentifierSafe
        self.deviceIdentifierHash = deviceIdentifierHash
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.deviceOSVersion = deviceOSVersion
        self.teamID = teamID
        self.sourceMainBundleID = sourceMainBundleID
        self.installedMainBundleID = installedMainBundleID
        self.sourceUITestBundleID = sourceUITestBundleID
        self.installedUITestBundleID = installedUITestBundleID
        self.sourceRunnerBundleID = sourceRunnerBundleID
        self.installedRunnerBundleID = installedRunnerBundleID
        self.mainProfile = mainProfile
        self.runnerProfile = runnerProfile
        self.lastInstallDate = lastInstallDate
        self.lastRefreshAttempt = lastRefreshAttempt
        self.lastRefreshSuccess = lastRefreshSuccess
        self.runtimeSetupStatus = runtimeSetupStatus
        self.lastRuntimeHealthCheck = lastRuntimeHealthCheck
        self.appVersion = appVersion
        self.provisionerVersion = provisionerVersion
        self.trueRenewalPhysicallyValidated = trueRenewalPhysicallyValidated
        self.setupCheckpoint = setupCheckpoint
        self.installationInventory = installationInventory
        self.developerProfileTrustStatus = developerProfileTrustStatus
        self.operationGeneration = operationGeneration
    }

    /// A missing legacy checkpoint is never proof of current device state.
    /// Migration conservatively returns to installation verification.
    public var effectiveSetupCheckpoint: ConsumerSetupCheckpoint {
        setupCheckpoint ?? .installationVerified
    }

    public func migratedToCurrentSchema() -> ConsumerProvisioningManifest {
        let migratedCheckpoint: ConsumerSetupCheckpoint
        if schemaVersion >= 3, effectiveSetupCheckpoint.remotePairingIsVerified {
            // Schema 3 could claim readiness before LocalDevVPN had been
            // functionally verified. Preserve pairing proof, then run the new
            // setup-only VPN gate.
            migratedCheckpoint = .remotePairingVerified
        } else if effectiveSetupCheckpoint.runtimeConfigurationIsVerified {
            migratedCheckpoint = .runtimeConfigurationVerified
        } else {
            migratedCheckpoint = effectiveSetupCheckpoint
        }
        return ConsumerProvisioningManifest(
            schemaVersion: Self.currentSchemaVersion,
            deviceIdentifierSafe: deviceIdentifierSafe,
            deviceIdentifierHash: deviceIdentifierHash,
            deviceName: deviceName,
            deviceModel: deviceModel,
            deviceOSVersion: deviceOSVersion,
            teamID: teamID,
            sourceMainBundleID: sourceMainBundleID,
            installedMainBundleID: installedMainBundleID,
            sourceUITestBundleID: sourceUITestBundleID,
            installedUITestBundleID: installedUITestBundleID,
            sourceRunnerBundleID: sourceRunnerBundleID,
            installedRunnerBundleID: installedRunnerBundleID,
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            lastInstallDate: lastInstallDate,
            lastRefreshAttempt: lastRefreshAttempt,
            lastRefreshSuccess: lastRefreshSuccess,
            runtimeSetupStatus: .userActionRequired,
            lastRuntimeHealthCheck: lastRuntimeHealthCheck,
            appVersion: appVersion,
            provisionerVersion: provisionerVersion,
            trueRenewalPhysicallyValidated: trueRenewalPhysicallyValidated,
            setupCheckpoint: migratedCheckpoint,
            installationInventory: installationInventory,
            developerProfileTrustStatus: developerProfileTrustStatus,
            operationGeneration: operationGeneration
        )
    }

    public var earliestExpiration: Date? {
        [mainProfile.expirationDate, runnerProfile.expirationDate].compactMap { $0 }.min()
    }

    public func updatingRuntimeSetupStatus(
        _ status: RuntimeSetupStatus,
        checkedAt: Date = Date()
    ) -> ConsumerProvisioningManifest {
        ConsumerProvisioningManifest(
            schemaVersion: schemaVersion,
            deviceIdentifierSafe: deviceIdentifierSafe,
            deviceIdentifierHash: deviceIdentifierHash,
            deviceName: deviceName,
            deviceModel: deviceModel,
            deviceOSVersion: deviceOSVersion,
            teamID: teamID,
            sourceMainBundleID: sourceMainBundleID,
            installedMainBundleID: installedMainBundleID,
            sourceUITestBundleID: sourceUITestBundleID,
            installedUITestBundleID: installedUITestBundleID,
            sourceRunnerBundleID: sourceRunnerBundleID,
            installedRunnerBundleID: installedRunnerBundleID,
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            lastInstallDate: lastInstallDate,
            lastRefreshAttempt: lastRefreshAttempt,
            lastRefreshSuccess: lastRefreshSuccess,
            runtimeSetupStatus: status,
            lastRuntimeHealthCheck: checkedAt,
            appVersion: appVersion,
            provisionerVersion: provisionerVersion,
            trueRenewalPhysicallyValidated: trueRenewalPhysicallyValidated,
            setupCheckpoint: setupCheckpoint,
            installationInventory: installationInventory,
            developerProfileTrustStatus: developerProfileTrustStatus,
            operationGeneration: operationGeneration
        )
    }

    public func recordingRefreshAttempt(at date: Date) -> ConsumerProvisioningManifest {
        ConsumerProvisioningManifest(
            schemaVersion: schemaVersion,
            deviceIdentifierSafe: deviceIdentifierSafe,
            deviceIdentifierHash: deviceIdentifierHash,
            deviceName: deviceName,
            deviceModel: deviceModel,
            deviceOSVersion: deviceOSVersion,
            teamID: teamID,
            sourceMainBundleID: sourceMainBundleID,
            installedMainBundleID: installedMainBundleID,
            sourceUITestBundleID: sourceUITestBundleID,
            installedUITestBundleID: installedUITestBundleID,
            sourceRunnerBundleID: sourceRunnerBundleID,
            installedRunnerBundleID: installedRunnerBundleID,
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            lastInstallDate: lastInstallDate,
            lastRefreshAttempt: date,
            lastRefreshSuccess: lastRefreshSuccess,
            runtimeSetupStatus: runtimeSetupStatus,
            lastRuntimeHealthCheck: lastRuntimeHealthCheck,
            appVersion: appVersion,
            provisionerVersion: provisionerVersion,
            trueRenewalPhysicallyValidated: trueRenewalPhysicallyValidated,
            setupCheckpoint: setupCheckpoint,
            installationInventory: installationInventory,
            developerProfileTrustStatus: developerProfileTrustStatus,
            operationGeneration: operationGeneration
        )
    }

    public func recordingRefreshSuccess(at date: Date) -> ConsumerProvisioningManifest {
        ConsumerProvisioningManifest(
            schemaVersion: schemaVersion,
            deviceIdentifierSafe: deviceIdentifierSafe,
            deviceIdentifierHash: deviceIdentifierHash,
            deviceName: deviceName,
            deviceModel: deviceModel,
            deviceOSVersion: deviceOSVersion,
            teamID: teamID,
            sourceMainBundleID: sourceMainBundleID,
            installedMainBundleID: installedMainBundleID,
            sourceUITestBundleID: sourceUITestBundleID,
            installedUITestBundleID: installedUITestBundleID,
            sourceRunnerBundleID: sourceRunnerBundleID,
            installedRunnerBundleID: installedRunnerBundleID,
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            lastInstallDate: lastInstallDate,
            lastRefreshAttempt: lastRefreshAttempt,
            lastRefreshSuccess: date,
            runtimeSetupStatus: runtimeSetupStatus,
            lastRuntimeHealthCheck: lastRuntimeHealthCheck,
            appVersion: appVersion,
            provisionerVersion: provisionerVersion,
            trueRenewalPhysicallyValidated: trueRenewalPhysicallyValidated,
            setupCheckpoint: setupCheckpoint,
            installationInventory: installationInventory,
            developerProfileTrustStatus: developerProfileTrustStatus,
            operationGeneration: operationGeneration
        )
    }

    public func updatingSetupCheckpoint(
        _ checkpoint: ConsumerSetupCheckpoint,
        inventory: InstallationInventoryResult? = nil,
        developerProfileTrustStatus: DeveloperProfileTrustStatus? = nil
    ) -> ConsumerProvisioningManifest {
        ConsumerProvisioningManifest(
            schemaVersion: schemaVersion,
            deviceIdentifierSafe: deviceIdentifierSafe,
            deviceIdentifierHash: deviceIdentifierHash,
            deviceName: deviceName,
            deviceModel: deviceModel,
            deviceOSVersion: deviceOSVersion,
            teamID: teamID,
            sourceMainBundleID: sourceMainBundleID,
            installedMainBundleID: installedMainBundleID,
            sourceUITestBundleID: sourceUITestBundleID,
            installedUITestBundleID: installedUITestBundleID,
            sourceRunnerBundleID: sourceRunnerBundleID,
            installedRunnerBundleID: installedRunnerBundleID,
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            lastInstallDate: lastInstallDate,
            lastRefreshAttempt: lastRefreshAttempt,
            lastRefreshSuccess: lastRefreshSuccess,
            runtimeSetupStatus: runtimeSetupStatus,
            lastRuntimeHealthCheck: lastRuntimeHealthCheck,
            appVersion: appVersion,
            provisionerVersion: provisionerVersion,
            trueRenewalPhysicallyValidated: trueRenewalPhysicallyValidated,
            setupCheckpoint: checkpoint,
            installationInventory: inventory ?? installationInventory,
            developerProfileTrustStatus: developerProfileTrustStatus ?? self.developerProfileTrustStatus,
            operationGeneration: operationGeneration
        )
    }

    public func updatingInstallationInventory(_ inventory: InstallationInventoryResult) -> ConsumerProvisioningManifest {
        ConsumerProvisioningManifest(
            schemaVersion: schemaVersion,
            deviceIdentifierSafe: deviceIdentifierSafe,
            deviceIdentifierHash: deviceIdentifierHash,
            deviceName: deviceName,
            deviceModel: deviceModel,
            deviceOSVersion: deviceOSVersion,
            teamID: teamID,
            sourceMainBundleID: sourceMainBundleID,
            installedMainBundleID: installedMainBundleID,
            sourceUITestBundleID: sourceUITestBundleID,
            installedUITestBundleID: installedUITestBundleID,
            sourceRunnerBundleID: sourceRunnerBundleID,
            installedRunnerBundleID: installedRunnerBundleID,
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            lastInstallDate: lastInstallDate,
            lastRefreshAttempt: lastRefreshAttempt,
            lastRefreshSuccess: lastRefreshSuccess,
            runtimeSetupStatus: runtimeSetupStatus,
            lastRuntimeHealthCheck: lastRuntimeHealthCheck,
            appVersion: appVersion,
            provisionerVersion: provisionerVersion,
            trueRenewalPhysicallyValidated: trueRenewalPhysicallyValidated,
            setupCheckpoint: setupCheckpoint,
            installationInventory: inventory,
            developerProfileTrustStatus: developerProfileTrustStatus,
            operationGeneration: operationGeneration
        )
    }
}

public struct ConsumerSetupReconciliationResult: Codable, Equatable, Sendable {
    public let trigger: ConsumerReconciliationTrigger
    public let persistedCheckpoint: ConsumerSetupCheckpoint
    public let derivedCheckpoint: ConsumerSetupCheckpoint?
    public let inventory: InstallationInventoryResult
    public let mainInstallRequired: Bool
    public let runnerInstallRequired: Bool
    public let repairScope: SetupRepairScope
    public let renewalRequired: Bool
    public let releaseUpgradeRequired: Bool
    public let checkpointSource: String
    public let selectedDeviceIdentityType: String
    public let legacyFallbackUsed: Bool
    public let consumerBuildAttempted: Bool

    public init(
        trigger: ConsumerReconciliationTrigger,
        persistedCheckpoint: ConsumerSetupCheckpoint,
        derivedCheckpoint: ConsumerSetupCheckpoint?,
        inventory: InstallationInventoryResult,
        mainInstallRequired: Bool,
        runnerInstallRequired: Bool,
        repairScope: SetupRepairScope = .none,
        renewalRequired: Bool = false,
        releaseUpgradeRequired: Bool = false
    ) {
        self.trigger = trigger
        self.persistedCheckpoint = persistedCheckpoint
        self.derivedCheckpoint = derivedCheckpoint
        self.inventory = inventory
        self.mainInstallRequired = mainInstallRequired
        self.runnerInstallRequired = runnerInstallRequired
        self.repairScope = repairScope
        self.renewalRequired = renewalRequired
        self.releaseUpgradeRequired = releaseUpgradeRequired
        self.checkpointSource = "PHYSICAL_DERIVED"
        self.selectedDeviceIdentityType = "LOCKDOWN_UDID"
        self.legacyFallbackUsed = false
        self.consumerBuildAttempted = false
    }

    public var repairRequired: Bool {
        mainInstallRequired || runnerInstallRequired || renewalRequired || releaseUpgradeRequired
    }
}

public struct ConsumerProvisioningResult: Codable, Equatable, Sendable {
    public let operation: ConsumerProvisioningOperation
    public let finalStage: ConsumerProvisioningStage
    public let manifest: ConsumerProvisioningManifest
    public let installedBundleIdentifiers: [String]
    public let runtimeRecoveryRecommended: Bool

    public init(
        operation: ConsumerProvisioningOperation,
        finalStage: ConsumerProvisioningStage,
        manifest: ConsumerProvisioningManifest,
        installedBundleIdentifiers: [String],
        runtimeRecoveryRecommended: Bool
    ) {
        self.operation = operation
        self.finalStage = finalStage
        self.manifest = manifest
        self.installedBundleIdentifiers = installedBundleIdentifiers.sorted()
        self.runtimeRecoveryRecommended = runtimeRecoveryRecommended
    }
}

public enum RefreshDueState: String, Codable, Equatable, Sendable {
    case current = "CURRENT"
    case dueSoon = "DUE_SOON"
    case dueNow = "DUE_NOW"
    case expired = "EXPIRED"
    case unavailable = "UNAVAILABLE"
}

public struct ConsumerRefreshPolicy: Codable, Equatable, Sendable {
    public static let recommended = ConsumerRefreshPolicy(recommendedThreshold: 48 * 60 * 60)
    public let recommendedThreshold: TimeInterval

    public init(recommendedThreshold: TimeInterval) {
        self.recommendedThreshold = recommendedThreshold
    }

    public func dueState(expiration: Date?, now: Date = Date()) -> RefreshDueState {
        guard let expiration else { return .unavailable }
        let remaining = expiration.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= recommendedThreshold { return .dueNow }
        if remaining <= recommendedThreshold * 2 { return .dueSoon }
        return .current
    }
}

public enum ProvisioningLogResult: String, Codable, Equatable, Sendable {
    case started = "STARTED"
    case passed = "PASSED"
    case failed = "FAILED"
    case skipped = "SKIPPED"
}

public struct ProvisioningLogEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let stage: ConsumerProvisioningStage
    public let artifact: String?
    public let selectedDevice: String?
    public let result: ProvisioningLogResult
    public let errorCode: ConsumerProvisioningErrorCode?
    public let durationMilliseconds: Int?
    public let detail: String?
    public let generation: UInt64?
    public let resumeCheckpoint: ConsumerSetupCheckpoint?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stage: ConsumerProvisioningStage,
        artifact: String? = nil,
        selectedDevice: String? = nil,
        result: ProvisioningLogResult,
        errorCode: ConsumerProvisioningErrorCode? = nil,
        durationMilliseconds: Int? = nil,
        detail: String? = nil,
        generation: UInt64? = nil,
        resumeCheckpoint: ConsumerSetupCheckpoint? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stage = stage
        self.artifact = artifact
        self.selectedDevice = selectedDevice.map(RuntimeProvisioning.shortIdentifier)
        self.result = result
        self.errorCode = errorCode
        self.durationMilliseconds = durationMilliseconds
        self.detail = detail.map(Redactor.redact)
        self.generation = generation
        self.resumeCheckpoint = resumeCheckpoint
    }
}

public enum ConsumerProvisioningErrorClassifier {
    public static func installErrorCode(output: String, artifact: String) -> ConsumerProvisioningErrorCode {
        let lower = output.lowercased()
        if lower.contains("locked") || lower.contains("passcode") && lower.contains("required") {
            return .deviceLocked
        }
        if lower.contains("developer mode") && (lower.contains("disabled") || lower.contains("required")) {
            return .developerModeRequired
        }
        if lower.contains("not paired") || lower.contains("trust this computer")
            || lower.contains("pairing") && lower.contains("trust") {
            return .computerTrustRequired
        }
        if lower.contains("mismatchedapplicationidentifierentitlement")
            || lower.contains("application-identifier") && lower.contains("does not match")
            || lower.contains("native_ownership_conflict") {
            return .crossTeamUpgradeBlocked
        }
        if lower.contains("device") && lower.contains("not") && lower.contains("profile") {
            return .deviceNotIncluded
        }
        if lower.contains("device unavailable") || lower.contains("device is unavailable")
            || lower.contains("device disconnected") || lower.contains("iphone disconnected")
            || lower.contains("lost connection") || lower.contains("no device found")
            || lower.contains("device was not found") || lower.contains("failed to connect to device")
            || lower.contains("connection invalidated") {
            return .deviceUnavailable
        }
        return artifact == "main" ? .mainInstallFailure : .runnerInstallFailure
    }

    /// Classifies the structured CoreDevice/FBS error chain observed on the
    /// physical iPhone. The profile-trust result requires domain/code evidence,
    /// the Security reason, and the explicit profile-trust diagnostic; a generic
    /// launch denial is deliberately not enough.
    public static func launchErrorCode(output: String) -> ConsumerProvisioningErrorCode {
        let lower = output.lowercased()
        let typedPrefixes: [(String, ConsumerProvisioningErrorCode)] = [
            ("device_resolution_failed:", .deviceResolutionFailed),
            ("coredevice_proxy_failed:", .coreDeviceProxyFailed),
            ("software_tunnel_failed:", .softwareTunnelFailed),
            ("rsd_unavailable:", .rsdUnavailable),
            ("remotexpc_failed:", .remoteXPCFailed),
            ("appservice_unavailable:", .appServiceUnavailable),
            ("feature_unavailable:", .featureUnavailable),
            ("application_not_found:", .applicationNotFound),
            ("ddi_required:", .ddiRequired),
            ("developer_services_not_ready:", .developerServicesNotReady),
            ("launch_rejected:", .launchRejected),
            ("protocol_error:", .nativeProtocolError),
        ]
        if let match = typedPrefixes.first(where: { lower.hasPrefix($0.0) }) {
            if match.1 == .launchRejected,
               lower.contains("profile has not been explicitly trusted") {
                return .developerProfileTrustRequired
            }
            return match.1
        }
        if lower.contains("coredeviceerror error 10002")
            && lower.contains("fbsopenapplicationerrordomain error 3")
            && lower.contains("bserrorcodedescription = security")
            && lower.contains("profile has not been explicitly trusted") {
            return .developerProfileTrustRequired
        }
        return installErrorCode(output: output, artifact: "main") == .mainInstallFailure
            ? .runtimeConfigurationWriteFailed
            : installErrorCode(output: output, artifact: "main")
    }

    public static func signingErrorCode(output: String) -> ConsumerProvisioningErrorCode {
        let lower = output.lowercased()
        if lower.contains("requires a development team") || lower.contains("no accounts") {
            return .appleAccountMissing
        }
        if lower.contains("certificate") || lower.contains("signing identity") {
            return .signingIdentityMissing
        }
        if lower.contains("register") && lower.contains("bundle") {
            return .bundleIDRegistrationFailure
        }
        return .profileUnavailable
    }
}
