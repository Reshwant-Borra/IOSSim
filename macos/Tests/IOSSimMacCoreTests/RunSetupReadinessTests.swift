import Foundation
@testable import IOSSimMacCore
import XCTest

/// Setup completion is the user's own Run Setup tap: Veya asks, waits, and reads.
/// It never starts the run, and only a receipt bound to this request, device, app
/// and delivered pairing satisfies setup.
final class RunSetupReadinessTests: XCTestCase {
    private let appBundleIdentifier = "com.example.main"
    private let pairingIdentifier = "pairing-id-1"
    private let fingerprint = String(repeating: "c", count: 64)

    private var stateRoots: [URL] = []

    override func tearDown() {
        for root in stateRoots { try? FileManager.default.removeItem(at: root) }
        stateRoots.removeAll()
        super.tearDown()
    }

    private func device(udid: String = "PHONE-0001") throws -> IOSSimDeviceIdentity {
        try IOSSimDeviceIdentity(udid: udid, usbmuxIdentifier: 7, connection: .usb, connectionGeneration: 9)
    }

    private func makeStateRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("veya-run-setup-\(UUID().uuidString)", isDirectory: true)
        stateRoots.append(root)
        return root
    }

    func testVeyaAsksAndWaitsWithoutEverStartingTheRunItself() async throws {
        let service = RunSetupApplicationService(mode: .noReceipt)
        let coordinator = RunSetupReadinessCoordinator(service: service, pollCount: 2, pollNanoseconds: 1)
        let request = try await coordinator.requestSetup(
            device: try device(), appBundleIdentifier: appBundleIdentifier,
            teamIdentifier: "TEAM1", releaseIdentity: "veya-v2:abc"
        )
        do {
            _ = try await coordinator.awaitRunSetup(
                request: request, device: try device(), appBundleIdentifier: appBundleIdentifier,
                pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint
            )
            XCTFail("waiting on the user is not success")
        } catch let failure as RunSetupFailure {
            XCTAssertEqual(failure, .notTapped)
        }
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.writtenPath, RunSetupReadinessCoordinator.requestPath)
        XCTAssertTrue(snapshot.launched.isEmpty, "Veya must never launch or drive the run itself")
    }

    func testTappedRunSetupSatisfiesSetupAndReportsWaitingUntilItLands() async throws {
        let service = RunSetupApplicationService(mode: .success(
            pairingIdentifier: pairingIdentifier, fingerprint: fingerprint, appBundleIdentifier: appBundleIdentifier
        ))
        let progress = ProgressRecorder()
        let coordinator = RunSetupReadinessCoordinator(
            service: service, pollCount: 4, pollNanoseconds: 1,
            progress: { progress.append($0) }
        )
        let request = try await coordinator.requestSetup(
            device: try device(), appBundleIdentifier: appBundleIdentifier,
            teamIdentifier: "TEAM1", releaseIdentity: "veya-v2:abc"
        )
        await service.tapRunSetup()
        let receipt = try await coordinator.awaitRunSetup(
            request: request, device: try device(), appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint
        )
        XCTAssertTrue(receipt.succeeded)
        XCTAssertTrue(receipt.satisfies(
            request, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint
        ))
        XCTAssertFalse(progress.values().contains(.waitingForRunSetupTap),
                       "a receipt that is already there needs no instruction")
    }

    func testFailedRunSetupNeverSatisfiesSetupAndKeepsTheRealError() async throws {
        let service = RunSetupApplicationService(mode: .failed(
            code: "ENDPOINT_UNREACHABLE", message: "TCP connect to 10.7.0.1:49152 failed.",
            appBundleIdentifier: appBundleIdentifier
        ))
        let progress = ProgressRecorder()
        let coordinator = RunSetupReadinessCoordinator(
            service: service, pollCount: 3, pollNanoseconds: 1, progress: { progress.append($0) }
        )
        let request = try await coordinator.requestSetup(
            device: try device(), appBundleIdentifier: appBundleIdentifier,
            teamIdentifier: "TEAM1", releaseIdentity: "veya-v2:abc"
        )
        await service.tapRunSetup()
        do {
            _ = try await coordinator.awaitRunSetup(
                request: request, device: try device(), appBundleIdentifier: appBundleIdentifier,
                pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint
            )
            XCTFail("a failed run is never setup complete")
        } catch let failure as RunSetupFailure {
            XCTAssertEqual(failure, .reportedOnPhone(
                code: "ENDPOINT_UNREACHABLE", message: "TCP connect to 10.7.0.1:49152 failed."))
        }
        XCTAssertTrue(progress.values().contains(
            .failedOnPhone(code: "ENDPOINT_UNREACHABLE", message: "TCP connect to 10.7.0.1:49152 failed.")),
            "the user is told the real reason while Veya is still waiting")
        // The same VPN failure reaches the engine as the phone's error, not a generic one.
        let mapped = RuntimeReadinessDomain.runSetupFailed(
            code: "ENDPOINT_UNREACHABLE", message: "TCP connect to 10.7.0.1:49152 failed.")
        XCTAssertTrue(mapped.safeMessage.contains("ENDPOINT_UNREACHABLE"))
        XCTAssertTrue(mapped.retryable)
        XCTAssertNotNil(mapped.userAction)
    }

    /// Prepare places the request and ends; Continue reuses it. Reissuing on every run would throw
    /// away a tap that landed between the two, so the user would have to tap again for nothing.
    func testPendingRequestIsReusedSoALateTapStillCounts() async throws {
        let root = makeStateRoot()
        let service = RunSetupApplicationService(mode: .success(
            pairingIdentifier: pairingIdentifier, fingerprint: fingerprint, appBundleIdentifier: appBundleIdentifier
        ))
        // Prepare: one read, no receipt, no waiting on the user.
        let prepare = RunSetupReadinessCoordinator(service: service, stateRoot: root)
        let issued = try await prepare.requestSetup(
            device: try device(), appBundleIdentifier: appBundleIdentifier,
            teamIdentifier: "TEAM1", releaseIdentity: "veya-v2:abc"
        )
        do {
            _ = try await prepare.awaitRunSetup(
                request: issued, device: try device(), appBundleIdentifier: appBundleIdentifier,
                pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint)
            XCTFail("preparation is never setup complete")
        } catch let failure as RunSetupFailure {
            XCTAssertEqual(failure, .notTapped)
        }

        await service.tapRunSetup()

        // Continue, in a later run of a relaunched Veya: same request, verified, never reissued.
        let verify = RunSetupReadinessCoordinator(service: service, stateRoot: root)
        let pending = await verify.pendingRequest(
            device: try device(), appBundleIdentifier: appBundleIdentifier,
            teamIdentifier: "TEAM1", releaseIdentity: "veya-v2:abc")
        XCTAssertEqual(pending?.requestID, issued.requestID)
        let receipt = try await verify.awaitRunSetup(
            request: try XCTUnwrap(pending), device: try device(), appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint)
        XCTAssertTrue(receipt.succeeded)
        XCTAssertEqual(receipt.requestID, issued.requestID)
        let launched = await service.snapshot().launched
        XCTAssertTrue(launched.isEmpty, "Veya never starts the run, on either press")

        // The phone retires an answered request, so Veya drops its copy: the next run asks afresh.
        let retired = await verify.pendingRequest(
            device: try device(), appBundleIdentifier: appBundleIdentifier,
            teamIdentifier: "TEAM1", releaseIdentity: "veya-v2:abc")
        XCTAssertNil(retired)
    }

    /// Reuse is bounded by the same binding the receipt is: anything else is reissued rather than
    /// verified against a request that no longer describes this iPhone, install or run.
    func testExpiredOrMisboundPendingRequestIsReplaced() async throws {
        let root = makeStateRoot()
        let service = RunSetupApplicationService(mode: .noReceipt)
        let clock = MutableClock()
        let coordinator = RunSetupReadinessCoordinator(service: service, stateRoot: root, now: { clock.now })
        _ = try await coordinator.requestSetup(
            device: try device(), appBundleIdentifier: appBundleIdentifier,
            teamIdentifier: "TEAM1", releaseIdentity: "veya-v2:abc"
        )
        func pending(udid: String = "PHONE-0001", app: String? = nil, team: String = "TEAM1",
                     release: String = "veya-v2:abc") async throws -> RunSetupRequest? {
            await coordinator.pendingRequest(
                device: try device(udid: udid), appBundleIdentifier: app ?? appBundleIdentifier,
                teamIdentifier: team, releaseIdentity: release)
        }
        var reused = try await pending()
        XCTAssertNotNil(reused, "a fresh, matching request is reused")
        for (value, reason) in [
            (try await pending(udid: "PHONE-0002"), "another iPhone"),
            (try await pending(app: "com.example.other"), "another installed app"),
            (try await pending(team: "TEAM2"), "another team"),
            (try await pending(release: "veya-v2:def"), "another signed payload"),
        ] {
            XCTAssertNil(value, reason)
        }

        clock.now += RunSetupRequest.lifetime + 1
        reused = try await pending()
        XCTAssertNil(reused, "a request the phone no longer accepts is reissued")

        clock.now -= RunSetupRequest.lifetime + 1
        await service.forgetContainer()
        reused = try await pending()
        XCTAssertNil(reused, "a container that carries neither the request nor its receipt")
    }

    func testOnlyAReceiptBoundToThisRequestDeviceAppAndPairingSatisfiesSetup() throws {
        let request = RunSetupRequest(
            deviceUDID: "PHONE-0001", teamIdentifier: "TEAM1", releaseIdentity: "veya-v2:abc",
            appBundleIdentifier: appBundleIdentifier
        )
        XCTAssertTrue(receipt(for: request).satisfies(
            request, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint))

        // A success recorded for an earlier request cannot satisfy a new one.
        let reissued = RunSetupRequest(
            deviceUDID: request.deviceUDID, teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity, appBundleIdentifier: appBundleIdentifier
        )
        XCTAssertFalse(receipt(for: request).satisfies(
            reissued, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint))
        // A receipt written before Veya asked is stale evidence, not an answer.
        XCTAssertFalse(receipt(for: request, completedAt: request.createdAt.addingTimeInterval(-120)).satisfies(
            request, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint))
        // Another device, another installed app, or a pairing Veya does not own.
        XCTAssertFalse(receipt(for: request, deviceUDID: "PHONE-0002").satisfies(
            request, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint))
        XCTAssertFalse(receipt(for: request).satisfies(
            request, appBundleIdentifier: "com.example.other",
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint))
        XCTAssertFalse(receipt(for: request).satisfies(
            request, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: String(repeating: "d", count: 64)))
        // Every stage of the real run is required, including the verified, cleared location.
        XCTAssertFalse(receipt(for: request, locationVerified: false).satisfies(
            request, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint))
        XCTAssertFalse(receipt(for: request, locationCleared: false).satisfies(
            request, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint))
        XCTAssertFalse(receipt(for: request, localDevVPNReady: false).satisfies(
            request, appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier, pairingPublicKeyFingerprint: fingerprint))
    }

    private func receipt(
        for request: RunSetupRequest,
        deviceUDID: String? = nil,
        localDevVPNReady: Bool = true,
        locationVerified: Bool = true,
        locationCleared: Bool = true,
        completedAt: Date? = nil
    ) -> RunSetupReceipt {
        RunSetupReceipt(
            requestID: request.requestID,
            deviceUDIDHash: RunSetupReceipt.hash(deviceUDID ?? request.deviceUDID),
            teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity,
            appBundleIdentifier: appBundleIdentifier,
            pairingIdentifier: pairingIdentifier,
            pairingPublicKeyFingerprint: fingerprint,
            pairingReady: true,
            localDevVPNReady: localDevVPNReady,
            endpointReachable: true,
            sessionEstablished: true,
            locationVerified: locationVerified,
            locationCleared: locationCleared,
            completedAt: completedAt ?? request.createdAt.addingTimeInterval(1)
        )
    }
}

private final class MutableClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_900_000_000)
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RunSetupProgress] = []
    func append(_ value: RunSetupProgress) { lock.lock(); recorded.append(value); lock.unlock() }
    func values() -> [RunSetupProgress] { lock.lock(); defer { lock.unlock() }; return recorded }
}

/// Stands in for the app container: Veya writes the request, and a receipt exists
/// only once `tapRunSetup()` models the user's tap.
private actor RunSetupApplicationService: NativeApplicationServicing {
    enum Mode {
        case noReceipt
        case success(pairingIdentifier: String, fingerprint: String, appBundleIdentifier: String)
        case failed(code: String, message: String, appBundleIdentifier: String)
    }
    struct Snapshot { let launched: [String]; let writtenPath: String? }

    private let mode: Mode
    private var request: RunSetupRequest?
    private var tapped = false
    private var retired = false
    private var launched: [String] = []
    private var writtenPath: String?

    init(mode: Mode) { self.mode = mode }
    func snapshot() -> Snapshot { Snapshot(launched: launched, writtenPath: writtenPath) }
    /// The user's tap. A successful run retires the request, exactly as `RunSetupInbox` does.
    func tapRunSetup() {
        tapped = true
        if case .success = mode { retired = true }
    }
    func forgetContainer() { request = nil; tapped = false; retired = false }

    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] { [] }
    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {}
    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {}
    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        launched.append(bundleIdentifier)
    }

    func writeContainer(
        bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity
    ) async throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        request = try decoder.decode(RunSetupRequest.self, from: data)
        retired = false
        writtenPath = relativePath
    }

    func readContainer(
        bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity
    ) async throws -> Data {
        // The phone keeps the request until a run succeeds, then replaces it with the receipt.
        if relativePath == RunSetupReadinessCoordinator.requestPath {
            guard let request, !retired else {
                throw NativeDeviceBridgeError.containerUnavailable("no run setup request")
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(request)
        }
        guard tapped, let request else {
            throw NativeDeviceBridgeError.containerUnavailable("no run setup receipt yet")
        }
        let receipt: RunSetupReceipt
        switch mode {
        case .noReceipt:
            throw NativeDeviceBridgeError.containerUnavailable("no run setup receipt yet")
        case .success(let pairingIdentifier, let fingerprint, let appBundleIdentifier):
            receipt = RunSetupReceipt(
                requestID: request.requestID,
                deviceUDIDHash: RunSetupReceipt.hash(request.deviceUDID),
                teamIdentifier: request.teamIdentifier,
                releaseIdentity: request.releaseIdentity,
                appBundleIdentifier: appBundleIdentifier,
                pairingIdentifier: pairingIdentifier,
                pairingPublicKeyFingerprint: fingerprint,
                pairingReady: true, localDevVPNReady: true, endpointReachable: true,
                sessionEstablished: true, locationVerified: true, locationCleared: true,
                completedAt: Date()
            )
        case .failed(let code, let message, let appBundleIdentifier):
            receipt = RunSetupReceipt(
                requestID: request.requestID,
                deviceUDIDHash: RunSetupReceipt.hash(request.deviceUDID),
                teamIdentifier: request.teamIdentifier,
                releaseIdentity: request.releaseIdentity,
                appBundleIdentifier: appBundleIdentifier,
                pairingIdentifier: "", pairingPublicKeyFingerprint: "",
                pairingReady: true, localDevVPNReady: false, endpointReachable: false,
                sessionEstablished: false, locationVerified: false, locationCleared: false,
                errorCode: code, errorMessage: message, completedAt: Date()
            )
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }
}
