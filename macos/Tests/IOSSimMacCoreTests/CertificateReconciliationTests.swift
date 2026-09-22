import Foundation
@testable import IOSSimMacCore
import XCTest

/// M6 hermetic certificate campaign: exact Apple call limits and cryptographic-only ownership.
final class CertificateReconciliationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let ours = "sha256:" + String(repeating: "a", count: 64)
    private let retired = "sha256:" + String(repeating: "b", count: 64)
    private let foreign = "sha256:" + String(repeating: "c", count: 64)

    private func cert(_ serial: String, _ spki: String, days: Double = 300) -> AppleCertificateObservation {
        .init(serial: serial, derSHA256: "der-\(serial)", spkiSHA256: spki, expiresAt: now.addingTimeInterval(days * 86_400))
    }

    private func run(_ apple: FakeAppleCertificates, keys: CertificateKeyFacts) async -> Result<AppleCertificateObservation, Error> {
        let clock = now
        do { return .success(try await CertificateReconciler(service: apple).reconcile(keys: keys, now: { clock })) }
        catch { return .failure(error) }
    }

    private func failureCode(_ result: Result<AppleCertificateObservation, Error>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return (error as? VeyaFailure)?.code
    }

    func testReusesOnlyByExactSPKIWithoutMutation() async {
        let apple = FakeAppleCertificates(inventory: [cert("X", foreign), cert("OURS", ours)])
        let result = await run(apple, keys: .init(signingKeySPKI: ours))
        XCTAssertEqual(try result.get().serial, "OURS")
        XCTAssertEqual(apple.calls, ["list"])
    }

    func testIssuesWhenNoMatchAndCapacityFree() async {
        let apple = FakeAppleCertificates(inventory: [cert("X", foreign)])
        let result = await run(apple, keys: .init(signingKeySPKI: ours))
        XCTAssertEqual(try result.get().spkiSHA256, ours)
        XCTAssertEqual(apple.calls, ["list", "issue"])
    }

    func testMatchInsideRenewalWindowIsReplaced() async {
        let apple = FakeAppleCertificates(inventory: [cert("OLD", ours, days: 2)])
        _ = await run(apple, keys: .init(signingKeySPKI: ours))
        XCTAssertEqual(apple.calls, ["list", "issue"])
    }

    func testCapacityReclaimsOneRetiredOwnedCertificateThenRetriesOnce() async {
        let apple = FakeAppleCertificates(
            inventory: [cert("FOREIGN", foreign, days: 1), cert("RETIRED", retired, days: 200)],
            capacity: 2
        )
        let result = await run(apple, keys: .init(signingKeySPKI: ours, retiredKeySPKIs: [retired]))
        XCTAssertEqual(try result.get().spkiSHA256, ours)
        XCTAssertEqual(apple.calls, ["list", "issue", "list", "revoke:RETIRED", "list", "issue"])
    }

    func testCapacityNeverRevokesUnknownOtherMacOrReferencedCertificates() async {
        // Foreign SPKI (Xcode / another Mac / Veya-named but not our key), plus a certificate for a key
        // this installation still references: none is reclaimable.
        let referenced = "sha256:" + String(repeating: "d", count: 64)
        let apple = FakeAppleCertificates(
            inventory: [cert("XCODE", foreign, days: 1), cert("REFERENCED", referenced, days: 1)],
            capacity: 2
        )
        let result = await run(apple, keys: .init(
            signingKeySPKI: ours, referencedKeySPKIs: [referenced], retiredKeySPKIs: [referenced]
        ))
        XCTAssertEqual(failureCode(result), CertificateFailure.capacityRequiresUser.code)
        XCTAssertEqual(apple.calls, ["list", "issue", "list"])
    }

    func testAtMostOneRevocationAndTwoIssues() async {
        let second = "sha256:" + String(repeating: "e", count: 64)
        let apple = FakeAppleCertificates(
            inventory: [cert("R1", retired), cert("R2", second)],
            capacity: 2,
            capacityAfterRevoke: true
        )
        let result = await run(apple, keys: .init(signingKeySPKI: ours, retiredKeySPKIs: [retired, second]))
        XCTAssertEqual(failureCode(result), CertificateFailure.capacityRequiresUser.code)
        XCTAssertEqual(apple.calls.filter { $0.hasPrefix("revoke") }.count, 1)
        XCTAssertEqual(apple.calls.filter { $0 == "issue" }.count, 2)
    }

    func testRetriedAttemptsOfOneTransitionShareTheRevokeAndIssueBudget() async {
        // Engine retries a retryable failure (here: the inventory read after a revocation is lost). The
        // retry must not revoke a second owned certificate or exceed two issues in total.
        let second = "sha256:" + String(repeating: "e", count: 64)
        let apple = FakeAppleCertificates(inventory: [cert("R1", retired), cert("R2", second)], capacity: 2,
                                          capacityAfterRevoke: true, failListAfterRevoke: true)
        let ledger = CertificateBudgetLedger()
        let keys = CertificateKeyFacts(signingKeySPKI: ours, retiredKeySPKIs: [retired, second])
        let clock = now
        for _ in 0..<5 {
            _ = try? await CertificateReconciler(service: apple).reconcile(
                keys: keys, budget: await ledger.budget(for: "transition"),
                spent: { await ledger.record($0, for: "transition") }, now: { clock })
        }
        XCTAssertEqual(apple.calls.filter { $0.hasPrefix("revoke") }.count, 1)
        XCTAssertLessThanOrEqual(apple.calls.filter { $0 == "issue" }.count, 2)
        // Without the shared ledger each retry starts fresh: the defect this guards against.
        let unshared = FakeAppleCertificates(inventory: [cert("R1", retired), cert("R2", second)], capacity: 2,
                                             capacityAfterRevoke: true, failListAfterRevoke: true)
        for _ in 0..<2 { _ = try? await CertificateReconciler(service: unshared).reconcile(keys: keys, now: { clock }) }
        XCTAssertEqual(unshared.calls.filter { $0.hasPrefix("revoke") }.count, 2)
    }

    func testContradictoryInventoryAndMismatchedIssuanceFailClosed() async {
        var duplicate = cert("S", foreign)
        duplicate = .init(serial: "S", derSHA256: "different", spkiSHA256: foreign, expiresAt: duplicate.expiresAt)
        let contradictory = FakeAppleCertificates(inventory: [cert("S", foreign), duplicate])
        let contradiction = await run(contradictory, keys: .init(signingKeySPKI: ours))
        XCTAssertEqual(failureCode(contradiction), CertificateFailure.inventoryContradiction.code)
        XCTAssertEqual(contradictory.calls, ["list"])

        let lying = FakeAppleCertificates(inventory: [], issueSPKIOverride: foreign)
        let mismatch = await run(lying, keys: .init(signingKeySPKI: ours))
        XCTAssertEqual(failureCode(mismatch), CertificateFailure.issuedCertificateMismatch.code)
    }

    func testAmbiguousIssueIsResolvedByInventoryOnRerun() async {
        // Apple created the certificate but the response was lost; the rerun reuses it by SPKI.
        let apple = FakeAppleCertificates(inventory: [], loseIssueResponse: true)
        _ = await run(apple, keys: .init(signingKeySPKI: ours))
        let rerun = await run(apple, keys: .init(signingKeySPKI: ours))
        XCTAssertEqual(try rerun.get().spkiSHA256, ours)
        XCTAssertEqual(apple.calls, ["list", "issue", "list"])
    }

    func testKeyFactsComeFromJournalSigningKeyRecords() throws {
        func record(_ id: String, _ digest: String, _ lifecycle: ResourceLifecycle) throws -> ResourceRecord {
            try ResourceRecord(
                id: id, identity: ResourceIdentity(domain: .signingKey, resourceID: id, digest: digest),
                lifecycle: lifecycle, generation: .initial, ownership: .privateKeyControl,
                createdAt: now, observedAt: now, relativeLocation: "secrets/signing-keys/\(id).vkey", metadata: [:]
            )
        }
        var journal = InstallationJournal(now: now)
        journal.active["signingKey"] = try record("active", ours, .active)
        journal.retiring["signingKey"] = [try record("old", retired, .retiring)]
        XCTAssertEqual(CertificateKeyFacts(journal: journal),
                       .init(signingKeySPKI: ours, referencedKeySPKIs: [ours], retiredKeySPKIs: [retired]))
        journal.candidates["signingKey"] = try record("next", foreign, .candidate)
        let facts = CertificateKeyFacts(journal: journal)
        XCTAssertEqual(facts.signingKeySPKI, foreign, "a pending candidate key is the one to certify")
        XCTAssertEqual(facts.referencedKeySPKIs, [ours, foreign])
    }

    func testCertificateSPKIDigestMatchesKeyStoreDigestAndOpenSSL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veya-cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("k.pem").path
        let der = dir.appendingPathComponent("c.der").path
        let pkcs1 = dir.appendingPathComponent("p1.der").path
        let spki = dir.appendingPathComponent("spki.der").path
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", der,
                     "-outform", "DER", "-subj", "/CN=Veya Synthetic", "-days", "30"])
        // PKCS#1 private key (the key store's input) and OpenSSL's own SPKI encoding as an oracle.
        try openssl(["rsa", "-in", key, "-outform", "DER", "-out", pkcs1])
        try openssl(["rsa", "-in", key, "-pubout", "-outform", "DER", "-out", spki])

        let observation = try XCTUnwrap(AppleCertificateObservation(serial: "1", der: try Data(contentsOf: URL(fileURLWithPath: der))))
        let keyStoreDigest = try VeyaSigningKeyStore.publicKeySHA256(pkcs1: Array(Data(contentsOf: URL(fileURLWithPath: pkcs1))))
        let opensslDigest = VeyaSigningKeyStore.sha256(try Data(contentsOf: URL(fileURLWithPath: spki)))
        XCTAssertEqual(observation.spkiSHA256, keyStoreDigest)
        XCTAssertEqual(observation.spkiSHA256, opensslDigest)
        XCTAssertGreaterThan(observation.expiresAt, Date())
        XCTAssertNil(AppleCertificateObservation(serial: "2", der: Data("not a certificate".utf8)))
    }

    private func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }
}

/// Scripted Apple certificate endpoint. `capacity` models Apple's development-certificate limit.
private final class FakeAppleCertificates: AppleCertificateService, @unchecked Sendable {
    private let lock = NSLock()
    private var inventory: [AppleCertificateObservation]
    private let capacity: Int
    private let capacityAfterRevoke: Bool
    private let issueSPKIOverride: String?
    private var loseIssueResponse: Bool
    private var revoked = false
    private var failListAfterRevoke: Bool
    private(set) var calls: [String] = []

    init(inventory: [AppleCertificateObservation], capacity: Int = 10, capacityAfterRevoke: Bool = false,
         issueSPKIOverride: String? = nil, loseIssueResponse: Bool = false, failListAfterRevoke: Bool = false) {
        self.failListAfterRevoke = failListAfterRevoke
        self.inventory = inventory
        self.capacity = capacity
        self.capacityAfterRevoke = capacityAfterRevoke
        self.issueSPKIOverride = issueSPKIOverride
        self.loseIssueResponse = loseIssueResponse
    }

    func listDevelopmentCertificates() async throws -> [AppleCertificateObservation] {
        try lock.withLock {
            calls.append("list")
            if revoked && failListAfterRevoke {
                failListAfterRevoke = false
                throw AppleDomainFailure.unreachable
            }
            return inventory
        }
    }

    func issueCertificate(forSPKI spkiSHA256: String) async throws -> AppleCertificateObservation {
        try lock.withLock {
            calls.append("issue")
            if inventory.count >= capacity || (revoked && capacityAfterRevoke) {
                throw AppleCertificateServiceError.capacityReached
            }
            let issued = AppleCertificateObservation(
                serial: "NEW\(inventory.count)", derSHA256: "der-new", spkiSHA256: issueSPKIOverride ?? spkiSHA256,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000 + 365 * 86_400)
            )
            inventory.append(issued)
            if loseIssueResponse {
                loseIssueResponse = false
                throw URLError(.networkConnectionLost)
            }
            return issued
        }
    }

    func revoke(_ certificate: OwnedObsoleteCertificate) async throws {
        lock.withLock {
            calls.append("revoke:\(certificate.serial)")
            inventory.removeAll { $0.serial == certificate.serial }
            revoked = true
        }
    }
}
