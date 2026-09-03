import XCTest
@testable import IOSSimMacCore

@MainActor
final class SetupStoreTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "IOSSimMac.onboardingCompleted")
        UserDefaults.standard.removeObject(forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.removeObject(forKey: "IOSSimMac.selectedDeviceName")
    }

    func testSuccessfulSetupFlowReachesRuntimeSetupWhenManualActionsRemain() async throws {
        let engine = MockIOSSimSetupEngine(scenario: .localDevVPNRequired)
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .runtimeSetup)
        XCTAssertNil(store.lastError)
    }

    func testNoDeviceFlowWaitsForDevice() async throws {
        let engine = MockIOSSimSetupEngine(scenario: .noDevice)
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .waitingForDevice)
        XCTAssertNil(store.selectedDevice)
    }

    func testOneDeviceAutoSelectsLiveDevice() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.selectedDeviceIdentifier, "A")
        XCTAssertEqual(store.selectedDevice?.name, "GOPI's iPhone")
    }

    func testMultipleDevicesWithoutRememberedSelectionRequiresExplicitChoice() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A"), Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertNil(store.selectedDeviceIdentifier)
        XCTAssertTrue(store.deviceSelectionRequired)
    }

    func testMultipleDevicesWithRememberedSelectionUsesRememberedDevice() async throws {
        UserDefaults.standard.set("B", forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.set("Test iPhone", forKey: "IOSSimMac.selectedDeviceName")
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A"), Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.selectedDeviceIdentifier, "B")
        XCTAssertEqual(store.selectedDevice?.name, "Test iPhone")
    }

    func testRememberedDeviceAbsentDoesNotShowStaleDevice() async throws {
        UserDefaults.standard.set("A", forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.set("GOPI's iPhone", forKey: "IOSSimMac.selectedDeviceName")
        let engine = SequenceSetupEngine(status: Self.status(devices: []))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertNil(store.selectedDeviceIdentifier)
        XCTAssertNil(store.selectedDevice)
        XCTAssertEqual(store.disconnectedDeviceName, "GOPI's iPhone")
    }

    func testNewSingleDeviceReplacingOldRememberedDeviceAutoSelectsLivePhone() async throws {
        UserDefaults.standard.set("A", forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.set("GOPI's iPhone", forKey: "IOSSimMac.selectedDeviceName")
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.selectedDeviceIdentifier, "B")
        XCTAssertEqual(store.selectedDevice?.name, "Test iPhone")
    }

    func testChangeDeviceActionPersistsExplicitSelection() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A"), Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.selectDevice(identifier: "B")
        XCTAssertEqual(store.selectedDeviceIdentifier, "B")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "IOSSimMac.selectedDeviceIdentifier"), "B")
    }

    func testOperationBoundToSelectedDevice() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)
        let provisioned = await engine.provisionedDeviceIdentifiers
        XCTAssertEqual(provisioned, ["A"])
    }

    func testAmbiguousOperationRejected() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A"), Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.runUpdateComponents()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertTrue(store.lastError?.details.contains("DEVICE_SELECTION_REQUIRED") == true)
        let provisioned = await engine.provisionedDeviceIdentifiers
        XCTAssertTrue(provisioned.isEmpty)
    }

    func testDisconnectMidInstallFailsWithoutSwitchingDevices() async throws {
        let engine = SequenceSetupEngine(
            status: Self.status(devices: [Self.device("A")]),
            failProvisionFor: "A",
            failureText: "IPHONE_DISCONNECTED: reconnect the selected iPhone or choose another device."
        )
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.lastError?.headline, "iPhone Disconnected")
        let provisioned = await engine.provisionedDeviceIdentifiers
        XCTAssertEqual(provisioned, ["A"])
    }

    func testReconnectSameDeviceRestoresSelection() async throws {
        UserDefaults.standard.set("A", forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.set("GOPI's iPhone", forKey: "IOSSimMac.selectedDeviceName")
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.selectedDeviceIdentifier, "A")
        XCTAssertEqual(store.selectedDevice?.name, "GOPI's iPhone")
    }

    func testDeveloperModeActionState() async throws {
        let engine = MockIOSSimSetupEngine(scenario: .developerModeRequired)
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .deviceActionRequired)
        let status = try await engine.doctor()
        XCTAssertEqual(StatusInterpreter.deviceReadiness(from: status), .developerModeRequired)
    }

    func testInstallFailureFlow() async throws {
        let engine = MockIOSSimSetupEngine(scenario: .installFailure)
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertNotNil(store.lastError)
    }

    private func waitUntilIdle(_ store: SetupStore, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isRunning {
            if Date() > deadline {
                XCTFail("Timed out waiting for store operation")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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

    private static func status(devices: [DetectedDevice], runtimeActions: [DoctorCheck] = []) -> DoctorStatus {
        var checks: [DoctorCheck] = [
            .init(state: .pass, component: "Mac", name: "macOS supported", detail: "ready"),
            .init(state: .pass, component: "Apple Tooling", name: "xcrun", detail: "ready")
        ]
        if devices.isEmpty {
            checks.append(.init(
                state: .action,
                component: "Device",
                name: "connected iPhone",
                detail: "not detected",
                action: "Connect and unlock an iPhone.",
                requiredFor: "device"
            ))
        } else {
            for device in devices {
                checks.append(.init(state: .pass, component: "Device", name: "iPhone detected", detail: device.name, requiredFor: "device"))
                checks.append(.init(state: .pass, component: "Device", name: "device trusted", detail: "paired", requiredFor: "device"))
                checks.append(.init(state: .pass, component: "Device", name: "Developer Mode", detail: "enabled", requiredFor: "device"))
            }
        }
        checks.append(contentsOf: runtimeActions)
        return DoctorStatus(
            ready: !devices.isEmpty && runtimeActions.isEmpty,
            mac: MacSummary(ready: true),
            device: DeviceSummary(ready: !devices.isEmpty && runtimeActions.isEmpty, connected: !devices.isEmpty, devices: devices),
            actionsRequired: [],
            checks: checks
        )
    }
}

private actor SequenceSetupEngine: IOSSimSetupEngine {
    let status: DoctorStatus
    let failProvisionFor: String?
    let failureText: String?
    private(set) var provisionedDeviceIdentifiers: [String] = []

    init(status: DoctorStatus, failProvisionFor: String? = nil, failureText: String? = nil) {
        self.status = status
        self.failProvisionFor = failProvisionFor
        self.failureText = failureText
    }

    func doctor() async throws -> DoctorStatus {
        status
    }

    func setup() async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "setup ok", stderr: "")
    }

    func build() async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "build ok", stderr: "")
    }

    func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        guard let selectedDeviceIdentifier else {
            throw ProcessFailure(
                commandName: "device",
                result: ProcessResult(exitCode: 2, stdout: "", stderr: "DEVICE_SELECTION_REQUIRED")
            )
        }
        provisionedDeviceIdentifiers.append(selectedDeviceIdentifier)
        if selectedDeviceIdentifier == failProvisionFor {
            throw ProcessFailure(
                commandName: "device",
                result: ProcessResult(exitCode: 2, stdout: "", stderr: failureText ?? "failed")
            )
        }
        return ProcessResult(exitCode: 0, stdout: "Installed artifacts", stderr: "")
    }
}
