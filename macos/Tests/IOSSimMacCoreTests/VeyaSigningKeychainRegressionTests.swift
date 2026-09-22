import CryptoKit
import Foundation
import Security
import XCTest
@testable import IOSSimMacCore

/// Regression coverage for PHYSICAL_DEFECT_001 — clean-Mac
/// `SIGNING_KEY_ACCESS_DENIED`.
///
/// The physical defect had two independent causes, and the pre-existing suite
/// could not see either one:
///
/// 1. `SecKeyCreateRandomKey` silently discards a `kSecAttrAccess` placed
///    inside `kSecPrivateKeyAttrs`, so the signing key was created with the
///    default ACL that trusts only its creating process.
/// 2. Far more decisively, `securityd` stamps every login-Keychain key created
///    by a non-Apple-signed process with `Partitions = [cdhash:<creator>]`.
///    `/usr/bin/codesign` can never match that partition, and the partition
///    list cannot be rewritten without the login Keychain password. A
///    login-Keychain key is therefore unusable by codesign *no matter what its
///    ACL says* — proved by
///    `testLoginKeychainKeyCreatedByAPackagedHelperIsBlockedByItsPartitionList`.
///
/// Classification of the tests below:
///
/// * `UNIT` — pure attribute-shape assertions, no Keychain writes.
/// * `LOCAL_SYSTEM` — real Keychain writes, real `SecAccess`, real
///   `/usr/bin/codesign`. Gated behind `IOSSIM_RUN_KEYCHAIN_INTEGRATION=1`
///   because they mutate the login Keychain of whoever runs them, and are run
///   by the signing qualification gate rather than by plain `swift test`.
///
/// Every key and certificate these tests create carries a per-run UUID in its
/// tag and label and is deleted before the helper returns. Nothing pre-existing
/// is read, modified or deleted.
final class VeyaSigningKeychainRegressionTests: XCTestCase {

    // MARK: - UNIT

    /// `kSecAttrAccess` must sit at the top level of the key-creation
    /// attributes. Nested inside `kSecPrivateKeyAttrs` it is silently dropped,
    /// which is how the shipped build lost its ACL entirely.
    func testSigningKeyAttributesCarryAccessAtTheTopLevelAndTargetTheVeyaKeychain() throws {
        let attributes = try signingKeyAttributeShape()
        XCTAssertNotNil(
            attributes[kSecAttrAccess as String],
            "kSecAttrAccess must be top level; SecKeyCreateRandomKey ignores it inside kSecPrivateKeyAttrs"
        )
        let privateAttributes = try XCTUnwrap(attributes[kSecPrivateKeyAttrs as String] as? [String: Any])
        XCTAssertNil(
            privateAttributes[kSecAttrAccess as String],
            "kSecAttrAccess inside kSecPrivateKeyAttrs is discarded and must not be relied on"
        )
        XCTAssertNotNil(
            attributes[kSecUseKeychain as String],
            "The key must be given an explicit Keychain destination, never an implicit default"
        )
        XCTAssertEqual(privateAttributes[kSecAttrIsPermanent as String] as? Bool, true)
        XCTAssertEqual(privateAttributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    /// Least privilege: exactly the executables that need the key, and nothing
    /// else. `/usr/bin/codesign` is the process that actually uses it.
    func testSigningAccessPolicyGrantsOnlyCodesignAndThePackagedVeyaExecutables() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("veya-signing-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Veya.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        for name in ["IOSSim", "IOSSimProvisioner"] {
            let url = macOS.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let policy = IOSSimSigningKeyAccessPolicy(bundleURL: bundle, bundleExecutableName: "IOSSim")

        XCTAssertEqual(policy.trustedExecutablePaths, [
            "/usr/bin/codesign",
            macOS.appendingPathComponent("IOSSim").path,
            macOS.appendingPathComponent("IOSSimProvisioner").path,
        ])
    }

    /// The Keychain password must never be committed, derived from a constant,
    /// or left world-readable.
    func testSigningKeychainPasswordIsRandomPerInstallationAndStoredPrivately() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("veya-keychain-password-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let passwordURL = root.appendingPathComponent("signing-keychain.secret")
        let keychain = VeyaSigningKeychain(
            keychainURL: root.appendingPathComponent("Unused.keychain-db"),
            passwordURL: passwordURL
        )

        let first = try keychain.password()
        XCTAssertGreaterThanOrEqual(first.count, 32)
        XCTAssertEqual(first, try keychain.password(), "The password must be stable across calls")

        let other = VeyaSigningKeychain(
            keychainURL: root.appendingPathComponent("Unused2.keychain-db"),
            passwordURL: root.appendingPathComponent("other.secret")
        )
        XCTAssertNotEqual(first, try other.password(), "Each installation must generate its own password")

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: passwordURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.int16Value & 0o777, 0o600)
    }

    // MARK: - LOCAL_SYSTEM
    //
    // These drive `IOSSimSigningKeyTestHelper`, a separate ad-hoc-signed
    // executable, instead of doing the work inline. That is the whole point of
    // the gate: `xctest` is Apple-signed, so keys it creates in the login
    // Keychain receive a partition `/usr/bin/codesign` can match and the defect
    // disappears. Only a process signed the way the packaged Veya helper is
    // reproduces the consumer's authorization conditions.

    /// The fix. A key created through the production path in the Veya-owned
    /// Keychain must carry a codesign-compatible Apple partition and be
    /// signable by real `/usr/bin/codesign` with no prompt.
    func testPackagedHelperCreatedKeyIsSignableByRealCodesignWithoutAnyPrompt() throws {
        try requireLocalSystemTests()
        let result = try runQualificationHelper(destination: "veya")
        XCTAssertEqual(
            result.exitCode, 0,
            "Veya-owned Keychain key must sign without a prompt. Helper output: \(result.output)"
        )
        XCTAssertFalse(
            result.output.contains("partition list: cdhash:"),
            "The fixed Veya-owned Keychain path must not leave a cdhash-only partition. Helper output: \(result.output)"
        )
        XCTAssertTrue(result.output.contains("codesign signed with no prompt"))
    }

    /// Upgrade/retry repair must heal an already-created Veya-owned key without
    /// prompting for the login-Keychain password.
    func testVeyaOwnedKeyRepairPathIsIdempotentAndSignsWithRealCodesign() throws {
        try requireLocalSystemTests()
        let result = try runQualificationHelper(destination: "veya-poisoned-repaired")
        XCTAssertEqual(
            result.exitCode, 0,
            "A Veya-owned key must be repairable with Veya's own Keychain password. Helper output: \(result.output)"
        )
        XCTAssertTrue(result.output.contains("codesign signed with no prompt"))
        XCTAssertFalse(
            result.output.contains("partition list: cdhash:"),
            "The production repair path must not leave a cdhash-only partition. Helper output: \(result.output)"
        )
    }

    /// Repair and replacement must never touch anything Veya does not own.
    func testSigningQualificationLeavesTheUserKeychainSearchListIntact() throws {
        try requireLocalSystemTests()
        let before = try userKeychainSearchList()
        _ = try runQualificationHelper(destination: "veya")
        XCTAssertEqual(
            try userKeychainSearchList(), before,
            "The qualification must restore the user's Keychain search list exactly"
        )
    }

    // MARK: - Helpers

    private func requireLocalSystemTests() throws {
        guard ProcessInfo.processInfo.environment["IOSSIM_RUN_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("LOCAL_SYSTEM: set IOSSIM_RUN_KEYCHAIN_INTEGRATION=1 to run real Keychain/codesign tests.")
        }
    }

    private func runQualificationHelper(destination: String) throws -> (exitCode: Int32, output: String) {
        let helper = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("IOSSimSigningKeyTestHelper", isDirectory: false)
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: helper.path),
            "IOSSimSigningKeyTestHelper must be built for this regression."
        )
        let process = Process()
        process.executableURL = helper
        process.arguments = ["qualify-signing", destination]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        var output = Data()
        let queue = DispatchQueue(label: "qualification.io")
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        process.waitUntilExit()
        _ = finished.wait(timeout: .now() + 30)
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private func userKeychainSearchList() throws -> [String] {
        var list: CFArray?
        guard SecKeychainCopySearchList(&list) == errSecSuccess,
              let keychains = list as? [SecKeychain] else { return [] }
        return keychains.compactMap { keychain in
            var length = UInt32(PATH_MAX)
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return nil }
            return String(cString: buffer)
        }
    }

    /// Mirrors the attribute dictionary `IOSSimIdentityMetadataStore.createPrivateKey`
    /// builds, without writing anything to a Keychain.
    private func signingKeyAttributeShape() throws -> [String: Any] {
        var access: SecAccess?
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess, let trusted,
              SecAccessCreate("probe" as CFString, [trusted] as CFArray, &access) == errSecSuccess,
              let access else {
            throw XCTSkip("SecAccess is unavailable in this environment.")
        }
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else {
            throw XCTSkip("No default Keychain in this environment.")
        }
        return [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
            kSecUseKeychain as String: keychain,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data("probe".utf8),
                kSecAttrLabel as String: "probe",
                kSecAttrSynchronizable as String: false,
            ],
            kSecAttrAccess as String: access,
        ]
    }
}
