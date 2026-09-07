import Foundation

/// Product-level provisioning selection. This is intentionally separate from
/// `DeviceProvisioningBackend`, which only owns USB device operations.
public enum ConsumerProvisioningBackendPreference: String, Codable, CaseIterable, Sendable {
    case automatic = "AUTO"
    case xcodeInvisible = "XCODE_INVISIBLE"
    case nativePersonalTeam = "NATIVE_PERSONAL_TEAM"
    /// Development compatibility aliases. Production AUTO never selects the
    /// manually configured fallback.
    case zeroXcode = "ZERO_XCODE"
    case xcodeFallback = "XCODE_FALLBACK"

    public static func selected(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        guard let raw = environment["IOSSIM_PROVISIONING_BACKEND"]?.uppercased(),
              let value = Self(rawValue: raw) else {
            return .automatic
        }
        return value
    }
}

public enum ConsumerProvisioningBackendIdentifier: String, Codable, Sendable {
    case nativePersonalTeam = "NATIVE_PERSONAL_TEAM"
    case xcodeInvisible = "XCODE_INVISIBLE"
    /// Existing manually configured development/recovery backend.
    case xcodeFallback = "XCODE_FALLBACK"
}

public enum AppleProvisioningOperation: String, Codable, CaseIterable, Sendable {
    case authenticateAppleAccount
    case discoverPersonalTeam
    case createOrReuseCertificate
    case registerDevice
    case registerBundleIdentifier
    case issueProvisioningProfile
    case renewProvisioningProfile
}

public enum AppleProvisioningSupportClassification: String, Codable, Sendable {
    case documentedSupported = "DOCUMENTED_SUPPORTED"
    case undocumentedButObserved = "UNDOCUMENTED_BUT_OBSERVED"
    case requiresXcode = "REQUIRES_XCODE"
    case unknown = "UNKNOWN"
}

public struct AppleProvisioningCapability: Codable, Equatable, Sendable {
    public let operation: AppleProvisioningOperation
    public let paidTeam: AppleProvisioningSupportClassification
    public let freePersonalTeam: AppleProvisioningSupportClassification
    public let detail: String

    public init(
        operation: AppleProvisioningOperation,
        paidTeam: AppleProvisioningSupportClassification,
        freePersonalTeam: AppleProvisioningSupportClassification,
        detail: String
    ) {
        self.operation = operation
        self.paidTeam = paidTeam
        self.freePersonalTeam = freePersonalTeam
        self.detail = detail
    }
}

public struct ConsumerProvisioningCapabilities: Codable, Equatable, Sendable {
    public let bundledDeviceBridgeReady: Bool
    public let nativeAppleAuthenticationReady: Bool
    public let nativePersonalTeamProvisioningReady: Bool
    public let directSigningReady: Bool
    public let xcodePresent: Bool
    public let headlessXcodeAuthenticationReady: Bool

    public init(
        bundledDeviceBridgeReady: Bool,
        nativeAppleAuthenticationReady: Bool,
        nativePersonalTeamProvisioningReady: Bool,
        directSigningReady: Bool,
        xcodePresent: Bool,
        headlessXcodeAuthenticationReady: Bool = false
    ) {
        self.bundledDeviceBridgeReady = bundledDeviceBridgeReady
        self.nativeAppleAuthenticationReady = nativeAppleAuthenticationReady
        self.nativePersonalTeamProvisioningReady = nativePersonalTeamProvisioningReady
        self.directSigningReady = directSigningReady
        self.xcodePresent = xcodePresent
        self.headlessXcodeAuthenticationReady = headlessXcodeAuthenticationReady
    }

    public var nativeZeroXcodeReady: Bool {
        bundledDeviceBridgeReady
            && nativeAppleAuthenticationReady
            && nativePersonalTeamProvisioningReady
            && directSigningReady
    }

    public var xcodeInvisibleReady: Bool {
        xcodePresent && headlessXcodeAuthenticationReady
    }
}

public struct ConsumerProvisioningBackendSelection: Codable, Equatable, Sendable {
    public let preference: ConsumerProvisioningBackendPreference
    public let backend: ConsumerProvisioningBackendIdentifier?
    public let xcodePresent: Bool
    public let zeroXcodeMode: Bool
    public let ready: Bool
    public let failureCode: String?

    public init(
        preference: ConsumerProvisioningBackendPreference,
        backend: ConsumerProvisioningBackendIdentifier?,
        xcodePresent: Bool,
        zeroXcodeMode: Bool,
        ready: Bool,
        failureCode: String? = nil
    ) {
        self.preference = preference
        self.backend = backend
        self.xcodePresent = xcodePresent
        self.zeroXcodeMode = zeroXcodeMode
        self.ready = ready
        self.failureCode = failureCode
    }
}

public enum ConsumerProvisioningBackendSelector {
    /// AUTO may select only a backend that meets the consumer requirement:
    /// Apple authorization starts in IOSSim and the user never configures
    /// Xcode. The proven manual Xcode path remains an explicit development and
    /// recovery override, never an automatic production fallback.
    public static func select(
        preference: ConsumerProvisioningBackendPreference,
        capabilities: ConsumerProvisioningCapabilities
    ) -> ConsumerProvisioningBackendSelection {
        switch preference {
        case .automatic:
            if capabilities.nativeZeroXcodeReady {
                return selection(.nativePersonalTeam, preference, capabilities, zeroXcode: true)
            }
            if capabilities.xcodeInvisibleReady {
                return selection(.xcodeInvisible, preference, capabilities, zeroXcode: false)
            }
            return unavailable(
                preference,
                capabilities,
                zeroXcode: !capabilities.xcodePresent,
                code: "CONSUMER_AUTHORIZATION_BACKEND_UNAVAILABLE"
            )
        case .nativePersonalTeam:
            guard capabilities.nativeZeroXcodeReady else {
                return unavailable(
                    preference,
                    capabilities,
                    zeroXcode: true,
                    code: "NATIVE_PERSONAL_TEAM_NOT_QUALIFIED"
                )
            }
            return selection(.nativePersonalTeam, preference, capabilities, zeroXcode: true)
        case .xcodeInvisible:
            guard capabilities.xcodeInvisibleReady else {
                return unavailable(
                    preference,
                    capabilities,
                    zeroXcode: false,
                    code: capabilities.xcodePresent
                        ? "PATH_A_BLOCKED_AT_INITIAL_ACCOUNT_AUTH"
                        : "XCODE_INVISIBLE_UNAVAILABLE"
                )
            }
            return selection(.xcodeInvisible, preference, capabilities, zeroXcode: false)
        case .zeroXcode:
            guard capabilities.nativeZeroXcodeReady else {
                return unavailable(
                    preference,
                    capabilities,
                    zeroXcode: true,
                    code: "ZERO_XCODE_BACKEND_NOT_QUALIFIED"
                )
            }
            return selection(.nativePersonalTeam, preference, capabilities, zeroXcode: true)
        case .xcodeFallback:
            guard capabilities.xcodePresent else {
                return unavailable(
                    preference,
                    capabilities,
                    zeroXcode: false,
                    code: "XCODE_FALLBACK_UNAVAILABLE"
                )
            }
            return selection(.xcodeFallback, preference, capabilities, zeroXcode: false)
        }
    }

    private static func selection(
        _ backend: ConsumerProvisioningBackendIdentifier,
        _ preference: ConsumerProvisioningBackendPreference,
        _ capabilities: ConsumerProvisioningCapabilities,
        zeroXcode: Bool
    ) -> ConsumerProvisioningBackendSelection {
        ConsumerProvisioningBackendSelection(
            preference: preference,
            backend: backend,
            xcodePresent: capabilities.xcodePresent,
            zeroXcodeMode: zeroXcode,
            ready: true
        )
    }

    private static func unavailable(
        _ preference: ConsumerProvisioningBackendPreference,
        _ capabilities: ConsumerProvisioningCapabilities,
        zeroXcode: Bool,
        code: String
    ) -> ConsumerProvisioningBackendSelection {
        ConsumerProvisioningBackendSelection(
            preference: preference,
            backend: nil,
            xcodePresent: capabilities.xcodePresent,
            zeroXcodeMode: zeroXcode,
            ready: false,
            failureCode: code
        )
    }
}

public enum ZeroXcodeCapabilityPolicy {
    /// Source-backed classification as of 2026-09-07. Paid-team provisioning
    /// uses App Store Connect API keys, not Apple Account passwords.
    public static let appleOperations: [AppleProvisioningCapability] = [
        .init(operation: .authenticateAppleAccount, paidTeam: .documentedSupported, freePersonalTeam: .undocumentedButObserved,
              detail: "Apple documents Personal Team setup through Xcode; current third-party tools observe private GrandSlam/SRP authentication."),
        .init(operation: .discoverPersonalTeam, paidTeam: .documentedSupported, freePersonalTeam: .undocumentedButObserved,
              detail: "No documented Personal Team API exists outside Xcode; private Developer Services listTeams is observed."),
        .init(operation: .createOrReuseCertificate, paidTeam: .documentedSupported, freePersonalTeam: .undocumentedButObserved,
              detail: "Private Developer Services certificate listing and CSR submission are observed."),
        .init(operation: .registerDevice, paidTeam: .documentedSupported, freePersonalTeam: .undocumentedButObserved,
              detail: "Private Developer Services device listing and registration are observed."),
        .init(operation: .registerBundleIdentifier, paidTeam: .documentedSupported, freePersonalTeam: .undocumentedButObserved,
              detail: "Private Developer Services App ID listing and registration are observed."),
        .init(operation: .issueProvisioningProfile, paidTeam: .documentedSupported, freePersonalTeam: .undocumentedButObserved,
              detail: "Private Developer Services provisioning-profile issuance is observed."),
        .init(operation: .renewProvisioningProfile, paidTeam: .documentedSupported, freePersonalTeam: .undocumentedButObserved,
              detail: "Seven-day renewal repeats the same private provisioning flow."),
    ]

    public static func currentCapabilities(
        resourcesURL: URL,
        fileManager: FileManager = .default
    ) -> ConsumerProvisioningCapabilities {
        let bridge = resourcesURL
            .appendingPathComponent("BundledTools", isDirectory: true)
            .appendingPathComponent("IOSSimIdeviceHost")
        return ConsumerProvisioningCapabilities(
            bundledDeviceBridgeReady: fileManager.isExecutableFile(atPath: bridge.path),
            nativeAppleAuthenticationReady: false,
            nativePersonalTeamProvisioningReady: false,
            directSigningReady: false,
            xcodePresent: XcodePresenceDetector.isPresent(fileManager: fileManager)
        )
    }
}

public enum XcodePresenceDetector {
    public static let knownApplicationPaths = [
        "/Applications/Xcode.app",
        "/Applications/Xcode-beta.app"
    ]

    /// Pure filesystem inspection. It never invokes xcode-select, xcrun, or
    /// searches arbitrary volumes, so ZERO_XCODE cannot silently discover and
    /// use another Xcode installation.
    public static func isPresent(fileManager: FileManager = .default) -> Bool {
        isPresent { fileManager.fileExists(atPath: $0) }
    }

    public static func isPresent(fileExists: (String) -> Bool) -> Bool {
        knownApplicationPaths.contains(where: fileExists)
    }
}
