import XCTest
@testable import IOSSimMacCore

final class DevelopmentCLIEngineTests: XCTestCase {
    func testDevelopmentEngineLaunchTargetUsesExecutableInterpreter() throws {
        let root = repositoryRoot()
        let engine = DevelopmentCLIEngine(
            cliURL: root.appendingPathComponent("iossim"),
            repositoryRoot: root
        )
        XCTAssertEqual(engine.executableURL.path, "/bin/bash")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: engine.executableURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.cliURL.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: engine.cliURL.path))
        XCTAssertEqual(engine.launchArguments(for: ["doctor", "--json"]).prefix(3), [engine.cliURL.path, "doctor", "--json"])
    }

    func testDevelopmentEngineDoctorExecutesAndDecodesJSON() async throws {
        let root = repositoryRoot()
        let engine = DevelopmentCLIEngine(
            cliURL: root.appendingPathComponent("iossim"),
            repositoryRoot: root
        )
        let status = try await engine.doctor()
        XCTAssertFalse(status.checks.isEmpty)
        XCTAssertNotNil(status.mac.ready)
    }

    func testGUISafeEnvironmentDoesNotDependOnInteractiveShell() {
        let root = repositoryRoot()
        let env = DevelopmentCLIEngine.guiSafeEnvironment(repositoryRoot: root)
        XCTAssertFalse(env["HOME", default: ""].isEmpty)
        XCTAssertTrue(env["PATH", default: ""].contains("/usr/bin"))
        XCTAssertEqual(env["IOSSIM_REPOSITORY_ROOT"], root.path)
    }

    private func repositoryRoot() -> URL {
        var current = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            let candidate = current.appendingPathComponent("../../../iossim").standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.deletingLastPathComponent()
            }
            current.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
