import CryptoKit
import Foundation
@testable import IOSSimMacCore
import Security
import XCTest

/// M4: real key store against the real login Keychain (ADR-001 backend for ad-hoc builds), isolated by
/// a test-only service name and random installation IDs. These tests are mandatory, never skipped.
final class SigningKeyStoreTests: XCTestCase {
    private static let testService = "com.veya.signing-wrap.v1.xctest"
    private var roots: [URL] = []
    private var installations: [UUID] = []
    private let wrapping = KeychainWrappingSecretStore(kind: .loginKeychain, service: SigningKeyStoreTests.testService)

    override func tearDown() {
        for installation in installations { try? wrapping.delete(installationID: installation) }
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        installations.removeAll()
        roots.removeAll()
        super.tearDown()
    }

    func testCreateThenReopenInFreshStoreInstanceDecryptsAndProbes() async throws {
        let (store, root, installation) = makeStore()
        let key = try await store.createCandidate(installationID: installation)
        XCTAssertEqual(key.algorithm, "rsa-2048")

        let reopened = VeyaSigningKeyStore(rootURL: root, wrapping: wrapping)
        let verified = try await reopened.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
        XCTAssertEqual(verified.ciphertextSHA256, key.ciphertextSHA256)
        let length = try await reopened.withUnlockedPKCS8(keyID: key.keyID, installationID: installation) { buffer in buffer.count }
        XCTAssertGreaterThan(length, 1100, "PKCS#8 RSA-2048 private key")

        XCTAssertEqual(try mode(root), 0o700)
        XCTAssertEqual(try mode(root.appendingPathComponent("\(key.keyID).vkey")), 0o600)
        let inventory = try await reopened.inventory()
        XCTAssertEqual(inventory.map(\.keyID), [key.keyID])
    }

    func testNoPlaintextKeyMaterialIsPersisted() async throws {
        let (store, root, installation) = makeStore()
        let key = try await store.createCandidate(installationID: installation)
        let plaintext = try await store.withUnlockedPKCS8(keyID: key.keyID, installationID: installation) { Data($0) }
        let pkcs1 = Data(try RSAKeyDER.pkcs1(fromPKCS8: Array(plaintext)))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where !file.hasDirectoryPath {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: plaintext.prefix(64)), "PKCS#8 bytes in \(file.lastPathComponent)")
            XCTAssertNil(bytes.range(of: pkcs1.suffix(64)), "PKCS#1 bytes in \(file.lastPathComponent)")
            XCTAssertNil(bytes.range(of: Data(plaintext.base64EncodedString().prefix(48).utf8)), "base64 key in \(file.lastPathComponent)")
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE KEY"))
        }
    }

    func testWrongWrappingSecretFailsAuthentication() async throws {
        let (store, _, installation) = makeStore()
        let key = try await store.createCandidate(installationID: installation)
        try wrapping.delete(installationID: installation)
        _ = try wrapping.create(installationID: installation)
        await assertFailure(SigningKeyFailure.authenticationFailed) {
            try await store.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
        }
    }

    func testMissingWrapperAndMissingCiphertextAreClassified() async throws {
        let (store, root, installation) = makeStore()
        let key = try await store.createCandidate(installationID: installation)
        try wrapping.delete(installationID: installation)
        await assertFailure(SigningKeyFailure.wrapperMissing) {
            try await store.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
        }
        let second = try await store.createCandidate(installationID: installation)
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(second.keyID).vkey"))
        await assertFailure(SigningKeyFailure.ciphertextMissing) {
            try await store.verify(keyID: second.keyID, installationID: installation, expectedPublicKeySHA256: second.publicKeySHA256)
        }
    }

    func testTamperedCiphertextTagAndHeaderAreRejected() async throws {
        for field in ["ciphertext", "tag", "nonce"] {
            let (store, root, installation) = makeStore()
            let key = try await store.createCandidate(installationID: installation)
            try tamper(root.appendingPathComponent("\(key.keyID).vkey")) { envelope in
                var bytes = Data(base64Encoded: envelope[field] as! String)!
                bytes[bytes.startIndex] ^= 0x01
                envelope[field] = bytes.base64EncodedString()
            }
            await assertFailure(SigningKeyFailure.authenticationFailed, "\(field)") {
                try await store.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
            }
        }
        let (store, root, installation) = makeStore()
        let key = try await store.createCandidate(installationID: installation)
        try tamper(root.appendingPathComponent("\(key.keyID).vkey")) { $0["publicKeySHA256"] = "sha256:" + String(repeating: "a", count: 64) }
        await assertFailure(SigningKeyFailure.publicKeyMismatch) {
            try await store.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
        }
        await assertFailure(SigningKeyFailure.corruptEnvelope) {
            try await store.withUnlockedPKCS8(keyID: key.keyID, installationID: installation) { _ in () }
        }
        try Data("{\"magic\":\"other\"}".utf8).write(to: root.appendingPathComponent("\(key.keyID).vkey"))
        chmod(root.appendingPathComponent("\(key.keyID).vkey").path, 0o600)
        await assertFailure(SigningKeyFailure.corruptEnvelope) {
            try await store.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
        }
    }

    func testEnvelopeIsBoundToItsInstallation() async throws {
        let (store, _, installation) = makeStore()
        let key = try await store.createCandidate(installationID: installation)
        let other = UUID()
        installations.append(other)
        _ = try wrapping.create(installationID: other)
        await assertFailure(SigningKeyFailure.authenticationFailed) {
            try await store.verify(keyID: key.keyID, installationID: other, expectedPublicKeySHA256: key.publicKeySHA256)
        }
    }

    func testUnsafePermissionsSymlinksAndDirectoryModesAreRefused() async throws {
        let (store, root, installation) = makeStore()
        let key = try await store.createCandidate(installationID: installation)
        let file = root.appendingPathComponent("\(key.keyID).vkey")
        chmod(file.path, 0o644)
        await assertFailure(SigningKeyFailure.unsafeFile) {
            try await store.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
        }
        chmod(file.path, 0o600)
        chmod(root.path, 0o755)
        await assertFailure(SigningKeyFailure.unsafeFile) {
            try await store.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
        }
        chmod(root.path, 0o700)
        let moved = root.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString).vkey")
        try FileManager.default.moveItem(at: file, to: moved)
        roots.append(moved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        await assertFailure(SigningKeyFailure.unsafeFile) {
            try await store.verify(keyID: key.keyID, installationID: installation, expectedPublicKeySHA256: key.publicKeySHA256)
        }
    }

    func testRotationKeepsWrapperUntilLastKeyRetires() async throws {
        let (store, _, installation) = makeStore()
        let first = try await store.createCandidate(installationID: installation)
        let second = try await store.createCandidate(installationID: installation)
        XCTAssertNotEqual(first.publicKeySHA256, second.publicKeySHA256)
        try await store.retire(keyID: first.keyID, installationID: installation)
        let firstExists = await store.keyExists(keyID: first.keyID)
        XCTAssertFalse(firstExists)
        try await store.verify(keyID: second.keyID, installationID: installation, expectedPublicKeySHA256: second.publicKeySHA256)
        let wrapperKept = try await store.wrapperExists(installationID: installation)
        XCTAssertTrue(wrapperKept)
        try await store.retire(keyID: second.keyID, installationID: installation)
        let wrapperRemaining = try await store.wrapperExists(installationID: installation)
        XCTAssertFalse(wrapperRemaining)
    }

    func testBackendIsSelectedBySignatureClassWithoutFallback() throws {
        XCTAssertEqual(WrappingSecretBackendKind.select(teamIdentifier: nil, entitlements: [:]), .unavailable)
        XCTAssertEqual(WrappingSecretBackendKind.select(teamIdentifier: "ABCDE12345", entitlements: [:]), .unavailable)
        XCTAssertEqual(
            WrappingSecretBackendKind.select(
                teamIdentifier: "ABCDE12345",
                entitlements: [
                    "com.apple.application-identifier": "ABCDE12345.com.veya.provisioner",
                    "com.apple.developer.team-identifier": "ABCDE12345",
                    "keychain-access-groups": ["ABCDE12345.com.veya.provisioner"],
                ]
            ),
            .dataProtectionKeychain
        )
        XCTAssertEqual(
            WrappingSecretBackendKind.select(
                teamIdentifier: "ABCDE12345",
                entitlements: [
                    "com.apple.application-identifier": "WRONGTEAM1.com.veya.provisioner",
                    "keychain-access-groups": ["ABCDE12345.com.veya.provisioner"],
                ]
            ),
            .unavailable
        )
        XCTAssertEqual(WrappingSecretBackendKind.select(teamIdentifier: nil, entitlements: ["keychain-access-groups": ["x"]]), .unavailable)
        XCTAssertEqual(WrappingSecretBackendKind.forRunningCode(), .unavailable, "test runner lacks a profile-validated keychain identity")

        let unavailable = KeychainWrappingSecretStore(kind: .unavailable, service: Self.testService)
        XCTAssertThrowsError(try unavailable.create(installationID: UUID())) {
            XCTAssertEqual(($0 as? VeyaFailure)?.code, SigningKeyFailure.wrappingStoreUnavailable.code)
        }

        // The data-protection backend fails closed for an unentitled process; it never falls back.
        let dataProtection = KeychainWrappingSecretStore(kind: .dataProtectionKeychain, service: Self.testService)
        let installation = UUID()
        XCTAssertThrowsError(try dataProtection.create(installationID: installation)) {
            XCTAssertEqual(($0 as? VeyaFailure)?.code, SigningKeyFailure.wrappingStoreUnavailable.code)
        }
        XCTAssertNil(try wrapping.read(installationID: installation), "no login-Keychain fallback item was created")
    }

    func testEngineCreatesProvesPromotesAndReplacesUnrecoverableKey() async throws {
        let (store, root, _) = makeStore()
        let repository = InstallationJournalRepository(rootURL: root.deletingLastPathComponent().appendingPathComponent("installation-\(UUID().uuidString)"))
        roots.append(repository.rootURL)
        let domain = SigningKeyDomain(store: store)
        let composition = EngineComposition(
            repository: repository, observers: [domain], transitions: [domain],
            identity: EngineIdentity(packaged: false, qualificationBuild: true)
        )
        let capabilities = CapabilityManifest(allowedDomains: [.signingKey])
        let created = await EngineHost.handle(EngineRequest(command: .reconcile, stage: .signingKey, capabilities: capabilities), composition: composition)
        XCTAssertEqual(created.status, "ready", "\(String(describing: created.firstFailure))")
        XCTAssertEqual(created.skippedProofs.map(\.domain), [.migration])
        let journal = try await repository.load()
        installations.append(journal.installationID)
        let active = try XCTUnwrap(journal.activeResource(for: .signingKey))
        XCTAssertEqual(active.ownership, .privateKeyControl)
        XCTAssertEqual(active.relativeLocation, "secrets/signing-keys/\(active.identity.resourceID).vkey")

        let verified = await EngineHost.handle(EngineRequest(command: .verify, stage: .signingKey), composition: composition)
        XCTAssertEqual(verified.status, "verified")

        // Unrecoverable local key (wrapper lost): observed invalid, replaced by a new proven candidate.
        try wrapping.delete(installationID: journal.installationID)
        let broken = await EngineHost.handle(EngineRequest(command: .verify, stage: .signingKey), composition: composition)
        XCTAssertEqual(broken.observations.first?.state, .invalid)
        XCTAssertEqual(broken.observations.first?.safeReason, SigningKeyFailure.wrapperMissing.code)
        let replaced = await EngineHost.handle(EngineRequest(command: .reconcile, stage: .signingKey, capabilities: capabilities), composition: composition)
        XCTAssertEqual(replaced.status, "ready")
        let after = try await repository.load()
        XCTAssertNotEqual(after.activeResource(for: .signingKey)?.identity, active.identity)
        XCTAssertEqual(after.retiring["signingKey"]?.map(\.identity), [active.identity])

        let journalText = try String(contentsOf: repository.journalURL, encoding: .utf8)
        XCTAssertFalse(journalText.contains("PRIVATE"))
        XCTAssertFalse(journalText.lowercased().contains("nonce"))
    }

    /// Packaged no-prompt gate: two ad-hoc app builds of the real helper (same bundle ID, different
    /// cdhash) launched through LaunchServices. A non-Keychain command establishes the SecurityAgent
    /// baseline before Build "11" creates/reopens and Build "12" attempts the upgrade read.
    func testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction() throws {
        let work = makeRoot()
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("IOSSimProvisioner")
        let build11 = try makeApp(named: "Veya11", helper: helper, in: work, version: "11", hardened: false)
        let build12 = try makeApp(named: "Veya12", helper: helper, in: work, version: "12", hardened: true)
        XCTAssertNotEqual(try cdhash(build11), try cdhash(build12))
        let state = work.appendingPathComponent("state", isDirectory: true)
        let capabilities = CapabilityManifest(allowedDomains: InstallationDomain.signingKey.closure)
        defer { _ = try? launch(build11, ["qualification-wrapper-cleanup", "--isolated-root", state.path], output: work.appendingPathComponent("cleanup.out")) }

        let agentsBefore = securityAgentPIDs()
        XCTAssertEqual(
            try launch(build12, ["protocol-info"], output: work.appendingPathComponent("baseline.out")),
            0,
            "non-Keychain baseline launch failed"
        )
        let agentsAfterBaseline = securityAgentPIDs()
        XCTAssertEqual(agentsAfterBaseline, agentsBefore, "the non-Keychain baseline changed SecurityAgent state")
        let create = try engine(build11, EngineRequest(command: .reconcile, stage: .signingKey, capabilities: capabilities, isolatedStateRoot: state.path), work)
        XCTAssertEqual(create.status, "ready", "\(String(describing: create.firstFailure))")
        XCTAssertTrue(create.identity.packaged)
        let reopen = try engine(build11, EngineRequest(command: .verify, stage: .signingKey, isolatedStateRoot: state.path), work)
        XCTAssertEqual(reopen.status, "verified")
        let upgraded = try engine(build12, EngineRequest(command: .verify, stage: .signingKey, isolatedStateRoot: state.path), work)
        XCTAssertEqual(upgraded.status, "verified", "\(String(describing: upgraded.firstFailure))")
        let steady = try engine(build12, EngineRequest(command: .reconcile, stage: .signingKey, capabilities: capabilities, isolatedStateRoot: state.path), work)
        XCTAssertEqual(steady.status, "ready")
        XCTAssertEqual(steady.transitionsCompleted, 0, "upgrade must reuse the existing key")
        XCTAssertEqual(securityAgentPIDs(), agentsAfterBaseline, "the M4 Keychain path changed SecurityAgent state")

        // Isolation: a same-team app with a different App ID / access group cannot unwrap Veya's key.
        if let unrelatedSigning = try ProductionSigning.load("VEYA_M4_UNRELATED_PROFILE") {
            let unrelated = try makeApp(named: "Unrelated", helper: helper, in: work, version: "1", hardened: true,
                                        signing: unrelatedSigning)
            let stolen = try engine(unrelated, EngineRequest(command: .verify, stage: .signingKey, isolatedStateRoot: state.path), work)
            XCTAssertNotEqual(stolen.status, "verified", "an unrelated application unwrapped the signing key")
            XCTAssertEqual(securityAgentPIDs(), agentsAfterBaseline)
        }
    }

    // MARK: - Helpers

    private func makeStore() -> (VeyaSigningKeyStore, URL, UUID) {
        let root = makeRoot().appendingPathComponent("signing-keys", isDirectory: true)
        let installation = UUID()
        installations.append(installation)
        return (VeyaSigningKeyStore(rootURL: root, wrapping: wrapping), root, installation)
    }

    private func makeRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("veya-key-tests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    private func tamper(_ url: URL, _ edit: (inout [String: Any]) -> Void) throws {
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        edit(&envelope)
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: url)
        chmod(url.path, 0o600)
    }

    private func assertFailure(
        _ expected: VeyaFailure,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Any
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected.code) \(context)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? VeyaFailure)?.code, expected.code, context, file: file, line: line)
        }
    }

    /// M4 production proof: team identity + provisioning profile authorizing
    /// `keychain-access-groups`. Without them the gate runs ad-hoc and must fail closed.
    private struct ProductionSigning {
        let identity: String
        let profile: URL
        let applicationIdentifier: String
        let teamIdentifier: String
        var bundleIdentifier: String { String(applicationIdentifier.dropFirst(teamIdentifier.count + 1)) }

        static func load(_ profileVariable: String) throws -> ProductionSigning? {
            let environment = ProcessInfo.processInfo.environment
            guard let identity = environment["VEYA_M4_SIGN_IDENTITY"], let path = environment[profileVariable] else { return nil }
            let decoded = Process()
            decoded.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            decoded.arguments = ["cms", "-D", "-i", path]
            let pipe = Pipe()
            decoded.standardOutput = pipe
            try decoded.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            decoded.waitUntilExit()
            let profile = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let entitlements = profile?["Entitlements"] as? [String: Any]
            guard let applicationIdentifier = entitlements?["com.apple.application-identifier"] as? String,
                  let team = (profile?["TeamIdentifier"] as? [String])?.first,
                  !applicationIdentifier.hasSuffix("*") else {
                XCTFail("\(profileVariable) must be an explicit (non-wildcard) macOS App ID profile")
                return nil
            }
            return ProductionSigning(identity: identity, profile: URL(fileURLWithPath: path),
                                     applicationIdentifier: applicationIdentifier, teamIdentifier: team)
        }

        func entitlementsFile(in directory: URL) throws -> URL {
            let url = directory.appendingPathComponent("\(applicationIdentifier).entitlements")
            let plist: [String: Any] = [
                "com.apple.application-identifier": applicationIdentifier,
                "com.apple.developer.team-identifier": teamIdentifier,
                "keychain-access-groups": [applicationIdentifier],
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
            return url
        }
    }

    private func makeApp(named name: String, helper: URL, in directory: URL, version: String, hardened: Bool,
                         signing: ProductionSigning? = nil) throws -> URL {
        let signing = try signing ?? ProductionSigning.load("VEYA_M4_PROFILE")
        let app = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: helper, to: macOS.appendingPathComponent("IOSSimProvisioner"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": signing?.bundleIdentifier ?? "com.veya.qualification.keystore-upgrade",
            "CFBundleExecutable": "IOSSimProvisioner",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.\(version)",
            "CFBundleVersion": version,
            "LSUIElement": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        var arguments = ["--force", "--sign", "-"]
        if let signing {
            try FileManager.default.copyItem(at: signing.profile, to: app.appendingPathComponent("Contents/embedded.provisionprofile"))
            arguments = ["--force", "--sign", signing.identity, "--timestamp=none",
                         "--entitlements", try signing.entitlementsFile(in: directory).path]
        }
        if hardened || signing != nil { arguments += ["--options", "runtime"] }
        let signed = try run("/usr/bin/codesign", arguments + [app.path])
        XCTAssertEqual(signed.status, 0, signed.output)
        return app
    }

    private func cdhash(_ app: URL) throws -> String {
        let inspection = try run("/usr/bin/codesign", ["-dvvv", app.path])
        guard inspection.status == 0,
              let value = inspection.output.split(separator: "\n")
              .first(where: { $0.hasPrefix("CDHash=") })?
              .dropFirst("CDHash=".count),
              value.count == 40,
              value.allSatisfy({ $0.isHexDigit }) else {
            throw SigningKeyFailure.probeFailed
        }
        return String(value)
    }

    private func engine(_ app: URL, _ request: EngineRequest, _ work: URL) throws -> QualificationResult {
        let body = String(decoding: try QualificationResult.encoder().encode(request), as: UTF8.self)
        let output = work.appendingPathComponent("engine-\(UUID().uuidString).json")
        try launch(app, [ProvisionerEngineProtocol.helperCommand, "--request", body], output: output)
        return try QualificationResult.decoder().decode(QualificationResult.self, from: Data(contentsOf: output))
    }

    @discardableResult
    private func launch(_ app: URL, _ arguments: [String], output: URL) throws -> Int32 {
        try run("/usr/bin/open", ["-W", "-n", "--stdout", output.path, "--stderr", output.path + ".err", app.path, "--args"] + arguments).status
    }

    private func securityAgentPIDs() -> Set<Int32> {
        Set((try? run("/usr/bin/pgrep", ["-x", "SecurityAgent"]).output.split(separator: "\n")
            .compactMap { Int32($0) }) ?? [])
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
