import CryptoKit
import Foundation

/// Setup-completion evidence written by the user's own Run Setup tap.
///
/// Veya writes `run-setup.request` into this app's container (House Arrest, the
/// same SetupInbox the automatic pairing and LocalDevVPN steps already use) and
/// then waits. Nothing here starts a setup run: only the Run Setup button does,
/// and this inbox records what that real run achieved. A failed or partial run
/// is recorded as a failure receipt and can never read as success.
public struct RunSetupRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Veya polls for a few minutes; a request outlives that so a late tap still answers it.
    public static let lifetime: TimeInterval = 15 * 60

    public let schemaVersion: Int
    public let requestID: String
    public let deviceUDID: String
    public let teamIdentifier: String
    public let releaseIdentity: String
    public let appBundleIdentifier: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: String = UUID().uuidString,
        deviceUDID: String,
        teamIdentifier: String,
        releaseIdentity: String,
        appBundleIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier
        self.releaseIdentity = releaseIdentity
        self.appBundleIdentifier = appBundleIdentifier
        self.createdAt = createdAt
    }
}

/// What the real Run Setup path reached, stage by stage. Veya requires every
/// stage plus the pairing identity it delivered; `errorCode` keeps the phone's
/// own POCError so the Mac shows the real failure instead of a generic one.
public struct RunSetupReceipt: Codable, Equatable, Sendable {
    /// 2: the session proof is a read-only dtservicehub round-trip. Version 1 proved it by
    /// simulating a coordinate and clearing it, which moved the user's location during setup.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let requestID: String
    public let deviceUDIDHash: String
    public let teamIdentifier: String
    public let releaseIdentity: String
    public let appBundleIdentifier: String
    /// Identity of the RPPairing record this app actually used, never the key material.
    public let pairingIdentifier: String
    public let pairingPublicKeyFingerprint: String
    public let pairingReady: Bool
    public let localDevVPNReady: Bool
    public let endpointReachable: Bool
    /// The tunnel, RSD, dtservicehub and LocationSimulation channel all came up.
    public let sessionEstablished: Bool
    /// A real request reached dtservicehub on this session and the answer came back. Read-only:
    /// setup never changes the device's location.
    public let sessionProbed: Bool
    public let errorCode: String?
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: String,
        deviceUDIDHash: String,
        teamIdentifier: String,
        releaseIdentity: String,
        appBundleIdentifier: String,
        pairingIdentifier: String,
        pairingPublicKeyFingerprint: String,
        pairingReady: Bool,
        localDevVPNReady: Bool,
        endpointReachable: Bool,
        sessionEstablished: Bool,
        sessionProbed: Bool,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        completedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.deviceUDIDHash = deviceUDIDHash
        self.teamIdentifier = teamIdentifier
        self.releaseIdentity = releaseIdentity
        self.appBundleIdentifier = appBundleIdentifier
        self.pairingIdentifier = pairingIdentifier
        self.pairingPublicKeyFingerprint = pairingPublicKeyFingerprint
        self.pairingReady = pairingReady
        self.localDevVPNReady = localDevVPNReady
        self.endpointReachable = endpointReachable
        self.sessionEstablished = sessionEstablished
        self.sessionProbed = sessionProbed
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }

    /// Every stage of the real run, with no reported error. Veya additionally
    /// binds this to its own request and pairing record.
    public var succeeded: Bool {
        schemaVersion == Self.currentSchemaVersion
            && deviceUDIDHash.count == 64
            && !pairingIdentifier.isEmpty
            && pairingPublicKeyFingerprint.count == 64
            && pairingReady && localDevVPNReady && endpointReachable
            && sessionEstablished && sessionProbed
            && errorCode == nil
    }

    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RunSetupInboxError: Error, Equatable, Sendable {
    case malformedRequest
    case requestExpired
    case appBindingMismatch
    case pairingUnavailable
    case unsafeInbox
}

/// Reads the pending request and records the result of a real Run Setup run.
/// It never opens LocalDevVPN, RSD, TestManager, XCTest or location services.
public struct RunSetupInbox: @unchecked Sendable {
    public static let requestFile = "run-setup.request"
    public static let receiptFile = "run-setup.receipt"

    private let fileManager: FileManager
    private let applicationSupportDirectory: URL?
    private let store: any RPPairingStore
    private let now: @Sendable () -> Date

    public init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        store: any RPPairingStore = KeychainRPPairingStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
        self.store = store
        self.now = now
    }

    /// The request Veya is waiting on, or nil when it is absent, expired, or
    /// addressed to another app. Callers poll this to show the Run Setup prompt.
    public func pendingRequest(
        appBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> RunSetupRequest? {
        let url = try inboxURL().appendingPathComponent(Self.requestFile)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let request = try? decoder.decode(RunSetupRequest.self, from: Data(contentsOf: url)),
              request.schemaVersion == RunSetupRequest.currentSchemaVersion,
              UUID(uuidString: request.requestID) != nil,
              !request.deviceUDID.isEmpty, !request.teamIdentifier.isEmpty,
              !request.releaseIdentity.isEmpty else {
            throw RunSetupInboxError.malformedRequest
        }
        guard request.appBundleIdentifier == appBundleIdentifier else {
            throw RunSetupInboxError.appBindingMismatch
        }
        let age = now().timeIntervalSince(request.createdAt)
        guard age >= -60, age <= RunSetupRequest.lifetime else {
            throw RunSetupInboxError.requestExpired
        }
        return request
    }

    /// Records a completed run. A success receipt retires the request so ordinary
    /// later Run Setup taps do not repeat the proof; a failure keeps it pending so
    /// the user can fix the cause and tap again without Veya reissuing anything.
    @discardableResult
    public func record(
        _ outcome: RunSetupOutcome,
        for request: RunSetupRequest,
        appBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> RunSetupReceipt {
        let identity = try pairingIdentity(required: outcome.pairingReady)
        let receipt = RunSetupReceipt(
            requestID: request.requestID,
            deviceUDIDHash: RunSetupReceipt.hash(request.deviceUDID),
            teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity,
            appBundleIdentifier: appBundleIdentifier ?? "",
            pairingIdentifier: identity.identifier,
            pairingPublicKeyFingerprint: identity.fingerprint,
            pairingReady: outcome.pairingReady,
            localDevVPNReady: outcome.localDevVPNReady,
            endpointReachable: outcome.endpointReachable,
            sessionEstablished: outcome.sessionEstablished,
            sessionProbed: outcome.sessionProbed,
            errorCode: outcome.errorCode,
            errorMessage: outcome.errorMessage.map(Self.sanitize),
            completedAt: now()
        )
        let inbox = try inboxURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try writeProtected(try encoder.encode(receipt), to: inbox.appendingPathComponent(Self.receiptFile))
        if receipt.succeeded {
            try? fileManager.removeItem(at: inbox.appendingPathComponent(Self.requestFile))
        }
        return receipt
    }

    /// Identity of the stored pairing. A run that never reached a usable pairing
    /// still needs a receipt, so the fields are empty rather than fatal there.
    private func pairingIdentity(required: Bool) throws -> (identifier: String, fingerprint: String) {
        guard let data = try? store.loadPairingData(),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let identifier = plist["identifier"] as? String, !identifier.isEmpty else {
            if required { throw RunSetupInboxError.pairingUnavailable }
            return ("", "")
        }
        let fingerprint = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return (identifier, fingerprint)
    }

    private func inboxURL() throws -> URL {
        guard let support = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RunSetupInboxError.unsafeInbox
        }
        let inbox = support.appendingPathComponent(AutomaticPairingInboxController.directory, isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// The receipt carries no secrets and Veya must be able to read it over AFC
    /// while the screen is locked, so it is protected only until first unlock.
    private func writeProtected(_ data: Data, to url: URL) throws {
        #if os(macOS)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #else
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    static func sanitize(_ message: String) -> String {
        let cleaned = message.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        return String(String(cleaned).prefix(300))
    }
}

/// Stage results of one real Run Setup run, in the order the run reaches them.
public struct RunSetupOutcome: Equatable, Sendable {
    public var pairingReady = false
    public var localDevVPNReady = false
    public var endpointReachable = false
    public var sessionEstablished = false
    public var sessionProbed = false
    public var errorCode: String?
    public var errorMessage: String?

    public init() {}

    public mutating func fail(code: String, message: String) {
        errorCode = code
        errorMessage = message
    }
}
