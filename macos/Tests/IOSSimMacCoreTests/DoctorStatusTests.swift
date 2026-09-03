import XCTest
@testable import IOSSimMacCore

final class DoctorStatusTests: XCTestCase {
    func testDoctorJSONDecoding() throws {
        let json = """
        {
          "ready": false,
          "mac": { "ready": true },
          "device": {
            "ready": false,
            "connected": true,
            "devices": [{
              "name": "iPhone",
              "identifier": "ABC123...7890",
              "udidRedacted": "ABC123...7890",
              "osVersion": "26.0",
              "developerModeStatus": "disabled",
              "pairingState": "paired",
              "tunnelState": "connected"
            }]
          },
          "actionsRequired": ["Enable Developer Mode"],
          "checks": [{
            "state": "ACTION",
            "component": "Device",
            "name": "Developer Mode",
            "detail": "disabled",
            "action": "On iPhone: Settings > Privacy & Security > Developer Mode.",
            "requiredFor": "device"
          }]
        }
        """
        let status = try DoctorStatus.decode(from: Data(json.utf8))
        XCTAssertEqual(status.device.devices.first?.name, "iPhone")
        XCTAssertEqual(StatusInterpreter.deviceReadiness(from: status), .developerModeRequired)
    }

    func testMissingDeviceState() {
        let status = DoctorStatus(
            ready: false,
            mac: MacSummary(ready: true),
            device: DeviceSummary(ready: false, connected: false, devices: []),
            actionsRequired: ["Connect an iPhone"],
            checks: [.init(state: .action, component: "Device", name: "connected iPhone", requiredFor: "device")]
        )
        XCTAssertEqual(StatusInterpreter.deviceReadiness(from: status), .noDevice)
    }

    func testLocalDevVPNAndPairingStates() {
        XCTAssertEqual(StatusInterpreter.deviceReadiness(from: status(runtimeName: "LocalDevVPN")), .localDevVPNRequired)
        XCTAssertEqual(StatusInterpreter.deviceReadiness(from: status(runtimeName: "PAIRING MATERIAL")), .pairingRequired)
    }

    func testRedaction() {
        let input = "token=abcdef password: hunter2 email me@example.com key 0123456789abcdef0123456789abcdef"
        let output = Redactor.redact(input)
        XCTAssertFalse(output.contains("hunter2"))
        XCTAssertFalse(output.contains("me@example.com"))
        XCTAssertFalse(output.contains("0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    private func status(runtimeName: String) -> DoctorStatus {
        let device = DetectedDevice(
            name: "iPhone",
            identifier: "ABC123...7890",
            osVersion: "26.0",
            developerModeStatus: "enabled",
            pairingState: "paired",
            tunnelState: "connected"
        )
        return DoctorStatus(
            ready: false,
            mac: MacSummary(ready: true),
            device: DeviceSummary(ready: false, connected: true, devices: [device]),
            actionsRequired: [runtimeName],
            checks: [.init(state: .action, component: "Runtime", name: runtimeName, requiredFor: "device")]
        )
    }
}
