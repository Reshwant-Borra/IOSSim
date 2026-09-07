import Foundation

/// Product-level provisioning selection. This is intentionally separate from
/// `DeviceProvisioningBackend`, which only owns USB device operations.
public enum ConsumerProvisioningBackendPreference: String, Codable, CaseIterable, Sendable {
    case automatic = "AUTO"
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
    case nativeZeroXcode = "NATIVE_ZERO_XCODE"
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

    public init(
        bundledDeviceBridgeReady: Bool,
        nativeAppleAuthenticationReady: Bool,
        nativePersonalTeamProvisioningReady: Bool,
        directSigningReady: Bool,
        xcodePresent: Bool
    ) {
        self.bundledDeviceBridgeReady = bundledDeviceBridgeReady
        self.nativeAppleAuthenticationReady = nativeAppleAuthenticationReady
        self.nativePersonalTeamProvisioningReady = nativePersonalTeamProvisioningReady
        self.directSigningReady = directSigningReady
        self.xcodePresent = xcodePresent
    }

    public var nativeZeroXcodeReady: Bool {
        bundledDeviceBridgeReady
            && nativeAppleAuthenticationReady
            && nativePersonalTeamProvisioningReady
            && directSigningReady
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
    /// AUTO prefers the native path. Until all native gates are qualified it
    /// reports the surviving Xcode path honestly as XCODE_FALLBACK.
    public static func select(
        preference: ConsumerProvisioningBackendPreference,
        capabilities: ConsumerProvisioningCapabilities
    ) -> ConsumerProvisioningBackendSelection {
        switch preference {
        case .automatic:
            if capabilities.nativeZeroXcodeReady {
                return selection(.nativeZeroXcode, preference, capabilities, zeroXcode: true)
            }
            if capabilities.xcodePresent {
                return selection(.xcodeFallback, preference, capabilities, zeroXcode: false)
            }
            return unavailable(
                preference,
                capabilities,
                zeroXcode: true,
                code: "ZERO_XCODE_PERSONAL_TEAM_BLOCKED"
            )
        case .zeroXcode:
            guard capabilities.nativeZeroXcodeReady else {
                return unavailable(
                    preference,
                    capabilities,
                    zeroXcode: true,
                    code: "ZERO_XCODE_BACKEND_NOT_QUALIFIED"
                )
            }
            return selection(.nativeZeroXcode, preference, capabilities, zeroXcode: true)
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
        .init(operation: .authenticateAppleAccount, paidTeam: .documentedSupported, freePersonalTeam: .requiresXcode,
              detail: "Paid teams can use App Store Connect API keys. Apple documents Personal Team setup through Xcode only."),
        .init(operation: .discoverPersonalTeam, paidTeam: .documentedSupported, freePersonalTeam: .requiresXcode,
              detail: "No documented Personal Team discovery API is available outside Xcode."),
        .init(operation: .createOrReuseCertificate, paidTeam: .documentedSupported, freePersonalTeam: .requiresXcode,
              detail: "Certificate APIs are documented for Developer Program teams; Personal Team assets are Xcode-managed."),
        .init(operation: .registerDevice, paidTeam: .documentedSupported, freePersonalTeam: .requiresXcode,
              detail: "Device APIs are documented for Developer Program teams; free-device registration is Xcode-managed."),
        .init(operation: .registerBundleIdentifier, paidTeam: .documentedSupported, freePersonalTeam: .requiresXcode,
              detail: "Bundle ID APIs are documented for Developer Program teams; free App IDs are Xcode-managed."),
        .init(operation: .issueProvisioningProfile, paidTeam: .documentedSupported, freePersonalTeam: .requiresXcode,
              detail: "Profile APIs are documented for Developer Program teams; free profiles are Xcode-managed."),
        .init(operation: .renewProvisioningProfile, paidTeam: .documentedSupported, freePersonalTeam: .requiresXcode,
              detail: "Free seven-day reprovisioning is documented as an Xcode workflow."),
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
