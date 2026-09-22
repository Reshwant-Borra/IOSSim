import CryptoKit
import Foundation
import Security

/// The clean-consumer signing qualification for PHYSICAL_DEFECT_001.
///
/// This deliberately lives in a library rather than in a test, because **it
/// cannot prove anything when it runs inside `xctest`**. `xctest` is an
/// Apple-signed binary, so `securityd` stamps keys it creates in the login
/// Keychain with a partition `/usr/bin/codesign` is able to match. A packaged
/// Veya build is not Apple-signed, so its login-Keychain keys are stamped
/// `cdhash:<Veya>`, which codesign can never match. The same can happen in a
/// Veya-created Keychain on current macOS unless Veya explicitly rewrites the
/// partition list using its own generated Keychain password. That difference
/// in *process identity between the test runner and the shipped binary* is why
/// a green suite coexisted with a clean-Mac failure.
///
/// Running this from `IOSSimSigningKeyTestHelper` — an ordinary ad-hoc-signed
/// SwiftPM executable, signed the way the packaged helper is — reproduces the
/// consumer's authorization conditions faithfully.
public enum VeyaSigningQualification {
    public enum Outcome: Int32 {
        case signedWithoutPrompt = 0
        case blockedOnKeychainPrompt = 3
        case setupFailed = 4
    }

    public enum Destination: String {
        /// The fix: the Veya-owned Keychain.
        case veyaKeychain = "veya"
        /// A Veya-owned Keychain key deliberately forced into the live failure
        /// shape: a partition list `codesign` cannot satisfy.
        case veyaKeychainPoisoned = "veya-poisoned"
        /// The same poisoned Veya-owned key, then repaired through the
        /// production ACL/partition path.
        case veyaKeychainPoisonedRepaired = "veya-poisoned-repaired"
        /// The shipped-and-broken behaviour, kept so the gate can demonstrate
        /// that it actually discriminates.
        case loginKeychain = "login"
    }

    /// Creates a signing key the way production does, issues a code-signing
    /// certificate for it from a throwaway CA, and proves whether real
    /// `/usr/bin/codesign` can use it without a Keychain dialog.
    ///
    /// Everything it creates is tagged with `runIdentifier` and removed before
    /// returning. Nothing pre-existing is read, modified or deleted, and no key
    /// material is written anywhere.
    public static func run(
        destination: Destination,
        runIdentifier: String = UUID().uuidString.uppercased(),
        log: (String) -> Void = { _ in }
    ) -> Outcome {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("veya-signing-qualification-\(runIdentifier)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        guard (try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
            return .setupFailed
        }

        let service = "com.iossim.qualification.\(runIdentifier)"
        let keyLabel = "Veya Signing Qualification \(runIdentifier)"
        let tag = Data("com.iossim.personal-team.QL\(runIdentifier.prefix(8)).\(runIdentifier)".utf8)
        let signingKeychain = VeyaSigningKeychain(
            keychainURL: root.appendingPathComponent("Veya-Signing-\(runIdentifier).keychain-db"),
            passwordURL: root.appendingPathComponent("signing-keychain.secret")
        )
        var ownedKeychain: SecKeychain?
        var ownedStore: IOSSimIdentityMetadataStore?

        let key: SecKey
        switch destination {
        case .veyaKeychain, .veyaKeychainPoisoned, .veyaKeychainPoisonedRepaired:
            let store = IOSSimIdentityMetadataStore(
                service: service,
                keyLabel: keyLabel,
                signingKeychain: signingKeychain
            )
            ownedStore = store
            guard let created = try? store.createPrivateKey(applicationTag: tag) else {
                log("key creation failed")
                return .setupFailed
            }
            key = created
            ownedKeychain = try? signingKeychain.open()
        case .loginKeychain:
            guard let created = createLoginKeychainKey(tag: tag, label: keyLabel) else {
                log("login-Keychain key creation failed")
                return .setupFailed
            }
            key = created
        }
        defer {
            var keyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
            ]
            if let ownedKeychain { keyQuery[kSecMatchSearchList as String] = [ownedKeychain] as CFArray }
            _ = SecItemDelete(keyQuery as CFDictionary)
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
            for label in [keyLabel, "Veya Qualification CA \(runIdentifier)"] {
                _ = SecItemDelete([
                    kSecClass as String: kSecClassCertificate,
                    kSecAttrLabel as String: label,
                ] as CFDictionary)
            }
            if let ownedKeychain {
                removeFromSearchList(matching: "Veya-Signing-\(runIdentifier)")
                _ = SecKeychainDelete(ownedKeychain)
            }
        }

        guard let certificate = issueCertificate(for: key, in: root, runIdentifier: runIdentifier) else {
            log("certificate issuance failed")
            return .setupFailed
        }
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: keyLabel,
        ]
        if let ownedKeychain { attributes[kSecUseKeychain as String] = ownedKeychain }
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            log("certificate could not be stored (OSStatus \(addStatus))")
            return .setupFailed
        }
        // codesign builds the chain through the login Keychain, so the
        // throwaway CA goes there regardless of where the leaf lives.
        if let caDER = try? Data(contentsOf: root.appendingPathComponent("ca.der")),
           let caCertificate = SecCertificateCreateWithData(nil, caDER as CFData) {
            _ = SecItemAdd([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: caCertificate,
                kSecAttrLabel as String: "Veya Qualification CA \(runIdentifier)",
            ] as CFDictionary, nil)
        }
        if ownedKeychain != nil { signingKeychain.ensureInUserSearchList() }

        if destination == .veyaKeychainPoisoned || destination == .veyaKeychainPoisonedRepaired {
            guard setPartitionList(
                ["cdhash:0000000000000000000000000000000000000000"],
                label: keyLabel,
                signingKeychain: signingKeychain,
                log: log
            ) else {
                log("partition poisoning failed")
                return .setupFailed
            }
            log("poisoned partition list: \(partitionListDescription(tag: tag, keychain: ownedKeychain))")
        }
        if destination == .veyaKeychainPoisonedRepaired {
            do {
                try ownedStore?.authorizePrivateKeyForSigning(applicationTag: tag)
            } catch {
                log("partition repair failed: \(Redactor.redact(String(describing: error)))")
                return .setupFailed
            }
        }

        log("partition list: \(partitionListDescription(tag: tag, keychain: ownedKeychain))")
        return codesignProbe(certificate: certificate, in: root, log: log)
    }

    // MARK: - Key creation

    /// Mirrors the *shipped* behaviour: an explicit login-Keychain destination
    /// with an ACL that trusts the creating process and `/usr/bin/codesign`.
    private static func createLoginKeychainKey(tag: Data, label: String) -> SecKey? {
        var current: SecTrustedApplication?
        var codesign: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &current) == errSecSuccess, let current,
              SecTrustedApplicationCreateFromPath(
                IOSSimSigningKeyAccessPolicy.codesignPath, &codesign
              ) == errSecSuccess, let codesign else { return nil }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, [current, codesign] as CFArray, &access) == errSecSuccess,
              let access else { return nil }
        var login: SecKeychain?
        guard SecKeychainCopyDefault(&login) == errSecSuccess, let login else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
            kSecUseKeychain as String: login,
            kSecAttrAccess as String: access,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrLabel as String: label,
                kSecAttrSynchronizable as String: false,
            ],
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    }

    // MARK: - Certificate

    private static func issueCertificate(for key: SecKey, in root: URL, runIdentifier: String) -> SecCertificate? {
        let caKey = root.appendingPathComponent("ca.key")
        let caPEM = root.appendingPathComponent("ca.pem")
        let caDER = root.appendingPathComponent("ca.der")
        let csrURL = root.appendingPathComponent("leaf.csr")
        let leafDER = root.appendingPathComponent("leaf.der")
        let extensions = root.appendingPathComponent("ext.cnf")
        do {
            try Data("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\n".utf8)
                .write(to: extensions)
            guard openssl([
                "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", caKey.path, "-out", caPEM.path, "-days", "1",
                "-subj", "/C=US/O=Veya Qualification CA/CN=Veya Qualification CA \(runIdentifier)",
            ], in: root),
                openssl(["x509", "-in", caPEM.path, "-outform", "DER", "-out", caDER.path], in: root) else {
                return nil
            }
            let request = try createCertificateSigningRequest(key: key, teamIdentifier: "QUALIFY")
                .replacingOccurrences(
                    of: "-----END CERTIFICATE REQUEST-----",
                    with: "\n-----END CERTIFICATE REQUEST-----"
                )
            try Data(request.utf8).write(to: csrURL)
            guard openssl([
                "x509", "-req", "-in", csrURL.path, "-CA", caPEM.path, "-CAkey", caKey.path,
                "-CAcreateserial", "-outform", "DER", "-out", leafDER.path, "-days", "1",
                "-extfile", extensions.path,
            ], in: root) else { return nil }
            return SecCertificateCreateWithData(nil, try Data(contentsOf: leafDER) as CFData)
        } catch {
            return nil
        }
    }

    private static func openssl(_ arguments: [String], in directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Probe

    /// A codesign child that has to be timed out is one that raised a
    /// SecurityAgent dialog, i.e. it was not authorized for the key.
    private static func codesignProbe(
        certificate: SecCertificate,
        in root: URL,
        log: (String) -> Void
    ) -> Outcome {
        let app = root.appendingPathComponent("VeyaQualificationProbe.app", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": "com.iossim.signing-qualification-probe",
                    "CFBundleExecutable": "VeyaQualificationProbe",
                    "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1",
                ] as [String: Any],
                format: .binary,
                options: 0
            ).write(to: app.appendingPathComponent("Info.plist"))
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: app.appendingPathComponent("VeyaQualificationProbe")
            )
        } catch {
            return .setupFailed
        }

        let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }.joined()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: IOSSimSigningKeyAccessPolicy.codesignPath)
        process.arguments = ["--force", "--sign", sha1, "--timestamp=none", app.path]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return .setupFailed }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning {
            process.terminate()
            usleep(300_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            log("codesign blocked on a SecurityAgent prompt")
            return .blockedOnKeychainPrompt
        }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            log("codesign failed: \(Redactor.redact(output))")
            return .blockedOnKeychainPrompt
        }
        log("codesign signed with no prompt")
        return .signedWithoutPrompt
    }

    // MARK: - Inspection

    private static func partitionListDescription(tag: Data, keychain: SecKeychain?) -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] as CFArray }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let reference = result as? Data else { return "<no key>" }
        var item: SecKeychainItem?
        guard SecKeychainItemCopyFromPersistentReference(reference as CFData, &item) == errSecSuccess,
              let item else { return "<not a legacy Keychain item>" }
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return "<no access>" }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess,
              let acls = list as? [SecACL] else { return "<no ACLs>" }
        for acl in acls {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard authorizations.contains(kSecACLAuthorizationPartitionID as String) else { continue }
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            _ = SecACLCopyContents(acl, &apps, &description, &prompt)
            let hex = (description as String?) ?? ""
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex,
                  let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
                bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
                index = next
            }
            let plist = String(decoding: bytes, as: UTF8.self)
            return plist.components(separatedBy: "<string>").dropFirst()
                .compactMap { $0.components(separatedBy: "</string>").first }
                .joined(separator: ",")
        }
        return "<none>"
    }

    private static func setPartitionList(
        _ partitions: [String],
        label: String,
        signingKeychain: VeyaSigningKeychain,
        log: (String) -> Void
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "set-key-partition-list",
            "-S", partitions.joined(separator: ","),
            "-s",
            "-l", label,
            signingKeychain.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let input = Pipe()
        process.standardInput = input.fileHandleForReading
        do {
            try process.run()
            let password = try signingKeychain.password()
            var data = Data(password.utf8)
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            log("set partition list launch failed: \(Redactor.redact(String(describing: error)))")
            return false
        }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning {
            process.terminate()
            usleep(300_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            log("set partition list failed: \(Redactor.redact(output))")
        }
        return process.terminationStatus == 0
    }

    private static func removeFromSearchList(matching fragment: String) {
        var current: CFArray?
        guard SecKeychainCopySearchList(&current) == errSecSuccess,
              let existing = current as? [SecKeychain] else { return }
        let remaining = existing.filter { keychain in
            var length = UInt32(PATH_MAX)
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return true }
            return !String(cString: buffer).contains(fragment)
        }
        guard remaining.count != existing.count else { return }
        _ = SecKeychainSetSearchList(remaining as CFArray)
    }
}
