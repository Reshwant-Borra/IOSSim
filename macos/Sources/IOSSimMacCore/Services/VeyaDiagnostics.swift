import Foundation

public enum VeyaErrorNamespace: String, Codable, CaseIterable, Sendable {
    case integrity = "VEYA-INTEGRITY"
    case device = "VEYA-DEVICE"
    case trust = "VEYA-TRUST"
    case developerSupport = "VEYA-DEVSUPPORT"
    case apple = "VEYA-APPLE"
    case signing = "VEYA-SIGNING"
    case profile = "VEYA-PROFILE"
    case install = "VEYA-INSTALL"
    case pairing = "VEYA-PAIRING"
    case vpn = "VEYA-VPN"
    case developerService = "VEYA-DEVSERVICE"
    case runner = "VEYA-RUNNER"
    case runtime = "VEYA-RUNTIME"
    case state = "VEYA-STATE"
    case update = "VEYA-UPDATE"
}

public enum VeyaRetryability: String, Codable, Sendable {
    case no = "NO"
    case automatic = "AUTOMATIC"
    case afterUserAction = "AFTER_USER_ACTION"
}

public struct VeyaDiagnosticDescriptor: Codable, Equatable, Sendable {
    public let code: String
    public let namespace: VeyaErrorNamespace
    public let stage: String
    public let userMessage: String
    public let safeDeveloperDetail: String
    public let retryability: VeyaRetryability
    public let automaticRepair: Bool
    public let requiredUserAction: String?
    public let supportFields: [String: String]
}

public enum VeyaErrorTaxonomy {
    public static func descriptor(for failure: ConsumerProvisioningFailure) -> VeyaDiagnosticDescriptor {
        descriptor(
            for: failure.code,
            stage: failure.stage,
            userMessage: failure.userMessage,
            developerDetail: failure.developerDetail,
            remediation: failure.remediation
        )
    }

    public static func descriptor(
        for code: ConsumerProvisioningErrorCode,
        stage: ConsumerProvisioningStage,
        userMessage: String = "Setup needs attention.",
        developerDetail: String = "",
        remediation: String = "Try the indicated setup step again."
    ) -> VeyaDiagnosticDescriptor {
        let identity = stableIdentity(for: code, stage: stage)
        let userAction = requiresUserAction(code) ? remediation : nil
        let retryability: VeyaRetryability
        if userAction != nil {
            retryability = .afterUserAction
        } else if isRetryable(code) {
            retryability = .automatic
        } else {
            retryability = .no
        }
        return VeyaDiagnosticDescriptor(
            code: "\(identity.0.rawValue)-\(identity.1)",
            namespace: identity.0,
            stage: stage.rawValue,
            userMessage: userMessage,
            safeDeveloperDetail: Redactor.redact(developerDetail),
            retryability: retryability,
            automaticRepair: retryability == .automatic,
            requiredUserAction: userAction,
            supportFields: [
                "legacyCode": code.rawValue,
                "stage": stage.rawValue,
            ]
        )
    }

    private static func stableIdentity(
        for code: ConsumerProvisioningErrorCode,
        stage: ConsumerProvisioningStage
    ) -> (VeyaErrorNamespace, String) {
        switch code {
        case .artifactInvalid: return (.integrity, "004")
        case .noIPhoneFound: return (.device, "001")
        case .deviceSelectionRequired: return (.device, "002")
        case .deviceUnavailable: return (.device, "003")
        case .deviceLocked: return (.device, "004")
        case .deviceResolutionFailed: return (.device, "005")
        case .computerTrustRequired: return (.trust, "003")
        case .developerModeRequired, .developerModeOff: return (.developerService, "001")
        case .ddiRequired: return (.developerSupport, "002")
        case .ddiPersonalizationFailed: return (.developerSupport, "005")
        case .ddiMountFailed: return (.developerSupport, "006")
        case .appleAccountMissing: return (.apple, "001")
        case .personalTeamUnavailable, .teamSelectionRequired: return (.apple, "011")
        case .accountTeamMismatch, .staleTeamState: return (.apple, "012")
        case .bundleIDRegistrationFailure: return (.apple, "022")
        // 020 is the taxonomy's certificate-limit slot. It now has a specified
        // exit rather than being terminal: Veya reclaims a certificate it can
        // prove it owns, and only reports 020 when it cannot.
        case .certificateCapacityExhausted: return (.apple, "020")
        case .certificateRevocationFailed: return (.apple, "023")
        case .certificateCapacityNotReleased: return (.apple, "024")
        case .signingIdentityMissing, .signingIdentityNotFound: return (.signing, "004")
        case .signingPrivateKeyNotFound: return (.signing, "002")
        case .signingCertificateNotFound: return (.signing, "005")
        case .signingCertificateKeyMismatch, .profileCertificateMismatch: return (.signing, "003")
        case .signingKeyAccessDenied, .signingIdentityAccessDenied: return (.signing, "004")
        case .signingKeychainUnavailable: return (.signing, "006")
        case .signingACLRepairFailed: return (.signing, "007")
        case .signingProbeFailed: return (.signing, "008")
        case .signOperationFailed, .nestedSigningFailed, .mainSigningFailure,
             .runnerSigningFailure, .runnerNestedSignatureFailure: return (.signing, "010")
        case .signatureVerificationFailed: return (.signing, "011")
        case .profileUnavailable: return (.profile, "001")
        case .profileExpired: return (.profile, "003")
        case .profileNearExpiry: return (.profile, "004")
        case .entitlementMismatch: return (.profile, "005")
        case .deviceNotIncluded: return (.profile, "006")
        case .developerProfileTrustRequired: return (.profile, "010")
        case .developerProfileTrustVerificationFailed: return (.profile, "011")
        case .mainInstallFailure: return (.install, "001")
        case .runnerInstallFailure: return (.install, "002")
        case .installInventoryPending, .installVerificationFailed: return (.install, "003")
        case .installCommandFailed: return (.install, "004")
        case .installedIdentityMigrationRequired, .crossTeamUpgradeBlocked,
             .crossTeamInstallConflict: return (.install, "005")
        case .remotePairingFailed: return (.pairing, "020")
        case .pairingDeliveryFailed: return (.pairing, "003")
        case .pairingReceiptFailed: return (.pairing, "005")
        case .localDevVPNMissing: return (.vpn, "001")
        case .localDevVPNUserActionRequired: return (.vpn, "003")
        case .localDevVPNReadinessFailed: return (.vpn, "007")
        case .coreDeviceProxyFailed: return (.developerService, "007")
        case .softwareTunnelFailed: return (.developerService, "008")
        case .rsdUnavailable: return (.developerService, "009")
        case .remoteXPCFailed: return (.developerService, "010")
        case .appServiceUnavailable: return (.developerService, "020")
        case .developerServicesNotReady: return (.developerService, "022")
        case .runnerMappingMissing: return (.runner, "002")
        case .runnerNotInstalled, .applicationNotFound: return (.runner, "001")
        case .duplicateRunner: return (.runner, "005")
        case .nativeLaunchUnavailable, .launchRejected: return (.runner, "003")
        case .staleRuntimeSession: return (.runner, "005")
        case .runtimeVerificationFailed: return (.runtime, "002")
        case .runtimeProofFailed: return (.runtime, "006")
        case .runtimeConfigurationWriteFailed: return (.runtime, "007")
        case .runtimeConfigurationReadbackFailed, .nativeContainerReadFailed,
             .houseArrestUnavailable: return (.runtime, "008")
        case .nativeProtocolError: return (.runtime, "009")
        case .manifestCorrupt: return (.state, "004")
        case .operationInProgress: return (.state, "001")
        case .xcodeMissing, .developerToolsUnavailable: return (.update, "002")
        case .featureUnavailable, .unsupported: return (.update, "003")
        case .unknown:
            return (namespace(for: stage), "099")
        }
    }

    private static func namespace(for stage: ConsumerProvisioningStage) -> VeyaErrorNamespace {
        switch stage {
        case .checkingDevice, .discoveringDevices, .waitingForDeviceSelection: return .device
        case .checkingDeveloperMode, .developerServicesReconciliationStarted,
             .coreDeviceProxyReady, .softwareTunnelReady, .rsdReady, .remoteXPCReady,
             .appServiceReady: return .developerService
        case .ddiRequired, .ddiAcquisitionStarted, .ddiAcquisitionSucceeded,
             .ddiPersonalizationStarted, .ddiPersonalizationSucceeded,
             .ddiMountStarted, .ddiMountSucceeded, .ddiNotRequired: return .developerSupport
        case .discoveringAppleAccounts, .waitingForTeamSelection, .validatingTeam: return .apple
        case .signingNestedComponents, .signingMain, .signingRunner, .verifyingSignatures: return .signing
        case .installingMain, .installingRunner, .verifyingInstallation,
             .installInventoryRefresh, .installInventoryPending: return .install
        case .pairingReconciliationStarted, .pairingDeliveryStarted, .pairingReceiptVerified: return .pairing
        case .localDevVPNReadinessStarted, .localDevVPNUserActionRequired: return .vpn
        case .verifyingRuntimeReadiness, .writingRuntimeConfiguration,
             .verifyingRuntimeConfiguration: return .runtime
        default: return .state
        }
    }

    private static func requiresUserAction(_ code: ConsumerProvisioningErrorCode) -> Bool {
        switch code {
        case .noIPhoneFound, .deviceSelectionRequired, .deviceUnavailable, .deviceLocked,
             .computerTrustRequired, .developerModeRequired, .developerModeOff,
             .appleAccountMissing, .personalTeamUnavailable, .teamSelectionRequired,
             .developerProfileTrustRequired, .localDevVPNMissing,
             .localDevVPNUserActionRequired:
            return true
        default:
            return false
        }
    }

    private static func isRetryable(_ code: ConsumerProvisioningErrorCode) -> Bool {
        switch code {
        case .deviceUnavailable, .installInventoryPending, .ddiRequired,
             .ddiPersonalizationFailed, .ddiMountFailed, .softwareTunnelFailed,
             .rsdUnavailable, .remoteXPCFailed, .appServiceUnavailable,
             .developerServicesNotReady, .remotePairingFailed, .pairingDeliveryFailed,
             .pairingReceiptFailed, .localDevVPNReadinessFailed, .staleRuntimeSession,
             .runtimeVerificationFailed, .runtimeProofFailed, .operationInProgress:
            return true
        default:
            return false
        }
    }
}

public extension ConsumerProvisioningFailure {
    var diagnosticDescriptor: VeyaDiagnosticDescriptor {
        VeyaErrorTaxonomy.descriptor(for: self)
    }
}

public enum SupportSecretScanner {
    public static func findings(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return ["NON_UTF8_SUPPORT_DOCUMENT"] }
        let patterns: [(String, String)] = [
            ("PRIVATE_KEY", "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
            ("PASSWORD", "(?i)password\\s*[:=]\\s*(?!\\[REDACTED\\])[^\\s,;\\\"]+"),
            ("TOKEN", "(?i)(?:token|authorization)\\s*[:=]\\s*(?!\\[REDACTED\\])[^\\s,;\\\"]+"),
            ("COOKIE", "(?i)(?:cookie|set-cookie)\\s*[:=]\\s*(?!\\[REDACTED\\])[^\\s,;\\\"]+"),
            ("PAIRING_SECRET", "(?i)(?:pairing[-_ ]?(?:psk|secret|material)|psk)\\s*[:=]\\s*(?!\\[REDACTED\\])[^\\s,;\\\"]+"),
            ("TWO_FACTOR_CODE", "(?i)(?:2fa|verification|two-factor)[-_ ]?(?:code)?\\s*[:=]\\s*[0-9]{4,8}"),
        ]
        return patterns.compactMap { label, pattern in
            text.range(of: pattern, options: .regularExpression) == nil ? nil : label
        }
    }
}
