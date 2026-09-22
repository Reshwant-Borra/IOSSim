import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

// Veya signing key store (M4, doc 05 + ADR-001).
// RSA-2048 private keys exist at rest only as AES-256-GCM encrypted PKCS#8 in `0600` files. The
// per-installation wrapping secret is the only Keychain item. No SecKey/SecIdentity/certificate is
// ever stored, no Keychain search list/ACL/partition is touched, and every Keychain call disables UI.

public struct SigningKeyDescriptor: Codable, Equatable, Sendable {
    public let keyID: String
    public let installationID: UUID
    public let algorithm: String
    public let publicKeySHA256: String
    public let ciphertextSHA256: String
    public let envelopeVersion: Int
    public let createdAt: Date
}

public enum SigningKeyFailure {
    public static func make(_ number: Int, _ operation: String, _ message: String, retryable: Bool = false) -> VeyaFailure {
        // Constant, validated inputs; construction cannot fail.
        try! VeyaFailure(
            namespace: .key,
            number: number,
            operation: operation,
            safeMessage: message,
            retryable: retryable,
            underlyingSubsystem: "signingKeyStore"
        )
    }

    public static let wrappingStoreUnavailable = make(1, "wrappingSecret", "The Keychain wrapping store is unavailable to this build.")
    public static let interactionRequired = make(2, "wrappingSecret", "Keychain access would require user interaction; Veya never prompts for it.")
    public static let wrapperMissing = make(3, "unwrap", "The signing key wrapping secret is missing.")
    public static let ciphertextMissing = make(4, "unwrap", "The encrypted signing key file is missing.")
    public static let authenticationFailed = make(5, "unwrap", "The encrypted signing key failed authentication.")
    public static let corruptEnvelope = make(6, "unwrap", "The encrypted signing key file is corrupt.")
    public static let unsafeFile = make(7, "fileSafety", "The signing key file or directory has unsafe ownership, type, or permissions.")
    public static let publicKeyMismatch = make(8, "verify", "The signing key does not match its recorded public key.")
    public static let generationFailed = make(9, "generate", "The signing key could not be generated.")
    public static let keychainFailure = make(10, "wrappingSecret", "The Keychain wrapping store returned an unexpected error.", retryable: true)
    public static let probeFailed = make(11, "verify", "The signing key failed its sign/verify probe.")
    public static let writeFailed = make(12, "persist", "The encrypted signing key could not be written.")
}

// MARK: - Wrapping secret backends

public enum WrappingSecretBackendKind: String, Codable, Sendable {
    case unavailable
    case dataProtectionKeychain
    /// Read-only/explicit compatibility surface for legacy fixtures. Production selection never
    /// returns this backend because file-based Keychain access cannot satisfy the no-UI gate.
    case loginKeychain

    /// Pure function of the running code's validated identity; never a runtime fallback.
    public static func select(teamIdentifier: String?, entitlements: [String: Any]) -> WrappingSecretBackendKind {
        guard let teamIdentifier, !teamIdentifier.isEmpty else { return .unavailable }
        let applicationIdentifier = entitlements["com.apple.application-identifier"] as? String
            ?? entitlements["application-identifier"] as? String
        let entitlementTeam = entitlements["com.apple.developer.team-identifier"] as? String
        let accessGroups = entitlements["keychain-access-groups"] as? [String] ?? []
        guard entitlementTeam == nil || entitlementTeam == teamIdentifier,
              applicationIdentifier?.hasPrefix("\(teamIdentifier).") == true,
              accessGroups.contains(where: { $0.hasPrefix("\(teamIdentifier).") }) else {
            return .unavailable
        }
        return .dataProtectionKeychain
    }

    public static func forRunningCode() -> WrappingSecretBackendKind {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unavailable }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unavailable }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let values = info as? [String: Any] else { return .unavailable }
        return select(
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        )
    }
}

public protocol WrappingSecretStore: Sendable {
    var kind: WrappingSecretBackendKind { get }
    /// Returns nil when no wrapping secret exists for the installation.
    func read(installationID: UUID) throws -> SymmetricKey?
    func create(installationID: UUID) throws -> SymmetricKey
    func delete(installationID: UUID) throws
}

public struct KeychainWrappingSecretStore: WrappingSecretStore {
    public static let service = "com.veya.signing-wrap.v1"
    public let kind: WrappingSecretBackendKind
    private let service: String
    private let label: String

    public init(
        kind: WrappingSecretBackendKind = .forRunningCode(),
        service: String = Self.service,
        label: String = "Veya signing key wrapping secret"
    ) {
        self.kind = kind
        self.service = service
        self.label = label
    }

    private func baseQuery(_ installationID: UUID) throws -> [String: Any] {
        guard kind != .unavailable else { throw SigningKeyFailure.wrappingStoreUnavailable }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: installationID.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: kind == .dataProtectionKeychain,
        ]
        if kind == .dataProtectionKeychain {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        } else {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    public func read(installationID: UUID) throws -> SymmetricKey? {
        var query = try baseQuery(installationID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard var bytes = result as? Data, bytes.count == 32 else { throw SigningKeyFailure.corruptEnvelope }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            return SymmetricKey(data: bytes)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.failure(status)
        }
    }

    public func create(installationID: UUID) throws -> SymmetricKey {
        var secret = [UInt8](repeating: 0, count: 32)
        defer { secret.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else {
            throw SigningKeyFailure.generationFailed
        }
        var attributes = try baseQuery(installationID)
        attributes[kSecValueData as String] = Data(secret)
        attributes[kSecAttrLabel as String] = label
        if kind == .dataProtectionKeychain {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.failure(status) }
        return SymmetricKey(data: secret)
    }

    public func delete(installationID: UUID) throws {
        var query = try baseQuery(installationID)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    static func failure(_ status: OSStatus) -> VeyaFailure {
        switch status {
        case errSecMissingEntitlement: return SigningKeyFailure.wrappingStoreUnavailable
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return SigningKeyFailure.interactionRequired
        default: return SigningKeyFailure.keychainFailure
        }
    }

}

// MARK: - DER (only the fixed RSA PKCS#8 / SPKI shapes Veya produces)

enum RSAKeyDER {
    private static let rsaAlgorithmIdentifier: [UInt8] = [
        0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
    ]

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + length(body.count) + body }

    /// PKCS#8 PrivateKeyInfo wrapping a PKCS#1 RSAPrivateKey.
    static func pkcs8(pkcs1: [UInt8]) -> [UInt8] {
        tlv(0x30, [0x02, 0x01, 0x00] + rsaAlgorithmIdentifier + tlv(0x04, pkcs1))
    }

    /// SubjectPublicKeyInfo wrapping a PKCS#1 RSAPublicKey.
    static func spki(pkcs1Public: [UInt8]) -> [UInt8] {
        tlv(0x30, rsaAlgorithmIdentifier + tlv(0x03, [0x00] + pkcs1Public))
    }

    /// Extracts the PKCS#1 RSAPrivateKey from Veya's PKCS#8 encoding; rejects anything else.
    static func pkcs1(fromPKCS8 bytes: [UInt8]) throws -> [UInt8] {
        var reader = DERReader(bytes)
        var info = try reader.read(tag: 0x30)
        guard reader.atEnd else { throw SigningKeyFailure.corruptEnvelope }
        guard try info.read(tag: 0x02).rest == [0x00] else { throw SigningKeyFailure.corruptEnvelope }
        let algorithm = try info.read(tag: 0x30)
        guard [0x30] + length(algorithm.rest.count) + algorithm.rest == rsaAlgorithmIdentifier else {
            throw SigningKeyFailure.corruptEnvelope
        }
        let key = try info.read(tag: 0x04)
        guard info.atEnd else { throw SigningKeyFailure.corruptEnvelope }
        return key.rest
    }
}

struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { offset == bytes.count }
    var rest: [UInt8] { Array(bytes[offset...]) }

    mutating func read(tag: UInt8) throws -> DERReader {
        guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw SigningKeyFailure.corruptEnvelope }
        var cursor = offset + 1
        var count = Int(bytes[cursor])
        cursor += 1
        if count & 0x80 != 0 {
            let width = count & 0x7f
            guard (1...4).contains(width), cursor + width <= bytes.count else { throw SigningKeyFailure.corruptEnvelope }
            count = bytes[cursor..<(cursor + width)].reduce(0) { ($0 << 8) | Int($1) }
            cursor += width
        }
        guard count >= 0, cursor + count <= bytes.count else { throw SigningKeyFailure.corruptEnvelope }
        offset = cursor + count
        return DERReader(Array(bytes[cursor..<(cursor + count)]))
    }
}

// MARK: - Envelope

struct SigningKeyEnvelope: Codable, Equatable {
    static let magic = "veya.signing-key"
    static let currentVersion = 1

    let magic: String
    let version: Int
    let keyID: String
    let installationID: UUID
    let algorithm: String
    let publicKeySHA256: String
    let createdAt: Date
    let nonce: Data
    let ciphertext: Data
    let tag: Data
    let associatedDataSHA256: String

    static func associatedData(installationID: UUID, keyID: String, algorithm: String, publicKeySHA256: String) -> Data {
        Data("\(magic)|v\(currentVersion)|\(installationID.uuidString.lowercased())|\(keyID)|\(algorithm)|\(publicKeySHA256)".utf8)
    }
}

// MARK: - Store

public actor VeyaSigningKeyStore {
    public static let algorithm = "rsa-2048"

    public nonisolated let rootURL: URL
    private let wrapping: any WrappingSecretStore
    private let now: @Sendable () -> Date

    public static func defaultRootURL() -> URL {
        InstallationJournalRepository.defaultRootURL().deletingLastPathComponent()
            .appendingPathComponent("secrets", isDirectory: true)
            .appendingPathComponent("signing-keys", isDirectory: true)
    }

    public init(
        rootURL: URL = VeyaSigningKeyStore.defaultRootURL(),
        wrapping: any WrappingSecretStore = KeychainWrappingSecretStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL
        self.wrapping = wrapping
        self.now = now
    }

    public nonisolated func relativeLocation(keyID: String) -> String { "secrets/signing-keys/\(keyID).vkey" }

    /// Generates a new RSA-2048 key, encrypts it under the installation's wrapping secret, writes it
    /// atomically, and proves decrypt/parse/sign/verify before returning. Nothing is promoted here.
    public func createCandidate(installationID: UUID) throws -> SigningKeyDescriptor {
        let secret = try wrapping.read(installationID: installationID) ?? wrapping.create(installationID: installationID)
        var pkcs1 = try Self.generatePKCS1()
        defer { Self.zero(&pkcs1) }
        var pkcs8 = RSAKeyDER.pkcs8(pkcs1: pkcs1)
        defer { Self.zero(&pkcs8) }
        let publicHash = try Self.publicKeySHA256(pkcs1: pkcs1)
        let keyID = UUID().uuidString.lowercased()
        let createdAt = now()
        let aad = SigningKeyEnvelope.associatedData(
            installationID: installationID, keyID: keyID, algorithm: Self.algorithm, publicKeySHA256: publicHash
        )
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(Data(pkcs8), using: secret, nonce: AES.GCM.Nonce(), authenticating: aad)
        } catch {
            throw SigningKeyFailure.generationFailed
        }
        let envelope = SigningKeyEnvelope(
            magic: SigningKeyEnvelope.magic,
            version: SigningKeyEnvelope.currentVersion,
            keyID: keyID,
            installationID: installationID,
            algorithm: Self.algorithm,
            publicKeySHA256: publicHash,
            createdAt: createdAt,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            associatedDataSHA256: Self.sha256(aad)
        )
        let bytes = try Self.encoder().encode(envelope)
        try writeAtomically(bytes, keyID: keyID)
        let descriptor = SigningKeyDescriptor(
            keyID: keyID,
            installationID: installationID,
            algorithm: Self.algorithm,
            publicKeySHA256: publicHash,
            ciphertextSHA256: Self.sha256(bytes),
            envelopeVersion: SigningKeyEnvelope.currentVersion,
            createdAt: createdAt
        )
        _ = try verify(keyID: keyID, installationID: installationID, expectedPublicKeySHA256: publicHash)
        return descriptor
    }

    /// Decrypts into a closure-scoped buffer that is zeroed afterwards. No API returns key bytes.
    public func withUnlockedPKCS8<R>(
        keyID: String,
        installationID: UUID,
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        let envelope = try readEnvelope(keyID: keyID)
        guard envelope.installationID == installationID else { throw SigningKeyFailure.authenticationFailed }
        guard let secret = try wrapping.read(installationID: installationID) else { throw SigningKeyFailure.wrapperMissing }
        let aad = SigningKeyEnvelope.associatedData(
            installationID: installationID, keyID: envelope.keyID, algorithm: envelope.algorithm,
            publicKeySHA256: envelope.publicKeySHA256
        )
        guard Self.sha256(aad) == envelope.associatedDataSHA256 else { throw SigningKeyFailure.corruptEnvelope }
        // No core dump may capture the key; left disabled afterwards (same policy as the signing FFI).
        var noCore = rlimit()
        guard getrlimit(RLIMIT_CORE, &noCore) == 0 else { throw SigningKeyFailure.unsafeFile }
        noCore.rlim_cur = 0
        guard setrlimit(RLIMIT_CORE, &noCore) == 0 else { throw SigningKeyFailure.unsafeFile }
        // Keep the single decrypted buffer and clear it in place; no uncleared copy.
        var plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce), ciphertext: envelope.ciphertext, tag: envelope.tag
            )
            plaintext = try AES.GCM.open(box, using: secret, authenticating: aad)
        } catch {
            throw SigningKeyFailure.authenticationFailed
        }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        return try plaintext.withUnsafeBytes(body)
    }

    /// Decrypts, parses, matches the recorded public key, and performs a local sign/verify probe.
    @discardableResult
    public func verify(keyID: String, installationID: UUID, expectedPublicKeySHA256: String) throws -> SigningKeyDescriptor {
        let envelope = try readEnvelope(keyID: keyID)
        guard envelope.publicKeySHA256 == expectedPublicKeySHA256 else { throw SigningKeyFailure.publicKeyMismatch }
        try withUnlockedPKCS8(keyID: keyID, installationID: installationID) { buffer in
            // The PKCS#8 copy is cleared too, not only the derived PKCS#1.
            var pkcs8 = Array(buffer)
            defer { Self.zero(&pkcs8) }
            var pkcs1 = try RSAKeyDER.pkcs1(fromPKCS8: pkcs8)
            defer { Self.zero(&pkcs1) }
            guard try Self.publicKeySHA256(pkcs1: pkcs1) == expectedPublicKeySHA256 else {
                throw SigningKeyFailure.publicKeyMismatch
            }
            try Self.signVerifyProbe(pkcs1: pkcs1)
        }
        let bytes = try readFile(keyID: keyID)
        return SigningKeyDescriptor(
            keyID: keyID,
            installationID: envelope.installationID,
            algorithm: envelope.algorithm,
            publicKeySHA256: envelope.publicKeySHA256,
            ciphertextSHA256: Self.sha256(bytes),
            envelopeVersion: envelope.version,
            createdAt: envelope.createdAt
        )
    }

    /// Public metadata of every key file; never decrypts.
    public func inventory() throws -> [SigningKeyDescriptor] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        try checkDirectory()
        return try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
            .filter { $0.hasSuffix(".vkey") }
            .sorted()
            .compactMap { name in
                let keyID = String(name.dropLast(5))
                guard let envelope = try? readEnvelope(keyID: keyID), let bytes = try? readFile(keyID: keyID) else { return nil }
                return SigningKeyDescriptor(
                    keyID: keyID,
                    installationID: envelope.installationID,
                    algorithm: envelope.algorithm,
                    publicKeySHA256: envelope.publicKeySHA256,
                    ciphertextSHA256: Self.sha256(bytes),
                    envelopeVersion: envelope.version,
                    createdAt: envelope.createdAt
                )
            }
    }

    public func keyExists(keyID: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(keyID).path)
    }

    public func wrapperExists(installationID: UUID) throws -> Bool {
        try wrapping.read(installationID: installationID) != nil
    }

    /// Removes a key's ciphertext; removes the wrapping secret only when no key of the installation remains.
    public func retire(keyID: String, installationID: UUID) throws {
        try Self.validateKeyID(keyID)
        let url = fileURL(keyID)
        if FileManager.default.fileExists(atPath: url.path) {
            guard unlink(url.path) == 0 else { throw SigningKeyFailure.writeFailed }
            try syncDirectory()
        }
        if try inventory().allSatisfy({ $0.installationID != installationID }) {
            try wrapping.delete(installationID: installationID)
        }
    }

    // MARK: File handling

    private func fileURL(_ keyID: String) -> URL { rootURL.appendingPathComponent("\(keyID).vkey") }

    private static func validateKeyID(_ keyID: String) throws {
        guard UUID(uuidString: keyID) != nil, keyID == keyID.lowercased() else { throw SigningKeyFailure.corruptEnvelope }
    }

    private func readEnvelope(keyID: String) throws -> SigningKeyEnvelope {
        let bytes = try readFile(keyID: keyID)
        guard let envelope = try? Self.decoder().decode(SigningKeyEnvelope.self, from: bytes),
              envelope.magic == SigningKeyEnvelope.magic,
              envelope.version == SigningKeyEnvelope.currentVersion,
              envelope.keyID == keyID,
              envelope.algorithm == Self.algorithm,
              envelope.nonce.count == 12,
              envelope.tag.count == 16 else {
            throw SigningKeyFailure.corruptEnvelope
        }
        return envelope
    }

    private func readFile(keyID: String) throws -> Data {
        try Self.validateKeyID(keyID)
        try checkDirectory()
        let path = fileURL(keyID).path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw SigningKeyFailure.ciphertextMissing }
            throw SigningKeyFailure.unsafeFile
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_size < 64 * 1024 else {
            throw SigningKeyFailure.unsafeFile
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == Int(info.st_size) else { throw SigningKeyFailure.corruptEnvelope }
        return data
    }

    private func checkDirectory() throws {
        var info = stat()
        guard lstat(rootURL.path, &info) == 0 else { throw SigningKeyFailure.ciphertextMissing }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw SigningKeyFailure.unsafeFile
        }
    }

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw SigningKeyFailure.writeFailed
        }
        guard chmod(rootURL.path, 0o700) == 0 else { throw SigningKeyFailure.unsafeFile }
        try checkDirectory()
    }

    private func writeAtomically(_ data: Data, keyID: String) throws {
        try ensureDirectory()
        let temporary = rootURL.appendingPathComponent(".\(keyID).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SigningKeyFailure.writeFailed }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written == data.count, synced, rename(temporary.path, fileURL(keyID).path) == 0 else {
            unlink(temporary.path)
            throw SigningKeyFailure.writeFailed
        }
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let descriptor = open(rootURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SigningKeyFailure.writeFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw SigningKeyFailure.writeFailed }
    }

    // MARK: Crypto

    /// Transient, non-persistent SecKey used only for generation and the local probe; never stored.
    private static func generatePKCS1() throws -> [UInt8] {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw SigningKeyFailure.generationFailed
        }
        return Array(data)
    }

    private static func transientKey(pkcs1: [UInt8]) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
        ]
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, nil) else {
            throw SigningKeyFailure.corruptEnvelope
        }
        return key
    }

    static func publicKeySHA256(pkcs1: [UInt8]) throws -> String {
        let key = try transientKey(pkcs1: pkcs1)
        guard let publicKey = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw SigningKeyFailure.corruptEnvelope
        }
        guard SecKeyGetBlockSize(publicKey) * 8 == 2048 else { throw SigningKeyFailure.corruptEnvelope }
        return sha256(Data(RSAKeyDER.spki(pkcs1Public: Array(data))))
    }

    private static func signVerifyProbe(pkcs1: [UInt8]) throws {
        let key = try transientKey(pkcs1: pkcs1)
        let challenge = Data("veya-signing-key-probe".utf8) + Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, &error),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, signature, &error) else {
            throw SigningKeyFailure.probeFailed
        }
    }

    static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func zero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
