import Foundation

public enum SetupPhase: String, Equatable, Sendable, CaseIterable {
    case welcome
    case checkingMac
    case macActionRequired
    case waitingForDevice
    case checkingDevice
    case deviceActionRequired
    case installing
    case runtimeSetup
    case verifying
    case complete
    case failed

    public var stepIndex: Int {
        switch self {
        case .welcome: return 1
        case .checkingMac, .macActionRequired: return 2
        case .waitingForDevice: return 3
        case .checkingDevice, .deviceActionRequired: return 4
        case .installing: return 5
        case .runtimeSetup: return 6
        case .verifying: return 7
        case .complete: return 8
        case .failed: return 0
        }
    }

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .checkingMac: return "Check This Mac"
        case .macActionRequired: return "Action Required"
        case .waitingForDevice: return "Connect iPhone"
        case .checkingDevice: return "Check iPhone"
        case .deviceActionRequired: return "Action Required"
        case .installing: return "Install IOSSim"
        case .runtimeSetup: return "Runtime Setup"
        case .verifying: return "Verify"
        case .complete: return "Complete"
        case .failed: return "Could Not Complete Setup"
        }
    }
}

public struct SetupError: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let headline: String
    public let recovery: String
    public let details: String

    public init(headline: String, recovery: String, details: String) {
        self.headline = headline
        self.recovery = recovery
        self.details = details
    }
}

public enum InstallStage: String, CaseIterable, Equatable, Sendable, Identifiable {
    case prepare
    case installIOSSim
    case installRuntime
    case verify

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .prepare: return "Preparing components"
        case .installIOSSim: return "Installing IOSSim"
        case .installRuntime: return "Installing runtime"
        case .verify: return "Verifying installation"
        }
    }
}
