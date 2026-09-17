import Foundation
import Security

public protocol RPPairingStore: Sendable {
    func importPairingData(_ data: Data) throws -> RPPairingSummary
    func importCandidatePairingData(_ data: Data) throws -> RPPairingSummary
    func loadPairingData() throws -> Data
    func loadCandidatePairingData() throws -> Data
    func promoteCandidatePairingData() throws
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
        try importPairingData(data, account: account)
    }

    public func importCandidatePairingData(_ data: Data) throws -> RPPairingSummary {
        try importPairingData(data, account: "\(account).candidate")
    }

    private func importPairingData(_ data: Data, account: String) throws -> RPPairingSummary {
        let summary = try RPPairingValidator.validate(data)
        let query = baseQuery(account: account)
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
        try loadPairingData(account: account)
    }

    public func loadCandidatePairingData() throws -> Data {
        try loadPairingData(account: "\(account).candidate")
    }

    private func loadPairingData(account: String) throws -> Data {
        var query = baseQuery(account: account)
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
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw POCError(.pairingStorageFailed, "Keychain delete failed with OSStatus \(status).", stage: .pairingImported)
        }
    }

    public func promoteCandidatePairingData() throws {
        let candidate = try loadCandidatePairingData()
        _ = try importPairingData(candidate)
        let status = SecItemDelete(baseQuery(account: "\(account).candidate") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw POCError(.pairingStorageFailed, "Candidate Keychain cleanup failed with OSStatus \(status).", stage: .pairingImported)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
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
    private var candidateData: Data?

    public func importCandidatePairingData(_ data: Data) throws -> RPPairingSummary {
        let summary = try RPPairingValidator.validate(data)
        candidateData = data
        return summary
    }

    public func loadPairingData() throws -> Data {
        guard let data else {
            throw POCError(.pairingCredentialMissing, "No RPPairing file has been imported.", stage: .pairingImported)
        }
        return data
    }
    public func loadCandidatePairingData() throws -> Data {
        guard let candidateData else {
            throw POCError(.pairingCredentialMissing, "No candidate RPPairing file has been imported.", stage: .pairingImported)
        }
        return candidateData
    }

    public func promoteCandidatePairingData() throws {
        data = try loadCandidatePairingData()
        candidateData = nil
    }

    public func pairingSummary() throws -> RPPairingSummary? {
        guard let data else { return nil }
        return try RPPairingValidator.validate(data)
    }

    public func deletePairingData() throws {
        data = nil
    }
}
