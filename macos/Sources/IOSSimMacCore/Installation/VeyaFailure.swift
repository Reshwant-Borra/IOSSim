import Foundation

public enum InstallationFailureNamespace: String, Codable, Sendable {
    case artifact = "VEYA-ART"
    case state = "VEYA-STATE"
    case authorization = "VEYA-AUTH"
    case team = "VEYA-TEAM"
    case key = "VEYA-KEY"
    case certificate = "VEYA-CERT"
    case profile = "VEYA-PROFILE"
    case signing = "VEYA-SIGN"
    case install = "VEYA-INSTALL"
    case device = "VEYA-DEVICE"
    case developerSupport = "VEYA-DDI"
    case pairing = "VEYA-PAIR"
    case vpn = "VEYA-VPN"
    case runtime = "VEYA-RUNTIME"
    case migration = "VEYA-MIG"
    case security = "VEYA-SEC"
}

public struct VeyaFailure: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let namespace: InstallationFailureNamespace
    public let operation: String
    public let safeMessage: String
    public let retryable: Bool
    public let userAction: String?
    public let underlyingSubsystem: String
    /// The reconciliation domain executing when this failure was produced.
    /// This is independent of the error namespace; a VPN transition may
    /// legitimately fail with a generic device transport error.
    public let originatingDomain: InstallationDomain?

    public init(
        namespace: InstallationFailureNamespace,
        number: Int,
        operation: String,
        safeMessage: String,
        retryable: Bool = false,
        userAction: String? = nil,
        underlyingSubsystem: String,
        originatingDomain: InstallationDomain? = nil
    ) throws {
        guard (0...999).contains(number) else { throw InstallationStateFailure.unsafeValue("error number") }
        try InstallationSafeValue.validate(operation, field: "operation", maximumLength: 96)
        try InstallationSafeValue.validate(safeMessage, field: "safe message", maximumLength: 512)
        try InstallationSafeValue.validate(underlyingSubsystem, field: "subsystem", maximumLength: 96)
        if let userAction {
            try InstallationSafeValue.validate(userAction, field: "user action", maximumLength: 256)
        }
        self.code = String(format: "%@-%03d", namespace.rawValue, number)
        self.namespace = namespace
        self.operation = operation
        self.safeMessage = safeMessage
        self.retryable = retryable
        self.userAction = userAction
        self.underlyingSubsystem = underlyingSubsystem
        self.originatingDomain = originatingDomain
    }

    public func originating(in domain: InstallationDomain) -> VeyaFailure {
        VeyaFailure(
            validatedCode: code,
            namespace: namespace,
            operation: operation,
            safeMessage: safeMessage,
            retryable: retryable,
            userAction: userAction,
            underlyingSubsystem: underlyingSubsystem,
            originatingDomain: domain
        )
    }

    private init(
        validatedCode: String,
        namespace: InstallationFailureNamespace,
        operation: String,
        safeMessage: String,
        retryable: Bool,
        userAction: String?,
        underlyingSubsystem: String,
        originatingDomain: InstallationDomain?
    ) {
        code = validatedCode
        self.namespace = namespace
        self.operation = operation
        self.safeMessage = safeMessage
        self.retryable = retryable
        self.userAction = userAction
        self.underlyingSubsystem = underlyingSubsystem
        self.originatingDomain = originatingDomain
    }

    public static func == (lhs: VeyaFailure, rhs: VeyaFailure) -> Bool {
        lhs.code == rhs.code
            && lhs.namespace == rhs.namespace
            && lhs.operation == rhs.operation
            && lhs.safeMessage == rhs.safeMessage
            && lhs.retryable == rhs.retryable
            && lhs.userAction == rhs.userAction
            && lhs.underlyingSubsystem == rhs.underlyingSubsystem
    }

    public var description: String { "\(code): \(safeMessage)" }
}

public enum InstallationStateFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case missingJournal
    case corruptJournal
    case unsupportedSchema(Int)
    case writeFailed(String)
    case lockUnavailable
    case leaseHeld(RunID)
    case leaseNotOwned
    case staleRevision(expected: UInt64, actual: UInt64)
    case staleGeneration(expected: Generation, actual: Generation)
    case candidateMissing(InstallationDomain)
    case candidateUnproved(InstallationDomain)
    case transitionInProgress
    case transitionMissing
    case transitionUnavailable(InstallationDomain)
    case cancelled
    case generationOverflow
    case unsafeValue(String)
    case secretMaterialRejected(String)
    case injectedCrash(JournalWritePoint)

    public var code: String {
        switch self {
        case .missingJournal: return "VEYA-STATE-001"
        case .unsupportedSchema: return "VEYA-STATE-002"
        case .corruptJournal: return "VEYA-STATE-003"
        case .writeFailed: return "VEYA-STATE-004"
        case .staleGeneration: return "VEYA-STATE-005"
        case .lockUnavailable, .leaseHeld: return "VEYA-STATE-006"
        case .leaseNotOwned: return "VEYA-STATE-007"
        case .staleRevision: return "VEYA-STATE-008"
        case .candidateMissing: return "VEYA-STATE-009"
        case .candidateUnproved: return "VEYA-STATE-010"
        case .generationOverflow: return "VEYA-STATE-011"
        case .transitionInProgress: return "VEYA-STATE-013"
        case .transitionMissing: return "VEYA-STATE-014"
        case .transitionUnavailable: return "VEYA-STATE-015"
        case .cancelled: return "VEYA-STATE-016"
        case .unsafeValue, .secretMaterialRejected: return "VEYA-SEC-003"
        case .injectedCrash: return "VEYA-STATE-099"
        }
    }

    public var description: String { code }
}
