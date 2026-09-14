import CryptoKit
import Foundation
import Security

/// Metadata is safe to journal; `pairingData` is deliberately kept out of
/// this type and is stored only in the Keychain record below.
public struct RemotePairingRecordMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let identifier: String
    public let publicKeyFingerprint: String
    public let createdAt: Date
    public let lastValidatedAt: Date?

    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                identifier: String, publicKeyFingerprint: String,
                createdAt: Date = .now, lastValidatedAt: Date? = nil) {
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.identifier = identifier
        self.publicKeyFingerprint = publicKeyFingerprint; self.createdAt = createdAt
        self.lastValidatedAt = lastValidatedAt
    }
}

public struct RemotePairingRecord: Codable, Equatable, Sendable {
    public let metadata: RemotePairingRecordMetadata
    public let pairingData: Data
    public init(metadata: RemotePairingRecordMetadata, pairingData: Data) {
        self.metadata = metadata; self.pairingData = pairingData
    }
}

public enum RemotePairingLifecycleState: String, Codable, Equatable, Sendable {
    case missing, creating, stored, delivering, awaitingReceipt, validating, operational
    case repairable, failed
}

public enum RemotePairingFailure: String, Error, Codable, Equatable, Sendable {
    case invalidRecord, wrongDevice, wrongTeam, deviceTrustRequired, deviceLocked
    case deliveryFailed, receiptMissing, receiptInvalid, receiptRejected
    case operationalProofFailed, nativeBridgeUnavailable, unsafePath
}

public struct RemotePairingMaterial: Sendable {
    public let pairingData: Data
    public let identifier: String
    public let publicKeyFingerprint: String

    public init(pairingData: Data, identifier: String, publicKeyFingerprint: String) {
        self.pairingData = pairingData; self.identifier = identifier
        self.publicKeyFingerprint = publicKeyFingerprint
    }
}

public struct RemotePairingBootstrapSession: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nonce: String
    public let importKey: Data
    public init(schemaVersion: Int = 1, nonce: String = UUID().uuidString, importKey: Data) {
        self.schemaVersion = schemaVersion; self.nonce = nonce; self.importKey = importKey
    }
}

public struct RemotePairingEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let nonce: String
    public let sealedPayload: Data
    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                nonce: String, sealedPayload: Data) {
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.nonce = nonce; self.sealedPayload = sealedPayload
    }

    public func decrypt(using session: RemotePairingBootstrapSession) throws -> Data {
        guard session.nonce == nonce else { throw RemotePairingFailure.receiptInvalid }
        let box = try AES.GCM.SealedBox(combined: sealedPayload)
        return try AES.GCM.open(box, using: SymmetricKey(data: session.importKey))
    }
}

public struct RemotePairingReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let nonce: String
    public let status: String
    public let identifier: String
    public let publicKeyFingerprint: String
    public let timestamp: Date
}

public protocol RemotePairingStore: Sendable {
    func load(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord?
    func save(_ record: RemotePairingRecord) throws
    func delete(deviceUDID: String, teamIdentifier: String) throws
}

/// A dedicated generic-password item per physical phone/team. Pairing bytes
/// never enter setup journals, logs, or support bundles.
public final class KeychainRemotePairingStore: RemotePairingStore, @unchecked Sendable {
    private let service: String
    private let accessible: CFString
    public init(service: String = "com.iossim.remote-pairing.v1",
                accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) {
        self.service = service; self.accessible = accessible
    }

    public func load(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord? {
        var query = baseQuery(deviceUDID: deviceUDID, teamIdentifier: teamIdentifier)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw RemotePairingFailure.invalidRecord }
        do { return try JSONDecoder().decode(RemotePairingRecord.self, from: data) }
        catch { throw RemotePairingFailure.invalidRecord }
    }

    public func save(_ record: RemotePairingRecord) throws {
        guard record.metadata.deviceUDID == record.metadata.deviceUDID,
              record.pairingData.count > 0 else { throw RemotePairingFailure.invalidRecord }
        let data = try JSONEncoder().encode(record)
        let query = baseQuery(deviceUDID: record.metadata.deviceUDID, teamIdentifier: record.metadata.teamIdentifier)
        let replacement: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        var status = SecItemUpdate(query as CFDictionary, replacement as CFDictionary)
        if status == errSecItemNotFound {
            var attrs = query; replacement.forEach { attrs[$0.key] = $0.value }
            status = SecItemAdd(attrs as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RemotePairingFailure.invalidRecord }
    }

    public func delete(deviceUDID: String, teamIdentifier: String) throws {
        let status = SecItemDelete(baseQuery(deviceUDID: deviceUDID, teamIdentifier: teamIdentifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemotePairingFailure.invalidRecord }
    }

    private func baseQuery(deviceUDID: String, teamIdentifier: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(teamIdentifier):\(deviceUDID)"]
    }
}

public final class InMemoryRemotePairingStore: RemotePairingStore, @unchecked Sendable {
    private var records: [String: RemotePairingRecord] = [:]
    public init() {}
    public func load(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord? {
        records["\(teamIdentifier):\(deviceUDID)"]
    }
    public func save(_ record: RemotePairingRecord) throws {
        records["\(record.metadata.teamIdentifier):\(record.metadata.deviceUDID)"] = record
    }
    public func delete(deviceUDID: String, teamIdentifier: String) throws { records.removeValue(forKey: "\(teamIdentifier):\(deviceUDID)") }
}

public protocol RemotePairingNativeOperations: Sendable {
    func create(on device: IOSSimDeviceIdentity, hostname: String) async throws -> RemotePairingMaterial
    func validate(_ record: RemotePairingRecord, on device: IOSSimDeviceIdentity, hostname: String) async throws
}

public struct NativeRemotePairingOperations: RemotePairingNativeOperations {
    private let transport: DynamicNativeDeviceTransport
    public init(transport: DynamicNativeDeviceTransport = DynamicNativeDeviceTransport()) { self.transport = transport }
    public func create(on device: IOSSimDeviceIdentity, hostname: String) async throws -> RemotePairingMaterial {
        let data = try transport.createRemotePairing(on: device, hostname: hostname)
        return try Self.material(from: data)
    }
    public func validate(_ record: RemotePairingRecord, on device: IOSSimDeviceIdentity, hostname: String) async throws {
        try transport.validateRemotePairing(on: device, hostname: hostname, pairingData: record.pairingData)
    }
    public static func material(from data: Data) throws -> RemotePairingMaterial {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let identifier = plist["identifier"] as? String, !identifier.isEmpty else {
            throw RemotePairingFailure.invalidRecord
        }
        _ = privateKey // validated, but never exposed in diagnostics
        let fingerprint = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return RemotePairingMaterial(pairingData: data, identifier: identifier, publicKeyFingerprint: fingerprint)
    }
}

public protocol RemotePairingContainerDelivery: Sendable {
    func writeEnvelope(_ envelope: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws
    func readReceipt(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data
}

public struct NativeRemotePairingContainerDelivery: RemotePairingContainerDelivery {
    private let service: any NativeApplicationServicing
    public init(service: any NativeApplicationServicing) { self.service = service }
    public func writeEnvelope(_ envelope: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        try await service.writeContainer(bundleIdentifier: appBundleIdentifier,
            relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.envelope",
            data: envelope, on: device)
    }
    public func readReceipt(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        try await service.readContainer(bundleIdentifier: appBundleIdentifier,
            relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.receipt", on: device)
    }
}

public protocol RemotePairingOperationalProof: Sendable {
    func verify(on device: IOSSimDeviceIdentity, pairing: RemotePairingRecord) async throws
}

public struct AwaitingPhysicalRemotePairingProof: RemotePairingOperationalProof {
    public init() {}
    public func verify(on device: IOSSimDeviceIdentity, pairing: RemotePairingRecord) async throws {
        throw RemotePairingFailure.operationalProofFailed
    }
}

public actor RemotePairingCoordinator {
    public private(set) var state: RemotePairingLifecycleState
    private let store: any RemotePairingStore
    private let native: any RemotePairingNativeOperations
    private let delivery: any RemotePairingContainerDelivery
    private let proof: any RemotePairingOperationalProof

    public init(store: any RemotePairingStore = KeychainRemotePairingStore(),
                native: any RemotePairingNativeOperations = NativeRemotePairingOperations(),
                delivery: any RemotePairingContainerDelivery,
                proof: any RemotePairingOperationalProof = AwaitingPhysicalRemotePairingProof()) {
        self.store = store; self.native = native; self.delivery = delivery; self.proof = proof; self.state = .missing
    }

    public func prepare(device: IOSSimDeviceIdentity, teamIdentifier: String,
                        appBundleIdentifier: String, hostname: String,
                        bootstrap: RemotePairingBootstrapSession,
                        forceRepair: Bool = false) async throws -> RemotePairingRecord {
        let existing = try store.load(deviceUDID: device.udid, teamIdentifier: teamIdentifier)
        var record = existing
        state = existing == nil ? .missing : .stored
        if let existing, !forceRepair {
            state = .validating
            do { try await native.validate(existing, on: device, hostname: hostname) }
            catch { record = nil; state = .repairable }
        }
        if record == nil {
            state = .creating
            let material = try await native.create(on: device, hostname: hostname)
            let metadata = RemotePairingRecordMetadata(deviceUDID: device.udid, teamIdentifier: teamIdentifier,
                identifier: material.identifier, publicKeyFingerprint: material.publicKeyFingerprint)
            record = RemotePairingRecord(metadata: metadata, pairingData: material.pairingData)
            try store.save(record!)
            state = .stored
        }
        guard let record else { throw RemotePairingFailure.invalidRecord }
        let envelope = try Self.makeEnvelope(record: record, bootstrap: bootstrap)
        let encoded = try JSONEncoder().encode(envelope)
        state = .delivering
        try await delivery.writeEnvelope(encoded, to: device, appBundleIdentifier: appBundleIdentifier)
        state = .awaitingReceipt
        let receiptData = try await delivery.readReceipt(from: device, appBundleIdentifier: appBundleIdentifier)
        let receipt = try JSONDecoder().decode(RemotePairingReceipt.self, from: receiptData)
        guard receipt.deviceUDID == device.udid, receipt.teamIdentifier == teamIdentifier,
              receipt.nonce == bootstrap.nonce, receipt.identifier == record.metadata.identifier,
              receipt.publicKeyFingerprint == record.metadata.publicKeyFingerprint else { throw RemotePairingFailure.receiptInvalid }
        guard receipt.status == "stored" else { throw RemotePairingFailure.receiptRejected }
        try await proof.verify(on: device, pairing: record)
        state = .operational
        return record
    }

    public static func makeEnvelope(record: RemotePairingRecord, bootstrap: RemotePairingBootstrapSession) throws -> RemotePairingEnvelope {
        let box = try AES.GCM.seal(record.pairingData, using: SymmetricKey(data: bootstrap.importKey))
        return RemotePairingEnvelope(deviceUDID: record.metadata.deviceUDID, teamIdentifier: record.metadata.teamIdentifier,
            nonce: bootstrap.nonce, sealedPayload: box.combined ?? Data())
    }
}
