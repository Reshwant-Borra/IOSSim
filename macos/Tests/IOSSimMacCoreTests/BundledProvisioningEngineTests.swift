import XCTest
@testable import IOSSimMacCore

final class BundledProvisioningEngineTests: XCTestCase {
    private var testRoot: URL!

    override func setUp() {
        super.setUp()
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        testRoot = repositoryRoot
            .appendingPathComponent(".build/iossim/bundled-engine-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let testRoot, testRoot.path.contains("/.build/iossim/bundled-engine-tests/") {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
        super.tearDown()
    }

    func testMissingHelperFailsWithoutDevelopmentFallback() async throws {
        let engine = BundledProvisioningEngine(
            helperURL: testRoot.appendingPathComponent("IOSSimProvisioner"),
            resourcesURL: testRoot
        )

        do {
            _ = try await engine.doctor()
            XCTFail("Expected missing helper to fail")
        } catch let failure as ProcessFailure {
            XCTAssertEqual(failure.result.exitCode, 127)
            XCTAssertTrue(failure.result.stderr.contains("VEYA-INTEGRITY-001"))
            XCTAssertTrue(failure.result.stderr.contains("setup helper is missing"))
            XCTAssertFalse(failure.result.stderr.lowercased().contains("find doctor"))
            XCTAssertFalse(failure.result.stderr.contains("IOSSIM_REPOSITORY_ROOT"))
        }
    }

    func testNonExecutableHelperHasPreciseIntegrityError() async throws {
        let helper = testRoot.appendingPathComponent("IOSSimProvisioner")
        try Data("not executable".utf8).write(to: helper)
        let engine = BundledProvisioningEngine(helperURL: helper, resourcesURL: testRoot)

        do {
            _ = try await engine.doctor()
            XCTFail("Expected non-executable helper to fail")
        } catch let failure as ProcessFailure {
            XCTAssertEqual(failure.commandName, "setup-integrity")
            XCTAssertTrue(failure.result.stderr.contains("VEYA-INTEGRITY-002"))
        }
    }

    func testTamperedHelperFailsBeforeInvocation() async throws {
        let fixture = try makeIntegrityFixture()
        let expected = fixture.integrity
        try Data("tampered helper".utf8).write(to: fixture.helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.helper.path)
        let engine = BundledProvisioningEngine(
            helperURL: fixture.helper,
            resourcesURL: testRoot,
            runner: ProcessRunner { _, _, _, _, _ in
                XCTFail("Tampered helper must not be invoked")
                return .init(exitCode: 0, stdout: "", stderr: "")
            },
            integrityManifest: expected
        )

        do {
            _ = try await engine.doctor()
            XCTFail("Expected helper hash mismatch")
        } catch let failure as ProcessFailure {
            XCTAssertTrue(failure.result.stderr.contains("VEYA-INTEGRITY-005"))
        }
    }

    func testWrongHelperProtocolFailsAsCompatibilityError() async throws {
        let fixture = try makeIntegrityFixture()
        let wrongHandshake = """
        {"ok":true,"schemaVersion":1,"data":{"helperSchemaVersion":9,"setupStateSchemaVersion":5,"provisioningManifestSchemaVersion":4,"artifactManifestSchemaVersion":2,"nativeBridgeABIExpected":1}}
        """
        let engine = BundledProvisioningEngine(
            helperURL: fixture.helper,
            resourcesURL: testRoot,
            runner: ProcessRunner { _, arguments, _, environment, _ in
                XCTAssertEqual(arguments, ["protocol-info"])
                XCTAssertNil(environment?["IOSSIM_REPOSITORY_ROOT"])
                return .init(exitCode: 0, stdout: wrongHandshake, stderr: "")
            },
            integrityManifest: fixture.integrity
        )

        do {
            _ = try await engine.doctor()
            XCTFail("Expected protocol mismatch")
        } catch let failure as ProcessFailure {
            XCTAssertEqual(failure.commandName, "setup-integrity")
            XCTAssertTrue(failure.result.stderr.contains("VEYA-INTEGRITY-006"))
            XCTAssertFalse(failure.result.stderr.lowercased().contains("doctor executable"))
        }
    }

    func testMissingIntegrityManifestFailsClosed() throws {
        let helper = testRoot.appendingPathComponent("IOSSimProvisioner")
        try Data("fixture helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        XCTAssertThrowsError(
            try PackagedEngineIntegrity.loadAndValidate(helperURL: helper, resourcesURL: testRoot)
        ) { error in
            XCTAssertEqual(error as? PackagedEngineIntegrityError, .integrityManifestMissing)
            XCTAssertTrue(String(describing: error).contains("VEYA-INTEGRITY-004"))
        }
    }

    func testBuiltPackagedAppStaticIntegrityAndHandshakeWhenProvided() async throws {
        guard let appPath = ProcessInfo.processInfo.environment["IOSSIM_V3_PACKAGED_APP"],
              !appPath.isEmpty else {
            throw XCTSkip("Set IOSSIM_V3_PACKAGED_APP for the V3 packaged artifact test.")
        }
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        let helper = app.appendingPathComponent("Contents/MacOS/IOSSimProvisioner")
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let integrity = try PackagedEngineIntegrity.loadAndValidate(
            helperURL: helper,
            resourcesURL: resources
        )
        let result = try await ProcessRunner().run(
            executableURL: helper,
            arguments: ["protocol-info"],
            workingDirectory: resources,
            environment: RuntimeProvisioning.deterministicEnvironment(),
            redactOutput: false
        )
        XCTAssertNoThrow(try PackagedEngineIntegrity.decodeAndValidateHandshake(result, expected: integrity))
    }

    func testBundledEnvironmentDoesNotExposeRepositoryRoot() {
        let environment = RuntimeProvisioning.deterministicEnvironment()
        XCTAssertNil(environment["IOSSIM_REPOSITORY_ROOT"])
        XCTAssertFalse(environment["PATH", default: ""].contains(".cargo"))
        XCTAssertFalse(environment["PATH", default: ""].contains("node"))
        XCTAssertTrue(environment["PATH", default: ""].contains("/usr/bin"))
    }

    func testTrustedHelperJSONIsDecodedBeforeUserVisibleRedaction() async throws {
        let root = testRoot!
        let helper = root.appendingPathComponent("IOSSimProvisioner")
        let identifier = "123E4567-E89B-12D3-A456-426614174000"
        let payload = """
        {"data":[{"teamIdentifier":"TEAM123","accountDisplayName":"\(identifier)","teamDisplayName":"Personal Team","signingIdentityCommonName":"Apple Development","signingIdentityFingerprint":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","certificateSubjectTeamIdentifier":"TEAM123","profileTeamIdentifiers":["TEAM123"],"matchingProfileCount":1,"selectedDeviceIncluded":true,"personalTeam":true}]}
        """
        let script = "#!/bin/sh\nprintf '%s' '\(payload)'\n"
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let engine = BundledProvisioningEngine(helperURL: helper, resourcesURL: root)

        let teams = try await engine.discoverPersonalTeams(selectedDeviceIdentifier: nil)

        XCTAssertEqual(teams.first?.accountDisplayName, identifier)
    }

    func testTrustedHelperFailureIsRedactedBeforeItLeavesEngine() async throws {
        let root = testRoot!
        let helper = root.appendingPathComponent("IOSSimProvisioner")
        let identifier = "123E4567-E89B-12D3-A456-426614174000"
        let script = "#!/bin/sh\nprintf '%s' '\(identifier)' >&2\nexit 1\n"
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let engine = BundledProvisioningEngine(helperURL: helper, resourcesURL: root)

        do {
            _ = try await engine.discoverPersonalTeams(selectedDeviceIdentifier: nil)
            XCTFail("Expected helper failure")
        } catch let failure as ProcessFailure {
            XCTAssertFalse(failure.result.stderr.contains(identifier))
            XCTAssertTrue(failure.result.stderr.contains("[REDACTED_UUID]"))
        }
    }

    func testStatusRequestCarriesExactDeviceAndTeamForKeyedState() async throws {
        let helper = testRoot.appendingPathComponent("IOSSimProvisioner")
        try Data("fixture helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let recorder = ProvisionerInvocationRecorder()
        let engine = BundledProvisioningEngine(
            helperURL: helper,
            resourcesURL: testRoot,
            runner: ProcessRunner { _, arguments, _, _, _ in
                await recorder.record(arguments)
                return .init(exitCode: 0, stdout: "{\"data\":null}", stderr: "")
            }
        )

        let manifest = try await engine.consumerProvisioningStatus(
            selectedDeviceIdentifier: "DEVICE-EXACT",
            selectedTeamIdentifier: "TEAM123456"
        )
        let arguments = await recorder.arguments
        XCTAssertNil(manifest)
        XCTAssertEqual(
            arguments,
            ["consumer-status", "--json", "--device", "DEVICE-EXACT", "--team", "TEAM123456"]
        )
    }

    func testComputerTrustRequestUsesDedicatedPackagedCommand() async throws {
        let helper = testRoot.appendingPathComponent("IOSSimProvisioner")
        try Data("fixture helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let recorder = ProvisionerInvocationRecorder()
        let payload = """
        {"data":{"schemaVersion":1,"state":"WAITING_FOR_USER_TRUST","identity":{"udid":"PHONE-0001","signingRegistrationIdentifier":"PHONE-0001","usbmuxIdentifier":7,"connection":"usb","connectionGeneration":3},"pairRecordCreated":false,"pairRecordPersisted":false,"sessionValidated":false}}
        """
        let engine = BundledProvisioningEngine(
            helperURL: helper,
            resourcesURL: testRoot,
            runner: ProcessRunner { _, arguments, _, _, _ in
                await recorder.record(arguments)
                return .init(exitCode: 0, stdout: payload, stderr: "")
            }
        )

        let receipt = try await engine.requestComputerTrust(selectedDeviceIdentifier: "PHONE-0001")
        let arguments = await recorder.arguments
        XCTAssertEqual(receipt.state, .waitingForUserTrust)
        XCTAssertEqual(arguments, ["pair-device", "--device", "PHONE-0001", "--json"])
    }

    private func makeIntegrityFixture() throws -> (
        helper: URL,
        integrity: PackagedEngineIntegrityManifest
    ) {
        let helper = testRoot.appendingPathComponent("IOSSimProvisioner")
        let bridgeRelative = "NativeDeviceBridge/libiossim_device_bridge.dylib"
        let payloadRelative = ArtifactManifestLoader.manifestRelativePath
        let bridge = testRoot.appendingPathComponent(bridgeRelative)
        let payload = testRoot.appendingPathComponent(payloadRelative)
        try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture helper".utf8).write(to: helper)
        try Data("fixture bridge".utf8).write(to: bridge)
        try Data("fixture payload manifest".utf8).write(to: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return (
            helper,
            PackagedEngineIntegrityManifest(
                schemaVersion: PackagedEngineIntegrityManifest.currentSchemaVersion,
                helperRelativePath: "Contents/MacOS/IOSSimProvisioner",
                helperSHA256: try PackagedEngineIntegrity.sha256(helper),
                helperSchemaVersion: RuntimeProvisioning.helperSchemaVersion,
                setupStateSchemaVersion: SetupStateSnapshot.currentSchemaVersion,
                artifactManifestSchemaVersion: ArtifactManifest.currentSchemaVersion,
                nativeBridgeRelativePath: bridgeRelative,
                nativeBridgeSHA256: try PackagedEngineIntegrity.sha256(bridge),
                nativeBridgeABI: DynamicNativeDeviceTransport.requiredABIVersion,
                payloadManifestRelativePath: payloadRelative,
                payloadManifestSHA256: try PackagedEngineIntegrity.sha256(payload)
            )
        )
    }
}

private actor ProvisionerInvocationRecorder {
    private(set) var arguments: [String] = []

    func record(_ arguments: [String]) {
        self.arguments = arguments
    }
}
