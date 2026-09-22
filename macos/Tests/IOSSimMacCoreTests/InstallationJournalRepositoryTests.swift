import CryptoKit
import Foundation
@testable import IOSSimMacCore
import XCTest

final class InstallationJournalRepositoryTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    func testNormalWriteReadAndCandidateSurvivesRepositoryRestart() async throws {
        let root = makeRoot()
        let runID = RunID()
        let repository = makeRepository(root: root)
        let initial = try await repository.initialize()
        _ = try await repository.acquireLease(runID: runID)
        let candidate = try makeCandidate(generation: try initial.generation.advanced())
        let written = try await repository.putCandidate(
            candidate,
            runID: runID,
            expectedGeneration: initial.generation
        )

        let reopened = makeRepository(root: root)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded, written)
        XCTAssertEqual(loaded.candidateResource(for: .signingKey)?.id, candidate.id)
    }

    /// Regression: with a real (sub-millisecond) clock every write used to fail post-write verification
    /// because dates persist at millisecond precision. Fixed-clock tests could not see this.
    func testRealClockWritesVerifyAndRoundTrip() async throws {
        let repository = InstallationJournalRepository(rootURL: makeRoot())
        let created = try await repository.initialize()
        let runID = RunID()
        let leased = try await repository.acquireLease(runID: runID)
        let renewed = try await repository.renewLease(runID: runID)
        let released = try await repository.releaseLease(runID: runID)
        let reloaded = try await repository.load()
        XCTAssertEqual(reloaded, released, "returned journal must equal the persisted document")
        XCTAssertEqual(reloaded.installationID, created.installationID)
        XCTAssertEqual(renewed.revision, leased.revision + 1)
        XCTAssertNil(reloaded.lease)
    }

    func testCrashBeforeRenameLeavesPriorJournalAuthoritative() async throws {
        let root = makeRoot()
        let runID = RunID()
        let normal = makeRepository(root: root)
        let initial = try await normal.initialize()
        _ = try await normal.acquireLease(runID: runID)
        let crashing = InstallationJournalRepository(
            rootURL: root,
            now: { self.fixedNow },
            faultInjector: { point in
                if point == .afterTemporaryFileSyncBeforeRename {
                    throw InstallationStateFailure.injectedCrash(point)
                }
            }
        )
        let candidate = try makeCandidate(generation: try initial.generation.advanced())

        do {
            _ = try await crashing.putCandidate(
                candidate,
                runID: runID,
                expectedGeneration: initial.generation
            )
            XCTFail("expected injected crash")
        } catch let error as InstallationStateFailure {
            XCTAssertEqual(error, .injectedCrash(.afterTemporaryFileSyncBeforeRename))
        }
        let loaded = try await normal.load()
        XCTAssertNil(loaded.candidateResource(for: .signingKey))
        XCTAssertEqual(loaded.generation, initial.generation)
    }

    func testDiskFullBeforeRenameLeavesPriorJournalAuthoritative() async throws {
        let root = makeRoot()
        let runID = RunID()
        let normal = makeRepository(root: root)
        let initial = try await normal.initialize()
        _ = try await normal.acquireLease(runID: runID)
        let failing = InstallationJournalRepository(
            rootURL: root,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            faultInjector: { point in
                if point == .afterTemporaryFileSyncBeforeRename {
                    throw InstallationStateFailure.writeFailed("diskFull")
                }
            }
        )

        do {
            _ = try await failing.putCandidate(
                makeCandidate(generation: try initial.generation.advanced()),
                runID: runID,
                expectedGeneration: initial.generation
            )
            XCTFail("expected storage failure")
        } catch let error as InstallationStateFailure {
            XCTAssertEqual(error, .writeFailed("diskFull"))
            XCTAssertEqual(error.code, "VEYA-STATE-004")
        }

        let loaded = try await normal.load()
        XCTAssertEqual(loaded.generation, initial.generation)
        XCTAssertNil(loaded.candidateResource(for: .signingKey))
    }

    func testCrashAfterRenameLeavesNewJournalAuthoritative() async throws {
        let root = makeRoot()
        let runID = RunID()
        let normal = makeRepository(root: root)
        let initial = try await normal.initialize()
        _ = try await normal.acquireLease(runID: runID)
        let crashing = InstallationJournalRepository(
            rootURL: root,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            faultInjector: { point in
                if point == .afterRenameBeforeDirectorySync {
                    throw InstallationStateFailure.injectedCrash(point)
                }
            }
        )
        let candidate = try makeCandidate(generation: try initial.generation.advanced())

        do {
            _ = try await crashing.putCandidate(
                candidate,
                runID: runID,
                expectedGeneration: initial.generation
            )
            XCTFail("expected injected crash")
        } catch let error as InstallationStateFailure {
            XCTAssertEqual(error, .injectedCrash(.afterRenameBeforeDirectorySync))
        }

        let loaded = try await normal.load()
        XCTAssertEqual(loaded.generation, candidate.generation)
        XCTAssertEqual(loaded.candidateResource(for: .signingKey)?.id, candidate.id)
    }

    func testTruncatedPrimaryRecoversPreviousCheckpointWithoutMutation() async throws {
        let root = makeRoot()
        let repository = makeRepository(root: root)
        _ = try await repository.initialize()
        _ = try await repository.acquireLease(runID: RunID())
        try Data("{\"schemaVersion\":".utf8).write(to: repository.journalURL)

        let recovered = try await repository.load()
        XCTAssertTrue(recovered.recovery.required)
        XCTAssertEqual(recovered.recovery.reason, "primaryJournalInvalid")
        XCTAssertEqual(recovered.revision, 0)
    }

    func testCorruptJSONWithoutCheckpointFailsClosed() async throws {
        let root = makeRoot()
        let repository = makeRepository(root: root)
        _ = try await repository.initialize()
        try Data("not-json".utf8).write(to: repository.journalURL)

        do {
            _ = try await repository.load()
            XCTFail("expected corrupt journal")
        } catch let error as InstallationStateFailure {
            XCTAssertEqual(error, .corruptJournal)
        }
    }

    func testOldSchemaIsMigratedInMemoryAndRequiresRecoveryWrite() async throws {
        let root = makeRoot()
        let repository = makeRepository(root: root)
        var journal = try await repository.initialize()
        journal.schemaVersion = 0
        try writeEnvelope(journal, to: repository.journalURL)

        let migrated = try await repository.load()
        XCTAssertEqual(migrated.schemaVersion, InstallationJournal.currentSchemaVersion)
        XCTAssertTrue(migrated.recovery.required)
        XCTAssertEqual(migrated.recovery.reason, "schemaMigrated")
    }

    func testConcurrentLogicalWriterIsRejectedByLiveLease() async throws {
        let root = makeRoot()
        let first = makeRepository(root: root)
        let second = makeRepository(root: root)
        let owner = RunID()
        _ = try await first.initialize()
        _ = try await first.acquireLease(runID: owner)

        do {
            _ = try await second.acquireLease(runID: RunID())
            XCTFail("expected lease conflict")
        } catch let error as InstallationStateFailure {
            XCTAssertEqual(error, .leaseHeld(owner))
        }
    }

    func testGenerationMismatchRejectsCandidateWithoutChangingState() async throws {
        let root = makeRoot()
        let repository = makeRepository(root: root)
        let runID = RunID()
        _ = try await repository.initialize()
        _ = try await repository.acquireLease(runID: runID)
        let candidate = try makeCandidate(generation: Generation(rawValue: 2))

        do {
            _ = try await repository.putCandidate(
                candidate,
                runID: runID,
                expectedGeneration: .initial
            )
            XCTFail("expected generation mismatch")
        } catch let error as InstallationStateFailure {
            XCTAssertEqual(
                error,
                .staleGeneration(expected: Generation(rawValue: 1), actual: Generation(rawValue: 2))
            )
        }
        let unchanged = try await repository.load()
        XCTAssertNil(unchanged.candidateResource(for: .signingKey))
    }

    func testStaleLeaseIsRecoveredExplicitly() async throws {
        let root = makeRoot()
        let expiredTime = Date(timeIntervalSince1970: 100)
        let first = InstallationJournalRepository(rootURL: root, now: { expiredTime })
        _ = try await first.initialize()
        _ = try await first.acquireLease(runID: RunID(), duration: 1)

        let second = InstallationJournalRepository(
            rootURL: root,
            now: { expiredTime.addingTimeInterval(2) }
        )
        let recovered = try await second.acquireLease(runID: RunID())
        XCTAssertTrue(recovered.recovery.required)
        XCTAssertEqual(recovered.recovery.reason, "staleLeaseRecovered")
    }

    func testCandidateRequiresEvidenceBeforePromotion() async throws {
        let root = makeRoot()
        let repository = makeRepository(root: root)
        let runID = RunID()
        _ = try await repository.initialize()
        _ = try await repository.acquireLease(runID: runID)
        let generation = Generation(rawValue: 1)
        _ = try await repository.putCandidate(
            makeCandidate(generation: generation),
            runID: runID,
            expectedGeneration: .initial
        )

        do {
            _ = try await repository.promote(
                domain: .signingKey,
                runID: runID,
                expectedGeneration: generation
            )
            XCTFail("expected proof requirement")
        } catch let error as InstallationStateFailure {
            XCTAssertEqual(error, .candidateUnproved(.signingKey))
        }

        let evidence = try makeEvidence(generation: generation)
        _ = try await repository.attachEvidence(evidence, runID: runID)
        let promoted = try await repository.promote(
            domain: .signingKey,
            runID: runID,
            expectedGeneration: generation
        )
        XCTAssertNotNil(promoted.activeResource(for: .signingKey))
        XCTAssertNil(promoted.candidateResource(for: .signingKey))
    }

    func testActiveSurvivesCandidateFailureAndDiscard() async throws {
        let root = makeRoot()
        let repository = makeRepository(root: root)
        let runID = RunID()
        _ = try await repository.initialize()
        _ = try await repository.acquireLease(runID: runID)
        let firstGeneration = Generation(rawValue: 1)
        let first = try makeCandidate(generation: firstGeneration, resourceID: "key-one")
        _ = try await repository.putCandidate(first, runID: runID, expectedGeneration: .initial)
        _ = try await repository.attachEvidence(try makeEvidence(generation: firstGeneration), runID: runID)
        _ = try await repository.promote(
            domain: .signingKey,
            runID: runID,
            expectedGeneration: firstGeneration
        )

        let secondGeneration = Generation(rawValue: 2)
        let second = try makeCandidate(generation: secondGeneration, resourceID: "key-two")
        _ = try await repository.putCandidate(
            second,
            runID: runID,
            expectedGeneration: firstGeneration
        )
        let discarded = try await repository.discardCandidate(
            domain: .signingKey,
            runID: runID,
            expectedGeneration: secondGeneration
        )
        XCTAssertEqual(discarded.activeResource(for: .signingKey)?.identity.resourceID, "key-one")
        XCTAssertNil(discarded.candidateResource(for: .signingKey))
    }

    func testSecretShapedMetadataIsRejectedBeforePersistence() throws {
        XCTAssertThrowsError(
            try ResourceRecord(
                identity: ResourceIdentity(domain: .signingKey, resourceID: "safe-key"),
                lifecycle: .candidate,
                generation: Generation(rawValue: 1),
                ownership: .privateKeyControl,
                createdAt: fixedNow,
                observedAt: fixedNow,
                metadata: ["password": "do-not-write"]
            )
        ) { error in
            XCTAssertEqual(error as? InstallationStateFailure, .secretMaterialRejected("attribute key"))
        }
    }

    func testOpaqueIdentifiersContainingTwoFactorHexAreNotMisclassifiedAsSecrets() throws {
        XCTAssertNoThrow(try ResourceIdentity(
            domain: .signingKey,
            resourceID: "8d2fa039-opaque-resource",
            digest: digest("opaque")
        ))
    }

    private func makeRoot() -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/installation-v2-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        roots.append(root)
        return root
    }

    private func makeRepository(root: URL) -> InstallationJournalRepository {
        InstallationJournalRepository(rootURL: root, now: { self.fixedNow })
    }

    private func makeCandidate(
        generation: Generation,
        resourceID: String = "key-candidate"
    ) throws -> ResourceRecord {
        try ResourceRecord(
            identity: ResourceIdentity(
                domain: .signingKey,
                resourceID: resourceID,
                digest: digest(resourceID)
            ),
            lifecycle: .candidate,
            generation: generation,
            ownership: .privateKeyControl,
            createdAt: fixedNow,
            observedAt: fixedNow,
            relativeLocation: "secrets/signing-keys/\(resourceID).vkey"
        )
    }

    private func makeEvidence(generation: Generation) throws -> Evidence {
        try Evidence(
            id: digest("evidence-\(generation.rawValue)"),
            kind: "localSignVerify",
            generation: generation,
            subject: ResourceIdentity(domain: .signingKey, resourceID: "key-candidate"),
            capturedAt: fixedNow,
            provenance: "installation-v2-tests"
        )
    }

    private func digest(_ value: String) -> String {
        "sha256:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func writeEnvelope(_ journal: InstallationJournal, to url: URL) throws {
        struct Envelope: Codable {
            let schemaVersion: Int
            let digest: String
            let payload: InstallationJournal
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payloadData = try encoder.encode(journal)
        let payloadDigest = "sha256:" + SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }.joined()
        let data = try encoder.encode(Envelope(schemaVersion: 1, digest: payloadDigest, payload: journal))
        try data.write(to: url, options: .atomic)
    }
}
