import CryptoKit
import Foundation
import Security
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
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let manifestURL = await store.manifestURL
        let manifestMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(manifestMode, 0o600)
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
        let logURL = await store.logURL
        let logMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: logURL.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(logMode, 0o600)
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
            stateStore: store,
            authorizationSessionStore: EmptyAuthorizationSessionStore()
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
        XCTAssertTrue(text.contains("Physical Personal Team provisioning, signing, main installation, runner installation"))
        XCTAssertTrue(text.contains("does not claim clean-Mac, no-Xcode, runtime-location, or public-release qualification"))
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

    func testLegacyXcodeManagedSigningShellRetainsAutomaticProvisioning() {
        let arguments = SigningShellBuildPlan.arguments(
            projectURL: URL(fileURLWithPath: "/fixture/SigningShell.xcodeproj"),
            derivedDataURL: URL(fileURLWithPath: "/fixture/DerivedData"),
            teamIdentifier: "LEGACYTEAM"
        )
        XCTAssertEqual(arguments.first, "xcodebuild")
        XCTAssertTrue(arguments.contains("build-for-testing"))
        XCTAssertTrue(arguments.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(arguments.contains("CODE_SIGN_STYLE=Automatic"))
        XCTAssertTrue(arguments.contains("DEVELOPMENT_TEAM=LEGACYTEAM"))
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

    func testDeviceDisconnectInstallErrorsAreRetryableDeviceUnavailability() {
        for output in [
            "Device unavailable: iPhone disconnected",
            "The device was not found",
            "Failed to connect to device; connection invalidated",
        ] {
            XCTAssertEqual(
                ConsumerProvisioningErrorClassifier.installErrorCode(output: output, artifact: "main"),
                .deviceUnavailable,
                output
            )
        }
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

    func testNativeSignatureVerificationFailureDoesNotSuggestXcodeAccountOrReauthorization() {
        let remediation = SignatureVerificationRemediation.message(nativeManaged: true)
        XCTAssertFalse(remediation.localizedCaseInsensitiveContains("Xcode"))
        XCTAssertFalse(remediation.localizedCaseInsensitiveContains("authorize again"))
        XCTAssertTrue(remediation.localizedCaseInsensitiveContains("authorization remains valid"))
        XCTAssertTrue(SignatureVerificationRemediation.message(nativeManaged: false).contains("Xcode"))
    }

    func testNativePersonalTeamDownstreamSucceedsWithoutXcodeAccountOrAutomaticProvisioning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-native-downstream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let state = root.appendingPathComponent("State", isDirectory: true)
        let nativeState = root.appendingPathComponent("NativeState", isDirectory: true)
        let workspaces = root.appendingPathComponent("Workspaces", isDirectory: true)
        let team = "T8SL4SG87F"
        let physicalUDID = "00008150-00022D581E12401C"
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: team)
        XCTAssertEqual(identifiers.main, "com.personalteam.iossim.t026e0910b111.on-device-dvt-poc")
        XCTAssertEqual(identifiers.runner, "com.personalteam.iossim.t026e0910b111.location-control-uitests.xctrunner")
        let certificate = Data("fixture-development-certificate".utf8)
        let certificateSHA256 = SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
        let certificateSHA1 = Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
        let profiles = try makeNativeProfiles(
            team: team,
            physicalUDID: physicalUDID,
            identifiers: identifiers,
            certificate: certificate,
            certificateFingerprint: certificateSHA256
        )
        let preparation = ExperimentalProvisioningPreparation(
            team: ExperimentalAppleTeam(id: team, name: "Personal Team", isPersonalTeam: true, isPaidDeveloperTeam: false),
            identity: ExperimentalSigningIdentity(
                certificateFingerprint: certificateSHA256,
                certificateExpiration: Date().addingTimeInterval(30 * 24 * 60 * 60),
                privateKeyPersistentReference: Data("keychain-reference".utf8),
                reused: true
            ),
            derivedIdentifiers: identifiers,
            profiles: profiles
        )
        let nativeStore = NativeProvisioningArtifactStore(directoryURL: nativeState)
        try await nativeStore.save(preparation, selectedDeviceIdentifier: physicalUDID)
        try makeConsumerArtifactFixture(at: resources)

        let recorder = NativePipelineRecorder(
            team: team,
            physicalUDID: physicalUDID,
            identifiers: identifiers,
            certificateSHA1: certificateSHA1,
            profileDataByBundle: Dictionary(uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0.profileData) })
        )
        let runner = ProcessRunner { executable, arguments, _, _, _ in
            try await recorder.run(executable: executable, arguments: arguments)
        }
        let provisioner = ConsumerArtifactProvisioner(
            context: RuntimeProvisioningContext(resourcesURL: resources, runner: runner),
            stateStore: ConsumerProvisioningStateStore(directoryURL: state),
            nativeArtifactStore: nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: workspaces
        )

        let result = try await provisioner.provision(ConsumerProvisioningRequest(
            operation: .install,
            selectedDeviceIdentifier: physicalUDID,
            selectedTeamIdentifier: team,
            allowFreshInstallAfterCrossTeamConflict: true,
            backend: .nativePersonalTeam
        ))

        XCTAssertEqual(result.finalStage, .complete)
        XCTAssertEqual(result.manifest.teamID, team)
        XCTAssertEqual(result.manifest.installedMainBundleID, identifiers.main)
        XCTAssertEqual(result.manifest.installedRunnerBundleID, identifiers.runner)
        let evidence = await recorder.evidence()
        XCTAssertFalse(evidence.commands.contains { $0.executable.lastPathComponent == "xcodebuild" || $0.arguments.first == "xcodebuild" })
        XCTAssertFalse(evidence.commands.flatMap(\.arguments).contains("-allowProvisioningUpdates"))
        XCTAssertFalse(evidence.commands.flatMap(\.arguments).contains("CODE_SIGN_STYLE=Automatic"))
        XCTAssertTrue(evidence.commands.contains { $0.arguments.contains(certificateSHA1) && $0.arguments.contains("--sign") })
        XCTAssertTrue(evidence.commands.contains { $0.arguments.contains(where: { $0.hasSuffix(".xctest") }) && $0.arguments.contains("--sign") })
        XCTAssertTrue(evidence.commands.contains { $0.arguments.contains(where: { $0.hasSuffix(".xctest") }) && $0.arguments.contains("--verify") })
        XCTAssertEqual(evidence.installedProfiles[identifiers.main], profiles.first(where: { $0.bundleIdentifier == identifiers.main })?.profileData)
        XCTAssertEqual(evidence.installedProfiles[identifiers.runner], profiles.first(where: { $0.bundleIdentifier == identifiers.runner })?.profileData)
        XCTAssertEqual(evidence.runtimeRunnerMapping, identifiers.runner)
        XCTAssertEqual(Set(evidence.installedBundleIdentifiers), Set([identifiers.main, identifiers.runner]))
        XCTAssertTrue(evidence.uninstalledBundleIdentifiers.allSatisfy(ConsumerInstalledIdentityPolicy.isIOSSimOwnedMainOrRunner))
    }

    func testNativeArtifactStoreRejectsHistoricalTeamDeviceAndExpiredProfilesAsProvisioningFailures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-native-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let team = "T8SL4SG87F"
        let udid = "00008150-00022D581E12401C"
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: team)
        let certificate = Data("certificate".utf8)
        let fingerprint = SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
        let profiles = try makeNativeProfiles(
            team: team,
            physicalUDID: udid,
            identifiers: identifiers,
            certificate: certificate,
            certificateFingerprint: fingerprint
        )
        let preparation = ExperimentalProvisioningPreparation(
            team: .init(id: team, name: "Personal Team", isPersonalTeam: true, isPaidDeveloperTeam: false),
            identity: .init(
                certificateFingerprint: fingerprint,
                certificateExpiration: Date().addingTimeInterval(86_400),
                privateKeyPersistentReference: Data([1]),
                keyApplicationTagIdentifier: "com.iossim.personal-team.\(team).00000000-0000-0000-0000-000000000001",
                reused: true
            ),
            derivedIdentifiers: identifiers,
            profiles: profiles
        )
        let store = NativeProvisioningArtifactStore(directoryURL: root)
        try await store.save(preparation, selectedDeviceIdentifier: udid)
        _ = try await store.load(teamIdentifier: team, selectedDeviceIdentifier: udid)
        _ = try await store.load(teamIdentifier: team)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let artifactURL = await store.artifactURL
        let artifactMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: artifactURL.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(artifactMode, 0o600)
        let serializedArtifacts = try String(contentsOf: artifactURL, encoding: .utf8)
        XCTAssertTrue(serializedArtifacts.contains("keyApplicationTagIdentifier"))
        XCTAssertFalse(serializedArtifacts.contains("privateKeyPersistentReference"))

        for (otherTeam, otherDevice) in [("OLDRTEAM01", udid), (team, "00008150-OTHERDEVICE000") ] {
            do {
                _ = try await store.load(teamIdentifier: otherTeam, selectedDeviceIdentifier: otherDevice)
                XCTFail("Expected scoped native artifact rejection")
            } catch let failure as ConsumerProvisioningFailure {
                XCTAssertEqual(failure.code, .profileUnavailable)
                XCTAssertFalse(failure.userMessage.localizedCaseInsensitiveContains("authorization"))
            }
        }
        do {
            _ = try await store.load(
                teamIdentifier: team,
                selectedDeviceIdentifier: udid,
                now: Date().addingTimeInterval(8 * 24 * 60 * 60)
            )
            XCTFail("Expected expired profile rejection")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .profileUnavailable)
        }
    }

    func testInvalidNativeCertificateProfileContinuityFailsBeforeFreshInstallDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-native-preflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let team = "T8SL4SG87F"
        let physicalUDID = "00008150-00022D581E12401C"
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: team)
        let profileCertificate = Data("profile-certificate".utf8)
        let differentIdentityCertificate = Data("different-identity-certificate".utf8)
        let identityFingerprint = SHA256.hash(data: differentIdentityCertificate)
            .map { String(format: "%02X", $0) }.joined()
        let profiles = try makeNativeProfiles(
            team: team,
            physicalUDID: physicalUDID,
            identifiers: identifiers,
            certificate: profileCertificate,
            certificateFingerprint: identityFingerprint
        )
        let preparation = ExperimentalProvisioningPreparation(
            team: .init(id: team, name: "Personal Team", isPersonalTeam: true, isPaidDeveloperTeam: false),
            identity: .init(
                certificateFingerprint: identityFingerprint,
                certificateExpiration: Date().addingTimeInterval(86_400),
                privateKeyPersistentReference: Data([1]),
                reused: true
            ),
            derivedIdentifiers: identifiers,
            profiles: profiles
        )
        let nativeStore = NativeProvisioningArtifactStore(directoryURL: root.appendingPathComponent("NativeState"))
        try await nativeStore.save(preparation, selectedDeviceIdentifier: physicalUDID)
        try makeConsumerArtifactFixture(at: resources)
        let recorder = NativePipelineRecorder(
            team: team,
            physicalUDID: physicalUDID,
            identifiers: identifiers,
            certificateSHA1: Insecure.SHA1.hash(data: differentIdentityCertificate)
                .map { String(format: "%02X", $0) }.joined(),
            profileDataByBundle: Dictionary(uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0.profileData) })
        )
        let provisioner = ConsumerArtifactProvisioner(
            context: RuntimeProvisioningContext(resourcesURL: resources, runner: ProcessRunner { executable, arguments, _, _, _ in
                try await recorder.run(executable: executable, arguments: arguments)
            }),
            stateStore: ConsumerProvisioningStateStore(directoryURL: root.appendingPathComponent("State")),
            nativeArtifactStore: nativeStore,
            workspaceRootURL: root.appendingPathComponent("Workspaces")
        )

        do {
            _ = try await provisioner.provision(.init(
                operation: .install,
                selectedDeviceIdentifier: physicalUDID,
                selectedTeamIdentifier: team,
                allowFreshInstallAfterCrossTeamConflict: true,
                backend: .nativePersonalTeam
            ))
            XCTFail("Expected native certificate continuity failure")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .profileCertificateMismatch)
            XCTAssertFalse(failure.userMessage.localizedCaseInsensitiveContains("authorization"))
        }
        let evidence = await recorder.evidence()
        XCTAssertTrue(evidence.uninstalledBundleIdentifiers.isEmpty)
        XCTAssertTrue(evidence.installedBundleIdentifiers.isEmpty)
        XCTAssertFalse(evidence.commands.contains { $0.arguments.contains("--sign") })
    }

    func testExplicitNestedCodesignFixturePassesStrictVerificationAndEntitlementInspection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-explicit-codesign-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = root.appendingPathComponent("Fixture-Runner.app", isDirectory: true)
        let test = runner.appendingPathComponent("PlugIns/Fixture.xctest", isDirectory: true)
        try FileManager.default.createDirectory(at: test, withIntermediateDirectories: true)
        try writeExecutableBundle(runner, identifier: "com.example.fixture.xctrunner", executable: "Runner")
        try writeExecutableBundle(test, identifier: "com.example.fixture", executable: "Fixture")
        let entitlements: [String: Any] = ["get-task-allow": true]
        let entitlementsURL = root.appendingPathComponent("runner-entitlements.plist")
        let entitlementData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try entitlementData.write(to: entitlementsURL)
        let processRunner = ProcessRunner()

        var result = try await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", test.path],
            workingDirectory: root
        )
        XCTAssertEqual(result.exitCode, 0, result.combinedOutput)
        result = try await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", "--entitlements", entitlementsURL.path, runner.path],
            workingDirectory: root
        )
        XCTAssertEqual(result.exitCode, 0, result.combinedOutput)
        for bundle in [test, runner] {
            result = try await processRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--strict", bundle.path],
                workingDirectory: root
            )
            XCTAssertEqual(result.exitCode, 0, result.combinedOutput)
        }
        result = try await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--entitlements", ":-", runner.path],
            workingDirectory: root
        )
        XCTAssertEqual(result.exitCode, 0, result.combinedOutput)
        XCTAssertTrue(result.combinedOutput.contains("get-task-allow"))
    }

    func testEveryDownstreamFaultPreservesNativeContextAndRetryCompletesWithoutDestructiveRollback() async throws {
        let expectations: [(ConsumerProvisioningFaultPoint, ConsumerProvisioningErrorCode, ConsumerProvisioningStage)] = [
            (.signingIdentityResolution, .signingIdentityNotFound, .preparingIdentities),
            (.preparingArtifacts, .artifactInvalid, .preparingArtifacts),
            (.nestedSigning, .nestedSigningFailed, .signingNestedComponents),
            (.mainSigning, .signOperationFailed, .signingMain),
            (.runnerSigning, .signOperationFailed, .signingRunner),
            (.signatureVerification, .signatureVerificationFailed, .verifyingSignatures),
            (.installMain, .mainInstallFailure, .installingMain),
            (.installRunner, .runnerInstallFailure, .installingRunner),
            (.installVerification, .mainInstallFailure, .verifyingInstallation),
            (.runtimeConfigWrite, .runtimeVerificationFailed, .writingRuntimeConfiguration),
            (.runtimeConfigVerify, .runtimeVerificationFailed, .verifyingRuntimeConfiguration),
            (.deviceDisconnected, .deviceUnavailable, .waitingForDevice),
        ]
        XCTAssertEqual(Set(expectations.map(\.0)), Set(ConsumerProvisioningFaultPoint.allCases))

        for (point, expectedCode, expectedStage) in expectations {
            let harness = try await makeNativeHarness(faultPoint: point)
            defer { try? FileManager.default.removeItem(at: harness.root) }
            do {
                _ = try await harness.provisioner.provision(harness.request)
                XCTFail("Expected injected failure at \(point.rawValue)")
            } catch let failure as ConsumerProvisioningFailure {
                XCTAssertEqual(failure.code, expectedCode, point.rawValue)
                XCTAssertEqual(failure.stage, expectedStage, point.rawValue)
            }
            _ = try await harness.nativeStore.load(
                teamIdentifier: harness.team,
                selectedDeviceIdentifier: harness.physicalUDID
            )
            let failedEvidence = await harness.recorder.evidence()
            XCTAssertTrue(failedEvidence.uninstalledBundleIdentifiers.isEmpty, point.rawValue)

            let retry = ConsumerArtifactProvisioner(
                context: RuntimeProvisioningContext(resourcesURL: harness.resources, runner: harness.runner),
                stateStore: harness.stateStore,
                nativeArtifactStore: harness.nativeStore,
                nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
                workspaceRootURL: harness.workspaces
            )
            let retried = try await retry.provision(harness.request)
            XCTAssertEqual(retried.finalStage, .complete, point.rawValue)
        }
    }

    func testDisconnectedPhoneStillCompletesLocalNativePreparationAndWaitsWithoutReauthentication() async throws {
        let harness = try await makeNativeHarness(faultPoint: .deviceDisconnected)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let disconnectedRunner = ProcessRunner { executable, arguments, _, _, _ in
            if executable.path == "/usr/bin/xcrun", arguments.starts(with: ["devicectl", "list", "devices"]) {
                if let index = arguments.firstIndex(of: "--json-output"), arguments.indices.contains(index + 1) {
                    let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": []]])
                    try data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
                }
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if executable.path == "/usr/bin/xcrun", arguments.starts(with: ["devicectl", "device", "install", "app"]) {
                return .init(exitCode: 1, stdout: "", stderr: "Device unavailable: iPhone disconnected")
            }
            return try await harness.recorder.run(executable: executable, arguments: arguments)
        }
        let stateStore = ConsumerProvisioningStateStore(directoryURL: harness.root.appendingPathComponent("DisconnectedState"))
        let provisioner = ConsumerArtifactProvisioner(
            context: RuntimeProvisioningContext(resourcesURL: harness.resources, runner: disconnectedRunner),
            stateStore: stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces
        )

        do {
            _ = try await provisioner.provision(harness.request)
            XCTFail("Expected the device-dependent install stage to wait")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .deviceUnavailable)
            XCTAssertEqual(failure.stage, .waitingForDevice)
            XCTAssertTrue(failure.remediation.contains("authorization") || failure.remediation.contains("Authorization"))
        }
        _ = try await harness.nativeStore.load(teamIdentifier: harness.team)
        let passed = await stateStore.loadEvents().filter { $0.result == .passed }.map(\.stage)
        for localStage in [
            ConsumerProvisioningStage.preparedNativeContextReused,
            .signingIdentityResolved, .preparingArtifacts, .signingNestedComponents,
            .signingMain, .signingRunner, .verifyingSignatures,
            .artifactValidationComplete, .installCommandsPrepared, .runtimeConfigurationPrepared,
        ] {
            XCTAssertTrue(passed.contains(localStage), "Missing disconnected local stage \(localStage.rawValue)")
        }
    }

    func testPhysicalUntrustedDeveloperErrorUsesStructuredTrustClassification() {
        let physicalError = """
        ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))
        The request was denied. (FBSOpenApplicationErrorDomain error 3 (0x03))
        BSErrorCodeDescription = Security
        Unable to launch because its profile has not been explicitly trusted by the user.
        """
        XCTAssertEqual(
            ConsumerProvisioningErrorClassifier.launchErrorCode(output: physicalError),
            .developerProfileTrustRequired
        )
        XCTAssertEqual(
            ConsumerProvisioningErrorClassifier.launchErrorCode(
                output: "FBSOpenApplicationErrorDomain error 3 BSErrorCodeDescription = Security invalid signature"
            ),
            .runtimeConfigurationWriteFailed
        )
    }

    func testPostInstallInventoryRetriesMissingMainThenSucceedsWithoutUserFailure() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let ids = try PersonalTeamBundleIdentifierSet(teamIdentifier: harness.team)
        let reader = SequenceApplicationInventoryReader([
            .available([]),
            .available([ids.runner]),
            .available([ids.main, ids.runner]),
        ])
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: harness.runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryReader: reader,
            inventoryRetryPolicy: .immediateTesting,
            profileWriteOptions: .atomic
        )

        let result = try await provisioner.provision(harness.request)

        XCTAssertEqual(result.finalStage, .complete)
        XCTAssertEqual(result.manifest.installationInventory?.retryCount, 1)
        let events = await harness.stateStore.loadEvents()
        XCTAssertTrue(events.contains { $0.stage == .installInventoryPending })
        XCTAssertFalse(events.contains { $0.result == .failed })
    }

    func testPostInstallInventoryImmediateExactMatchNeedsNoRetry() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let ids = try PersonalTeamBundleIdentifierSet(teamIdentifier: harness.team)
        let reader = SequenceApplicationInventoryReader([
            .available([]),
            .available([ids.main, ids.runner]),
        ])
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: harness.runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryReader: reader,
            inventoryRetryPolicy: .immediateTesting,
            profileWriteOptions: .atomic
        )

        let result = try await provisioner.provision(harness.request)
        let events = await harness.stateStore.loadEvents()

        XCTAssertEqual(result.manifest.installationInventory?.retryCount, 0)
        XCTAssertTrue(result.manifest.installationInventory?.verified == true)
        XCTAssertFalse(events.contains { $0.stage == .installInventoryPending })
    }

    func testPostInstallInventoryRetriesMainOnlyUntilRunnerAppears() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let ids = try PersonalTeamBundleIdentifierSet(teamIdentifier: harness.team)
        let reader = SequenceApplicationInventoryReader([
            .available([]),
            .available([ids.main]),
            .available([ids.main, ids.runner]),
        ])
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: harness.runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryReader: reader,
            inventoryRetryPolicy: .immediateTesting,
            profileWriteOptions: .atomic
        )

        let result = try await provisioner.provision(harness.request)

        XCTAssertEqual(result.manifest.installationInventory?.safeReason, "exact current main and runner present")
        XCTAssertEqual(result.manifest.installationInventory?.retryCount, 1)
    }

    func testPostInstallInventoryBoundProducesVerificationFailureAndResumeCheckpoint() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let reader = SequenceApplicationInventoryReader([.available([])])
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: harness.runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryReader: reader,
            inventoryRetryPolicy: .init(backoffNanoseconds: [0, 0]),
            profileWriteOptions: .atomic
        )

        do {
            _ = try await provisioner.provision(harness.request)
            XCTFail("Expected bounded inventory failure")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .installVerificationFailed)
            XCTAssertEqual(failure.stage, .verifyingInstallation)
        }
        let checkpoint = try await harness.stateStore.loadManifest()?.effectiveSetupCheckpoint
        let readCount = await reader.readCount
        XCTAssertEqual(checkpoint, .installCommandsSucceeded)
        XCTAssertEqual(readCount, 4) // validation + three bounded post-install reads
    }

    func testPostInstallInventoryDisconnectTransitionsToWaitingForDevice() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let reader = SequenceApplicationInventoryReader([
            .available([]),
            .unavailable(.deviceUnavailable, reason: "device disconnected"),
        ])
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: harness.runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryReader: reader,
            inventoryRetryPolicy: .immediateTesting,
            profileWriteOptions: .atomic
        )

        do {
            _ = try await provisioner.provision(harness.request)
            XCTFail("Expected disconnect")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .deviceUnavailable)
            XCTAssertEqual(failure.stage, .waitingForDevice)
        }
    }

    func testWrongTeamInventoryNeverCountsAsCurrentInstallation() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let stale = try PersonalTeamBundleIdentifierSet(teamIdentifier: "5337SALD55")
        let reader = SequenceApplicationInventoryReader([.available([stale.main, stale.runner])])
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: harness.runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryReader: reader,
            inventoryRetryPolicy: .init(backoffNanoseconds: [0]),
            profileWriteOptions: .atomic
        )
        do {
            _ = try await provisioner.provision(harness.request)
            XCTFail("Expected exact-current inventory failure")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .installedIdentityMigrationRequired)
        }
    }

    func testCurrentInventoryOverridesHistoricalTeamManifestWithoutFreshInstall() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.stateStore.saveManifest(try makeManifest(team: "5337SALD55", device: harness.physicalUDID))
        let current = try PersonalTeamBundleIdentifierSet(teamIdentifier: harness.team)
        let reader = SequenceApplicationInventoryReader([
            .available([current.main, current.runner]),
            .available([current.main, current.runner]),
        ])
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: harness.runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryReader: reader,
            inventoryRetryPolicy: .immediateTesting,
            profileWriteOptions: .atomic
        )

        let result = try await provisioner.provision(harness.request)

        XCTAssertEqual(result.manifest.teamID, harness.team)
        let evidence = await harness.recorder.evidence()
        let events = await harness.stateStore.loadEvents()
        XCTAssertTrue(evidence.uninstalledBundleIdentifiers.isEmpty)
        XCTAssertTrue(events.contains {
            $0.errorCode == .staleTeamState && $0.result == .passed
        })
    }

    func testRefreshUsesPostInstallInventoryWhenPreInstallInventoryMissesMain() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try await harness.stateStore.saveManifest(
            try makeManifest(team: harness.team, device: harness.physicalUDID)
        )
        let current = try PersonalTeamBundleIdentifierSet(teamIdentifier: harness.team)
        let reader = SequenceApplicationInventoryReader([
            .available([]),
            .available([current.main, current.runner]),
        ])
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: harness.runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryReader: reader,
            inventoryRetryPolicy: .immediateTesting,
            profileWriteOptions: .atomic
        )
        let request = ConsumerProvisioningRequest(
            operation: .refresh,
            selectedDeviceIdentifier: harness.physicalUDID,
            selectedTeamIdentifier: harness.team,
            backend: .nativePersonalTeam
        )

        let result = try await provisioner.provision(request)

        XCTAssertEqual(result.finalStage, .complete)
        XCTAssertTrue(result.manifest.installationInventory?.verified == true)
        XCTAssertEqual(result.manifest.installationInventory?.retryCount, 0)
        let inventoryReadCount = await reader.readCount
        XCTAssertEqual(inventoryReadCount, 2)
    }

    func testDeveloperTrustPendingPersistsAndResumeNeverReinstalls() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let ids = try PersonalTeamBundleIdentifierSet(teamIdentifier: harness.team)
        let inventory = SequenceApplicationInventoryReader([
            .available([]), .available([ids.main, ids.runner]),
        ])
        let launch = LaunchSequenceRecorder(
            base: harness.recorder,
            results: [.untrustedDeveloper, .untrustedDeveloper, .success]
        )
        let runner = ProcessRunner { executable, arguments, _, _, _ in
            try await launch.run(executable: executable, arguments: arguments)
        }
        func makeProvisioner() -> ConsumerArtifactProvisioner {
            ConsumerArtifactProvisioner(
                context: .init(resourcesURL: harness.resources, runner: runner),
                stateStore: harness.stateStore,
                nativeArtifactStore: harness.nativeStore,
                nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
                workspaceRootURL: harness.workspaces,
                inventoryReader: inventory,
                inventoryRetryPolicy: .immediateTesting,
                profileWriteOptions: .atomic
            )
        }

        let initial = try await makeProvisioner().provision(harness.request)
        XCTAssertEqual(initial.finalStage, .developerProfileTrustRequired)
        XCTAssertEqual(initial.manifest.developerProfileTrustStatus, .required)
        let persistedCheckpoint = try await harness.stateStore.loadManifest()?.effectiveSetupCheckpoint
        XCTAssertEqual(persistedCheckpoint, .developerProfileTrustRequired)
        let installedCount = (await harness.recorder.evidence()).installedBundleIdentifiers.count

        let stillPending = try await makeProvisioner().resumeSetup(harness.request)
        XCTAssertEqual(stillPending.finalStage, .developerProfileTrustRequired)
        let installedAfterPending = (await harness.recorder.evidence()).installedBundleIdentifiers.count
        XCTAssertEqual(installedAfterPending, installedCount)

        let complete = try await makeProvisioner().resumeSetup(harness.request)
        XCTAssertEqual(complete.finalStage, .complete)
        XCTAssertEqual(complete.manifest.developerProfileTrustStatus, .trusted)
        XCTAssertEqual(complete.manifest.effectiveSetupCheckpoint, .runtimeConfigurationVerified)
        let installedAfterComplete = (await harness.recorder.evidence()).installedBundleIdentifiers.count
        XCTAssertEqual(installedAfterComplete, installedCount)
        _ = try await harness.nativeStore.load(
            teamIdentifier: harness.team,
            selectedDeviceIdentifier: harness.physicalUDID
        )
    }

    func testTrustResumeUnrelatedLaunchFailureKeepsActualClassification() async throws {
        let harness = try await makeNativeHarness(faultPoint: nil)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let pending = try makeManifest(team: harness.team, device: harness.physicalUDID)
            .updatingSetupCheckpoint(.developerProfileTrustRequired, developerProfileTrustStatus: .required)
        try await harness.stateStore.saveManifest(pending)
        let launch = LaunchSequenceRecorder(base: harness.recorder, results: [.unrelatedFailure])
        let runner = ProcessRunner { executable, arguments, _, _, _ in
            try await launch.run(executable: executable, arguments: arguments)
        }
        let provisioner = ConsumerArtifactProvisioner(
            context: .init(resourcesURL: harness.resources, runner: runner),
            stateStore: harness.stateStore,
            nativeArtifactStore: harness.nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            workspaceRootURL: harness.workspaces,
            inventoryRetryPolicy: .immediateTesting,
            profileWriteOptions: .atomic
        )

        do {
            _ = try await provisioner.resumeSetup(harness.request)
            XCTFail("Expected unrelated launch failure")
        } catch let failure as ConsumerProvisioningFailure {
            XCTAssertEqual(failure.code, .runtimeConfigurationWriteFailed)
            XCTAssertNotEqual(failure.code, .developerProfileTrustRequired)
        }
    }

    private func makeNativeHarness(faultPoint: ConsumerProvisioningFaultPoint?) async throws -> (
        root: URL,
        resources: URL,
        workspaces: URL,
        team: String,
        physicalUDID: String,
        nativeStore: NativeProvisioningArtifactStore,
        stateStore: ConsumerProvisioningStateStore,
        recorder: NativePipelineRecorder,
        runner: ProcessRunner,
        provisioner: ConsumerArtifactProvisioner,
        request: ConsumerProvisioningRequest
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-native-fault-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let workspaces = root.appendingPathComponent("Workspaces", isDirectory: true)
        let team = "T8SL4SG87F"
        let physicalUDID = "00008150-00022D581E12401C"
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: team)
        let certificate = Data("fixture-development-certificate".utf8)
        let sha256 = SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
        let profiles = try makeNativeProfiles(
            team: team,
            physicalUDID: physicalUDID,
            identifiers: identifiers,
            certificate: certificate,
            certificateFingerprint: sha256
        )
        let preparation = ExperimentalProvisioningPreparation(
            team: .init(id: team, name: "Personal Team", isPersonalTeam: true, isPaidDeveloperTeam: false),
            identity: .init(
                certificateFingerprint: sha256,
                certificateExpiration: Date().addingTimeInterval(86_400),
                privateKeyPersistentReference: Data([1]),
                reused: true
            ),
            derivedIdentifiers: identifiers,
            profiles: profiles
        )
        let nativeStore = NativeProvisioningArtifactStore(directoryURL: root.appendingPathComponent("Native"))
        // This harness exercises the downstream signing/install state machine,
        // not NativeProvisioningArtifactStore.save (which has its own protected-
        // data tests). Materialize the valid envelope directly so these state
        // tests remain runnable while macOS protected data is unavailable.
        let artifactURL = await nativeStore.artifactURL
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let artifactEncoder = JSONEncoder()
        artifactEncoder.dateEncodingStrategy = .iso8601
        artifactEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try artifactEncoder.encode(NativeProvisioningArtifacts(
            preparation: preparation,
            selectedDeviceIdentifier: physicalUDID
        )).write(to: artifactURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifactURL.path)
        try makeConsumerArtifactFixture(at: resources)
        let recorder = NativePipelineRecorder(
            team: team,
            physicalUDID: physicalUDID,
            identifiers: identifiers,
            certificateSHA1: Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined(),
            profileDataByBundle: Dictionary(uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0.profileData) })
        )
        let runner = ProcessRunner { executable, arguments, _, _, _ in
            try await recorder.run(executable: executable, arguments: arguments)
        }
        let stateStore = ConsumerProvisioningStateStore(directoryURL: root.appendingPathComponent("State"))
        let faultInjector: any ConsumerProvisioningFaultInjecting = if let faultPoint {
            FixtureFaultInjector(point: faultPoint)
        } else {
            NoConsumerProvisioningFaults()
        }
        let provisioner = ConsumerArtifactProvisioner(
            context: RuntimeProvisioningContext(resourcesURL: resources, runner: runner),
            stateStore: stateStore,
            nativeArtifactStore: nativeStore,
            nativeIdentityResolver: FixtureNativeSigningIdentityResolver(),
            faultInjector: faultInjector,
            workspaceRootURL: workspaces,
            profileWriteOptions: .atomic
        )
        return (
            root, resources, workspaces, team, physicalUDID, nativeStore, stateStore, recorder, runner,
            provisioner,
            .init(
                operation: .install,
                selectedDeviceIdentifier: physicalUDID,
                selectedTeamIdentifier: team,
                allowFreshInstallAfterCrossTeamConflict: false,
                backend: .nativePersonalTeam
            )
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

    private func makeNativeProfiles(
        team: String,
        physicalUDID: String,
        identifiers: PersonalTeamBundleIdentifierSet,
        certificate: Data,
        certificateFingerprint: String
    ) throws -> [ExperimentalProfile] {
        let issuedAt = Date().addingTimeInterval(-60)
        let expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
        return try [identifiers.main, identifiers.runner].map { bundleIdentifier in
            let applicationIdentifier = "\(team).\(bundleIdentifier)"
            let entitlements: [String: Any] = [
                "application-identifier": applicationIdentifier,
                "com.apple.developer.team-identifier": team,
                "get-task-allow": true,
                "keychain-access-groups": [applicationIdentifier]
            ]
            let profile: [String: Any] = [
                "UUID": UUID().uuidString,
                "TeamIdentifier": [team],
                "ApplicationIdentifierPrefix": [team],
                "CreationDate": issuedAt,
                "ExpirationDate": expiresAt,
                "ProvisionedDevices": [physicalUDID],
                "DeveloperCertificates": [certificate],
                "Entitlements": entitlements
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            return ExperimentalProfile(
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: team,
                certificateFingerprint: certificateFingerprint,
                provisionedDeviceIdentifiers: [physicalUDID],
                applicationIdentifierEntitlement: applicationIdentifier,
                applicationIdentifierPrefix: team,
                getTaskAllow: true,
                profileType: "development",
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                profileData: data
            )
        }
    }

    private func makeConsumerArtifactFixture(at resources: URL) throws {
        let artifacts = resources.appendingPathComponent("DeviceArtifacts", isDirectory: true)
        let main = artifacts.appendingPathComponent("IOSSim.app", isDirectory: true)
        let runner = artifacts.appendingPathComponent("IOSSimUITests-Runner.app", isDirectory: true)
        let test = runner.appendingPathComponent("PlugIns/IOSSimUITests.xctest", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: test, withIntermediateDirectories: true)
        try writeFixtureBundle(main, identifier: ProtectedSourceBundleIdentifiers.default.main, executable: "IOSSim")
        try writeFixtureBundle(runner, identifier: ProtectedSourceBundleIdentifiers.default.runner, executable: "IOSSimUITests-Runner")
        try writeFixtureBundle(test, identifier: ProtectedSourceBundleIdentifiers.default.uiTests, executable: "IOSSimUITests")
        let release = ReleaseManifest(
            sourceCommit: "fixture",
            sourceDirty: false,
            buildTimestamp: "2026-09-08T16:55:20Z",
            macVersion: "0.1.0",
            buildNumber: "1",
            variant: "TEST",
            helperSchemaVersion: 1
        )
        let relativeMain = "DeviceArtifacts/IOSSim.app"
        let relativeRunner = "DeviceArtifacts/IOSSimUITests-Runner.app"
        var manifest = ArtifactManifest(schemaVersion: 1, release: release, components: [
            .init(role: "iosMain", bundleIdentifier: ProtectedSourceBundleIdentifiers.default.main, version: "1", relativePath: relativeMain, sha256: "pending", signingMode: "personalTeamResign"),
            .init(role: "locationControlRunner", bundleIdentifier: ProtectedSourceBundleIdentifiers.default.runner, version: "1", relativePath: relativeRunner, sha256: "pending", signingMode: "personalTeamResign")
        ])
        let verification = ArtifactManifestLoader.verify(resourcesURL: resources, manifest: manifest)
        manifest = ArtifactManifest(schemaVersion: 1, release: release, components: zip(manifest.components, verification).map { component, result in
            DeviceArtifactComponent(
                role: component.role,
                bundleIdentifier: component.bundleIdentifier,
                version: component.version,
                relativePath: component.relativePath,
                sha256: result.actualSHA256!,
                signingMode: component.signingMode
            )
        })
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: artifacts.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func writeFixtureBundle(_ url: URL, identifier: String, executable: String) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executable,
            "CFBundleShortVersionString": "1.0"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"), options: .atomic)
        try Data("fixture executable".utf8).write(to: url.appendingPathComponent(executable), options: .atomic)
    }

    private func writeExecutableBundle(_ url: URL, identifier: String, executable: String) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executable,
            "CFBundlePackageType": url.pathExtension == "app" ? "APPL" : "BNDL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"), options: .atomic)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: url.appendingPathComponent(executable)
        )
    }
}

private actor SequenceApplicationInventoryReader: DeviceApplicationInventoryReading {
    private var values: [DeviceApplicationInventory]
    private let fallback: DeviceApplicationInventory
    private(set) var readCount = 0

    init(_ values: [DeviceApplicationInventory]) {
        self.values = values
        self.fallback = values.last ?? .available([])
    }

    func read(rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> DeviceApplicationInventory {
        readCount += 1
        return values.isEmpty ? fallback : values.removeFirst()
    }
}

private struct EmptyAuthorizationSessionStore: AppleAuthorizationSessionStoring {
    func load() throws -> AppleAuthorizationSession? { nil }
    func loadMetadata() throws -> AppleAuthorizationSessionMetadata? { nil }
    func save(_ session: AppleAuthorizationSession) throws {}
    func remove() throws {}
}

private extension DeviceApplicationInventory {
    static func available(_ identifiers: Set<String>) -> DeviceApplicationInventory {
        DeviceApplicationInventory(selectedDeviceMatches: true, bundleIdentifiers: identifiers)
    }

    static func unavailable(
        _ code: ConsumerProvisioningErrorCode,
        reason: String
    ) -> DeviceApplicationInventory {
        DeviceApplicationInventory(
            selectedDeviceMatches: false,
            bundleIdentifiers: [],
            failureCode: code,
            safeReason: reason
        )
    }
}

private actor LaunchSequenceRecorder {
    enum Result {
        case untrustedDeveloper
        case success
        case unrelatedFailure
    }

    private let base: NativePipelineRecorder
    private var results: [Result]

    init(base: NativePipelineRecorder, results: [Result]) {
        self.base = base
        self.results = results
    }

    func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        if executable.path == "/usr/bin/xcrun",
           arguments.starts(with: ["devicectl", "device", "process", "launch"]),
           !results.isEmpty {
            switch results.removeFirst() {
            case .success:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case .untrustedDeveloper:
                return .init(exitCode: 1, stdout: "", stderr: Self.physicalUntrustedDeveloperError)
            case .unrelatedFailure:
                return .init(exitCode: 1, stdout: "", stderr: "CoreDevice launch failed for an unrelated reason")
            }
        }
        return try await base.run(executable: executable, arguments: arguments)
    }

    private static let physicalUntrustedDeveloperError = """
    ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))
    The request to open the app failed. (FBSOpenApplicationServiceErrorDomain error 1 (0x01))
    The operation could not be completed. (FBSOpenApplicationErrorDomain error 3 (0x03))
    BSErrorCodeDescription = Security
    Unable to launch because its profile has not been explicitly trusted by the user.
    """
}

private struct FixtureNativeSigningIdentityResolver: NativeSigningIdentityResolving {
    func resolve(
        certificateDER: Data,
        expectedSHA256: String,
        expectedKeyApplicationTagIdentifier: String?,
        teamIdentifier: String,
        workingDirectory: URL
    ) async throws -> NativeSigningIdentityResolution {
        let actual = SHA256.hash(data: certificateDER).map { String(format: "%02X", $0) }.joined()
        guard actual == expectedSHA256 else {
            throw ConsumerProvisioningFailure(
                code: .profileCertificateMismatch,
                stage: .preparingIdentities,
                userMessage: "fixture mismatch",
                remediation: "fixture mismatch",
                developerDetail: "fixture mismatch"
            )
        }
        var diagnostics = NativeSigningIdentityDiagnostics()
        diagnostics.profileCertificatePresent = true
        diagnostics.keychainCertificateFound = true
        diagnostics.keychainPrivateKeyFound = true
        diagnostics.certificatePublicKeyMatch = true
        diagnostics.keychainIdentityFound = true
        diagnostics.secIdentityResolutionSucceeded = true
        diagnostics.codesignIdentityVisible = true
        diagnostics.codesignSignTestSucceeded = true
        diagnostics.certificateQueryStatus = errSecSuccess
        diagnostics.privateKeyQueryStatus = errSecSuccess
        diagnostics.identityQueryStatus = errSecSuccess
        diagnostics.secIdentityResolutionStatus = errSecSuccess
        diagnostics.certificateFingerprint = expectedSHA256
        diagnostics.publicKeyFingerprint = expectedSHA256
        diagnostics.keyApplicationTagIdentifier = expectedKeyApplicationTagIdentifier
        return NativeSigningIdentityResolution(
            certificateSHA1: Insecure.SHA1.hash(data: certificateDER).map { String(format: "%02X", $0) }.joined(),
            diagnostics: diagnostics
        )
    }
}

private struct FixtureFaultInjector: ConsumerProvisioningFaultInjecting {
    let point: ConsumerProvisioningFaultPoint

    func check(_ candidate: ConsumerProvisioningFaultPoint) throws {
        guard candidate == point else { return }
        let classification: (ConsumerProvisioningErrorCode, ConsumerProvisioningStage)
        switch point {
        case .signingIdentityResolution: classification = (.signingIdentityNotFound, .preparingIdentities)
        case .preparingArtifacts: classification = (.artifactInvalid, .preparingArtifacts)
        case .nestedSigning: classification = (.nestedSigningFailed, .signingNestedComponents)
        case .mainSigning: classification = (.signOperationFailed, .signingMain)
        case .runnerSigning: classification = (.signOperationFailed, .signingRunner)
        case .signatureVerification: classification = (.signatureVerificationFailed, .verifyingSignatures)
        case .installMain: classification = (.mainInstallFailure, .installingMain)
        case .installRunner: classification = (.runnerInstallFailure, .installingRunner)
        case .installVerification: classification = (.mainInstallFailure, .verifyingInstallation)
        case .runtimeConfigWrite: classification = (.runtimeVerificationFailed, .writingRuntimeConfiguration)
        case .runtimeConfigVerify: classification = (.runtimeVerificationFailed, .verifyingRuntimeConfiguration)
        case .deviceDisconnected: classification = (.deviceUnavailable, .waitingForDevice)
        }
        throw ConsumerProvisioningFailure(
            code: classification.0,
            stage: classification.1,
            userMessage: "Injected downstream failure.",
            remediation: "Retry with the same prepared native context; Apple authorization remains valid.",
            developerDetail: "Injected \(point.rawValue); no destructive rollback is permitted."
        )
    }
}

private actor NativePipelineRecorder {
    struct Command: Sendable {
        let executable: URL
        let arguments: [String]
    }

    struct Evidence: Sendable {
        let commands: [Command]
        let installedProfiles: [String: Data]
        let installedBundleIdentifiers: [String]
        let uninstalledBundleIdentifiers: [String]
        let runtimeRunnerMapping: String?
    }

    private let team: String
    private let physicalUDID: String
    private let identifiers: PersonalTeamBundleIdentifierSet
    private let certificateSHA1: String
    private let profileDataByBundle: [String: Data]
    private var commands: [Command] = []
    private var installedProfiles: [String: Data] = [:]
    private var installedBundleIdentifiers: [String] = []
    private var uninstalledBundleIdentifiers: [String] = []
    private var runtimeRunnerMapping: String?

    init(
        team: String,
        physicalUDID: String,
        identifiers: PersonalTeamBundleIdentifierSet,
        certificateSHA1: String,
        profileDataByBundle: [String: Data]
    ) {
        self.team = team
        self.physicalUDID = physicalUDID
        self.identifiers = identifiers
        self.certificateSHA1 = certificateSHA1
        self.profileDataByBundle = profileDataByBundle
    }

    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        commands.append(Command(executable: executable, arguments: arguments))
        if executable.path == "/usr/bin/security", arguments.starts(with: ["find-identity"]) {
            return .init(exitCode: 0, stdout: "1) \(certificateSHA1) Apple Development: IOSSim (\(team))", stderr: "")
        }
        if executable.path == "/usr/bin/codesign" {
            if arguments.contains("-dvv"), let path = arguments.last {
                let identifier = try bundleIdentifier(at: URL(fileURLWithPath: path))
                return .init(exitCode: 0, stdout: "", stderr: "Identifier=\(identifier)\nTeamIdentifier=\(team)")
            }
            if arguments.contains("--entitlements"), arguments.contains(":-"), let path = arguments.last {
                let identifier = try bundleIdentifier(at: URL(fileURLWithPath: path))
                guard let data = profileDataByBundle[identifier],
                      let profile = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let entitlements = profile["Entitlements"] as? [String: Any] else {
                    return .init(exitCode: 1, stdout: "", stderr: "missing fixture entitlements")
                }
                let xml = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
                return .init(exitCode: 0, stdout: String(decoding: xml, as: UTF8.self), stderr: "")
            }
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        if executable.path == "/usr/bin/xcrun", arguments.first == "devicectl" {
            if arguments.starts(with: ["devicectl", "list", "devices"]) {
                try writeJSON([
                    "result": ["devices": [[
                        "identifier": physicalUDID,
                        "deviceProperties": ["name": "Fixture iPhone", "developerModeStatus": "enabled"],
                        "hardwareProperties": ["deviceType": "iPhone", "platform": "iOS", "udid": physicalUDID],
                        "connectionProperties": ["pairingState": "paired"]
                    ]]]
                ], toOption: "--json-output", arguments: arguments)
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments.starts(with: ["devicectl", "device", "info", "lockState"]) {
                try writeJSON(["result": ["passcodeRequired": false]], toOption: "--json-output", arguments: arguments)
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments.starts(with: ["devicectl", "device", "info", "apps"]) {
                let bundle = option("--bundle-id", arguments: arguments)
                let apps: [[String: Any]]
                if let bundle, [identifiers.main, identifiers.runner].contains(bundle) {
                    apps = [["bundleIdentifier": bundle]]
                } else if bundle == nil {
                    apps = [identifiers.main, identifiers.runner].map { ["bundleIdentifier": $0] }
                } else {
                    apps = []
                }
                try writeJSON(["result": ["apps": apps]], toOption: "--json-output", arguments: arguments)
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments.starts(with: ["devicectl", "device", "uninstall", "app"]), arguments.count > 6 {
                uninstalledBundleIdentifiers.append(arguments[6])
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments.starts(with: ["devicectl", "device", "install", "app"]),
               let path = arguments.first(where: { $0.hasSuffix(".app") }) {
                let url = URL(fileURLWithPath: path)
                let identifier = try bundleIdentifier(at: url)
                installedBundleIdentifiers.append(identifier)
                installedProfiles[identifier] = try Data(contentsOf: url.appendingPathComponent("embedded.mobileprovision"))
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments.starts(with: ["devicectl", "device", "process", "launch"]) {
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments.starts(with: ["devicectl", "device", "copy", "from"]),
               let destination = option("--destination", arguments: arguments) {
                let directory = URL(fileURLWithPath: destination, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let preferences = ["IOSSimGate3RunnerBundleIdentifier": identifiers.runner]
                let data = try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
                try data.write(to: directory.appendingPathComponent("preferences.plist"))
                runtimeRunnerMapping = identifiers.runner
                return .init(exitCode: 0, stdout: "", stderr: "")
            }
        }
        return .init(exitCode: 1, stdout: "", stderr: "Unexpected fixture command: \(executable.path) \(arguments)")
    }

    func evidence() -> Evidence {
        Evidence(
            commands: commands,
            installedProfiles: installedProfiles,
            installedBundleIdentifiers: installedBundleIdentifiers,
            uninstalledBundleIdentifiers: uninstalledBundleIdentifiers,
            runtimeRunnerMapping: runtimeRunnerMapping
        )
    }

    private func bundleIdentifier(at url: URL) throws -> String {
        let data = try Data(contentsOf: url.appendingPathComponent("Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
        return plist["CFBundleIdentifier"] as! String
    }

    private func option(_ name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func writeJSON(_ object: Any, toOption name: String, arguments: [String]) throws {
        guard let path = option(name, arguments: arguments) else { return }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: URL(fileURLWithPath: path))
    }
}

private extension ConsumerProvisioningManifest {
    var installedBundleIdentifiersForTest: [String] {
        [installedMainBundleID, installedRunnerBundleID]
    }
}
