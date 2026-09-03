import XCTest
@testable import IOSSimMacCore

final class ProvisioningProfileInspectorTests: XCTestCase {
    func testInstallableWhenSelectedDeviceIsInProfile() async throws {
        let app = try makeApp(
            creation: Date().addingTimeInterval(-86_400),
            expiration: Date().addingTimeInterval(86_400),
            devices: ["A"]
        )
        let summary = await ProvisioningProfileInspector.inspect(
            appURL: app,
            bundleIdentifier: "com.iossim.on-device-dvt-poc",
            selectedDeviceIdentifier: "A"
        )
        XCTAssertEqual(summary.status, .installable)
        XCTAssertEqual(summary.profileType, "development")
        XCTAssertEqual(summary.provisionedDeviceCount, 1)
        XCTAssertEqual(summary.selectedDeviceEligible, true)
        XCTAssertEqual(summary.personalTeam, true)
        XCTAssertEqual(summary.refreshRecommended, true)
        XCTAssertNotNil(summary.creationDate)
        XCTAssertNotNil(summary.remainingValiditySeconds)
    }

    func testDeviceNotInProfile() async throws {
        let app = try makeApp(expiration: Date().addingTimeInterval(86_400), devices: ["A"])
        let summary = await ProvisioningProfileInspector.inspect(
            appURL: app,
            bundleIdentifier: "com.iossim.on-device-dvt-poc",
            selectedDeviceIdentifier: "B"
        )
        XCTAssertEqual(summary.status, .deviceNotInProfile)
        XCTAssertEqual(summary.selectedDeviceEligible, false)
    }

    func testExpiredProfile() async throws {
        let app = try makeApp(expiration: Date().addingTimeInterval(-86_400), devices: ["A"])
        let summary = await ProvisioningProfileInspector.inspect(
            appURL: app,
            bundleIdentifier: "com.iossim.on-device-dvt-poc",
            selectedDeviceIdentifier: "A"
        )
        XCTAssertEqual(summary.status, .profileExpired)
    }

    func testMissingProfileRequiresResigning() async throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-profile-missing-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let summary = await ProvisioningProfileInspector.inspect(
            appURL: app,
            bundleIdentifier: "com.iossim.on-device-dvt-poc",
            selectedDeviceIdentifier: "A"
        )
        XCTAssertEqual(summary.status, .requiresResigning)
    }

    func testLongDevelopmentProfileDoesNotInferPersonalTeam() async throws {
        let app = try makeApp(
            creation: Date(),
            expiration: Date().addingTimeInterval(365 * 24 * 60 * 60),
            devices: ["A"],
            name: "iOS Team Provisioning Profile"
        )
        let summary = await ProvisioningProfileInspector.inspect(
            appURL: app,
            bundleIdentifier: "com.iossim.on-device-dvt-poc",
            selectedDeviceIdentifier: "A"
        )
        XCTAssertNil(summary.personalTeam)
        XCTAssertFalse(summary.refreshRecommended)
    }

    private func makeApp(
        creation: Date = Date(),
        expiration: Date,
        devices: [String],
        name: String = "iOS Team Provisioning Profile: Personal Team"
    ) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-profile-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let profile: [String: Any] = [
            "CreationDate": creation,
            "ExpirationDate": expiration,
            "Name": name,
            "ProvisionedDevices": devices,
            "TeamIdentifier": ["TEAMID1234"],
            "Entitlements": [
                "application-identifier": "TEAMID1234.com.iossim.on-device-dvt-poc",
                "get-task-allow": true
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("embedded.mobileprovision"))
        return app
    }
}
