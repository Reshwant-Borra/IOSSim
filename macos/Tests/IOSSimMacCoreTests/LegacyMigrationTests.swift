import Foundation
@testable import IOSSimMacCore
import XCTest

/// M8: read-only legacy snapshot through the production engine; nothing legacy is modified or imported.
final class LegacyMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-m8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Sanitized Build 1-11 layout: synthetic contents, real file names.
    private func writeLegacyHome() throws -> (URL, [URL: Data]) {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/IOSSim", isDirectory: true)
        let keychains = home.appendingPathComponent("Library/Keychains", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keychains, withIntermediateDirectories: true)
        var files: [URL: Data] = [:]
        for (url, text) in [
            (support.appendingPathComponent("signing-keychain.secret"), "synthetic-legacy-secret-canary"),
            (support.appendingPathComponent("authorization-session.enc"), "synthetic-ciphertext"),
            (support.appendingPathComponent("provisioning-state.json"), #"{"stage":"ready"}"#),
            (keychains.appendingPathComponent("Veya-Signing.keychain-db"), "synthetic-keychain"),
        ] {
            try Data(text.utf8).write(to: url)
            files[url] = Data(text.utf8)
        }
        return (home, files)
    }

    func testInventoryClassifiesWithoutReadingSecretsAndIsIdempotent() throws {
        let (home, _) = try writeLegacyHome()
        let reader = LocalLegacyInventoryReader(home: home, loginKeychainServices: [])
        let items = Dictionary(uniqueKeysWithValues: reader.inventory().map { ($0.name, $0) })
        XCTAssertEqual(items["file.signing-keychain"]?.classification, .present)
        XCTAssertEqual(items["file.signing-keychain"]?.disposition, .replaceWithNewKey)
        XCTAssertEqual(items["file.signing-keychain-secret"]?.disposition, .retireOnCleanup)
        XCTAssertNil(items["file.signing-keychain-secret"]?.digest, "secret-bearing files are never hashed or read")
        XCTAssertNotNil(items["file.provisioning-state.json"]?.digest)
        XCTAssertEqual(items["file.setup-journal.json"]?.classification, .absent)
        XCTAssertEqual(reader.inventory(), reader.inventory())
    }

    func testEngineRecordsLedgerLeavesLegacyUntouchedAndIsIdempotent() async throws {
        let (home, files) = try writeLegacyHome()
        let repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
        let domain = MigrationDomain(reader: LocalLegacyInventoryReader(home: home, loginKeychainServices: []), repository: repository)
        let engine = try VeyaReconciliationEngine(journalRepository: repository, observers: [domain], transitions: [domain])
        let scope = try InstallationScope(domains: [.migration])
        let desired = try DesiredInstallationState(requirements: [.init(domain: .migration)])
        let policy = try ReconciliationPolicy(allowedDomains: [.migration], maximumTransitions: 4)

        let first = try await engine.reconcile(scope: scope, to: desired, policy: policy)
        XCTAssertEqual(first.status, .ready, "\(String(describing: first.failure))")
        let journal = try await repository.load()
        XCTAssertEqual(journal.migration.phase, .inventoried)
        XCTAssertEqual(journal.migration.items["file.signing-keychain"], "present|replaceWithNewKey|-")
        XCTAssertNotNil(journal.activeResource(for: .migration))

        for (url, bytes) in files { XCTAssertEqual(try Data(contentsOf: url), bytes, "legacy \(url.lastPathComponent) modified") }
        let text = try String(contentsOf: repository.journalURL, encoding: .utf8)
        XCTAssertFalse(text.contains("synthetic-legacy-secret-canary"))

        let second = try await engine.reconcile(scope: scope, to: desired, policy: policy)
        XCTAssertEqual(second.transitionsCompleted, 0)
    }

    func testProductionCompositionRequiresMigrationBeforeSigningKey() {
        let composition = ProductionComposition.make(helperURL: URL(fileURLWithPath: "/tmp/IOSSimProvisioner"), stateRoot: root)
        // Every domain is composed exactly once, in product order, so READY can never be reported by
        // skipping an unobserved domain; migration still precedes the signing key.
        XCTAssertEqual(composition.observers.map(\.domain), InstallationDomain.reconciliationOrder)
        XCTAssertEqual(composition.transitions.map(\.domain), InstallationDomain.reconciliationOrder)
        XCTAssertEqual(InstallationDomain.signingKey.closure, [.migration, .signingKey])
    }
}
