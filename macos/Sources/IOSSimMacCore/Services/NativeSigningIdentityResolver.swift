import CryptoKit
import Foundation
import Security

public struct NativeSigningIdentityDiagnostics: Equatable, Sendable {
    var profileCertificatePresent = false
    var keychainCertificateFound = false
    var keychainPrivateKeyFound = false
    var certificatePublicKeyMatch = false
    var keychainIdentityFound = false
    var secIdentityResolutionSucceeded = false
    var codesignIdentityVisible = false
    var codesignSignTestSucceeded = false
    var certificateQueryStatus: OSStatus?
    var privateKeyQueryStatus: OSStatus?
    var identityQueryStatus: OSStatus?
    var secIdentityResolutionStatus: OSStatus?
    var certificateFingerprint: String?
    var publicKeyFingerprint: String?
    var keyApplicationTagIdentifier: String?
    var certificateInserted = false
}

public struct NativeSigningIdentityResolution: Equatable, Sendable {
    public let certificateSHA1: String
    public let diagnostics: NativeSigningIdentityDiagnostics

    public init(certificateSHA1: String, diagnostics: NativeSigningIdentityDiagnostics) {
        self.certificateSHA1 = certificateSHA1
        self.diagnostics = diagnostics
    }
}

struct NativeSigningIdentityResolutionFailure: Error, Sendable {
    let failure: ConsumerProvisioningFailure
    let diagnostics: NativeSigningIdentityDiagnostics
}

public protocol NativeSigningIdentityResolving: Sendable {
    func resolve(
        certificateDER: Data,
        expectedSHA256: String,
        expectedKeyApplicationTagIdentifier: String?,
        teamIdentifier: String,
        workingDirectory: URL
    ) async throws -> NativeSigningIdentityResolution
}

final class NativeSigningIdentityResolver: NativeSigningIdentityResolving, @unchecked Sendable {
    private let runner: ProcessRunner
    private let fileManager: FileManager
    private let signingKeychain: VeyaSigningKeychain

    init(
        runner: ProcessRunner,
        fileManager: FileManager = .default,
        signingKeychain: VeyaSigningKeychain = VeyaSigningKeychain()
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.signingKeychain = signingKeychain
    }

    /// Restricts a Keychain query to the Veya signing Keychain -- the only
    /// place a key `/usr/bin/codesign` can actually use is stored.
    private func scoped(_ query: [String: Any]) -> [String: Any] {
        guard let keychain = try? signingKeychain.open() else { return query }
        var value = query
        value[kSecMatchSearchList as String] = [keychain] as CFArray
        return value
    }

    public func resolve(
        certificateDER: Data,
        expectedSHA256: String,
        expectedKeyApplicationTagIdentifier: String?,
        teamIdentifier: String,
        workingDirectory: URL
    ) async throws -> NativeSigningIdentityResolution {
        var diagnostics = NativeSigningIdentityDiagnostics()
        let expectedFingerprint = expectedSHA256.uppercased()
        diagnostics.certificateFingerprint = expectedFingerprint

        do {
            _ = try signingKeychain.open()
        } catch {
            throw resolutionFailure(
                .signingKeychainUnavailable,
                detail: "The IOSSim-owned signing Keychain could not be opened (\(error)).",
                diagnostics: diagnostics
            )
        }
        // codesign resolves identities through the user Keychain search list.
        signingKeychain.ensureInUserSearchList()

        guard !certificateDER.isEmpty,
              sha256Hex(certificateDER) == expectedFingerprint,
              let profileCertificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              certificateTeamIdentifiers(profileCertificate).contains(teamIdentifier) else {
            throw resolutionFailure(
                .profileCertificateMismatch,
                detail: "Prepared profile certificate DER does not match its recorded SHA-256 fingerprint.",
                diagnostics: diagnostics
            )
        }
        diagnostics.profileCertificatePresent = true

        var certificateLookup = findCertificate(sha256: expectedFingerprint)
        diagnostics.certificateQueryStatus = certificateLookup.status
        if certificateLookup.certificate == nil, certificateLookup.status == errSecItemNotFound {
            var addAttributes: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: profileCertificate,
                kSecAttrLabel as String: "IOSSim Apple Development \(teamIdentifier)",
                kSecAttrSynchronizable as String: false,
            ]
            if let keychain = try? signingKeychain.open() {
                addAttributes[kSecUseKeychain as String] = keychain
            }
            let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                diagnostics.certificateQueryStatus = addStatus
                throw resolutionFailure(
                    .signingCertificateNotFound,
                    detail: "The profile certificate could not be materialized in the IOSSim user Keychain (OSStatus \(addStatus)).",
                    diagnostics: diagnostics
                )
            }
            diagnostics.certificateInserted = addStatus == errSecSuccess
            certificateLookup = findCertificate(sha256: expectedFingerprint)
            diagnostics.certificateQueryStatus = certificateLookup.status
        }
        guard let keychainCertificate = certificateLookup.certificate else {
            throw resolutionFailure(
                isAccessDenied(certificateLookup.status) ? .signingIdentityAccessDenied : .signingCertificateNotFound,
                detail: "The prepared profile certificate is not readable from the IOSSim user Keychain (OSStatus \(certificateLookup.status)).",
                diagnostics: diagnostics
            )
        }
        diagnostics.keychainCertificateFound = true

        guard let certificatePublicKey = SecCertificateCopyKey(keychainCertificate),
              let certificatePublicBytes = externalPublicKeyBytes(certificatePublicKey) else {
            throw resolutionFailure(
                .profileCertificateMismatch,
                detail: "The prepared certificate public key could not be read.",
                diagnostics: diagnostics
            )
        }
        diagnostics.publicKeyFingerprint = sha256Hex(certificatePublicBytes)

        let keyLookup = findManagedPrivateKey(
            certificatePublicKey: certificatePublicKey,
            expectedApplicationTagIdentifier: expectedKeyApplicationTagIdentifier,
            teamIdentifier: teamIdentifier
        )
        diagnostics.privateKeyQueryStatus = keyLookup.status
        diagnostics.keyApplicationTagIdentifier = keyLookup.applicationTagIdentifier
        guard let privateKey = keyLookup.key else {
            throw resolutionFailure(
                isAccessDenied(keyLookup.status) ? .signingKeyAccessDenied : .signingPrivateKeyNotFound,
                detail: "No readable IOSSim-owned private key matches the prepared certificate (OSStatus \(keyLookup.status)).",
                diagnostics: diagnostics
            )
        }
        diagnostics.keychainPrivateKeyFound = true

        guard let privatePublicKey = SecKeyCopyPublicKey(privateKey),
              let privatePublicBytes = externalPublicKeyBytes(privatePublicKey),
              secureEqual(certificatePublicBytes, privatePublicBytes) else {
            throw resolutionFailure(
                .signingCertificateKeyMismatch,
                detail: "The prepared certificate public key does not match the IOSSim-owned private key.",
                diagnostics: diagnostics
            )
        }
        diagnostics.certificatePublicKeyMatch = true

        let identityLookup = findIdentity(sha256: expectedFingerprint)
        diagnostics.identityQueryStatus = identityLookup.status
        diagnostics.keychainIdentityFound = identityLookup.identity != nil

        var resolvedIdentity: SecIdentity?
        let identitySearchScope = (try? signingKeychain.open()).map { $0 as CFTypeRef }
        let resolutionStatus = SecIdentityCreateWithCertificate(
            identitySearchScope,
            keychainCertificate,
            &resolvedIdentity
        )
        diagnostics.secIdentityResolutionStatus = resolutionStatus
        guard resolutionStatus == errSecSuccess, let resolvedIdentity else {
            throw resolutionFailure(
                isAccessDenied(resolutionStatus) ? .signingIdentityAccessDenied : .signingIdentityNotFound,
                detail: "Security.framework could not associate the prepared certificate with its private key (OSStatus \(resolutionStatus)).",
                diagnostics: diagnostics
            )
        }
        diagnostics.secIdentityResolutionSucceeded = true

        var identityPrivateKey: SecKey?
        let identityKeyStatus = SecIdentityCopyPrivateKey(resolvedIdentity, &identityPrivateKey)
        guard identityKeyStatus == errSecSuccess, identityPrivateKey != nil else {
            throw resolutionFailure(
                isAccessDenied(identityKeyStatus) ? .signingIdentityAccessDenied : .signingIdentityNotFound,
                detail: "Security.framework resolved an identity but could not access its private key (OSStatus \(identityKeyStatus)).",
                diagnostics: diagnostics
            )
        }

        let sha1 = Insecure.SHA1.hash(data: certificateDER).map { String(format: "%02X", $0) }.joined()
        let visibility = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            workingDirectory: workingDirectory,
            environment: RuntimeProvisioning.deterministicEnvironment(),
            redactOutput: false
        )
        diagnostics.codesignIdentityVisible = visibility.exitCode == 0
            && visibility.combinedOutput.uppercased().contains(sha1)

        let probeURL = fileManager.temporaryDirectory
            .appendingPathComponent("iossim-codesign-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: probeURL) }
        let appURL = probeURL.appendingPathComponent("IOSSimIdentityProbe.app", isDirectory: true)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.iossim.signing-identity-probe",
            "CFBundleExecutable": "IOSSimIdentityProbe",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try infoData.write(to: appURL.appendingPathComponent("Info.plist"), options: .atomic)
        try fileManager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: appURL.appendingPathComponent("IOSSimIdentityProbe")
        )
        let sign = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", sha1, "--timestamp=none", appURL.path],
            workingDirectory: probeURL,
            environment: RuntimeProvisioning.deterministicEnvironment(),
            redactOutput: false
        )
        guard sign.exitCode == 0 else {
            throw resolutionFailure(
                codesignAccessDenied(sign.combinedOutput) ? .signingKeyAccessDenied : .signingProbeFailed,
                detail: "The IOSSim-owned identity was visible but the codesign probe failed (process exit \(sign.exitCode)): \(Redactor.redact(sign.combinedOutput))",
                diagnostics: diagnostics
            )
        }
        let verify = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", appURL.path],
            workingDirectory: probeURL,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        diagnostics.codesignSignTestSucceeded = verify.exitCode == 0
        guard diagnostics.codesignSignTestSucceeded else {
            throw resolutionFailure(
                .signatureVerificationFailed,
                detail: "The disposable codesign probe could not be verified (process exit \(verify.exitCode)).",
                diagnostics: diagnostics
            )
        }
        return NativeSigningIdentityResolution(certificateSHA1: sha1, diagnostics: diagnostics)
    }

    private func findCertificate(sha256: String) -> (certificate: SecCertificate?, status: OSStatus) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(scoped([
            kSecClass as String: kSecClassCertificate,
            kSecAttrSynchronizable as String: false,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]) as CFDictionary, &result)
        guard status == errSecSuccess, let certificates = result as? [SecCertificate] else {
            return (nil, status)
        }
        return (certificates.first { sha256Hex(SecCertificateCopyData($0) as Data) == sha256 },
                certificates.contains(where: { sha256Hex(SecCertificateCopyData($0) as Data) == sha256 }) ? errSecSuccess : errSecItemNotFound)
    }

    private func findManagedPrivateKey(
        certificatePublicKey: SecKey,
        expectedApplicationTagIdentifier: String?,
        teamIdentifier: String
    ) -> (key: SecKey?, applicationTagIdentifier: String?, status: OSStatus) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable as String: false,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let expectedApplicationTagIdentifier {
            query[kSecAttrApplicationTag as String] = Data(expectedApplicationTagIdentifier.utf8)
        } else if let attributes = SecKeyCopyAttributes(certificatePublicKey) as? [String: Any],
                  let applicationLabel = attributes[kSecAttrApplicationLabel as String] as? Data {
            query[kSecAttrApplicationLabel as String] = applicationLabel
        } else {
            return (nil, nil, errSecParam)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(scoped(query) as CFDictionary, &result)
        guard status == errSecSuccess else {
            return (nil, expectedApplicationTagIdentifier, status)
        }
        let dictionaries: [[String: Any]]
        if let values = result as? [[String: Any]] {
            dictionaries = values
        } else if let value = result as? [String: Any] {
            dictionaries = [value]
        } else {
            return (nil, expectedApplicationTagIdentifier, errSecItemNotFound)
        }
        for dictionary in dictionaries {
            guard let tagData = dictionary[kSecAttrApplicationTag as String] as? Data,
                  let tag = canonicalManagedKeyTag(tagData, teamIdentifier: teamIdentifier),
                  let key = dictionary[kSecValueRef as String] as! SecKey? else { continue }
            return (key, tag, errSecSuccess)
        }
        return (nil, expectedApplicationTagIdentifier, errSecItemNotFound)
    }

    private func findIdentity(sha256: String) -> (identity: SecIdentity?, status: OSStatus) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(scoped([
            kSecClass as String: kSecClassIdentity,
            kSecAttrSynchronizable as String: false,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]) as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            return (nil, status)
        }
        let identity = identities.first { identity in
            var certificate: SecCertificate?
            return SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess
                && certificate.map { sha256Hex(SecCertificateCopyData($0) as Data) == sha256 } == true
        }
        return (identity, identity == nil ? errSecItemNotFound : errSecSuccess)
    }

    private func externalPublicKeyBytes(_ key: SecKey) -> Data? {
        SecKeyCopyExternalRepresentation(key, nil) as Data?
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private func isAccessDenied(_ status: OSStatus) -> Bool {
        [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNotAvailable].contains(status)
    }

    private func codesignAccessDenied(_ output: String) -> Bool {
        let value = output.lowercased()
        return ["errsecinternalcomponent", "interaction is not allowed", "user canceled", "authorization denied"]
            .contains(where: value.contains)
    }

    private func secureEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    private func resolutionFailure(
        _ code: ConsumerProvisioningErrorCode,
        detail: String,
        diagnostics: NativeSigningIdentityDiagnostics
    ) -> NativeSigningIdentityResolutionFailure {
        NativeSigningIdentityResolutionFailure(
            failure: ConsumerProvisioningFailure(
                code: code,
                stage: .preparingIdentities,
                userMessage: "IOSSim could not use its managed signing identity.",
                remediation: "Try again. IOSSim will repair access to its own signing key automatically; Apple authorization remains valid.",
                developerDetail: detail
            ),
            diagnostics: diagnostics
        )
    }
}
