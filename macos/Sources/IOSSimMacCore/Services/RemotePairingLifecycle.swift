import CryptoKit
import Foundation
import LocalAuthentication
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
    public let pairingGeneration: UInt64?
    public let releaseIdentity: String?

    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                identifier: String, publicKeyFingerprint: String,
                createdAt: Date = .now, lastValidatedAt: Date? = nil,
                pairingGeneration: UInt64? = nil, releaseIdentity: String? = nil) {
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.identifier = identifier
        self.publicKeyFingerprint = publicKeyFingerprint; self.createdAt = createdAt
        self.lastValidatedAt = lastValidatedAt
        self.pairingGeneration = pairingGeneration
        self.releaseIdentity = releaseIdentity
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
    case missing, creating, candidateStored, delivering, awaitingReceipt, provingPossession
    case provingDeveloperServices, promoting, stored, validating, operational
    case repairable, failed
}

public enum RemotePairingDisposition: String, Codable, Equatable, Sendable {
    case none = "NONE"
    case created = "CREATED"
    case reused = "REUSED"
}

public enum RemotePairingFailure: String, Error, Codable, Equatable, Sendable {
    case invalidRecord, wrongDevice, wrongTeam, deviceTrustRequired, deviceLocked
    case deliveryFailed, receiptMissing, receiptInvalid, receiptRejected
    case bootstrapMissing, bootstrapInvalid, bootstrapExpired, pairingRejected
    case transientTransport, operationalProofFailed, nativeBridgeUnavailable, unsafePath
    /// The fail-closed secure store cannot be used without interaction (or is unavailable in this build).
    case secureStorageUnavailable
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
    public let requestID: String?
    public let pairingGeneration: UInt64?
    public let releaseIdentity: String?
    public init(schemaVersion: Int = 2, nonce: String = UUID().uuidString, importKey: Data,
                requestID: String? = nil, pairingGeneration: UInt64? = nil,
                releaseIdentity: String? = nil) {
        self.schemaVersion = schemaVersion; self.nonce = nonce; self.importKey = importKey
        self.requestID = requestID; self.pairingGeneration = pairingGeneration
        self.releaseIdentity = releaseIdentity
    }
}

public struct RemotePairingBootstrapRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let appBundleIdentifier: String
    public let requestID: String
    public let createdAt: Date
    public let pairingGeneration: UInt64?
    public let releaseIdentity: String?

    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                appBundleIdentifier: String, requestID: String = UUID().uuidString,
                createdAt: Date = .now, pairingGeneration: UInt64? = nil,
                releaseIdentity: String? = nil) {
        self.schemaVersion = schemaVersion
        self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier
        self.appBundleIdentifier = appBundleIdentifier
        self.requestID = requestID
        self.createdAt = createdAt
        self.pairingGeneration = pairingGeneration
        self.releaseIdentity = releaseIdentity
    }
}

public struct RemotePairingEnvelope: Codable, Equatable, Sendable {
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
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.nonce = nonce; self.sealedPayload = sealedPayload
        self.requestID = requestID; self.pairingGeneration = pairingGeneration
        self.releaseIdentity = releaseIdentity
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

public struct RemotePairingPossessionChallenge: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let requestID: String
    public let pairingGeneration: UInt64
    public let releaseIdentity: String
    public let nonce: String
    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                requestID: String, pairingGeneration: UInt64, releaseIdentity: String,
                nonce: String = UUID().uuidString) {
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.requestID = requestID
        self.pairingGeneration = pairingGeneration; self.releaseIdentity = releaseIdentity
        self.nonce = nonce
    }
}

public struct RemotePairingPossessionResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceUDID: String
    public let teamIdentifier: String
    public let requestID: String
    public let pairingGeneration: UInt64
    public let releaseIdentity: String
    public let nonce: String
    public let proof: String
    public init(schemaVersion: Int = 1, deviceUDID: String, teamIdentifier: String,
                requestID: String, pairingGeneration: UInt64, releaseIdentity: String,
                nonce: String, proof: String) {
        self.schemaVersion = schemaVersion; self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier; self.requestID = requestID
        self.pairingGeneration = pairingGeneration; self.releaseIdentity = releaseIdentity
        self.nonce = nonce; self.proof = proof
    }
}

public struct RemotePairingPromotionRequest: Codable, Equatable, Sendable {
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

public protocol RemotePairingStore: Sendable {
    func load(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord?
    func loadCandidate(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord?
    func save(_ record: RemotePairingRecord) throws
    func saveCandidate(_ record: RemotePairingRecord) throws
    func promoteCandidate(deviceUDID: String, teamIdentifier: String) throws
    func delete(deviceUDID: String, teamIdentifier: String) throws
}

/// A dedicated generic-password item per physical phone/team. Pairing bytes
/// never enter setup journals, logs, or support bundles.
public final class KeychainRemotePairingStore: RemotePairingStore, @unchecked Sendable {
    /// Installation V2 service: same fail-closed backend as the signing key store (M4).
    public static let v2Service = "com.veya.remote-pairing.v2"
    private let service: String
    private let accessible: CFString
    /// nil: the Build 1-11 login-Keychain behavior (legacy route only). Otherwise the M4 backend: Data
    /// Protection Keychain without UI, or `.unavailable`, which fails closed and never prompts.
    private let backend: WrappingSecretBackendKind?
    public init(service: String = "com.iossim.remote-pairing.v1",
                accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                backend: WrappingSecretBackendKind? = nil) {
        self.service = service; self.accessible = accessible; self.backend = backend
    }

    /// The Installation V2 store: never shows Keychain UI and never falls back to the login Keychain.
    public static func installationV2(backend: WrappingSecretBackendKind = .forRunningCode()) -> KeychainRemotePairingStore {
        KeychainRemotePairingStore(service: v2Service, backend: backend)
    }

    private func check(_ status: OSStatus) throws {
        if backend != nil, [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement, errSecNotAvailable].contains(status) {
            throw RemotePairingFailure.secureStorageUnavailable
        }
    }

    public func load(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord? {
        try load(deviceUDID: deviceUDID, teamIdentifier: teamIdentifier, candidate: false)
    }

    public func loadCandidate(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord? {
        try load(deviceUDID: deviceUDID, teamIdentifier: teamIdentifier, candidate: true)
    }

    private func load(deviceUDID: String, teamIdentifier: String, candidate: Bool) throws -> RemotePairingRecord? {
        var query = try baseQuery(deviceUDID: deviceUDID, teamIdentifier: teamIdentifier, candidate: candidate)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard status == errSecSuccess, let data = item as? Data else { throw RemotePairingFailure.invalidRecord }
        do { return try JSONDecoder().decode(RemotePairingRecord.self, from: data) }
        catch { throw RemotePairingFailure.invalidRecord }
    }

    public func save(_ record: RemotePairingRecord) throws {
        try save(record, candidate: false)
    }

    public func saveCandidate(_ record: RemotePairingRecord) throws {
        try save(record, candidate: true)
    }

    private func save(_ record: RemotePairingRecord, candidate: Bool) throws {
        guard [1, 2].contains(record.metadata.schemaVersion),
              IOSSimDeviceIdentity.isValidIdentifier(record.metadata.deviceUDID),
              !record.metadata.teamIdentifier.isEmpty,
              !record.metadata.identifier.isEmpty,
              record.metadata.publicKeyFingerprint.count == 64,
              (record.metadata.schemaVersion == 1 || (record.metadata.pairingGeneration ?? 0) > 0),
              (try? NativeRemotePairingOperations.material(from: record.pairingData)) != nil else {
            throw RemotePairingFailure.invalidRecord
        }
        let data = try JSONEncoder().encode(record)
        let query = try baseQuery(deviceUDID: record.metadata.deviceUDID, teamIdentifier: record.metadata.teamIdentifier, candidate: candidate)
        let replacement: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        var status = SecItemUpdate(query as CFDictionary, replacement as CFDictionary)
        if status == errSecItemNotFound {
            var attrs = query; replacement.forEach { attrs[$0.key] = $0.value }
            status = SecItemAdd(attrs as CFDictionary, nil)
        }
        try check(status)
        guard status == errSecSuccess else { throw RemotePairingFailure.invalidRecord }
    }

    public func promoteCandidate(deviceUDID: String, teamIdentifier: String) throws {
        guard let candidate = try loadCandidate(deviceUDID: deviceUDID, teamIdentifier: teamIdentifier) else {
            throw RemotePairingFailure.invalidRecord
        }
        try save(candidate)
        let status = SecItemDelete(try baseQuery(deviceUDID: deviceUDID, teamIdentifier: teamIdentifier, candidate: true) as CFDictionary)
        try check(status)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemotePairingFailure.invalidRecord }
    }

    public func delete(deviceUDID: String, teamIdentifier: String) throws {
        let status = SecItemDelete(try baseQuery(deviceUDID: deviceUDID, teamIdentifier: teamIdentifier, candidate: false) as CFDictionary)
        try check(status)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemotePairingFailure.invalidRecord }
    }

    private func baseQuery(deviceUDID: String, teamIdentifier: String, candidate: Bool) throws -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(teamIdentifier):\(deviceUDID)\(candidate ? ":candidate" : "")"]
        switch backend {
        case nil:
            break
        case .unavailable?:
            throw RemotePairingFailure.secureStorageUnavailable
        case .dataProtectionKeychain?:
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = false
            query[kSecUseAuthenticationContext as String] = context
        case .loginKeychain?:
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }
}

public final class InMemoryRemotePairingStore: RemotePairingStore, @unchecked Sendable {
    private var records: [String: RemotePairingRecord] = [:]
    private var candidates: [String: RemotePairingRecord] = [:]
    public init() {}
    public func load(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord? {
        records["\(teamIdentifier):\(deviceUDID)"]
    }
    public func save(_ record: RemotePairingRecord) throws {
        records["\(record.metadata.teamIdentifier):\(record.metadata.deviceUDID)"] = record
    }
    public func loadCandidate(deviceUDID: String, teamIdentifier: String) throws -> RemotePairingRecord? {
        candidates["\(teamIdentifier):\(deviceUDID)"]
    }
    public func saveCandidate(_ record: RemotePairingRecord) throws {
        candidates["\(record.metadata.teamIdentifier):\(record.metadata.deviceUDID)"] = record
    }
    public func promoteCandidate(deviceUDID: String, teamIdentifier: String) throws {
        let key = "\(teamIdentifier):\(deviceUDID)"
        guard let candidate = candidates[key] else { throw RemotePairingFailure.invalidRecord }
        records[key] = candidate
        candidates.removeValue(forKey: key)
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
        do {
            let data = try transport.createRemotePairing(on: device, hostname: hostname)
            return try Self.material(from: data)
        } catch let error as NativeDeviceBridgeError {
            throw Self.map(error)
        }
    }
    public func validate(_ record: RemotePairingRecord, on device: IOSSimDeviceIdentity, hostname: String) async throws {
        guard record.metadata.deviceUDID == device.udid else { throw RemotePairingFailure.wrongDevice }
        _ = try Self.material(from: record.pairingData)
        do {
            try transport.validateRemotePairing(on: device, hostname: hostname, pairingData: record.pairingData)
        } catch let error as NativeDeviceBridgeError {
            throw Self.map(error)
        }
    }
    public static func material(from data: Data) throws -> RemotePairingMaterial {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let identifier = plist["identifier"] as? String, !identifier.isEmpty else {
            throw RemotePairingFailure.invalidRecord
        }
        if let altIRK = plist["alt_irk"] as? Data, altIRK.count != 16 {
            throw RemotePairingFailure.invalidRecord
        }
        _ = privateKey // validated, but never exposed in diagnostics
        let fingerprint = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return RemotePairingMaterial(pairingData: data, identifier: identifier, publicKeyFingerprint: fingerprint)
    }

    private static func map(_ error: NativeDeviceBridgeError) -> RemotePairingFailure {
        switch error {
        case .deviceNotFound, .deviceResolutionFailed, .deviceDisconnected, .timedOut:
            return .transientTransport
        case .deviceLocked:
            return .deviceLocked
        case .trustRequired:
            return .deviceTrustRequired
        case .pairingRejected:
            return .pairingRejected
        case .invalidIdentity:
            return .wrongDevice
        default:
            return .nativeBridgeUnavailable
        }
    }
}

public protocol RemotePairingContainerDelivery: Sendable {
    func writeEnvelope(_ envelope: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws
    func readReceipt(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data
    func writeBootstrapRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws
    func readBootstrap(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data
    func activateApp(on device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws
    func writePossessionChallenge(_ challenge: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws
    func readPossessionResponse(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data
    func writePromotionRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws
}

public extension RemotePairingContainerDelivery {
    func writeBootstrapRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        throw RemotePairingFailure.bootstrapMissing
    }
    func readBootstrap(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        throw RemotePairingFailure.bootstrapMissing
    }
    func activateApp(on device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {}
    func writePossessionChallenge(_ challenge: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        throw RemotePairingFailure.operationalProofFailed
    }
    func readPossessionResponse(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        throw RemotePairingFailure.operationalProofFailed
    }
    func writePromotionRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        throw RemotePairingFailure.operationalProofFailed
    }
}

public struct NativeRemotePairingContainerDelivery: RemotePairingContainerDelivery {
    private let service: any NativeApplicationServicing
    public init(service: any NativeApplicationServicing) { self.service = service }
    public func writeEnvelope(_ envelope: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        do {
            try await service.writeContainer(bundleIdentifier: appBundleIdentifier,
                relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.envelope",
                data: envelope, on: device)
        } catch { throw Self.map(error, fallback: .deliveryFailed) }
    }
    public func readReceipt(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        do {
            return try await service.readContainer(bundleIdentifier: appBundleIdentifier,
                relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.receipt", on: device)
        } catch { throw Self.map(error, fallback: .receiptMissing) }
    }
    public func writeBootstrapRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        do {
            try await service.writeContainer(bundleIdentifier: appBundleIdentifier,
                relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.request",
                data: request, on: device)
        } catch { throw Self.map(error, fallback: .deliveryFailed) }
    }
    public func readBootstrap(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        do {
            return try await service.readContainer(bundleIdentifier: appBundleIdentifier,
                relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.bootstrap", on: device)
        } catch { throw Self.map(error, fallback: .bootstrapMissing) }
    }
    public func activateApp(on device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        do { try await service.launch(bundleIdentifier: appBundleIdentifier, on: device) }
        catch { throw Self.map(error, fallback: .deliveryFailed) }
    }
    public func writePossessionChallenge(_ challenge: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        do {
            try await service.writeContainer(bundleIdentifier: appBundleIdentifier,
                relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.challenge",
                data: challenge, on: device)
        } catch { throw Self.map(error, fallback: .operationalProofFailed) }
    }
    public func readPossessionResponse(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        do {
            return try await service.readContainer(bundleIdentifier: appBundleIdentifier,
                relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.challenge-response", on: device)
        } catch { throw Self.map(error, fallback: .operationalProofFailed) }
    }
    public func writePromotionRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        do {
            try await service.writeContainer(bundleIdentifier: appBundleIdentifier,
                relativePath: "Library/Application Support/IOSSim/SetupInbox/remote-pairing.promote",
                data: request, on: device)
        } catch { throw Self.map(error, fallback: .operationalProofFailed) }
    }

    private static func map(_ error: Error, fallback: RemotePairingFailure) -> RemotePairingFailure {
        guard let bridge = error as? NativeDeviceBridgeError else { return fallback }
        switch bridge {
        case .deviceLocked: return .deviceLocked
        case .trustRequired: return .deviceTrustRequired
        case .deviceNotFound, .deviceResolutionFailed, .deviceDisconnected, .timedOut:
            return .transientTransport
        default: return fallback
        }
    }
}

public protocol RemotePairingOperationalProof: Sendable {
    func verify(on device: IOSSimDeviceIdentity, pairing: RemotePairingRecord) async throws
}

public struct UnavailableRemotePairingOperationalProof: RemotePairingOperationalProof {
    public init() {}
    public func verify(on device: IOSSimDeviceIdentity, pairing: RemotePairingRecord) async throws {
        throw RemotePairingFailure.operationalProofFailed
    }
}

public struct NativeDeveloperServicesRemotePairingProof: RemotePairingOperationalProof {
    private let native: any RemotePairingNativeOperations
    private let developerServices: any DeveloperServicesPreparing
    private let hostname: String

    public init(
        native: any RemotePairingNativeOperations,
        developerServices: any DeveloperServicesPreparing,
        hostname: String = "IOSSim-Mac"
    ) {
        self.native = native
        self.developerServices = developerServices
        self.hostname = hostname
    }

    public func verify(on device: IOSSimDeviceIdentity, pairing: RemotePairingRecord) async throws {
        do {
            try await native.validate(pairing, on: device, hostname: hostname)
            let identifiers = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(
                teamIdentifier: pairing.metadata.teamIdentifier
            )
            let releaseIdentity = pairing.metadata.releaseIdentity ?? "local-unknown"
            let receipt = try await developerServices.prepare(
                device: device,
                context: DeveloperServicesProofContext(
                    releaseIdentity: releaseIdentity,
                    pairingGeneration: pairing.metadata.pairingGeneration,
                    targetBundleIdentifier: identifiers.main
                )
            ) { _ in }
            guard receipt.isCurrent(
                for: device,
                releaseIdentity: releaseIdentity,
                pairingGeneration: pairing.metadata.pairingGeneration,
                targetBundleIdentifier: identifiers.main
            ) else { throw RemotePairingFailure.operationalProofFailed }
        } catch let failure as RemotePairingFailure {
            throw failure
        } catch {
            throw RemotePairingFailure.operationalProofFailed
        }
    }
}

public actor RemotePairingCoordinator {
    public private(set) var state: RemotePairingLifecycleState
    public private(set) var lastDisposition: RemotePairingDisposition = .none
    private let store: any RemotePairingStore
    private let native: any RemotePairingNativeOperations
    private let delivery: any RemotePairingContainerDelivery
    private let proof: any RemotePairingOperationalProof

    public init(store: any RemotePairingStore = KeychainRemotePairingStore(),
                native: any RemotePairingNativeOperations = NativeRemotePairingOperations(),
                delivery: any RemotePairingContainerDelivery,
                proof: any RemotePairingOperationalProof = UnavailableRemotePairingOperationalProof()) {
        self.store = store; self.native = native; self.delivery = delivery; self.proof = proof; self.state = .missing
    }

    public func prepare(device: IOSSimDeviceIdentity, teamIdentifier: String,
                        appBundleIdentifier: String, hostname: String,
                        bootstrap: RemotePairingBootstrapSession,
        forceRepair: Bool = false,
        releaseIdentity: String = "local-unknown") async throws -> RemotePairingRecord {
        let active = try store.load(deviceUDID: device.udid, teamIdentifier: teamIdentifier)
        let staged = try store.loadCandidate(deviceUDID: device.udid, teamIdentifier: teamIdentifier)
        let generation = bootstrap.pairingGeneration
            ?? staged?.metadata.pairingGeneration
            ?? ((active?.metadata.pairingGeneration ?? 0) &+ 1)
        let requestID = bootstrap.requestID ?? UUID().uuidString
        let boundRelease = bootstrap.releaseIdentity ?? releaseIdentity
        guard !requestID.isEmpty, generation > 0, !boundRelease.isEmpty else {
            throw RemotePairingFailure.bootstrapInvalid
        }

        var record: RemotePairingRecord?
        var reused = false
        state = active == nil ? .missing : .stored
        if !forceRepair, let active {
            state = .validating
            do {
                try await native.validate(active, on: device, hostname: hostname)
                record = Self.rebinding(active, generation: generation, releaseIdentity: boundRelease)
                reused = true
            } catch RemotePairingFailure.invalidRecord {
                state = .repairable
            } catch RemotePairingFailure.pairingRejected {
                state = .repairable
            }
        }
        if record == nil, let staged,
           staged.metadata.pairingGeneration == generation,
           staged.metadata.releaseIdentity == boundRelease {
            do {
                try await native.validate(staged, on: device, hostname: hostname)
                record = staged
            } catch RemotePairingFailure.invalidRecord {
                state = .repairable
            } catch RemotePairingFailure.pairingRejected {
                state = .repairable
            }
        }
        if record == nil {
            state = .creating
            let material = try await native.create(on: device, hostname: hostname)
            let metadata = RemotePairingRecordMetadata(
                schemaVersion: 2,
                deviceUDID: device.udid,
                teamIdentifier: teamIdentifier,
                identifier: material.identifier,
                publicKeyFingerprint: material.publicKeyFingerprint,
                pairingGeneration: generation,
                releaseIdentity: boundRelease
            )
            record = RemotePairingRecord(metadata: metadata, pairingData: material.pairingData)
        }
        guard let record else { throw RemotePairingFailure.invalidRecord }
        try store.saveCandidate(record)
        try await native.validate(record, on: device, hostname: hostname)
        lastDisposition = reused ? .reused : .created
        state = .candidateStored
        let boundBootstrap = RemotePairingBootstrapSession(
            schemaVersion: 2,
            nonce: bootstrap.nonce,
            importKey: bootstrap.importKey,
            requestID: requestID,
            pairingGeneration: generation,
            releaseIdentity: boundRelease
        )
        let envelope = try Self.makeEnvelope(record: record, bootstrap: boundBootstrap)
        let encoded = try JSONEncoder().encode(envelope)
        state = .delivering
        try await delivery.writeEnvelope(encoded, to: device, appBundleIdentifier: appBundleIdentifier)
        state = .awaitingReceipt
        let receiptData = try await poll(
            maxAttempts: 20, delayNanoseconds: 250_000_000,
            escalate: { try await self.delivery.activateApp(on: device, appBundleIdentifier: appBundleIdentifier) }
        ) {
            try await self.delivery.readReceipt(from: device, appBundleIdentifier: appBundleIdentifier)
        }
        let receipt = try JSONDecoder().decode(RemotePairingReceipt.self, from: receiptData)
        guard receipt.schemaVersion == 2,
              receipt.deviceUDID == device.udid, receipt.teamIdentifier == teamIdentifier,
              receipt.nonce == boundBootstrap.nonce, receipt.identifier == record.metadata.identifier,
              receipt.publicKeyFingerprint == record.metadata.publicKeyFingerprint,
              receipt.requestID == requestID,
              receipt.pairingGeneration == generation,
              receipt.releaseIdentity == boundRelease else { throw RemotePairingFailure.receiptInvalid }
        guard receipt.status == "candidate-stored" else { throw RemotePairingFailure.receiptRejected }

        let challenge = RemotePairingPossessionChallenge(
            deviceUDID: device.udid,
            teamIdentifier: teamIdentifier,
            requestID: requestID,
            pairingGeneration: generation,
            releaseIdentity: boundRelease
        )
        state = .provingPossession
        try await delivery.writePossessionChallenge(
            try JSONEncoder().encode(challenge), to: device,
            appBundleIdentifier: appBundleIdentifier
        )
        let responseData = try await poll(
            maxAttempts: 20, delayNanoseconds: 250_000_000,
            escalate: { try await self.delivery.activateApp(on: device, appBundleIdentifier: appBundleIdentifier) }
        ) {
            try await self.delivery.readPossessionResponse(from: device, appBundleIdentifier: appBundleIdentifier)
        }
        let response = try JSONDecoder().decode(RemotePairingPossessionResponse.self, from: responseData)
        guard response.schemaVersion == 1,
              response.deviceUDID == challenge.deviceUDID,
              response.teamIdentifier == challenge.teamIdentifier,
              response.requestID == challenge.requestID,
              response.pairingGeneration == challenge.pairingGeneration,
              response.releaseIdentity == challenge.releaseIdentity,
              response.nonce == challenge.nonce,
              response.proof == Self.possessionProof(record: record, challenge: challenge) else {
            throw RemotePairingFailure.operationalProofFailed
        }

        state = .provingDeveloperServices
        try await proof.verify(on: device, pairing: record)
        state = .promoting
        let promotion = RemotePairingPromotionRequest(
            deviceUDID: device.udid,
            teamIdentifier: teamIdentifier,
            requestID: requestID,
            pairingGeneration: generation,
            releaseIdentity: boundRelease
        )
        try await delivery.writePromotionRequest(
            try JSONEncoder().encode(promotion), to: device,
            appBundleIdentifier: appBundleIdentifier
        )
        let promotionReceiptData = try await poll(
            maxAttempts: 20, delayNanoseconds: 250_000_000,
            escalate: { try await self.delivery.activateApp(on: device, appBundleIdentifier: appBundleIdentifier) }
        ) {
            try await self.delivery.readReceipt(from: device, appBundleIdentifier: appBundleIdentifier)
        }
        let promotionReceipt = try JSONDecoder().decode(RemotePairingReceipt.self, from: promotionReceiptData)
        guard promotionReceipt.schemaVersion == 2,
              promotionReceipt.deviceUDID == device.udid,
              promotionReceipt.teamIdentifier == teamIdentifier,
              promotionReceipt.requestID == requestID,
              promotionReceipt.pairingGeneration == generation,
              promotionReceipt.releaseIdentity == boundRelease,
              promotionReceipt.identifier == record.metadata.identifier,
              promotionReceipt.publicKeyFingerprint == record.metadata.publicKeyFingerprint,
              promotionReceipt.status == "operational" else {
            throw RemotePairingFailure.receiptInvalid
        }
        try store.promoteCandidate(deviceUDID: device.udid, teamIdentifier: teamIdentifier)
        state = .operational
        return record
    }

    public func prepareAutomatically(
        device: IOSSimDeviceIdentity,
        teamIdentifier: String,
        appBundleIdentifier: String,
        hostname: String,
        forceRepair: Bool = false,
        releaseIdentity: String = "local-unknown"
    ) async throws -> RemotePairingRecord {
        let active = try store.load(deviceUDID: device.udid, teamIdentifier: teamIdentifier)
        let candidate = try store.loadCandidate(deviceUDID: device.udid, teamIdentifier: teamIdentifier)
        let generation = candidate?.metadata.pairingGeneration
            ?? ((active?.metadata.pairingGeneration ?? 0) &+ 1)
        let request = RemotePairingBootstrapRequest(
            schemaVersion: 2,
            deviceUDID: device.udid,
            teamIdentifier: teamIdentifier,
            appBundleIdentifier: appBundleIdentifier,
            pairingGeneration: generation,
            releaseIdentity: releaseIdentity
        )
        try await delivery.writeBootstrapRequest(
            try JSONEncoder().encode(request),
            to: device,
            appBundleIdentifier: appBundleIdentifier
        )
        let bootstrapData = try await poll(
            maxAttempts: 20, delayNanoseconds: 250_000_000,
            escalate: { try await self.delivery.activateApp(on: device, appBundleIdentifier: appBundleIdentifier) }
        ) {
            try await self.delivery.readBootstrap(from: device, appBundleIdentifier: appBundleIdentifier)
        }
        guard let bootstrap = try? JSONDecoder().decode(RemotePairingBootstrapSession.self, from: bootstrapData),
              bootstrap.schemaVersion == 2, bootstrap.importKey.count == 32,
              bootstrap.requestID == request.requestID,
              bootstrap.pairingGeneration == generation,
              bootstrap.releaseIdentity == releaseIdentity,
              !bootstrap.nonce.isEmpty else {
            throw RemotePairingFailure.bootstrapInvalid
        }
        return try await prepare(
            device: device,
            teamIdentifier: teamIdentifier,
            appBundleIdentifier: appBundleIdentifier,
            hostname: hostname,
            bootstrap: bootstrap,
            forceRepair: forceRepair,
            releaseIdentity: releaseIdentity
        )
    }

    public func reconcileAutomatically(
        device: IOSSimDeviceIdentity,
        teamIdentifier: String,
        appBundleIdentifier: String,
        hostname: String,
        forceRepair: Bool = false,
        releaseIdentity: String = "local-unknown"
    ) async throws -> RemotePairingRecord {
        return try await prepareAutomatically(
            device: device,
            teamIdentifier: teamIdentifier,
            appBundleIdentifier: appBundleIdentifier,
            hostname: hostname,
            forceRepair: forceRepair,
            releaseIdentity: releaseIdentity
        )
    }

    /// After the first activation the phone's inbox watcher polls the container for 60 s, so it picks
    /// up each later write on its own. An AppService launch kills and restarts the app (`kill_existing`),
    /// which restarts that watcher from zero and is visible to the user, so activation is an escalation
    /// rather than a step: it runs only once the watcher has demonstrably not answered.
    static let activationEscalationAttempt = 8

    private func poll(
        maxAttempts: Int,
        delayNanoseconds: UInt64,
        escalate: (() async throws -> Void)? = nil,
        operation: () async throws -> Data
    ) async throws -> Data {
        var lastError: Error = RemotePairingFailure.receiptMissing
        var escalated = false
        for attempt in 0..<maxAttempts {
            do { return try await operation() }
            catch { lastError = error }
            if let escalate, !escalated, attempt >= Self.activationEscalationAttempt {
                escalated = true
                try await escalate()
            }
            if attempt + 1 < maxAttempts { try await Task.sleep(nanoseconds: delayNanoseconds) }
        }
        throw lastError
    }

    public static func makeEnvelope(record: RemotePairingRecord, bootstrap: RemotePairingBootstrapSession) throws -> RemotePairingEnvelope {
        let box = try AES.GCM.seal(record.pairingData, using: SymmetricKey(data: bootstrap.importKey))
        return RemotePairingEnvelope(
            schemaVersion: 2,
            deviceUDID: record.metadata.deviceUDID,
            teamIdentifier: record.metadata.teamIdentifier,
            nonce: bootstrap.nonce,
            sealedPayload: box.combined ?? Data(),
            requestID: bootstrap.requestID,
            pairingGeneration: record.metadata.pairingGeneration,
            releaseIdentity: record.metadata.releaseIdentity
        )
    }

    public static func possessionProof(
        record: RemotePairingRecord,
        challenge: RemotePairingPossessionChallenge
    ) -> String {
        let message = [
            challenge.deviceUDID, challenge.teamIdentifier, challenge.requestID,
            String(challenge.pairingGeneration), challenge.releaseIdentity, challenge.nonce,
            record.metadata.identifier, record.metadata.publicKeyFingerprint,
        ].joined(separator: "\n")
        let key = SymmetricKey(data: Data(SHA256.hash(data: record.pairingData)))
        return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func rebinding(
        _ record: RemotePairingRecord,
        generation: UInt64,
        releaseIdentity: String
    ) -> RemotePairingRecord {
        RemotePairingRecord(
            metadata: RemotePairingRecordMetadata(
                schemaVersion: 2,
                deviceUDID: record.metadata.deviceUDID,
                teamIdentifier: record.metadata.teamIdentifier,
                identifier: record.metadata.identifier,
                publicKeyFingerprint: record.metadata.publicKeyFingerprint,
                createdAt: record.metadata.createdAt,
                lastValidatedAt: .now,
                pairingGeneration: generation,
                releaseIdentity: releaseIdentity
            ),
            pairingData: record.pairingData
        )
    }
}
