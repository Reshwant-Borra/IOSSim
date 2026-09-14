import Foundation
import XCTest
@testable import IOSSimMacCore

final class ConsumerOnboardingCoordinatorTests: XCTestCase {
    func testSingleDeviceRunsConsumerPhasesAndResumesSafely() async throws {
        let identity = try IOSSimDeviceIdentity(udid: "ONBOARD-DEVICE-001", usbmuxIdentifier: 1)
        let descriptor = NativeDeviceDescriptor(identity: identity, connection: .usb)
        let services = FakeOnboardingServices(identity: identity)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("onboarding-\(UUID().uuidString).json")
        let coordinator = ConsumerOnboardingCoordinator(bridge: IOSSimDeviceBridge(transport: OnboardingTransport(descriptor: descriptor)), services: services, journal: SetupJournalStore(url: url))
        let result = try await coordinator.run()
        XCTAssertEqual(result.phase, .ready)
        XCTAssertEqual(services.calls, ["account", "iossim", "install", "pair", "verify"])
        try? FileManager.default.removeItem(at: url)
    }

    func testMultipleDevicesRequireExplicitSelection() async throws {
        let first = NativeDeviceDescriptor(identity: try IOSSimDeviceIdentity(udid: "ONBOARD-DEVICE-001"), connection: .usb)
        let second = NativeDeviceDescriptor(identity: try IOSSimDeviceIdentity(udid: "ONBOARD-DEVICE-002"), connection: .usb)
        let services = FakeOnboardingServices(identity: first.identity)
        let coordinator = ConsumerOnboardingCoordinator(bridge: IOSSimDeviceBridge(transport: OnboardingTransport(descriptors: [first, second])), services: services)
        do { _ = try await coordinator.run(); XCTFail("expected explicit selection") }
        catch let error as ConsumerOnboardingError { XCTAssertEqual(error, .selectionRequired) }
    }

    func testLockedDeviceReturnsUserActionWithoutDestructiveRepair() async throws {
        let identity = try IOSSimDeviceIdentity(udid: "ONBOARD-DEVICE-001")
        let services = FakeOnboardingServices(identity: identity, lockState: .locked)
        let coordinator = ConsumerOnboardingCoordinator(bridge: IOSSimDeviceBridge(transport: OnboardingTransport(descriptor: .init(identity: identity, connection: .usb))), services: services)
        let result = try await coordinator.run()
        XCTAssertEqual(result.userAction, .unlockIPhone)
        XCTAssertTrue(services.calls.isEmpty)
    }
}

private actor OnboardingTransport: NativeDeviceTransport {
    let descriptors: [NativeDeviceDescriptor]
    init(descriptor: NativeDeviceDescriptor) { descriptors = [descriptor] }
    init(descriptors: [NativeDeviceDescriptor]) { self.descriptors = descriptors }
    func listDevices(timeout: Duration) async throws -> [NativeDeviceDescriptor] { descriptors }
    func inspect(_ identity: IOSSimDeviceIdentity, timeout: Duration) async throws -> NativeDeviceInspection {
        NativeDeviceInspection(identity: identity, connection: .usb, trust: .trusted, lockState: .unlocked, developerMode: .enabled)
    }
}

private final class FakeOnboardingServices: ConsumerOnboardingServices, @unchecked Sendable {
    let identity: IOSSimDeviceIdentity; let lockState: DeviceLockState; private(set) var calls: [String] = []
    init(identity: IOSSimDeviceIdentity, lockState: DeviceLockState = .unlocked) { self.identity = identity; self.lockState = lockState }
    func inspect(_ device: IOSSimDeviceIdentity) async throws -> NativeDeviceInspection { .init(identity: device, connection: .usb, trust: .trusted, lockState: lockState, developerMode: .enabled) }
    func prepareAppleAccount() async throws { calls.append("account") }
    func prepareIOSSim() async throws { calls.append("iossim") }
    func install(on device: IOSSimDeviceIdentity) async throws { calls.append("install") }
    func pair(on device: IOSSimDeviceIdentity) async throws { calls.append("pair") }
    func verify(on device: IOSSimDeviceIdentity) async throws { calls.append("verify") }
}
