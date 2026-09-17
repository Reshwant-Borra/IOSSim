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

    func testInstallReceiptBindsExactDeviceArtifactTeamAndVersion() async throws {
        let fixture = try makeSignedApp(bundleID: "com.example.main")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let service = FakeApplicationService()
        let device = try IOSSimDeviceIdentity(
            udid: "PHONE-0001",
            usbmuxIdentifier: 42,
            connection: .usb,
            connectionGeneration: 7
        )

        let receipt = try await NativeApplicationManager(service: service).installOrUpgradeReceipt(
            appURL: fixture,
            expectedBundleIdentifier: "com.example.main",
            expectedTeamIdentifier: "TEAM1",
            on: device
        )

        XCTAssertEqual(receipt.schemaVersion, NativeApplicationInstallReceipt.currentSchemaVersion)
        XCTAssertEqual(receipt.mode, .fresh)
        XCTAssertEqual(receipt.usbmuxIdentifier, 42)
        XCTAssertEqual(receipt.connection, .usb)
        XCTAssertEqual(receipt.connectionGeneration, 7)
        XCTAssertEqual(receipt.bundleIdentifier, "com.example.main")
        XCTAssertEqual(receipt.version, "1")
        XCTAssertEqual(receipt.teamIdentifier, "TEAM1")
        XCTAssertEqual(receipt.artifactSHA256.count, 64)
        XCTAssertFalse(receipt.reconciledAfterInterruptedResponse)
        XCTAssertFalse(receipt.deviceUDIDHash.contains("PHONE-0001"))
    }

    func testWrongOrUnknownInstalledTeamIsNeverOverwritten() async throws {
        let fixture = try makeSignedApp(bundleID: "com.example.main")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        for team in ["OTHER", nil] as [String?] {
            let service = FakeApplicationService(apps: [
                NativeInstalledApplication(bundleIdentifier: "com.example.main", version: "1", teamIdentifier: team)
            ])
            do {
                _ = try await NativeApplicationManager(service: service).installOrUpgradeReceipt(
                    appURL: fixture,
                    expectedBundleIdentifier: "com.example.main",
                    expectedTeamIdentifier: "TEAM1",
                    on: try IOSSimDeviceIdentity(udid: "PHONE-0001")
                )
                XCTFail("expected ownership conflict")
            } catch let error as NativeApplicationManagementError {
                XCTAssertEqual(error, .ownershipConflict)
            }
            let modes = await service.installModes
            XCTAssertTrue(modes.isEmpty)
        }
    }

    func testInterruptedInstallResponseReconcilesOnlyExactInventory() async throws {
        let fixture = try makeSignedApp(bundleID: "com.example.main")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let applied = FakeApplicationService(failInstallAfterMutation: true)
        let receipt = try await NativeApplicationManager(service: applied).installOrUpgradeReceipt(
            appURL: fixture,
            expectedBundleIdentifier: "com.example.main",
            expectedTeamIdentifier: "TEAM1",
            on: try IOSSimDeviceIdentity(udid: "PHONE-0001")
        )
        XCTAssertTrue(receipt.reconciledAfterInterruptedResponse)

        let notApplied = FakeApplicationService(failInstallBeforeMutation: true)
        do {
            _ = try await NativeApplicationManager(service: notApplied).installOrUpgradeReceipt(
                appURL: fixture,
                expectedBundleIdentifier: "com.example.main",
                expectedTeamIdentifier: "TEAM1",
                on: try IOSSimDeviceIdentity(udid: "PHONE-0001")
            )
            XCTFail("expected original install failure")
        } catch let error as NativeApplicationManagementError {
            XCTAssertEqual(error, .serviceUnavailable)
        }
    }

    func testUninstallRequiresExactTeamAndVerifiesAbsence() async throws {
        let device = try IOSSimDeviceIdentity(udid: "PHONE-0001")
        let unknown = FakeApplicationService(apps: [
            NativeInstalledApplication(bundleIdentifier: "com.example.main", version: "1", teamIdentifier: nil)
        ])
        do {
            try await NativeApplicationManager(service: unknown).uninstallIOSSimOwned(
                bundleIdentifiers: ["com.example.main"],
                allowedBundleIdentifiers: ["com.example.main"],
                expectedTeamIdentifier: "TEAM1",
                on: device
            )
            XCTFail("expected ownership conflict")
        } catch let error as NativeApplicationManagementError {
            XCTAssertEqual(error, .ownershipConflict)
        }
        let unknownUninstallCount = await unknown.uninstallCount
        XCTAssertEqual(unknownUninstallCount, 0)

        let owned = FakeApplicationService(apps: [
            NativeInstalledApplication(bundleIdentifier: "com.example.main", version: "1", teamIdentifier: "TEAM1")
        ])
        try await NativeApplicationManager(service: owned).uninstallIOSSimOwned(
            bundleIdentifiers: ["com.example.main"],
            allowedBundleIdentifiers: ["com.example.main"],
            expectedTeamIdentifier: "TEAM1",
            on: device
        )
        let ownedUninstallCount = await owned.uninstallCount
        let remainingApps = await owned.apps
        XCTAssertEqual(ownedUninstallCount, 1)
        XCTAssertTrue(remainingApps.isEmpty)
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

    func testRuntimeMappingIsIdempotentAndRepairsStaleValues() async throws {
        let device = try IOSSimDeviceIdentity(udid: "PHONE-0001")
        let service = FakeApplicationService()
        let manager = NativeApplicationManager(service: service)

        let first = try await manager.writeAndVerifyRuntimeMapping(
            mainBundleIdentifier: "com.example.main",
            runnerBundleIdentifier: "com.example.runner",
            teamIdentifier: "TEAM1",
            on: device
        )
        let second = try await manager.writeAndVerifyRuntimeMapping(
            mainBundleIdentifier: "com.example.main",
            runnerBundleIdentifier: "com.example.runner",
            teamIdentifier: "TEAM1",
            on: device
        )
        let repaired = try await manager.writeAndVerifyRuntimeMapping(
            mainBundleIdentifier: "com.example.main",
            runnerBundleIdentifier: "com.example.runner.v2",
            teamIdentifier: "TEAM1",
            on: device
        )

        XCTAssertEqual(first, .writtenAndVerified)
        XCTAssertEqual(second, .alreadyCurrent)
        XCTAssertEqual(repaired, .writtenAndVerified)
        let writeCount = await service.writeCount
        XCTAssertEqual(writeCount, 2)
    }

    func testUninstallIsScopedAndLaunchFailurePropagates() async throws {
        let service = FakeApplicationService(launchFailure: true)
        let manager = NativeApplicationManager(service: service)
        let device = try IOSSimDeviceIdentity(udid: "PHONE-0001")
        do {
            try await manager.uninstallIOSSimOwned(
                bundleIdentifiers: ["com.unrelated.app"],
                allowedBundleIdentifiers: ["com.example.main", "com.example.runner"],
                expectedTeamIdentifier: "TEAM1",
                on: device
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
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appendingPathComponent(".build/iossim/v7-native-tests/\(UUID().uuidString)", isDirectory: true)
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
    var writeCount = 0
    var uninstallCount = 0
    let corruptReadback: Bool
    let launchFailure: Bool
    let failInstallBeforeMutation: Bool
    let failInstallAfterMutation: Bool

    init(
        apps: [NativeInstalledApplication] = [],
        corruptReadback: Bool = false,
        launchFailure: Bool = false,
        failInstallBeforeMutation: Bool = false,
        failInstallAfterMutation: Bool = false
    ) {
        self.apps = apps
        self.corruptReadback = corruptReadback
        self.launchFailure = launchFailure
        self.failInstallBeforeMutation = failInstallBeforeMutation
        self.failInstallAfterMutation = failInstallAfterMutation
    }

    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] { apps }

    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {
        installModes.append(mode)
        if failInstallBeforeMutation { throw NativeApplicationManagementError.serviceUnavailable }
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))
        let bundle = info?["CFBundleIdentifier"] as? String ?? "missing"
        apps.removeAll { $0.bundleIdentifier == bundle }
        apps.append(NativeInstalledApplication(bundleIdentifier: bundle, version: "1", teamIdentifier: "TEAM1"))
        if failInstallAfterMutation { throw NativeApplicationManagementError.serviceUnavailable }
    }

    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        uninstallCount += 1
        apps.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        if launchFailure { throw NativeApplicationManagementError.launchFailed }
    }

    func writeContainer(
        bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity
    ) async throws {
        writeCount += 1
        container["\(bundleIdentifier):\(relativePath)"] = data
    }

    func readContainer(
        bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity
    ) async throws -> Data {
        if corruptReadback { return Data("wrong".utf8) }
        return container["\(bundleIdentifier):\(relativePath)"] ?? Data()
    }
}
