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
}

public enum AutomaticPairingInboxError: Error, Equatable, Sendable {
    case malformedEnvelope
    case nonceMismatch
    case decryptionFailed
    case invalidPairing
    case deviceBindingMismatch
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
              envelope.schemaVersion == 1,
              envelope.deviceUDID == expectedDeviceUDID,
              envelope.teamIdentifier == expectedTeamIdentifier else { throw AutomaticPairingInboxError.malformedEnvelope }
        guard envelope.nonce == bootstrap.nonce else { throw AutomaticPairingInboxError.nonceMismatch }
        let pairingData: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
            pairingData = try AES.GCM.open(box, using: SymmetricKey(data: bootstrap.importKey))
        } catch { throw AutomaticPairingInboxError.decryptionFailed }
        let summary: RPPairingSummary
        do { summary = try store.importPairingData(pairingData) }
        catch { throw AutomaticPairingInboxError.invalidPairing }
        _ = summary
        let plist = try PropertyListSerialization.propertyList(from: pairingData, options: [], format: nil) as? [String: Any]
        let publicKey = plist?["public_key"] as? Data
        guard let publicKey, publicKey.count == 32, let identifier = plist?["identifier"] as? String, !identifier.isEmpty else { throw AutomaticPairingInboxError.invalidPairing }
        let fingerprint = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return AutomaticPairingReceipt(schemaVersion: 1, deviceUDID: expectedDeviceUDID,
            teamIdentifier: expectedTeamIdentifier, nonce: envelope.nonce, status: "stored",
            identifier: identifier, publicKeyFingerprint: fingerprint, timestamp: .now)
    }
}

public struct RemotePairingBootstrap: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nonce: String
    public let importKey: Data
    public init(schemaVersion: Int = 1, nonce: String, importKey: Data) {
        self.schemaVersion = schemaVersion; self.nonce = nonce; self.importKey = importKey
    }
}
