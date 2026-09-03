import XCTest
@testable import IOSSimMacCore

final class ProvisioningProfileInspectorTests: XCTestCase {
    func testInstallableWhenSelectedDeviceIsInProfile() async throws {
        let app = try makeApp(expiration: Date().addingTimeInterval(86_400), devices: ["A"])
        let summary = await ProvisioningProfileInspector.inspect(
            appURL: app,
            bundleIdentifier: "com.iossim.on-device-dvt-poc",
            selectedDeviceIdentifier: "A"
        )
        XCTAssertEqual(summary.status, .installable)
        XCTAssertEqual(summary.profileType, "development")
        XCTAssertEqual(summary.provisionedDeviceCount, 1)
        XCTAssertEqual(summary.selectedDeviceEligible, true)
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

    private func makeApp(expiration: Date, devices: [String]) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-profile-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let profile: [String: Any] = [
            "ExpirationDate": expiration,
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
