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
#endif
