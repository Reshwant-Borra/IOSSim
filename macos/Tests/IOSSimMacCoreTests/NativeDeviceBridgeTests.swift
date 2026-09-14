import XCTest
@testable import IOSSimMacCore

final class NativeDeviceBridgeTests: XCTestCase {
    func testZeroDevices() async throws {
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: []))
        let devices = try await bridge.listDevices()
        XCTAssertEqual(devices, [])
    }

    func testOneDeviceGetsConnectionGenerationAndInspection() async throws {
        let device = try descriptor("PHONE-0001", connection: .usb, mux: 7)
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [device]))
        let listed = try await bridge.listDevices()
        XCTAssertEqual(listed.count, 1)
        XCTAssertGreaterThan(listed[0].identity.connectionGeneration, 0)
        let inspected = try await bridge.inspect(listed[0].identity)
        XCTAssertEqual(inspected.identity.udid, "PHONE-0001")
        XCTAssertEqual(inspected.trust, .trusted)
    }

    func testTwoDevicesRemainDistinct() async throws {
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [
            try descriptor("PHONE-0001", connection: .usb, mux: 1),
            try descriptor("PHONE-0002", connection: .usb, mux: 2)
        ]))
        let devices = try await bridge.listDevices()
        XCTAssertEqual(devices.map(\.identity.udid), ["PHONE-0001", "PHONE-0002"])
    }

    func testUSBAndWirelessDuplicatePreferUSB() async throws {
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [
            try descriptor("PHONE-0001", connection: .wireless, mux: 5),
            try descriptor("PHONE-0001", connection: .usb, mux: 9)
        ]))
        let devices = try await bridge.listDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].connection, .usb)
        XCTAssertEqual(devices[0].identity.usbmuxIdentifier, 9)
    }

    func testLockedUntrustedAndDeveloperModeOffAreTyped() async throws {
        let device = try descriptor("PHONE-0001", connection: .usb, mux: 1)
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(
            devices: [device], trust: .missing, lockState: .locked, developerMode: .disabled
        ))
        let listed = try await bridge.listDevices()
        let state = try await bridge.inspect(listed[0].identity)
        XCTAssertEqual(state.trust, .missing)
        XCTAssertEqual(state.lockState, .locked)
        XCTAssertEqual(state.developerMode, .disabled)
    }

    func testDisconnectAndStructuredErrorPropagate() async throws {
        let device = try descriptor("PHONE-0001", connection: .usb, mux: 1)
        let disconnected = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [device], failure: .deviceDisconnected))
        let listed = try await disconnected.listDevices()
        do {
            _ = try await disconnected.inspect(listed[0].identity)
            XCTFail("expected disconnect")
        } catch let error as NativeDeviceBridgeError {
            XCTAssertEqual(error, .deviceDisconnected)
        }

        let protocolFailure = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [], listFailure: .protocolFailure("safe")))
        do {
            _ = try await protocolFailure.listDevices()
            XCTFail("expected structured failure")
        } catch let error as NativeDeviceBridgeError {
            XCTAssertEqual(error, .protocolFailure("safe"))
        }
    }

    func testIdentityRejectsCrossDeviceBinding() throws {
        let first = try IOSSimDeviceIdentity(udid: "PHONE-0001")
        let second = try IOSSimDeviceIdentity(udid: "PHONE-0002")
        XCTAssertFalse(first.binds(to: second))
        XCTAssertThrowsError(try IOSSimDeviceIdentity(udid: "../bad"))
    }

    func testProductionCandidatesContainNoXcodePath() {
        let paths = DynamicNativeDeviceTransport.libraryCandidates(environment: [:], bundle: .main)
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix("libiossim_device_bridge.dylib") })
        XCTAssertFalse(paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined().contains("devicectl"))
    }

    private func descriptor(_ id: String, connection: DeviceConnectionKind, mux: UInt32) throws -> NativeDeviceDescriptor {
        NativeDeviceDescriptor(identity: try IOSSimDeviceIdentity(udid: id, usbmuxIdentifier: mux), connection: connection)
    }
}

private actor FakeNativeTransport: NativeDeviceTransport {
    let devices: [NativeDeviceDescriptor]
    let trust: DeviceTrustState
    let lockState: DeviceLockState
    let developerMode: DeveloperModeReadiness
    let failure: NativeDeviceBridgeError?
    let listFailure: NativeDeviceBridgeError?

    init(
        devices: [NativeDeviceDescriptor],
        trust: DeviceTrustState = .trusted,
        lockState: DeviceLockState = .unlocked,
        developerMode: DeveloperModeReadiness = .enabled,
        failure: NativeDeviceBridgeError? = nil,
        listFailure: NativeDeviceBridgeError? = nil
    ) {
        self.devices = devices
        self.trust = trust
        self.lockState = lockState
        self.developerMode = developerMode
        self.failure = failure
        self.listFailure = listFailure
    }

    func listDevices(timeout: Duration) async throws -> [NativeDeviceDescriptor] {
        if let listFailure { throw listFailure }
        return devices
    }

    func inspect(_ identity: IOSSimDeviceIdentity, timeout: Duration) async throws -> NativeDeviceInspection {
        if let failure { throw failure }
        guard devices.contains(where: { $0.identity.udid == identity.udid }) else {
            throw NativeDeviceBridgeError.deviceNotFound
        }
        return NativeDeviceInspection(
            identity: identity,
            connection: devices.first(where: { $0.identity.udid == identity.udid })?.connection ?? .unknown,
            name: "Test iPhone",
            model: "iPhone99,1",
            osVersion: "26.0",
            osBuild: "23A1",
            trust: trust,
            lockState: lockState,
            developerMode: developerMode
        )
    }
}
