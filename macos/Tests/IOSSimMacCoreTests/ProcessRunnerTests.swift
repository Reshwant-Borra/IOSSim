import XCTest
@testable import IOSSimMacCore

final class ProcessRunnerTests: XCTestCase {
    func testProcessExitHandlingAndOutputCapture() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["hello"],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertEqual(result.stderr, "")
    }
}
