import Foundation
import Security

public protocol RPPairingStore: Sendable {
    func importPairingData(_ data: Data) throws -> RPPairingSummary
    func loadPairingData() throws -> Data
    func pairingSummary() throws -> RPPairingSummary?
    func deletePairingData() throws
}

public final class KeychainRPPairingStore: RPPairingStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessible: CFString

    public init(
        service: String = "com.iossim.on-device-dvt-poc.rppairing",
        account: String = "primary",
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.account = account
        self.accessible = accessible
    }

    public func importPairingData(_ data: Data) throws -> RPPairingSummary {
        let summary = try RPPairingValidator.validate(data)
        let query = baseQuery()
        let replacement: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        var status = SecItemUpdate(query as CFDictionary, replacement as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            replacement.forEach { attributes[$0.key] = $0.value }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw POCError(.pairingStorageFailed, "Keychain write failed with OSStatus \(status).", stage: .pairingImported)
        }
        return summary
    }

    public func loadPairingData() throws -> Data {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw POCError(.pairingCredentialMissing, "No RPPairing file has been imported.", stage: .pairingImported)
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw POCError(.pairingStorageFailed, "Keychain read failed with OSStatus \(status).", stage: .pairingImported)
        }
        return data
    }

    public func pairingSummary() throws -> RPPairingSummary? {
        do {
            return try RPPairingValidator.validate(loadPairingData())
        } catch let error as POCError where error.code == .pairingCredentialMissing {
            return nil
        }
    }

    public func deletePairingData() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw POCError(.pairingStorageFailed, "Keychain delete failed with OSStatus \(status).", stage: .pairingImported)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum RPPairingUpdatePersistence {
    /// Persists only a semantically valid changed record. The store owns the
    /// secure/atomic storage mechanism; no pairing bytes are logged here.
    @discardableResult
    public static func persistIfChanged(
        _ updatedData: Data,
        originalData: Data,
        store: RPPairingStore?
    ) throws -> Bool {
        guard updatedData != originalData else { return false }
        _ = try RPPairingValidator.validate(updatedData)
        guard let store else { return false }
        _ = try store.importPairingData(updatedData)
        return true
    }
}

public final class InMemoryRPPairingStore: RPPairingStore, @unchecked Sendable {
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func importPairingData(_ data: Data) throws -> RPPairingSummary {
        let summary = try RPPairingValidator.validate(data)
        self.data = data
        return summary
    }

    public func loadPairingData() throws -> Data {
        guard let data else {
            throw POCError(.pairingCredentialMissing, "No RPPairing file has been imported.", stage: .pairingImported)
        }
        return data
    }

    public func pairingSummary() throws -> RPPairingSummary? {
        guard let data else { return nil }
        return try RPPairingValidator.validate(data)
    }

    public func deletePairingData() throws {
        data = nil
    }
}

public struct AutomaticPairingReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: UUID
    public let state: String

    public init(schemaVersion: Int = 1, transactionID: UUID, state: String) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.state = state
    }
}

/// Consumes pairing candidates placed in the app's private data container by
/// the Mac setup app. A candidate is committed to the primary Keychain item
/// only after the pinned runtime establishes a real tunnel with it.
public actor AutomaticPairingInboxProcessor {
    public typealias ClientFactory = @Sendable (RPPairingStore) -> any OnDeviceTunnelClient

    private let primaryStore: RPPairingStore
    private let fileManager: FileManager
    private let rootURL: URL
    private let clientFactory: ClientFactory

    public init(
        primaryStore: RPPairingStore = KeychainRPPairingStore(),
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        clientFactory: @escaping ClientFactory = { stagingStore in
            IdeviceOnDeviceTunnelClient(recorder: nil, pairingStore: stagingStore)
        }
    ) {
        self.primaryStore = primaryStore
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IOSSim", isDirectory: true)
        self.clientFactory = clientFactory
    }

    @discardableResult
    public func processPending() async -> [AutomaticPairingReceipt] {
        let inbox = rootURL.appendingPathComponent("PairingInbox", isDirectory: true)
        let receipts = rootURL.appendingPathComponent("PairingReceipts", isDirectory: true)
        do {
            try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: receipts, withIntermediateDirectories: true)
            try applyPrivateProtection(to: inbox)
            try applyPrivateProtection(to: receipts)
        } catch {
            return []
        }
        let candidates = (try? fileManager.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "plist" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        var results: [AutomaticPairingReceipt] = []
        for candidateURL in candidates {
            guard let transactionID = UUID(uuidString: candidateURL.deletingPathExtension().lastPathComponent) else {
                try? fileManager.removeItem(at: candidateURL)
                continue
            }
            let receipt: AutomaticPairingReceipt
            do {
                let candidateData = try Data(contentsOf: candidateURL, options: .mappedIfSafe)
                _ = try RPPairingValidator.validate(candidateData)
                let stagingStore = InMemoryRPPairingStore(data: candidateData)
                let client = clientFactory(stagingStore)
                defer { Task { await client.disconnect() } }
                try await client.connect(pairingData: candidateData, endpoint: DeveloperEndpoint())
                let deviceVerifiedData = try stagingStore.loadPairingData()
                _ = try RPPairingValidator.validate(deviceVerifiedData)
                _ = try primaryStore.importPairingData(deviceVerifiedData)
                receipt = AutomaticPairingReceipt(transactionID: transactionID, state: "PAIRING_READY")
            } catch {
                // The primary Keychain item has not been touched, so a prior
                // known-good record remains authoritative.
                receipt = AutomaticPairingReceipt(transactionID: transactionID, state: "PAIRING_FAILED")
            }
            do {
                let receiptURL = receipts.appendingPathComponent("\(transactionID.uuidString).json")
                let data = try JSONEncoder().encode(receipt)
                #if os(iOS)
                try data.write(to: receiptURL, options: [.atomic, .completeFileProtection])
                #else
                // Complete file protection is an iOS data-protection class;
                // macOS package checks still enforce owner-only permissions.
                try data.write(to: receiptURL, options: .atomic)
                #endif
                try applyPrivateProtection(to: receiptURL)
                try fileManager.removeItem(at: candidateURL)
                results.append(receipt)
            } catch {
                // Keep the candidate for retry if receipt persistence or
                // cleanup did not complete.
            }
        }
        return results
    }

    private func applyPrivateProtection(to url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        if !url.hasDirectoryPath { attributes[.posixPermissions] = 0o600 }
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
