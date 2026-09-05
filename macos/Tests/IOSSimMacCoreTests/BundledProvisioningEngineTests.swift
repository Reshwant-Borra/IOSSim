import XCTest
@testable import IOSSimMacCore

final class BundledProvisioningEngineTests: XCTestCase {
    func testMissingHelperFailsWithoutDevelopmentFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-bundled-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = BundledProvisioningEngine(
            helperURL: root.appendingPathComponent("IOSSimProvisioner"),
            resourcesURL: root
        )

        do {
            _ = try await engine.doctor()
            XCTFail("Expected missing helper to fail")
        } catch let failure as ProcessFailure {
            XCTAssertEqual(failure.result.exitCode, 127)
            XCTAssertTrue(failure.result.stderr.contains("Bundled runtime damaged"))
            XCTAssertFalse(failure.result.stderr.contains("IOSSIM_REPOSITORY_ROOT"))
        }
    }

    func testBundledEnvironmentDoesNotExposeRepositoryRoot() {
        let environment = RuntimeProvisioning.deterministicEnvironment()
        XCTAssertNil(environment["IOSSIM_REPOSITORY_ROOT"])
        XCTAssertFalse(environment["PATH", default: ""].contains(".cargo"))
        XCTAssertFalse(environment["PATH", default: ""].contains("node"))
        XCTAssertTrue(environment["PATH", default: ""].contains("/usr/bin"))
    }

    func testTrustedHelperJSONIsDecodedBeforeUserVisibleRedaction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-bundled-engine-json-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-bundled-engine-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
}
