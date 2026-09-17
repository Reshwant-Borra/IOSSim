import Foundation
@testable import IOSSimMacCore
import XCTest

final class RichRuntimeReadinessTests: XCTestCase {
    func testBoundReceiptRequiresEveryOperationalStageAndCleanup() throws {
        let request = fixtureRequest()
        XCTAssertTrue(fixtureReceipt(request: request).validates(request))
        XCTAssertFalse(fixtureReceipt(request: request, locationCleared: false).validates(request))
        XCTAssertFalse(fixtureReceipt(request: request, testPlanStarted: false).validates(request))
        let anotherGeneration = RichRuntimeProofRequest(
            deviceUDID: request.deviceUDID,
            teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity,
            artifactSetIdentity: request.artifactSetIdentity,
            profileSetIdentity: request.profileSetIdentity,
            pairingGeneration: request.pairingGeneration + 1,
            developerServicesSession: request.developerServicesSession,
            developerSupportIdentity: request.developerSupportIdentity,
            runnerBundleIdentifier: request.runnerBundleIdentifier
        )
        XCTAssertFalse(fixtureReceipt(request: request).validates(anotherGeneration))
    }

    func testCoordinatorWritesRequestLaunchesExactAppAndAcceptsOnlyMatchingReceipt() async throws {
        let request = fixtureRequest()
        let service = RuntimeProofApplicationService(mode: .success)
        let device = try IOSSimDeviceIdentity(
            udid: request.deviceUDID, usbmuxIdentifier: 7,
            connection: .usb, connectionGeneration: 9
        )
        let receipt = try await RichRuntimeReadinessCoordinator(
            service: service, pollCount: 2, pollNanoseconds: 1
        ).prove(request: request, device: device, appBundleIdentifier: "com.example.main")
        XCTAssertTrue(receipt.validates(request))
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.launched, ["com.example.main"])
        XCTAssertEqual(snapshot.writtenPath, RichRuntimeReadinessCoordinator.requestPath)
    }

    func testCoordinatorRejectsFailureReceiptAndTimesOutWithoutReceipt() async throws {
        let request = fixtureRequest()
        let device = try IOSSimDeviceIdentity(udid: request.deviceUDID)
        do {
            _ = try await RichRuntimeReadinessCoordinator(
                service: RuntimeProofApplicationService(mode: .cleanupFailed),
                pollCount: 2, pollNanoseconds: 1
            ).prove(request: request, device: device, appBundleIdentifier: "com.example.main")
            XCTFail("Expected cleanup rejection")
        } catch let failure as RichRuntimeProofFailure {
            XCTAssertEqual(failure, .cleanupFailed)
        }
        do {
            _ = try await RichRuntimeReadinessCoordinator(
                service: RuntimeProofApplicationService(mode: .missing),
                pollCount: 2, pollNanoseconds: 1
            ).prove(request: request, device: device, appBundleIdentifier: "com.example.main")
            XCTFail("Expected bounded timeout")
        } catch let failure as RichRuntimeProofFailure {
            XCTAssertEqual(failure, .receiptUnavailable)
        }
    }

    private func fixtureRequest() -> RichRuntimeProofRequest {
        RichRuntimeProofRequest(
            deviceUDID: "PHONE-0001",
            teamIdentifier: "TEAM1",
            releaseIdentity: "0.1.0:4",
            artifactSetIdentity: String(repeating: "a", count: 64),
            profileSetIdentity: String(repeating: "b", count: 64),
            pairingGeneration: 4,
            developerServicesSession: UUID().uuidString,
            developerSupportIdentity: "23A1:fixture",
            runnerBundleIdentifier: "com.example.runner"
        )
    }

    private func fixtureReceipt(
        request: RichRuntimeProofRequest,
        testPlanStarted: Bool = true,
        locationCleared: Bool = true
    ) -> RichRuntimeProofReceipt {
        RichRuntimeProofReceipt(
            schemaVersion: 1,
            requestID: request.requestID,
            deviceUDIDHash: RichRuntimeProofReceipt.hash(request.deviceUDID),
            teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity,
            artifactSetIdentity: request.artifactSetIdentity,
            profileSetIdentity: request.profileSetIdentity,
            pairingGeneration: request.pairingGeneration,
            developerServicesSession: request.developerServicesSession,
            developerSupportIdentity: request.developerSupportIdentity,
            runnerBundleIdentifier: request.runnerBundleIdentifier,
            testManagerControlReady: true,
            runnerLaunched: true,
            xctestHandshakeReady: true,
            testPlanStarted: testPlanStarted,
            richLocationProbeCompleted: true,
            locationCleared: locationCleared,
            sessionCleanedUp: locationCleared,
            completedAt: Date()
        )
    }
}

private actor RuntimeProofApplicationService: NativeApplicationServicing {
    enum Mode { case success, cleanupFailed, missing }
    struct Snapshot { let launched: [String]; let writtenPath: String? }
    let mode: Mode
    private var request: RichRuntimeProofRequest?
    private var launched: [String] = []
    private var writtenPath: String?

    init(mode: Mode) { self.mode = mode }
    func snapshot() -> Snapshot { Snapshot(launched: launched, writtenPath: writtenPath) }
    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] { [] }
    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {}
    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {}
    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws { launched.append(bundleIdentifier) }
    func writeContainer(bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity) async throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        request = try decoder.decode(RichRuntimeProofRequest.self, from: data)
        writtenPath = relativePath
    }
    func readContainer(bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity) async throws -> Data {
        guard mode != .missing, let request else {
            throw NativeDeviceBridgeError.containerUnavailable("fixture receipt missing")
        }
        let cleared = mode == .success
        let receipt = RichRuntimeProofReceipt(
            schemaVersion: 1,
            requestID: request.requestID,
            deviceUDIDHash: RichRuntimeProofReceipt.hash(request.deviceUDID),
            teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity,
            artifactSetIdentity: request.artifactSetIdentity,
            profileSetIdentity: request.profileSetIdentity,
            pairingGeneration: request.pairingGeneration,
            developerServicesSession: request.developerServicesSession,
            developerSupportIdentity: request.developerSupportIdentity,
            runnerBundleIdentifier: request.runnerBundleIdentifier,
            testManagerControlReady: true,
            runnerLaunched: true,
            xctestHandshakeReady: true,
            testPlanStarted: true,
            richLocationProbeCompleted: true,
            locationCleared: cleared,
            sessionCleanedUp: cleared,
            completedAt: Date()
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }
}
