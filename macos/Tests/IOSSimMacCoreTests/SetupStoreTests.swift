import XCTest
@testable import IOSSimMacCore

@MainActor
final class SetupStoreTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "IOSSimMac.onboardingCompleted")
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
}
