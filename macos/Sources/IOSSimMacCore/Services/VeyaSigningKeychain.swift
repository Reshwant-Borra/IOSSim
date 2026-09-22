import Foundation
import Darwin
import Security

/// The Keychain that holds the signing key IOSSim/Veya generates for the
/// consumer's Personal Team, plus the Apple-issued certificate that matches it.
///
/// Why this is not the login Keychain
/// ----------------------------------
/// `securityd` stamps every key stored in the login Keychain with a partition
/// list derived from the *creating process's* code identity. A packaged Veya
/// build is not an Apple-signed binary, so its keys are stamped
/// `Partitions = [cdhash:<Veya's own cdhash>]`. `/usr/bin/codesign` — which is
/// the process that actually consumes the key when payloads are signed — can
/// never match that partition, so every signing attempt raises a SecurityAgent
/// dialog and fails when it is not answered.
///
/// The partition list is not repairable in-process: rewriting it requires the
/// login Keychain password (`SecKeychainItemSetAccess` returns
/// `errSecAuthFailed`), which a consumer installer must not ask for. A trusted
/// application ACL does not help either — a login-Keychain key whose ACL trusts
/// *every* application still prompts, because the partition list is checked
/// independently of the ACL.
///
/// Keys created in a Keychain that Veya itself creates receive **no** partition
/// ACL, so the trusted-application ACL alone governs access. Listing
/// `/usr/bin/codesign` there lets signing proceed with no dialog and without
/// widening access to anything else on the Mac.
///
/// See `docs/installation-v2/implementation/physical-validation/` for the
/// reproduction that establishes each of those statements.
struct VeyaSigningKeychain {
    enum Failure: Error, Equatable {
        case unavailable(OSStatus)
        case passwordUnavailable
        case partitionRepairFailed(Int32)
    }

    static let keychainFileName = "Veya-Signing.keychain-db"
    static let passwordFileName = "signing-keychain.secret"

    private let keychainURL: URL
    private let passwordURL: URL
    private let fileManager: FileManager

    init(
        keychainURL: URL? = nil,
        passwordURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.keychainURL = keychainURL ?? home
            .appendingPathComponent("Library/Keychains", isDirectory: true)
            .appendingPathComponent(Self.keychainFileName)
        self.passwordURL = passwordURL ?? home
            .appendingPathComponent("Library/Application Support/IOSSim", isDirectory: true)
            .appendingPathComponent(Self.passwordFileName)
        self.fileManager = fileManager
    }

    var path: String { keychainURL.path }

    /// Opens the Veya signing Keychain, creating it on first use, and leaves it
    /// unlocked for the lifetime of the login session.
    ///
    /// Unlocking with the stored password is silent, so this never puts a
    /// dialog in front of the consumer. Note that user interaction must stay
    /// *enabled* while this runs: with it disabled, `SecKeyCreateRandomKey`
    /// into a freshly created Keychain fails outright with -128
    /// `userCanceledErr`.
    func open() throws -> SecKeychain {
        let password = try password()
        var keychain: SecKeychain?
        var status = SecKeychainOpen(keychainURL.path, &keychain)
        if status == errSecSuccess, let existing = keychain, fileManager.fileExists(atPath: keychainURL.path) {
            try unlock(existing, password: password)
            return existing
        }
        keychain = nil
        status = password.withCString { pointer in
            SecKeychainCreate(
                keychainURL.path,
                UInt32(strlen(pointer)),
                pointer,
                false, // never prompt the consumer for a Keychain password
                nil,
                &keychain
            )
        }
        if status == errSecDuplicateKeychain {
            var existing: SecKeychain?
            guard SecKeychainOpen(keychainURL.path, &existing) == errSecSuccess, let existing else {
                throw Failure.unavailable(status)
            }
            try unlock(existing, password: password)
            return existing
        }
        guard status == errSecSuccess, let created = keychain else { throw Failure.unavailable(status) }
        try unlock(created, password: password)
        return created
    }

    /// `/usr/bin/codesign` resolves signing identities through the user's
    /// Keychain search list, so the Veya Keychain has to appear there. The
    /// existing entries are always preserved — this only ever appends.
    @discardableResult
    func ensureInUserSearchList() -> OSStatus {
        var current: CFArray?
        let status = SecKeychainCopySearchList(&current)
        guard status == errSecSuccess, let existing = current as? [SecKeychain] else { return status }
        let alreadyListed = existing.contains { keychain in
            var pathLength = UInt32(PATH_MAX)
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard SecKeychainGetPath(keychain, &pathLength, &buffer) == errSecSuccess else { return false }
            return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
                == keychainURL.standardizedFileURL
        }
        guard !alreadyListed else { return errSecSuccess }
        guard let keychain = try? open() else { return errSecNoSuchKeychain }
        return SecKeychainSetSearchList((existing + [keychain]) as CFArray)
    }

    private func unlock(_ keychain: SecKeychain, password: String) throws {
        var status = password.withCString { pointer in
            SecKeychainUnlock(keychain, UInt32(strlen(pointer)), pointer, true)
        }
        if status == errSecSuccess { return }
        // An already-unlocked Keychain reports success; anything else is fatal
        // except the benign "no such keychain" that a stale password file can
        // produce, which the caller recovers from by recreating the Keychain.
        var settings = SecKeychainStatus()
        if SecKeychainGetStatus(keychain, &settings) == errSecSuccess,
           settings & SecKeychainStatus(kSecUnlockStateStatus) != 0 {
            status = errSecSuccess
        }
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
    }

    /// The password protecting the Veya signing Keychain. It is generated once,
    /// per installation, from the system CSPRNG and stored 0600 in Veya's own
    /// Application Support directory.
    ///
    /// It deliberately does not live in the login Keychain: reading it back
    /// from a differently-signed Veya executable would hit the very partition
    /// check this type exists to avoid. The material it protects is a
    /// seven-day Apple Development Personal Team key scoped to this user's own
    /// devices, and the file sits inside the user's home directory under the
    /// same ownership boundary that protects the login Keychain itself.
    func password() throws -> String {
        if let existing = try? Data(contentsOf: passwordURL),
           let password = String(data: existing, encoding: .utf8),
           !password.isEmpty {
            return password
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.passwordUnavailable
        }
        let password = Data(bytes).base64EncodedString()
        try fileManager.createDirectory(
            at: passwordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(password.utf8).write(to: passwordURL, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)
        return password
    }

    /// Gives Apple's own signing tools a partition they can actually satisfy.
    ///
    /// A Veya-created Keychain is still a Keychain: on current macOS releases,
    /// private keys created by an ad-hoc packaged app can receive a
    /// `cdhash:<Veya>` partition ACL even outside the login Keychain. A trusted
    /// application ACL that names `/usr/bin/codesign` is not enough in that
    /// state; `codesign` fails with `errSecInternalComponent` before the ACL is
    /// considered. The login Keychain variant is not repairable without the
    /// user's login password, but this Keychain is Veya-owned and protected by
    /// Veya's own generated secret, so Veya can safely repair only its managed
    /// keys.
    ///
    /// The secret is passed over stdin, never in argv or the environment.
    func authorizeAppleSigningToolPartitions(label: String) throws {
        _ = try open()
        ensureInUserSearchList()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "set-key-partition-list",
            "-S", "apple-tool:,apple:,codesign:",
            "-s",
            "-l", label,
            keychainURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input.fileHandleForReading
        do {
            try process.run()
            let secret = try password()
            var bytes = Data(secret.utf8)
            bytes.append(0x0A)
            input.fileHandleForWriting.write(bytes)
            try? input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            throw Failure.partitionRepairFailed(-1)
        }

        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw Failure.partitionRepairFailed(124)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.partitionRepairFailed(process.terminationStatus)
        }
    }
}
