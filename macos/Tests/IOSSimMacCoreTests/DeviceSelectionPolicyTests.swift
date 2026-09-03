import XCTest
@testable import IOSSimMacCore

final class DeviceSelectionPolicyTests: XCTestCase {
    func testZeroDevicesClearsLiveSelection() {
        let result = DeviceSelectionPolicy.resolve(devices: [], rememberedIdentifier: nil)
        XCTAssertNil(result.selectedIdentifier)
        XCTAssertEqual(result.reason, .noConnectedDevices)
        XCTAssertFalse(result.selectionRequired)
    }

    func testOneDeviceAutoSelects() {
        let result = DeviceSelectionPolicy.resolve(devices: [Self.device("A")], rememberedIdentifier: nil)
        XCTAssertEqual(result.selectedIdentifier, "A")
        XCTAssertEqual(result.reason, .autoSelectedOnlyDevice)
    }

    func testRememberedDeviceConnectedWins() {
        let result = DeviceSelectionPolicy.resolve(devices: [Self.device("A"), Self.device("B")], rememberedIdentifier: "B")
        XCTAssertEqual(result.selectedIdentifier, "B")
        XCTAssertEqual(result.reason, .rememberedDeviceConnected)
        XCTAssertFalse(result.selectionRequired)
    }

    func testMultipleDevicesWithoutRememberedSelectionRequiresSelection() {
        let result = DeviceSelectionPolicy.resolve(devices: [Self.device("A"), Self.device("B")], rememberedIdentifier: nil)
        XCTAssertNil(result.selectedIdentifier)
        XCTAssertEqual(result.reason, .selectionRequired)
        XCTAssertTrue(result.selectionRequired)
    }

    func testRememberedDeviceAbsentRequiresSelectionWhenReplacementExists() {
        let result = DeviceSelectionPolicy.resolve(devices: [Self.device("B")], rememberedIdentifier: "A", rememberedName: "Old iPhone")
        XCTAssertEqual(result.selectedIdentifier, "B")
        XCTAssertEqual(result.reason, .autoSelectedOnlyDevice)
        XCTAssertFalse(result.selectionRequired)
    }

    func testRememberedDeviceAbsentWithMultipleDevicesDoesNotGuess() {
        let result = DeviceSelectionPolicy.resolve(devices: [Self.device("B"), Self.device("C")], rememberedIdentifier: "A", rememberedName: "Old iPhone")
        XCTAssertNil(result.selectedIdentifier)
        XCTAssertEqual(result.reason, .rememberedDeviceDisconnected)
        XCTAssertTrue(result.selectionRequired)
        XCTAssertEqual(result.disconnectedRememberedName, "Old iPhone")
    }

    func testReconnectSameDeviceRestoresSelection() {
        let result = DeviceSelectionPolicy.resolve(devices: [Self.device("A")], rememberedIdentifier: "A", rememberedName: "GOPI's iPhone")
        XCTAssertEqual(result.selectedIdentifier, "A")
        XCTAssertEqual(result.reason, .rememberedDeviceConnected)
    }

    private static func device(_ selectionIdentifier: String) -> DetectedDevice {
        DetectedDevice(
            name: selectionIdentifier == "A" ? "GOPI's iPhone" : "Test iPhone",
            identifier: RuntimeProvisioning.shortIdentifier(selectionIdentifier),
            selectionIdentifier: selectionIdentifier,
            osVersion: "26.6",
            developerModeStatus: "enabled",
            pairingState: "paired",
            tunnelState: "connected"
        )
    }
}
