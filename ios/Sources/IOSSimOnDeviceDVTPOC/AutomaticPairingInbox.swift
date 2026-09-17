import CryptoKit
import Foundation

/// Phone-side one-time inbox for the Mac-created RemotePairing envelope. The
/// inbox is app-private and is never exposed as a Finder/Files workflow.
public struct AutomaticPairingEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let nonce: String
    public let sealedPayload: Data
    public let requestID: String?
    public let pairingGeneration: UInt64?
    public let releaseIdentity: String?

    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                nonce: String, sealedPayload: Data, requestID: String? = nil,
                pairingGeneration: UInt64? = nil, releaseIdentity: String? = nil) {
        self.schemaVersion = schemaVersion
        self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier
        self.nonce = nonce
        self.sealedPayload = sealedPayload
        self.requestID = requestID; self.pairingGeneration = pairingGeneration
        self.releaseIdentity = releaseIdentity
    }
}

public struct AutomaticPairingBootstrapRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let appBundleIdentifier: String
    public let requestID: String
    public let createdAt: Date
    public let pairingGeneration: UInt64?
    public let releaseIdentity: String?

    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                appBundleIdentifier: String, requestID: String, createdAt: Date,
                pairingGeneration: UInt64? = nil, releaseIdentity: String? = nil) {
        self.schemaVersion = schemaVersion
        self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier
        self.appBundleIdentifier = appBundleIdentifier
        self.requestID = requestID
        self.createdAt = createdAt
        self.pairingGeneration = pairingGeneration; self.releaseIdentity = releaseIdentity
    }
}

public struct AutomaticPairingReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let nonce: String
    public let status: String
    public let identifier: String
    public let publicKeyFingerprint: String
    public let timestamp: Date
    public let requestID: String?
    public let pairingGeneration: UInt64?
    public let releaseIdentity: String?

    public init(schemaVersion: Int = 2, deviceUDID: String, teamIdentifier: String,
                nonce: String, status: String, identifier: String,
                publicKeyFingerprint: String, timestamp: Date,
                requestID: String? = nil, pairingGeneration: UInt64? = nil,
                releaseIdentity: String? = nil) {
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.nonce = nonce; self.status = status
        self.identifier = identifier; self.publicKeyFingerprint = publicKeyFingerprint
        self.timestamp = timestamp; self.requestID = requestID
        self.pairingGeneration = pairingGeneration; self.releaseIdentity = releaseIdentity
    }
}

public struct AutomaticPairingPossessionChallenge: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let requestID: String
    public let pairingGeneration: UInt64
    public let releaseIdentity: String
    public let nonce: String
    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                requestID: String, pairingGeneration: UInt64, releaseIdentity: String,
                nonce: String) {
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.requestID = requestID
        self.pairingGeneration = pairingGeneration; self.releaseIdentity = releaseIdentity
        self.nonce = nonce
    }
}

public struct AutomaticPairingPossessionResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let requestID: String
    public let pairingGeneration: UInt64
    public let releaseIdentity: String
    public let nonce: String
    public let proof: String
}

public struct AutomaticPairingPromotionRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let requestID: String
    public let pairingGeneration: UInt64
    public let releaseIdentity: String
    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                requestID: String, pairingGeneration: UInt64, releaseIdentity: String) {
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.requestID = requestID
        self.pairingGeneration = pairingGeneration; self.releaseIdentity = releaseIdentity
    }
}

public enum AutomaticPairingInboxError: Error, Equatable, Sendable {
    case malformedEnvelope
    case nonceMismatch
    case decryptionFailed
    case invalidPairing
    case deviceBindingMismatch
    case requestExpired
    case appBindingMismatch
    case unsafeInbox
}

/// Reconciles only the one-time setup inbox. It never opens LocalDevVPN, RSD,
/// TestManager, XCTest, or location services.
public struct AutomaticPairingInboxController {
    public static let directory = "IOSSim/SetupInbox"
    public static let requestFile = "remote-pairing.request"
    public static let bootstrapFile = "remote-pairing.bootstrap"
    public static let envelopeFile = "remote-pairing.envelope"
    public static let receiptFile = "remote-pairing.receipt"
    public static let challengeFile = "remote-pairing.challenge"
    public static let challengeResponseFile = "remote-pairing.challenge-response"
    public static let promotionFile = "remote-pairing.promote"

    private let fileManager: FileManager
    private let store: any RPPairingStore
    private let applicationSupportDirectory: URL?

    public init(
        fileManager: FileManager = .default,
        store: any RPPairingStore = KeychainRPPairingStore(),
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.store = store
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    @discardableResult
    public func reconcile(
        now: Date = .now,
        appBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> AutomaticPairingReceipt? {
        let inbox = try inboxURL()
        let requestURL = inbox.appendingPathComponent(Self.requestFile)
        guard fileManager.fileExists(atPath: requestURL.path) else { return nil }
        let requestData = try Data(contentsOf: requestURL)
        let request = try JSONDecoder().decode(AutomaticPairingBootstrapRequest.self, from: requestData)
        guard request.schemaVersion == 2,
              let generation = request.pairingGeneration, generation > 0,
              let releaseIdentity = request.releaseIdentity, !releaseIdentity.isEmpty else {
            throw AutomaticPairingInboxError.malformedEnvelope
        }
        guard now.timeIntervalSince(request.createdAt) >= -60,
              now.timeIntervalSince(request.createdAt) <= 10 * 60 else {
            throw AutomaticPairingInboxError.requestExpired
        }
        guard request.appBundleIdentifier == appBundleIdentifier else {
            throw AutomaticPairingInboxError.appBindingMismatch
        }

        let bootstrapURL = inbox.appendingPathComponent(Self.bootstrapFile)
        let envelopeURL = inbox.appendingPathComponent(Self.envelopeFile)
        let bootstrap: RemotePairingBootstrap
        if let data = try? Data(contentsOf: bootstrapURL),
           let existing = try? JSONDecoder().decode(RemotePairingBootstrap.self, from: data),
           existing.requestID == request.requestID,
           existing.pairingGeneration == generation,
           existing.releaseIdentity == releaseIdentity {
            bootstrap = existing
        } else {
            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            bootstrap = RemotePairingBootstrap(
                nonce: UUID().uuidString,
                importKey: keyData,
                requestID: request.requestID,
                pairingGeneration: generation,
                releaseIdentity: releaseIdentity
            )
            try writeProtected(try JSONEncoder().encode(bootstrap), to: bootstrapURL)
        }

        let processor = AutomaticPairingInboxProcessor()
        let promotionURL = inbox.appendingPathComponent(Self.promotionFile)
        if fileManager.fileExists(atPath: promotionURL.path) {
            let receipt = try processor.promote(
                requestData: Data(contentsOf: promotionURL),
                bootstrap: bootstrap,
                expectedDeviceUDID: request.deviceUDID,
                expectedTeamIdentifier: request.teamIdentifier,
                store: store
            )
            try writeProtected(try JSONEncoder().encode(receipt), to: inbox.appendingPathComponent(Self.receiptFile))
            for url in [promotionURL, bootstrapURL, requestURL,
                        inbox.appendingPathComponent(Self.challengeResponseFile)] {
                try? fileManager.removeItem(at: url)
            }
            return receipt
        }

        let challengeURL = inbox.appendingPathComponent(Self.challengeFile)
        if fileManager.fileExists(atPath: challengeURL.path) {
            let response = try processor.respond(
                challengeData: Data(contentsOf: challengeURL),
                expectedDeviceUDID: request.deviceUDID,
                expectedTeamIdentifier: request.teamIdentifier,
                store: store
            )
            try writeProtected(
                try JSONEncoder().encode(response),
                to: inbox.appendingPathComponent(Self.challengeResponseFile)
            )
            try? fileManager.removeItem(at: challengeURL)
            return nil
        }

        guard fileManager.fileExists(atPath: envelopeURL.path) else { return nil }
        let receipt = try processor.process(
            envelopeData: Data(contentsOf: envelopeURL),
            bootstrap: bootstrap,
            expectedDeviceUDID: request.deviceUDID,
            expectedTeamIdentifier: request.teamIdentifier,
            store: store
        )
        try writeProtected(try JSONEncoder().encode(receipt), to: inbox.appendingPathComponent(Self.receiptFile))
        try? fileManager.removeItem(at: envelopeURL)
        return receipt
    }

    private func inboxURL() throws -> URL {
        guard let support = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AutomaticPairingInboxError.unsafeInbox
        }
        let inbox = support.appendingPathComponent(Self.directory, isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        #if os(macOS)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #else
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #endif
    }
}

public struct AutomaticPairingInboxProcessor: Sendable {
    public init() {}

    @discardableResult
    public func process(
        envelopeData: Data,
        bootstrap: RemotePairingBootstrap,
        expectedDeviceUDID: String,
        expectedTeamIdentifier: String,
        store: any RPPairingStore
    ) throws -> AutomaticPairingReceipt {
        guard let envelope = try? JSONDecoder().decode(AutomaticPairingEnvelope.self, from: envelopeData),
              envelope.schemaVersion == 2,
              envelope.deviceUDID == expectedDeviceUDID,
              envelope.teamIdentifier == expectedTeamIdentifier,
              envelope.requestID == bootstrap.requestID,
              envelope.pairingGeneration == bootstrap.pairingGeneration,
              envelope.releaseIdentity == bootstrap.releaseIdentity else {
            throw AutomaticPairingInboxError.malformedEnvelope
        }
        guard envelope.nonce == bootstrap.nonce else { throw AutomaticPairingInboxError.nonceMismatch }
        let pairingData: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
            pairingData = try AES.GCM.open(box, using: SymmetricKey(data: bootstrap.importKey))
        } catch { throw AutomaticPairingInboxError.decryptionFailed }
        let summary: RPPairingSummary
        do { summary = try store.importCandidatePairingData(pairingData) }
        catch { throw AutomaticPairingInboxError.invalidPairing }
        _ = summary
        let plist = try PropertyListSerialization.propertyList(from: pairingData, options: [], format: nil) as? [String: Any]
        let publicKey = plist?["public_key"] as? Data
        guard let publicKey, publicKey.count == 32, let identifier = plist?["identifier"] as? String, !identifier.isEmpty else { throw AutomaticPairingInboxError.invalidPairing }
        let fingerprint = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return AutomaticPairingReceipt(deviceUDID: expectedDeviceUDID,
            teamIdentifier: expectedTeamIdentifier, nonce: envelope.nonce, status: "candidate-stored",
            identifier: identifier, publicKeyFingerprint: fingerprint, timestamp: .now,
            requestID: envelope.requestID, pairingGeneration: envelope.pairingGeneration,
            releaseIdentity: envelope.releaseIdentity)
    }

    public func respond(
        challengeData: Data,
        expectedDeviceUDID: String,
        expectedTeamIdentifier: String,
        store: any RPPairingStore
    ) throws -> AutomaticPairingPossessionResponse {
        guard let challenge = try? JSONDecoder().decode(AutomaticPairingPossessionChallenge.self, from: challengeData),
              challenge.schemaVersion == 1,
              challenge.deviceUDID == expectedDeviceUDID,
              challenge.teamIdentifier == expectedTeamIdentifier,
              !challenge.requestID.isEmpty, challenge.pairingGeneration > 0,
              !challenge.releaseIdentity.isEmpty, !challenge.nonce.isEmpty else {
            throw AutomaticPairingInboxError.deviceBindingMismatch
        }
        let pairingData = try store.loadCandidatePairingData()
        let (identifier, fingerprint) = try pairingIdentity(pairingData)
        let message = [
            challenge.deviceUDID, challenge.teamIdentifier, challenge.requestID,
            String(challenge.pairingGeneration), challenge.releaseIdentity, challenge.nonce,
            identifier, fingerprint,
        ].joined(separator: "\n")
        let key = SymmetricKey(data: Data(SHA256.hash(data: pairingData)))
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
            .map { String(format: "%02x", $0) }.joined()
        return AutomaticPairingPossessionResponse(
            schemaVersion: 1,
            deviceUDID: challenge.deviceUDID,
            teamIdentifier: challenge.teamIdentifier,
            requestID: challenge.requestID,
            pairingGeneration: challenge.pairingGeneration,
            releaseIdentity: challenge.releaseIdentity,
            nonce: challenge.nonce,
            proof: proof
        )
    }

    public func promote(
        requestData: Data,
        bootstrap: RemotePairingBootstrap,
        expectedDeviceUDID: String,
        expectedTeamIdentifier: String,
        store: any RPPairingStore
    ) throws -> AutomaticPairingReceipt {
        guard let request = try? JSONDecoder().decode(AutomaticPairingPromotionRequest.self, from: requestData),
              request.schemaVersion == 1,
              request.deviceUDID == expectedDeviceUDID,
              request.teamIdentifier == expectedTeamIdentifier,
              request.requestID == bootstrap.requestID,
              request.pairingGeneration == bootstrap.pairingGeneration,
              request.releaseIdentity == bootstrap.releaseIdentity else {
            throw AutomaticPairingInboxError.deviceBindingMismatch
        }
        let pairingData = try store.loadCandidatePairingData()
        let (identifier, fingerprint) = try pairingIdentity(pairingData)
        try store.promoteCandidatePairingData()
        return AutomaticPairingReceipt(
            deviceUDID: expectedDeviceUDID,
            teamIdentifier: expectedTeamIdentifier,
            nonce: bootstrap.nonce,
            status: "operational",
            identifier: identifier,
            publicKeyFingerprint: fingerprint,
            timestamp: .now,
            requestID: request.requestID,
            pairingGeneration: request.pairingGeneration,
            releaseIdentity: request.releaseIdentity
        )
    }

    private func pairingIdentity(_ pairingData: Data) throws -> (String, String) {
        guard let plist = try? PropertyListSerialization.propertyList(from: pairingData, options: [], format: nil) as? [String: Any],
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let identifier = plist["identifier"] as? String, !identifier.isEmpty else {
            throw AutomaticPairingInboxError.invalidPairing
        }
        let fingerprint = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return (identifier, fingerprint)
    }
}

public struct RemotePairingBootstrap: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nonce: String
    public let importKey: Data
    public let requestID: String?
    public let pairingGeneration: UInt64?
    public let releaseIdentity: String?
    public init(schemaVersion: Int = 2, nonce: String, importKey: Data,
                requestID: String? = nil, pairingGeneration: UInt64? = nil,
                releaseIdentity: String? = nil) {
        self.schemaVersion = schemaVersion; self.nonce = nonce; self.importKey = importKey
        self.requestID = requestID; self.pairingGeneration = pairingGeneration
        self.releaseIdentity = releaseIdentity
    }
}
