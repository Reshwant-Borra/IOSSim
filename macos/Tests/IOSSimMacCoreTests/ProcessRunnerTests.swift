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

    func testLargeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; sys.stdout.write('x' * 200000); sys.stderr.write('y' * 200000)"],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testTrustedMachineReadableOutputCanBypassTransportRedaction() async throws {
        let identifier = "123E4567-E89B-12D3-A456-426614174000"
        let result = try await ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: [identifier],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            redactOutput: false
        )

        XCTAssertEqual(result.stdout, identifier)
    }

    func testCodesigningFingerprintIsRedactedByDefaultButPreservedForInternalMatching() async throws {
        let fingerprint = "ECB013F5978D9E00E71989ECFE71FCF2DDB4D6A2"
        let runner = ProcessRunner()
        let redacted = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: [fingerprint],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        let internalResult = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: [fingerprint],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            redactOutput: false
        )

        XCTAssertEqual(redacted.stdout, "[REDACTED_HEX]")
        XCTAssertEqual(internalResult.stdout, fingerprint)
    }
}
