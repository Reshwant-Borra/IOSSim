import CryptoKit
import Foundation
import XCTest
@testable import IOSSimMacCore

final class AppleAuthorizationKeychainRegressionTests: XCTestCase {
    private static let testWrappingService = "com.veya.authorization-wrap.v1.xctest"
    private var roots: [URL] = []
    private var wrappers: [KeychainWrappingSecretStore] = []

    override func tearDown() {
        for wrapper in wrappers {
            try? wrapper.delete(installationID: KeychainAppleAuthorizationSessionStore.wrappingAccount)
        }
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    func testSessionRoundTripsSealedUnderSeparateWrappingDomain() throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root, kind: .loginKeychain)
        let payload = Data("synthetic-session-unit-canary".utf8)
        try store.save(session(payload))

        let file = root.appendingPathComponent(KeychainAppleAuthorizationSessionStore.sessionFileName)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: payload), "session payload must not be stored in plaintext")
        XCTAssertNil(bytes.range(of: Data("unit-account".utf8)))
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(root), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path),
                       [KeychainAppleAuthorizationSessionStore.sessionFileName],
                       "no key file may sit beside the ciphertext")

        let loaded = try XCTUnwrap(try makeStore(root: root, kind: .loginKeychain).load())
        var loadedPayload = loaded.withOpaquePayload { Data($0) }
        defer { loadedPayload.resetBytes(in: 0..<loadedPayload.count) }
        XCTAssertEqual(loaded.metadata.accountFingerprint, "unit-account")
        XCTAssertEqual(loadedPayload, payload)
        XCTAssertNotEqual(KeychainAppleAuthorizationSessionStore.wrappingService, KeychainWrappingSecretStore.service,
                          "Apple authorization and signing keys must not share a wrapping item")

        try store.remove()
        XCTAssertNil(try store.load())
    }

    func testUnavailableBackendKeepsSessionInMemoryOnlyAndPurgesV1State() throws {
        let root = try temporaryRoot()
        try writeV1State(root: root, payload: Data("v1-session".utf8), quarantineCopies: true)
        let store = makeStore(root: root, kind: .unavailable)
        XCTAssertFalse(store.persistsAcrossLaunches)
        try store.save(session(Data("never-on-disk".utf8)))
        XCTAssertNil(try store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [],
                       "no session, key, or quarantined v1 copy may remain")
    }

    func testV1StateMigratesIntoV2AndIsDeleted() throws {
        let root = try temporaryRoot()
        let payload = Data("v1-session-payload".utf8)
        try writeV1State(root: root, payload: payload, quarantineCopies: true)
        let loaded = try XCTUnwrap(try makeStore(root: root, kind: .loginKeychain).load())
        XCTAssertEqual(loaded.withOpaquePayload { Data($0) }, payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path),
                       [KeychainAppleAuthorizationSessionStore.sessionFileName])
        XCTAssertEqual(try makeStore(root: root, kind: .loginKeychain).load()?.withOpaquePayload { Data($0) }, payload)
    }

    func testTamperedFileOrMissingWrapperFailsClosedWithoutPrompt() throws {
        let root = try temporaryRoot()
        let store = makeStore(root: root, kind: .loginKeychain)
        let file = root.appendingPathComponent(KeychainAppleAuthorizationSessionStore.sessionFileName)

        try store.save(session(Data("a".utf8)))
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: file)
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "tampered session must be discarded")

        try store.save(session(Data("b".utf8)))
        try wrappers.last!.delete(installationID: KeychainAppleAuthorizationSessionStore.wrappingAccount)
        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPackagedHelperCanReuseAuthorizationSessionAcrossRelaunchWithoutPrompt() throws {
        try requireLocalSystemTests()
        let root = try temporaryRoot()
        let wrappingService = "\(Self.testWrappingService).\(UUID().uuidString)"
        defer {
            try? KeychainWrappingSecretStore(kind: .loginKeychain, service: wrappingService)
                .delete(installationID: KeychainAppleAuthorizationSessionStore.wrappingAccount)
        }
        for command in ["create", "read", "update", "read", "remove"] {
            let result = try runAuthHelper(command, directory: root.path, wrappingService: wrappingService)
            XCTAssertEqual(result.exitCode, 0, result.output)
            XCTAssertFalse(result.timedOut, "Possible SecurityAgent prompt while running \(command): \(result.output)")
        }
        let production = try runAuthHelper("read", directory: root.path, wrappingService: wrappingService, backend: "running-code")
        XCTAssertTrue(production.output.contains("AUTH_STORE_BACKEND unavailable persists=false"),
                      "ad-hoc builds must not persist sessions: \(production.output)")
        XCTAssertEqual(production.exitCode, 3, production.output)
    }

    private func makeStore(root: URL, kind: WrappingSecretBackendKind) -> KeychainAppleAuthorizationSessionStore {
        let wrapping = KeychainWrappingSecretStore(kind: kind, service: "\(Self.testWrappingService).\(root.lastPathComponent)")
        if kind != .unavailable { wrappers.append(wrapping) }
        return KeychainAppleAuthorizationSessionStore(
            service: "com.iossim.mac.apple-authorization.unit",
            account: "synthetic-session",
            wrapping: wrapping,
            directory: root,
            legacyKeychainURL: root.appendingPathComponent("Veya-Authorization.keychain-db")
        )
    }

    private func session(_ payload: Data) -> AppleAuthorizationSession {
        AppleAuthorizationSession(
            metadata: .init(
                accountFingerprint: "unit-account",
                clientIdentityVersion: "unit",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            opaquePayload: payload
        )
    }

    /// Reproduces the auth v1 layout: AES-GCM file keyed by a plaintext secret file beside it.
    private func writeV1State(root: URL, payload: Data, quarantineCopies: Bool) throws {
        struct V1Envelope: Codable { let metadata: AppleAuthorizationSessionMetadata; let payload: Data }
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let encoded = try PropertyListEncoder().encode(V1Envelope(metadata: session(payload).metadata, payload: payload))
        let sealed = try AES.GCM.seal(encoded, using: SymmetricKey(data: secret)).combined!
        try Data(secret.base64EncodedString().utf8).write(to: root.appendingPathComponent("authorization-keychain.secret"))
        try sealed.write(to: root.appendingPathComponent("authorization-session.enc"))
        if quarantineCopies {
            try Data(secret.base64EncodedString().utf8)
                .write(to: root.appendingPathComponent("authorization-keychain.secret.quarantine-\(UUID().uuidString)"))
            try Data("keychain".utf8).write(to: root.appendingPathComponent("Veya-Authorization.keychain-db.quarantine-\(UUID().uuidString)"))
        }
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0) & 0o777
    }

    private func requireLocalSystemTests() throws {
        guard ProcessInfo.processInfo.environment["IOSSIM_RUN_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("LOCAL_SYSTEM: set IOSSIM_RUN_KEYCHAIN_INTEGRATION=1 to run real Keychain tests.")
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeyaAuthQualification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        roots.append(root)
        return root
    }

    private func runAuthHelper(
        _ command: String,
        directory: String,
        wrappingService: String,
        backend: String = "login-keychain-test"
    ) throws -> (exitCode: Int32, output: String, timedOut: Bool) {
        let helper = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("IOSSimAuthDiagnostic", isDirectory: false)
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: helper.path),
            "IOSSimAuthDiagnostic must be built for this regression."
        )
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            "qualification-auth-store", command,
            "--directory", directory,
            "--wrapping-backend", backend,
            "--wrapping-service", wrappingService
        ]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let timedOut = finished.wait(timeout: .now() + 12) == .timedOut
        if timedOut {
            process.terminate()
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output, timedOut)
    }
}
