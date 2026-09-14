import XCTest
@testable import IOSSimMacCore

final class NativeApplicationManagementTests: XCTestCase {
    func testFreshInstallAndUpgradeUseCorrectMode() async throws {
        let fixture = try makeSignedApp(bundleID: "com.example.main")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let service = FakeApplicationService()
        let manager = NativeApplicationManager(service: service)
        let device = try IOSSimDeviceIdentity(udid: "PHONE-0001")

        let fresh = try await manager.installOrUpgrade(
            appURL: fixture, expectedBundleIdentifier: "com.example.main",
            expectedTeamIdentifier: "TEAM1", on: device
        )
        XCTAssertEqual(fresh, .fresh)
        let upgrade = try await manager.installOrUpgrade(
            appURL: fixture, expectedBundleIdentifier: "com.example.main",
            expectedTeamIdentifier: "TEAM1", on: device
        )
        XCTAssertEqual(upgrade, .upgrade)
        let modes = await service.installModes
        XCTAssertEqual(modes, [.fresh, .upgrade])
    }

    func testRunnerMissingAndTeamMismatchAreRejected() async throws {
        let device = try IOSSimDeviceIdentity(udid: "PHONE-0001")
        let missing = NativeApplicationManager(service: FakeApplicationService(apps: [
            NativeInstalledApplication(bundleIdentifier: "com.example.main", teamIdentifier: "TEAM1")
        ]))
        do {
            _ = try await missing.verifyInstallation(
                mainBundleIdentifier: "com.example.main", runnerBundleIdentifier: "com.example.runner",
                expectedTeamIdentifier: "TEAM1", on: device
            )
            XCTFail("expected runner failure")
        } catch let error as NativeApplicationManagementError {
            XCTAssertEqual(error, .runnerMissing)
        }

        let wrongTeam = NativeApplicationManager(service: FakeApplicationService(apps: [
            NativeInstalledApplication(bundleIdentifier: "com.example.main", teamIdentifier: "OTHER"),
            NativeInstalledApplication(bundleIdentifier: "com.example.runner", teamIdentifier: "TEAM1")
        ]))
        do {
            _ = try await wrongTeam.verifyInstallation(
                mainBundleIdentifier: "com.example.main", runnerBundleIdentifier: "com.example.runner",
                expectedTeamIdentifier: "TEAM1", on: device
            )
            XCTFail("expected inventory mismatch")
        } catch let error as NativeApplicationManagementError {
            XCTAssertEqual(error, .inventoryMismatch)
        }
    }

    func testInvalidSignedAppAndWrongBundleAreRejectedBeforeInstall() async throws {
        let fixture = try makeSignedApp(bundleID: "com.example.actual")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let service = FakeApplicationService()
        let manager = NativeApplicationManager(service: service)
        do {
            _ = try await manager.installOrUpgrade(
                appURL: fixture, expectedBundleIdentifier: "com.example.expected",
                expectedTeamIdentifier: "TEAM1", on: try IOSSimDeviceIdentity(udid: "PHONE-0001")
            )
            XCTFail("expected validation failure")
        } catch let error as NativeApplicationManagementError {
            XCTAssertEqual(error, .invalidSignedApplication)
        }
        let modes = await service.installModes
        XCTAssertEqual(modes, [])
    }

    func testContainerPathTraversalRejected() {
        XCTAssertTrue(NativeApplicationPathPolicy.isSafeContainerPath("Library/Application Support/IOSSim/config.json"))
        XCTAssertFalse(NativeApplicationPathPolicy.isSafeContainerPath("../Pairing.plist"))
        XCTAssertFalse(NativeApplicationPathPolicy.isSafeContainerPath("Library//config"))
        XCTAssertFalse(NativeApplicationPathPolicy.isSafeContainerPath("/private/var/tmp/file"))
    }

    func testRuntimeMappingRequiresReadbackMatch() async throws {
        let device = try IOSSimDeviceIdentity(udid: "PHONE-0001")
        let goodService = FakeApplicationService()
        try await NativeApplicationManager(service: goodService).writeAndVerifyRuntimeMapping(
            mainBundleIdentifier: "com.example.main", runnerBundleIdentifier: "com.example.runner", on: device
        )

        let badService = FakeApplicationService(corruptReadback: true)
        do {
            try await NativeApplicationManager(service: badService).writeAndVerifyRuntimeMapping(
                mainBundleIdentifier: "com.example.main", runnerBundleIdentifier: "com.example.runner", on: device
            )
            XCTFail("expected readback mismatch")
        } catch let error as NativeApplicationManagementError {
            XCTAssertEqual(error, .readbackMismatch)
        }
    }

    func testUninstallIsScopedAndLaunchFailurePropagates() async throws {
        let service = FakeApplicationService(launchFailure: true)
        let manager = NativeApplicationManager(service: service)
        let device = try IOSSimDeviceIdentity(udid: "PHONE-0001")
        do {
            try await manager.uninstallIOSSimOwned(
                bundleIdentifiers: ["com.unrelated.app"],
                allowedBundleIdentifiers: ["com.example.main", "com.example.runner"], on: device
            )
            XCTFail("expected scoped uninstall rejection")
        } catch let error as NativeApplicationManagementError {
            XCTAssertEqual(error, .wrongBundleIdentifier)
        }
        do {
            try await manager.launchMain(bundleIdentifier: "com.example.main", on: device)
            XCTFail("expected launch failure")
        } catch let error as NativeApplicationManagementError {
            XCTAssertEqual(error, .launchFailed)
        }
    }

    private func makeSignedApp(bundleID: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleVersion": "1"]
        XCTAssertTrue(info.write(to: app.appendingPathComponent("Info.plist"), atomically: true))
        try Data("profile".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        try Data("signature".utf8).write(to: app.appendingPathComponent("_CodeSignature/CodeResources"))
        return app
    }
}

private actor FakeApplicationService: NativeApplicationServicing {
    var apps: [NativeInstalledApplication]
    var installModes: [NativeApplicationInstallMode] = []
    var container: [String: Data] = [:]
    let corruptReadback: Bool
    let launchFailure: Bool

    init(
        apps: [NativeInstalledApplication] = [],
        corruptReadback: Bool = false,
        launchFailure: Bool = false
    ) {
        self.apps = apps
        self.corruptReadback = corruptReadback
        self.launchFailure = launchFailure
    }

    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] { apps }

    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {
        installModes.append(mode)
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))
        let bundle = info?["CFBundleIdentifier"] as? String ?? "missing"
        apps.removeAll { $0.bundleIdentifier == bundle }
        apps.append(NativeInstalledApplication(bundleIdentifier: bundle, version: "1", teamIdentifier: "TEAM1"))
    }

    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        apps.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        if launchFailure { throw NativeApplicationManagementError.launchFailed }
    }

    func writeContainer(
        bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity
    ) async throws { container["\(bundleIdentifier):\(relativePath)"] = data }

    func readContainer(
        bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity
    ) async throws -> Data {
        if corruptReadback { return Data("wrong".utf8) }
        return container["\(bundleIdentifier):\(relativePath)"] ?? Data()
    }
}
