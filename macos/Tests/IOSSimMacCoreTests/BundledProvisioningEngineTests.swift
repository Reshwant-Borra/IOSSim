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
}
