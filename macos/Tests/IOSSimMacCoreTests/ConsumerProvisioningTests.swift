import Foundation
import XCTest
@testable import IOSSimMacCore

final class ConsumerProvisioningTests: XCTestCase {
    func testCertificateSubjectOUWinsOverDisplayNameSuffix() {
        let output = """
        subject= /UID=3WY4BJMTP5/CN=Apple Development: user@example.com (DISPLAY123)/OU=ACTUALTEAM/O=Example/C=US
        SHA1 Fingerprint=83:4D:BB:A7:24:C2:54:30:59:A8:B9:52:18:45:4E:AE:DF:E0:0C:14
        """
        let evidence = ApplePersonalTeamDiscovery.parseCertificateEvidence(output)
        XCTAssertEqual(evidence?.subjectTeamIdentifier, "ACTUALTEAM")
        XCTAssertEqual(evidence?.fingerprint, "834DBBA724C2543059A8B95218454EAEDFE00C14")
        XCTAssertNotEqual(evidence?.subjectTeamIdentifier, "DISPLAY123")
    }

    func testCertificateParserSupportsCommaSeparatedOpenSSLSubject() {
        let output = """
        subject=UID=ABC, CN=Apple Development: user@example.com (DISPLAY), OU=TEAM123, O=Example, C=US
        sha1 Fingerprint=3A:D4:C1:96:58:94:1F:80:5A:EF:81:BF:11:A6:33:05:AB:33:32:57
        """
        XCTAssertEqual(ApplePersonalTeamDiscovery.parseCertificateEvidence(output)?.subjectTeamIdentifier, "TEAM123")
    }

    func testRefreshPolicyUsesFortyEightHourThreshold() {
        let now = Date(timeIntervalSince1970: 10_000)
        let policy = ConsumerRefreshPolicy.recommended
        XCTAssertEqual(policy.dueState(expiration: now.addingTimeInterval(49 * 60 * 60), now: now), .dueSoon)
        XCTAssertEqual(policy.dueState(expiration: now.addingTimeInterval(48 * 60 * 60), now: now), .dueNow)
        XCTAssertEqual(policy.dueState(expiration: now.addingTimeInterval(-1), now: now), .expired)
    }

    func testManifestAtomicRoundTripAndStableRunnerMapping() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-consumer-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConsumerProvisioningStateStore(directoryURL: directory)
        let manifest = try makeManifest(team: "TEAM1", device: "raw-device")
        try await store.saveManifest(manifest)
        let loaded = try await store.loadManifest()
        XCTAssertEqual(loaded?.schemaVersion, manifest.schemaVersion)
        XCTAssertEqual(loaded?.teamID, manifest.teamID)
        XCTAssertEqual(loaded?.deviceIdentifierHash, manifest.deviceIdentifierHash)
        XCTAssertEqual(loaded?.sourceMainBundleID, ProtectedSourceBundleIdentifiers.default.main)
        XCTAssertEqual(loaded?.installedMainBundleID, try PersonalTeamBundleIdentifierSet(teamIdentifier: "TEAM1").main)
        XCTAssertEqual(loaded?.sourceUITestBundleID, ProtectedSourceBundleIdentifiers.default.uiTests)
        XCTAssertEqual(loaded?.installedUITestBundleID, try PersonalTeamBundleIdentifierSet(teamIdentifier: "TEAM1").uiTests)
        XCTAssertEqual(loaded?.sourceRunnerBundleID, ProtectedSourceBundleIdentifiers.default.runner)
        XCTAssertEqual(loaded?.installedRunnerBundleID, try PersonalTeamBundleIdentifierSet(teamIdentifier: "TEAM1").runner)
    }

    func testRuntimeSetupConfirmationPreservesProvisioningIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-consumer-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConsumerProvisioningStateStore(directoryURL: directory)
        let original = try makeManifest(team: "TEAM1", device: "raw-device")
        let checkedAt = Date(timeIntervalSince1970: 42_000)
        try await store.saveManifest(original)

        let updated = try await store.markRuntimeSetupReady(checkedAt: checkedAt)

        XCTAssertEqual(updated.runtimeSetupStatus, .ready)
        XCTAssertEqual(updated.lastRuntimeHealthCheck, checkedAt)
        XCTAssertEqual(updated.teamID, original.teamID)
        XCTAssertEqual(updated.installedMainBundleID, original.installedMainBundleID)
        XCTAssertEqual(updated.installedRunnerBundleID, original.installedRunnerBundleID)
        let persisted = try await store.loadManifest()
        XCTAssertEqual(persisted, updated)
    }

    func testRuntimeSetupConfirmationRequiresInstalledManifest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-consumer-runtime-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConsumerProvisioningStateStore(directoryURL: directory)

        do {
            _ = try await store.markRuntimeSetupReady()
            XCTFail("Expected missing manifest failure")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .runnerMappingMissing)
        }
    }

    func testRefreshAttemptIsRecordedWithoutChangingLastSuccess() throws {
        let original = try makeManifest(team: "TEAM1", device: "raw-device")
        let attemptedAt = Date(timeIntervalSince1970: 52_000)

        let updated = original.recordingRefreshAttempt(at: attemptedAt)

        XCTAssertEqual(updated.lastRefreshAttempt, attemptedAt)
        XCTAssertEqual(updated.lastRefreshSuccess, original.lastRefreshSuccess)
        XCTAssertEqual(updated.installedRunnerBundleID, original.installedRunnerBundleID)
        XCTAssertEqual(updated.runtimeSetupStatus, original.runtimeSetupStatus)
    }

    func testCorruptManifestReturnsStructuredFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-consumer-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appendingPathComponent(ConsumerProvisioningStateStore.manifestFileName))
        let store = ConsumerProvisioningStateStore(directoryURL: directory)
        do {
            _ = try await store.loadManifest()
            XCTFail("Expected corrupt manifest failure")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .manifestCorrupt)
        }
    }

    func testStructuredLogRedactsDeviceAndSecrets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-consumer-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConsumerProvisioningStateStore(directoryURL: directory)
        try await store.append(ProvisioningLogEvent(
            stage: .signingMain,
            selectedDevice: "00008150-00022D581E12401C",
            result: .failed,
            detail: "password=super-secret user@example.com"
        ))
        let events = await store.loadEvents()
        XCTAssertEqual(events.first?.selectedDevice, "000081...401C")
        XCTAssertFalse(events.first?.detail?.contains("super-secret") == true)
        XCTAssertFalse(events.first?.detail?.contains("user@example.com") == true)
    }

    func testStructuredLogReadsLegacyMultilineObjects() throws {
        let first = ProvisioningLogEvent(stage: .signingMain, result: .passed)
        let second = ProvisioningLogEvent(stage: .installingRunner, result: .passed)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try [first, second]
            .map { try encoder.encode($0) }
            .reduce(into: Data()) { output, object in
                output.append(object)
                output.append(0x0A)
            }

        let events = ConsumerProvisioningStateStore.decodeEvents(data)

        XCTAssertEqual(events.map(\.stage), [.signingMain, .installingRunner])
    }

    func testSupportBundleContainsSanitizedStateWithoutRawDeviceOrSecret() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-support-test-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let expandedDirectory = root.appendingPathComponent("expanded", isDirectory: true)
        let output = root.appendingPathComponent("support.zip")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConsumerProvisioningStateStore(directoryURL: stateDirectory)
        let rawDevice = "00008150-00022D581E12401C"
        try await store.saveManifest(try makeManifest(team: "TEAM1", device: rawDevice))
        try await store.append(ProvisioningLogEvent(
            stage: .installingMain,
            selectedDevice: rawDevice,
            result: .failed,
            detail: "password=do-not-export user@example.com"
        ))

        _ = try await SupportBundleExporter.export(
            to: output,
            release: ReleaseManifest(
                sourceCommit: "release-commit",
                sourceDirty: false,
                buildTimestamp: "2026-09-05T12:00:00Z",
                macVersion: "0.1.0",
                buildNumber: "1",
                variant: "PRODUCTION",
                helperSchemaVersion: 1
            ),
            stateStore: store
        )
        try FileManager.default.createDirectory(at: expandedDirectory, withIntermediateDirectories: true)
        let extraction = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", output.path, expandedDirectory.path],
            workingDirectory: root
        )
        XCTAssertEqual(extraction.exitCode, 0)
        let supportURL = expandedDirectory.appendingPathComponent("IOSSim Support/support.json")
        let text = try String(contentsOf: supportURL, encoding: .utf8)
        XCTAssertTrue(text.contains("TEAM1"))
        XCTAssertTrue(text.contains("release-commit"))
        XCTAssertTrue(text.contains("0.1.0"))
        XCTAssertTrue(text.contains("PRODUCTION"))
        XCTAssertTrue(text.contains("True Personal Team profile-expiration extension remains pending"))
        XCTAssertFalse(text.contains(rawDevice))
        XCTAssertFalse(text.contains("do-not-export"))
        XCTAssertFalse(text.contains("user@example.com"))
    }

    func testRefreshCoordinatorRejectsConcurrentOperationAndRecovers() async throws {
        let coordinator = ConsumerRefreshCoordinator()
        try await coordinator.begin()
        do {
            try await coordinator.begin()
            XCTFail("Expected concurrent refresh rejection")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .operationInProgress)
        }
        await coordinator.end()
        try await coordinator.begin()
        await coordinator.end()
    }

    func testProductionManifestMapsCanonicalSourcesToDerivedInstalledIdentities() throws {
        let manifest = try makeManifest(team: "TEAM1", device: "raw-device")
        let expected = try PersonalTeamBundleIdentifierSet(teamIdentifier: "TEAM1")
        XCTAssertEqual(manifest.sourceMainBundleID, ProtectedSourceBundleIdentifiers.default.main)
        XCTAssertEqual(manifest.installedMainBundleID, expected.main)
        XCTAssertNotEqual(manifest.installedMainBundleID, ProtectedSourceBundleIdentifiers.default.main)
        XCTAssertEqual(manifest.sourceUITestBundleID, ProtectedSourceBundleIdentifiers.default.uiTests)
        XCTAssertEqual(manifest.installedUITestBundleID, expected.uiTests)
        XCTAssertEqual(manifest.sourceRunnerBundleID, ProtectedSourceBundleIdentifiers.default.runner)
        XCTAssertEqual(manifest.installedRunnerBundleID, try PersonalTeamBundleIdentifierSet(teamIdentifier: "TEAM1").runner)
        XCTAssertNotEqual(manifest.installedRunnerBundleID, ProtectedSourceBundleIdentifiers.default.runner)
        XCTAssertFalse(manifest.installedBundleIdentifiersForTest.contains(ProtectedSourceBundleIdentifiers.default.witness))
    }

    func testInstallRefreshAndRepairUseSameDerivedMainIdentifier() throws {
        let team = "LA898U57K7"
        let expected = try PersonalTeamBundleIdentifierSet(teamIdentifier: team)

        for operation in [
            ConsumerProvisioningOperation.install,
            .refresh,
            .repair,
        ] {
            let identifiers = try ConsumerArtifactProvisioner.installedIdentifiers(
                teamIdentifier: team,
                operation: operation
            )
            XCTAssertEqual(identifiers.main, expected.main, operation.rawValue)
            XCTAssertEqual(identifiers.runner, expected.runner, operation.rawValue)
            XCTAssertNotEqual(identifiers.main, ProtectedSourceBundleIdentifiers.default.main)
        }
    }

    func testSigningShellRegistersDerivedMainIdentifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-signing-shell-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: "LA898U57K7")

        try SigningShellProjectGenerator.generate(
            at: root,
            teamIdentifier: "LA898U57K7",
            mainBundleIdentifier: identifiers.main,
            uiTestBundleIdentifier: identifiers.uiTests
        )

        let project = try String(
            contentsOf: root.appendingPathComponent("IOSSimSigningShell.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = \(identifiers.main);"))
        XCTAssertFalse(project.contains(
            "PRODUCT_BUNDLE_IDENTIFIER = \(ProtectedSourceBundleIdentifiers.default.main);"
        ))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = \(identifiers.uiTests);"))
    }

    func testCrossTeamInstallErrorIsFirstClass() {
        XCTAssertEqual(
            ConsumerProvisioningErrorClassifier.installErrorCode(
                output: "CoreDeviceError MismatchedApplicationIdentifierEntitlement",
                artifact: "main"
            ),
            .crossTeamUpgradeBlocked
        )
    }

    func testFreshInstallOwnershipPolicyOnlyMatchesIOSSimMainAndRunnerIdentities() {
        XCTAssertTrue(ConsumerInstalledIdentityPolicy.isIOSSimOwnedMain(
            ProtectedSourceBundleIdentifiers.default.main
        ))
        XCTAssertTrue(ConsumerInstalledIdentityPolicy.isIOSSimOwnedMain(
            "com.personalteam.iossim.t218ab9ef6bf9.on-device-dvt-poc"
        ))
        XCTAssertTrue(ConsumerInstalledIdentityPolicy.isIOSSimOwnedRunner(
            ProtectedSourceBundleIdentifiers.default.runner
        ))
        XCTAssertTrue(ConsumerInstalledIdentityPolicy.isIOSSimOwnedRunner(
            "com.personalteam.iossim.t218ab9ef6bf9.location-control-uitests.xctrunner"
        ))
        XCTAssertFalse(ConsumerInstalledIdentityPolicy.isIOSSimOwnedRunner(
            "com.personalteam.iossim.bad.location-control-uitests.xctrunner"
        ))
        XCTAssertFalse(ConsumerInstalledIdentityPolicy.isIOSSimOwnedRunner(
            "com.example.t218ab9ef6bf9.location-control-uitests.xctrunner"
        ))
        XCTAssertFalse(ConsumerInstalledIdentityPolicy.isIOSSimOwnedMain(
            "com.personalteam.iossim.bad.on-device-dvt-poc"
        ))
        XCTAssertFalse(ConsumerInstalledIdentityPolicy.isIOSSimOwnedMain(
            "com.example.t218ab9ef6bf9.on-device-dvt-poc"
        ))
    }

    func testMissingCertificateAndBundleRegistrationAreClassified() {
        XCTAssertEqual(
            ConsumerProvisioningErrorClassifier.signingErrorCode(output: "No signing certificate Apple Development found"),
            .signingIdentityMissing
        )
        XCTAssertEqual(
            ConsumerProvisioningErrorClassifier.signingErrorCode(output: "Failed to register bundle identifier"),
            .bundleIDRegistrationFailure
        )
    }

    private func makeManifest(team: String, device: String) throws -> ConsumerProvisioningManifest {
        let ids = try PersonalTeamBundleIdentifierSet(teamIdentifier: team)
        let expiration = Date().addingTimeInterval(7 * 24 * 60 * 60)
        let mainProfile = profile(artifact: "main", team: team, bundle: ids.main, expiration: expiration)
        let runnerProfile = profile(artifact: "runner", team: team, bundle: ids.runner, expiration: expiration)
        return ConsumerProvisioningManifest(
            deviceIdentifierSafe: RuntimeProvisioning.shortIdentifier(device),
            deviceIdentifierHash: PersonalTeamProvisioningPOC.deviceIdentifierHash(device),
            teamID: team,
            sourceMainBundleID: ProtectedSourceBundleIdentifiers.default.main,
            installedMainBundleID: ids.main,
            sourceUITestBundleID: ProtectedSourceBundleIdentifiers.default.uiTests,
            installedUITestBundleID: ids.uiTests,
            sourceRunnerBundleID: ProtectedSourceBundleIdentifiers.default.runner,
            installedRunnerBundleID: ids.runner,
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            lastInstallDate: Date(),
            appVersion: "1",
            provisionerVersion: "1"
        )
    }

    private func profile(artifact: String, team: String, bundle: String, expiration: Date) -> ConsumerProfileState {
        ConsumerProfileState(
            artifact: artifact,
            teamIdentifier: team,
            bundleIdentifier: bundle,
            creationDate: Date(),
            expirationDate: expiration,
            remainingValidity: expiration.timeIntervalSinceNow,
            selectedDeviceIncluded: true,
            personalTeam: true,
            profileIdentifier: "profile",
            profileFingerprint: "fingerprint",
            refreshRecommended: false
        )
    }
}

private extension ConsumerProvisioningManifest {
    var installedBundleIdentifiersForTest: [String] {
        [installedMainBundleID, installedRunnerBundleID]
    }
}
