import XCTest
@testable import IOSSimMacCore

final class XcodePrerequisiteTests: XCTestCase {
    func testNoXcodeAndCommandLineToolsOnlyAreDistinct() async {
        let missing = detector(candidates: [], systemDirectory: nil)
        let clt = detector(candidates: [], systemDirectory: "/Library/Developer/CommandLineTools")

        let missingReport = await missing.detect()
        let cltReport = await clt.detect()
        XCTAssertEqual(missingReport.state, .notFound)
        XCTAssertEqual(cltReport.state, .commandLineToolsOnly)
    }

    func testValidInitializedXcodeIsReady() async {
        let report = await detector(candidates: [app("Xcode.app")]).detect()

        XCTAssertEqual(report.state, .ready)
        XCTAssertEqual(report.selectedInstallation?.version, XcodeVersion("26.6"))
    }

    func testUninitializedXcodeIsReportedWithoutRunningDevicectl() async {
        let report = await detector(
            candidates: [app("Xcode.app")],
            result: { arguments in
                arguments == ["-checkFirstLaunchStatus"]
                    ? ProcessResult(exitCode: 69, stdout: "", stderr: "first launch required")
                    : ProcessResult(exitCode: 0, stdout: "ok", stderr: "")
            }
        ).detect()

        XCTAssertEqual(report.state, .notInitialized)
    }

    func testMissingDevicectlIsReported() async {
        let report = await detector(
            candidates: [app("Xcode.app")],
            result: { arguments in
                arguments.contains("devicectl")
                    ? ProcessResult(exitCode: 72, stdout: "", stderr: "not found")
                    : ProcessResult(exitCode: 0, stdout: "ok", stderr: "")
            }
        ).detect()

        XCTAssertEqual(report.state, .devicectlUnavailable)
    }

    func testIncompatibleAndDamagedXcodesAreDistinct() async {
        let incompatible = await detector(
            candidates: [app("Old.app")],
            info: { _ in Self.bundleInfo(version: "14.3") }
        ).detect()
        let damaged = await detector(
            candidates: [app("Broken.app")],
            info: { _ in ["CFBundleIdentifier": "not.xcode"] }
        ).detect()

        XCTAssertEqual(incompatible.state, .incompatible)
        XCTAssertEqual(damaged.state, .damaged)
    }

    func testBestStableXcodeIsSelectedWithoutChangingGlobalSelection() async {
        let old = app("Xcode-15.app")
        let beta = app("Xcode-beta.app")
        let stable = app("Xcode-26.6.app")
        let report = await detector(
            candidates: [old, beta, stable],
            systemDirectory: old.appendingPathComponent("Contents/Developer").path,
            info: { application in
                if application == old { return Self.bundleInfo(version: "15.4") }
                if application == beta { return Self.bundleInfo(version: "27.0") }
                return Self.bundleInfo(version: "26.6")
            }
        ).detect()

        XCTAssertTrue(report.multipleInstallations)
        XCTAssertEqual(report.state, .readyUsingAlternative)
        XCTAssertEqual(report.selectedInstallation?.applicationURL, stable)
    }

    func testMacOSCompatibilityIsEnforced() async {
        let report = await detector(
            candidates: [app("Xcode.app")],
            info: { _ in Self.bundleInfo(version: "26.6", minimumMacOS: "27.0") },
            currentMacOS: "26.6"
        ).detect()

        XCTAssertEqual(report.state, .incompatible)
    }

    func testDeviceOSCompatibilityIsEnforcedByCentralPolicy() async {
        let report = await detector(
            candidates: [app("Xcode-15.app")],
            info: { _ in Self.bundleInfo(version: "15.4") },
            requiredDeviceOS: "26.5"
        ).detect()

        XCTAssertEqual(report.state, .incompatible)
    }

    func testVersionParserHandlesOperatingSystemDescription() {
        XCTAssertEqual(XcodeVersion("Version 26.6.2 (Build 25G83)"), XcodeVersion("26.6.2"))
    }

    func testDeterministicEnvironmentUsesPerProcessDeveloperDirectory() {
        let selected = URL(fileURLWithPath: "/Applications/IOSSim-Xcode.app/Contents/Developer")
        let environment = RuntimeProvisioning.deterministicEnvironment(
            preferredDeveloperDirectory: selected,
            processEnvironment: ["DEVELOPER_DIR": "/Applications/Other.app/Contents/Developer"]
        )

        XCTAssertEqual(environment["DEVELOPER_DIR"], selected.path)
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    private func detector(
        candidates: [URL],
        systemDirectory: String? = "/Applications/Xcode.app/Contents/Developer",
        info: @escaping XcodePrerequisiteDetector.BundleInfo = { _ in XcodePrerequisiteTests.bundleInfo() },
        currentMacOS: String = "26.6",
        requiredDeviceOS: String? = nil,
        result: @escaping @Sendable ([String]) -> ProcessResult = { _ in
            ProcessResult(exitCode: 0, stdout: "ok", stderr: "")
        }
    ) -> XcodePrerequisiteDetector {
        XcodePrerequisiteDetector(
            candidatePaths: { candidates },
            bundleInfo: info,
            directoryExists: { _ in true },
            executableExists: { _ in true },
            systemDeveloperDirectory: { systemDirectory },
            runner: ProcessRunner { _, arguments, _, _, _ in result(arguments) },
            currentMacOSVersion: XcodeVersion(currentMacOS),
            requiredDeviceOSVersion: requiredDeviceOS.map(XcodeVersion.init),
            verifiedSelectionHandler: { _ in }
        )
    }

    private func app(_ name: String) -> URL {
        URL(fileURLWithPath: "/Applications/\(name)")
    }

    private static func bundleInfo(version: String = "26.6", minimumMacOS: String = "15.6") -> [String: Any] {
        [
            "CFBundleIdentifier": "com.apple.dt.Xcode",
            "CFBundleShortVersionString": version,
            "DTXcodeBuild": "17F113",
            "LSMinimumSystemVersion": minimumMacOS
        ]
    }
}
