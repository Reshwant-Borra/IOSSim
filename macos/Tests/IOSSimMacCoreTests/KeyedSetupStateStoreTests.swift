import Foundation
import XCTest
@testable import IOSSimMacCore

final class KeyedSetupStateStoreTests: XCTestCase {
    private var testRoot: URL!

    override func setUp() {
        super.setUp()
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        testRoot = repositoryRoot
            .appendingPathComponent(".build/iossim/keyed-state-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let testRoot, testRoot.path.contains("/.build/iossim/keyed-state-tests/") {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
        super.tearDown()
    }

    func testSetupKeyIsStableAndSeparatesReleaseTeamDeviceAndArtifacts() throws {
        let original = try identity()
        XCTAssertEqual(original.key, try identity().key)
        let variants = try [
            identity(release: "release-B"),
            identity(team: "TEAM654321"),
            identity(device: "DEVICE-B"),
            identity(artifacts: "artifacts-B"),
        ]
        XCTAssertEqual(Set(variants.map(\.key)).count, variants.count)
        XCTAssertFalse(original.key.contains(original.teamIdentifier))
        XCTAssertFalse(original.key.contains(original.deviceIdentifier))
    }

    func testMutationWritesIntentObservationCommitAndCASnapshot() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        let result: SetupMutationResult<String> = try await store.withMutation(
            identity: selected,
            expectedGeneration: 0,
            domain: "installation",
            safeDetail: "Exact installed inventory observed."
        ) { operationID in
            XCTAssertFalse(operationID.isEmpty)
            return "done"
        }

        XCTAssertEqual(result.value, "done")
        XCTAssertEqual(result.snapshot.generation, 1)
        XCTAssertEqual(result.snapshot.lastDomain, "installation")
        let journal = try await store.journal(identity: selected)
        XCTAssertEqual(journal.map(\.phase), [.intent, .observed, .committed])
        XCTAssertEqual(Set(journal.map(\.operationID)).count, 1)
        XCTAssertEqual(journal.last?.resultingGeneration, 1)
    }

    func testTwoStoresCannotMutateSameSetupKeyConcurrently() async throws {
        let firstStore = KeyedSetupStateStore(rootURL: testRoot)
        let secondStore = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        let gate = MutationGate()
        let first = Task {
            try await firstStore.withMutation(identity: selected, domain: "installation") { _ in
                await gate.wait()
                return true
            }
        }
        while !(await gate.hasStarted) { await Task.yield() }

        do {
            let _: SetupMutationResult<Bool> = try await secondStore.withMutation(
                identity: selected,
                domain: "pairing"
            ) { _ in true }
            XCTFail("Expected OS lease contention")
        } catch let error as SetupStateError {
            XCTAssertEqual(error, .leaseHeld)
            XCTAssertEqual(error.code, "VEYA-STATE-001")
        }
        await gate.open()
        let completed = try await first.value
        XCTAssertEqual(completed.snapshot.generation, 1)
    }

    func testStaleGenerationCannotOverwriteNewerSnapshot() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        let first: SetupMutationResult<Bool> = try await store.withMutation(
            identity: selected,
            expectedGeneration: 0,
            domain: "profiles"
        ) { _ in true }
        XCTAssertEqual(first.snapshot.generation, 1)

        do {
            let _: SetupMutationResult<Bool> = try await store.withMutation(
                identity: selected,
                expectedGeneration: 0,
                domain: "profiles"
            ) { _ in true }
            XCTFail("Expected stale generation rejection")
        } catch let error as SetupStateError {
            XCTAssertEqual(error, .staleGeneration(expected: 0, actual: 1))
        }
        let loaded = try await store.load(identity: selected)
        XCTAssertEqual(loaded.generation, 1)
    }

    func testCrashLeavesUnknownIntentAndRecoveryCommitsObservedEffect() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        do {
            let _: SetupMutationResult<Bool> = try await store.withMutation(
                identity: selected,
                domain: "installation"
            ) { _ in throw SimulatedCrash.crash }
            XCTFail("Expected simulated crash")
        } catch SimulatedCrash.crash {}

        let interruptedSnapshot = try await store.load(identity: selected)
        let interruptedJournal = try await store.journal(identity: selected)
        XCTAssertEqual(interruptedSnapshot.generation, 0)
        XCTAssertEqual(interruptedJournal.map(\.phase), [.intent])
        let recovered = try await store.recoverInterrupted(
            identity: selected,
            effectObserved: true,
            safeDetail: "Exact external inventory proves the interrupted effect."
        )
        XCTAssertEqual(recovered.generation, 1)
        let recoveredJournal = try await store.journal(identity: selected)
        XCTAssertEqual(recoveredJournal.map(\.phase), [.intent, .observed, .committed])
    }

    func testAbandonedInterruptedIntentDoesNotAdvanceGenerationAndCanRetry() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        do {
            let _: SetupMutationResult<Bool> = try await store.withMutation(
                identity: selected,
                domain: "signing"
            ) { _ in throw SimulatedCrash.crash }
        } catch SimulatedCrash.crash {}
        let unchanged = try await store.recoverInterrupted(
            identity: selected,
            effectObserved: false,
            safeDetail: "No candidate signing resource was observed."
        )
        XCTAssertEqual(unchanged.generation, 0)
        let retry: SetupMutationResult<Bool> = try await store.withMutation(
            identity: selected,
            expectedGeneration: 0,
            domain: "signing"
        ) { _ in true }
        XCTAssertEqual(retry.snapshot.generation, 1)
        let journal = try await store.journal(identity: selected)
        XCTAssertEqual(journal.filter { $0.phase == .abandoned }.count, 1)
    }

    func testRecoveryCompletesJournalWhenSnapshotWasRenamedBeforeCommitEntry() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        do {
            let _: SetupMutationResult<Bool> = try await store.withMutation(
                identity: selected,
                domain: "installation"
            ) { _ in throw SimulatedCrash.crash }
        } catch SimulatedCrash.crash {}
        let interruptedJournal = try await store.journal(identity: selected)
        let intent = try XCTUnwrap(interruptedJournal.last)
        let durableSnapshot = SetupStateSnapshot(
            schemaVersion: SetupStateSnapshot.currentSchemaVersion,
            setupKey: selected.key,
            generation: 1,
            releaseIdentityHash: selected.releaseHash,
            teamIdentityHash: selected.teamHash,
            deviceIdentityHash: selected.deviceHash,
            artifactSetIdentityHash: selected.artifactSetHash,
            lastOperationID: intent.operationID,
            lastDomain: intent.domain,
            legacyManifestSHA256: nil,
            updatedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(durableSnapshot).write(
            to: store.directory(for: selected).appendingPathComponent(KeyedSetupStateStore.snapshotFileName),
            options: .atomic
        )

        let recovered = try await store.recoverInterrupted(
            identity: selected,
            effectObserved: false,
            safeDetail: "Snapshot rename was already durable."
        )
        let phases = try await store.journal(identity: selected).map(\.phase)
        XCTAssertEqual(recovered.generation, 1)
        XCTAssertEqual(phases, [.intent, .committed])
    }

    func testCorruptSnapshotFailsClosed() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        let result: SetupMutationResult<Bool> = try await store.withMutation(
            identity: selected,
            domain: "install"
        ) { _ in true }
        let snapshotURL = store.directory(for: selected)
            .appendingPathComponent(KeyedSetupStateStore.snapshotFileName)
        try Data("not-json".utf8).write(to: snapshotURL, options: .atomic)

        do {
            _ = try await store.load(identity: selected)
            XCTFail("Expected corrupt snapshot rejection")
        } catch let error as SetupStateError {
            XCTAssertEqual(error, .corruptSnapshot)
        }
        XCTAssertEqual(result.snapshot.generation, 1)
    }

    func testSecretShapedJournalDetailIsRejectedBeforeWrite() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        do {
            let _: SetupMutationResult<Bool> = try await store.withMutation(
                identity: selected,
                domain: "pairing",
                safeDetail: "password=SENTINEL_SECRET"
            ) { _ in true }
            XCTFail("Expected secret-shaped journal detail rejection")
        } catch let error as SetupStateError {
            XCTAssertEqual(error.code, "VEYA-STATE-005")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.directory(for: selected)
                    .appendingPathComponent(KeyedSetupStateStore.journalFileName).path
            )
        )
    }

    func testDeviceTeamReleaseChangesUseIndependentSnapshots() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let identities = try [
            identity(), identity(device: "DEVICE-B"), identity(team: "TEAM654321"), identity(release: "release-B")
        ]
        for selected in identities {
            let result: SetupMutationResult<Bool> = try await store.withMutation(
                identity: selected,
                expectedGeneration: 0,
                domain: "install"
            ) { _ in true }
            XCTAssertEqual(result.snapshot.generation, 1)
        }
        var directories: [String] = []
        for selected in identities {
            directories.append(store.directory(for: selected).path)
        }
        XCTAssertEqual(Set(directories).count, identities.count)
    }

    func testCorruptJournalFailsClosedWithoutOverwritingSnapshot() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        let committed: SetupMutationResult<Bool> = try await store.withMutation(
            identity: selected,
            domain: "install"
        ) { _ in true }
        let directory = store.directory(for: selected)
        let journalURL = directory.appendingPathComponent(KeyedSetupStateStore.journalFileName)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered\n".utf8))
        try handle.close()

        do {
            _ = try await store.load(identity: selected)
            XCTFail("Expected corrupt journal rejection")
        } catch let error as SetupStateError {
            XCTAssertEqual(error, .corruptJournal)
        }
        let snapshotData = try Data(contentsOf: directory.appendingPathComponent(KeyedSetupStateStore.snapshotFileName))
        XCTAssertTrue(String(decoding: snapshotData, as: UTF8.self).contains("\"generation\":1"))
        XCTAssertEqual(committed.snapshot.generation, 1)
    }

    func testLegacySchemaFourImportStoresOnlyDigestAndSafeAliases() async throws {
        let store = KeyedSetupStateStore(rootURL: testRoot)
        let selected = try identity()
        let legacy = try manifest(team: selected.teamIdentifier, device: selected.deviceIdentifier)
        let data = try JSONEncoder().encode(legacy)
        let snapshot = try await store.importLegacyManifest(data, identity: selected)
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(snapshot.legacyManifestSHA256?.count, 64)

        let directory = store.directory(for: selected)
        let persisted = try String(
            contentsOf: directory.appendingPathComponent(KeyedSetupStateStore.snapshotFileName),
            encoding: .utf8
        ) + String(
            contentsOf: directory.appendingPathComponent(KeyedSetupStateStore.journalFileName),
            encoding: .utf8
        )
        XCTAssertFalse(persisted.contains(selected.deviceIdentifier))
        XCTAssertFalse(persisted.contains(selected.teamIdentifier))
        XCTAssertFalse(persisted.lowercased().contains("password"))
        XCTAssertFalse(persisted.lowercased().contains("privatekey"))
    }

    private func identity(
        release: String = "release-A",
        team: String = "TEAM123456",
        device: String = "DEVICE-A",
        artifacts: String = "artifacts-A"
    ) throws -> SetupIdentity {
        try SetupIdentity(
            releaseIdentity: release,
            teamIdentifier: team,
            deviceIdentifier: device,
            artifactSetIdentity: artifacts
        )
    }

    private func manifest(team: String, device: String) throws -> ConsumerProvisioningManifest {
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: team)
        let profile = ConsumerProfileState(
            artifact: "main",
            teamIdentifier: team,
            bundleIdentifier: identifiers.main,
            creationDate: .now,
            expirationDate: Date().addingTimeInterval(86_400),
            remainingValidity: 86_400,
            selectedDeviceIncluded: true,
            personalTeam: true,
            profileIdentifier: nil,
            profileFingerprint: nil,
            refreshRecommended: false
        )
        let runner = ConsumerProfileState(
            artifact: "runner",
            teamIdentifier: team,
            bundleIdentifier: identifiers.runner,
            creationDate: profile.creationDate,
            expirationDate: profile.expirationDate,
            remainingValidity: profile.remainingValidity,
            selectedDeviceIncluded: true,
            personalTeam: true,
            profileIdentifier: nil,
            profileFingerprint: nil,
            refreshRecommended: false
        )
        return ConsumerProvisioningManifest(
            deviceIdentifierSafe: device,
            deviceIdentifierHash: "legacy-device-hash",
            teamID: team,
            sourceMainBundleID: ProtectedSourceBundleIdentifiers.default.main,
            installedMainBundleID: identifiers.main,
            sourceUITestBundleID: ProtectedSourceBundleIdentifiers.default.uiTests,
            installedUITestBundleID: identifiers.uiTests,
            sourceRunnerBundleID: ProtectedSourceBundleIdentifiers.default.runner,
            installedRunnerBundleID: identifiers.runner,
            mainProfile: profile,
            runnerProfile: runner,
            lastInstallDate: .now,
            appVersion: "1",
            provisionerVersion: "1"
        )
    }
}

private enum SimulatedCrash: Error { case crash }

private actor MutationGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        hasStarted = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
