#if VEYA_QUALIFICATION
import Foundation

/// Development-session presentation only. Every label routes to the same reconciliation command;
/// the label describes what the user is continuing, not a different engine operation.
public enum DevelopmentInstallationPrimaryAction: String, CaseIterable, Equatable, Sendable {
    case installOrPrepare = "Install / Prepare"
    case continueUserAction = "Continue"
    case continueOrVerifySetup = "Continue / Verify Setup"

    public var command: EngineCommand { .reconcile }

    public static func resolve(firstFailureCode: String?, userAction: String?) -> Self {
        if let firstFailureCode, runSetupContinuationCodes.contains(firstFailureCode) {
            return .continueOrVerifySetup
        }
        if userAction != nil {
            return .continueUserAction
        }
        return .installOrPrepare
    }

    private static let runSetupContinuationCodes: Set<String> = [
        RuntimeReadinessDomain.runtimeActionRequired.code,
        RuntimeReadinessDomain.runSetupRequired.code,
        "VEYA-RUNTIME-012",
    ]
}

/// Qualification UI stages derived from existing engine failures and progress.
/// They change presentation only; every primary action remains `.reconcile`.
public enum DevelopmentInstallationStage: String, CaseIterable, Equatable, Sendable {
    case preparingApp
    case revealDeveloperMode
    case enableDeveloperMode
    case trustDeveloper
    case connectLocalDevVPN
    case preparingPairing
    case readyForSetup
    case verifyingSetup
    case ready

    public var title: String {
        switch self {
        case .preparingApp: return "Preparing App"
        case .revealDeveloperMode: return "Enable Developer Mode"
        case .enableDeveloperMode: return "Enable Developer Mode"
        case .trustDeveloper: return "Trust Developer"
        case .connectLocalDevVPN: return "Connect LocalDevVPN"
        case .preparingPairing: return "Preparing Pairing"
        case .readyForSetup: return "READY FOR SETUP"
        case .verifyingSetup: return "Verifying Setup"
        case .ready: return "READY"
        }
    }

    public var instruction: String {
        switch self {
        case .preparingApp:
            return "Veya will prepare and install the app for this iPhone."
        case .revealDeveloperMode:
            return "Veya will ask this iPhone to show its Developer Mode option in Settings. "
                + "Nothing is installed and Developer Mode is not turned on for you."
        case .enableDeveloperMode:
            return "On your iPhone, open Settings > Privacy & Security > Developer Mode, turn it on, follow the restart prompt, unlock the iPhone, then return here."
        case .trustDeveloper:
            return "On your iPhone, open Settings > General > VPN & Device Management, choose the Apple Development profile for this account, tap Trust, then return here."
        case .connectLocalDevVPN:
            return "Complete the LocalDevVPN action shown below, then return here."
        case .preparingPairing:
            return "Veya is preparing automatic pairing. No pairing-file import is needed."
        case .readyForSetup:
            return "Open Veya on your iPhone and tap Run Setup, then continue here."
        case .verifyingSetup:
            return "Veya is verifying the Run Setup result from your iPhone."
        case .ready:
            return "Setup is complete and the iPhone is ready."
        }
    }

    public var primaryAction: DevelopmentInstallationPrimaryAction {
        switch self {
        case .preparingApp: return .installOrPrepare
        // The two gate stages are driven by `DeveloperModeGateCoordinator`, not by an engine
        // command; this value is only read once the gate has already released the button.
        case .revealDeveloperMode, .enableDeveloperMode, .trustDeveloper, .connectLocalDevVPN,
             .preparingPairing:
            return .continueUserAction
        case .readyForSetup, .verifyingSetup, .ready:
            return .continueOrVerifySetup
        }
    }

    /// Stages owned by the pre-install Developer Mode gate rather than by the engine.
    public var isDeveloperModeGate: Bool {
        self == .revealDeveloperMode || self == .enableDeveloperMode
    }

    public static func resolve(
        firstFailureCode: String?,
        failureDomain: InstallationDomain?,
        userAction: String?,
        status: String?,
        issuedRunSetupRequest: Bool
    ) -> Self {
        if status == ReconciliationOutcomeStatus.ready.rawValue { return .ready }
        if issuedRunSetupRequest,
           firstFailureCode == RuntimeReadinessDomain.runSetupRequired.code
            || firstFailureCode == RuntimeReadinessDomain.runtimeActionRequired.code {
            return .readyForSetup
        }
        if userAction == DeviceFailureMapping.developerMode { return .enableDeveloperMode }
        if userAction == DeviceFailureMapping.developerTrust { return .trustDeveloper }
        if failureDomain == .vpn
            || firstFailureCode?.hasPrefix(InstallationFailureNamespace.vpn.rawValue) == true
            || userAction?.contains("LocalDevVPN") == true {
            return .connectLocalDevVPN
        }
        if failureDomain == .pairing { return .preparingPairing }
        return .preparingApp
    }

    public static func transition(_ domain: InstallationDomain, current: Self = .preparingApp) -> Self {
        if current == .verifyingSetup, domain == .runtime { return .verifyingSetup }
        return domain == .pairing ? .preparingPairing : .preparingApp
    }
}

public enum DevelopmentDeviceRebinding {
    /// A restart may replace mux/transport identity, but never the stable UDID.
    /// Another attached iPhone is not an eligible substitute.
    public static func descriptor(
        forStableUDID udid: String,
        in descriptors: [NativeDeviceDescriptor]
    ) -> NativeDeviceDescriptor? {
        descriptors.first { $0.identity.udid == udid }
    }
}

public struct DevelopmentInstallationFailureContext: Equatable, Sendable {
    public let domain: InstallationDomain?
    public let code: String?
    public let safeMessage: String
    public let userAction: String?

    public init?(result: QualificationResult) {
        guard let failure = result.firstFailure ?? result.userAction.map({
            EngineFailureSummary(code: "ACTION_REQUIRED", safeMessage: $0, domain: nil)
        }) else { return nil }
        domain = failure.domain
        code = failure.code == "ACTION_REQUIRED" ? nil : failure.code
        safeMessage = failure.safeMessage
        userAction = result.userAction
    }
}
#endif
