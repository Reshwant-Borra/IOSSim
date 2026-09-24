import CryptoKit
import Foundation
import XCTest
@testable import IOSSimMacCore

final class RemotePairingLifecycleTests: XCTestCase {
    private func device() throws -> IOSSimDeviceIdentity { try IOSSimDeviceIdentity(udid: "PAIRING-DEVICE-001") }

    func testEnvelopeRoundTripAndNonceBinding() throws {
        let d = try device()
        let material = try FakePairingNative.material()
        let record = RemotePairingRecord(metadata: .init(deviceUDID: d.udid, teamIdentifier: "TEAM123",
            identifier: material.identifier, publicKeyFingerprint: material.publicKeyFingerprint), pairingData: material.pairingData)
        let session = RemotePairingBootstrapSession(importKey: Data(repeating: 7, count: 32))
        let envelope = try RemotePairingCoordinator.makeEnvelope(record: record, bootstrap: session)
        XCTAssertEqual(try envelope.decrypt(using: session), material.pairingData)
        XCTAssertThrowsError(try envelope.decrypt(using: .init(nonce: "other", importKey: session.importKey)))
    }

    func testNativeFallbackActivationPreservesDeveloperModeAndTrust() async throws {
        let trustDetail = "launchapplication: com.apple.dt.CoreDeviceError code = 10002 "
            + "FBSOpenApplicationErrorDomain code = 3 BSErrorCodeDescription: Security "
            + "profile has not been explicitly trusted"
        for (bridge, expected) in [
            (NativeDeviceBridgeError.developerModeRequired, RemotePairingFailure.developerModeRequired),
            (NativeDeviceBridgeError.launchRejected(trustDetail), .developerTrustRequired),
        ] {
            let delivery = NativeRemotePairingContainerDelivery(
                service: ActivationFailureService(error: bridge)
            )
            do {
                try await delivery.activateApp(
                    on: try device(), appBundleIdentifier: "com.example.veya"
                )
                XCTFail("expected typed launch failure")
            } catch {
                XCTAssertEqual(error as? RemotePairingFailure, expected)
            }
        }
    }

    func testCoordinatorReusesValidRecordAndCompletesReceiptAndProof() async throws {
        let d = try device(); let store = InMemoryRemotePairingStore(); let native = FakePairingNative()
        let delivery = FakePairingDelivery(native: native, device: d, team: "TEAM123")
        let coordinator = RemotePairingCoordinator(store: store, native: native, delivery: delivery, proof: AcceptingProof())
        let session = RemotePairingBootstrapSession(importKey: Data(repeating: 1, count: 32))
        let first = try await coordinator.prepare(device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app", hostname: "IOSSim-Mac", bootstrap: session)
        let second = try await coordinator.prepare(device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app", hostname: "IOSSim-Mac", bootstrap: session)
        XCTAssertEqual(first.pairingData, second.pairingData)
        XCTAssertEqual(first.metadata.identifier, second.metadata.identifier)
        XCTAssertNotNil(second.metadata.lastValidatedAt)
        XCTAssertEqual(native.createCount, 1)
        XCTAssertEqual(delivery.lastEnvelope?.deviceUDID, d.udid)
    }

    func testCoordinatorRepairsOnlyWhenValidationFails() async throws {
        let d = try device(); let store = InMemoryRemotePairingStore(); let native = FakePairingNative(failNextValidation: true)
        let material = try FakePairingNative.material()
        try store.save(RemotePairingRecord(
            metadata: .init(
                deviceUDID: d.udid,
                teamIdentifier: "TEAM123",
                identifier: material.identifier,
                publicKeyFingerprint: material.publicKeyFingerprint
            ),
            pairingData: material.pairingData
        ))
        let delivery = FakePairingDelivery(native: native, device: d, team: "TEAM123")
        let coordinator = RemotePairingCoordinator(store: store, native: native, delivery: delivery, proof: AcceptingProof())
        let session = RemotePairingBootstrapSession(importKey: Data(repeating: 2, count: 32))
        _ = try await coordinator.prepare(device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app", hostname: "IOSSim-Mac", bootstrap: session)
        XCTAssertEqual(native.createCount, 1)
    }

    func testReceiptForAnotherDeviceIsRejected() async throws {
        let d = try device(); let native = FakePairingNative()
        let delivery = FakePairingDelivery(native: native, device: d, team: "TEAM123", wrongDevice: true)
        let coordinator = RemotePairingCoordinator(store: InMemoryRemotePairingStore(), native: native, delivery: delivery, proof: AcceptingProof())
        let session = RemotePairingBootstrapSession(importKey: Data(repeating: 3, count: 32))
        do {
            _ = try await coordinator.prepare(device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app", hostname: "IOSSim-Mac", bootstrap: session)
            XCTFail("expected receipt rejection")
        } catch let error as RemotePairingFailure { XCTAssertEqual(error, .receiptInvalid) }
    }

    func testFailedRepairReceiptKeepsPriorActiveRecord() async throws {
        let d = try device(); let store = InMemoryRemotePairingStore()
        let material = try FakePairingNative.material()
        let active = RemotePairingRecord(
            metadata: .init(deviceUDID: d.udid, teamIdentifier: "TEAM123",
                identifier: material.identifier, publicKeyFingerprint: material.publicKeyFingerprint),
            pairingData: material.pairingData
        )
        try store.save(active)
        let native = FakePairingNative()
        let delivery = FakePairingDelivery(native: native, device: d, team: "TEAM123", wrongDevice: true)
        let coordinator = RemotePairingCoordinator(store: store, native: native, delivery: delivery, proof: AcceptingProof())
        do {
            _ = try await coordinator.prepare(
                device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app",
                hostname: "IOSSim-Mac", bootstrap: .init(importKey: Data(repeating: 4, count: 32)),
                forceRepair: true, releaseIdentity: "test:1"
            )
            XCTFail("Expected receipt rejection")
        } catch let failure as RemotePairingFailure {
            XCTAssertEqual(failure, .receiptInvalid)
        }
        XCTAssertEqual(try store.load(deviceUDID: d.udid, teamIdentifier: "TEAM123"), active)
        XCTAssertNotNil(try store.loadCandidate(deviceUDID: d.udid, teamIdentifier: "TEAM123"))
    }

    func testPossessionOrDeveloperProofFailureNeverPromotesCandidate() async throws {
        for (corruptProof, operationalProof) in [
            (true, false),
            (false, true),
        ] {
            let d = try device(); let store = InMemoryRemotePairingStore()
            let material = try FakePairingNative.material()
            let active = RemotePairingRecord(
                metadata: .init(deviceUDID: d.udid, teamIdentifier: "TEAM123",
                    identifier: material.identifier, publicKeyFingerprint: material.publicKeyFingerprint),
                pairingData: material.pairingData
            )
            try store.save(active)
            let native = FakePairingNative()
            let delivery = FakePairingDelivery(
                native: native, device: d, team: "TEAM123", corruptProof: corruptProof
            )
            let proof: any RemotePairingOperationalProof = operationalProof ? FailingProof() : AcceptingProof()
            let coordinator = RemotePairingCoordinator(store: store, native: native, delivery: delivery, proof: proof)
            do {
                _ = try await coordinator.prepare(
                    device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app",
                    hostname: "IOSSim-Mac", bootstrap: .init(importKey: Data(repeating: 5, count: 32)),
                    forceRepair: true, releaseIdentity: "test:1"
                )
                XCTFail("Expected proof failure")
            } catch let failure as RemotePairingFailure {
                XCTAssertEqual(failure, .operationalProofFailed)
            }
            XCTAssertEqual(try store.load(deviceUDID: d.udid, teamIdentifier: "TEAM123"), active)
            XCTAssertNotNil(try store.loadCandidate(deviceUDID: d.udid, teamIdentifier: "TEAM123"))
        }
    }

    func testCrashBeforePromotionResumesCandidateWithoutCreatingAnotherRecord() async throws {
        let d = try device(); let store = InMemoryRemotePairingStore(); let native = FakePairingNative()
        let session = RemotePairingBootstrapSession(
            importKey: Data(repeating: 6, count: 32), requestID: "request-1",
            pairingGeneration: 1, releaseIdentity: "test:1"
        )
        let first = RemotePairingCoordinator(
            store: store, native: native,
            delivery: FakePairingDelivery(native: native, device: d, team: "TEAM123"),
            proof: FailingProof()
        )
        do {
            _ = try await first.prepare(
                device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app",
                hostname: "IOSSim-Mac", bootstrap: session, forceRepair: true,
                releaseIdentity: "test:1"
            )
            XCTFail("Expected simulated pre-promotion crash")
        } catch let failure as RemotePairingFailure {
            XCTAssertEqual(failure, .operationalProofFailed)
        }
        XCTAssertEqual(native.createCount, 1)
        let resumed = RemotePairingCoordinator(
            store: store, native: native,
            delivery: FakePairingDelivery(native: native, device: d, team: "TEAM123"),
            proof: AcceptingProof()
        )
        _ = try await resumed.prepare(
            device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app",
            hostname: "IOSSim-Mac", bootstrap: session, forceRepair: true,
            releaseIdentity: "test:1"
        )
        XCTAssertEqual(native.createCount, 1)
        XCTAssertNotNil(try store.load(deviceUDID: d.udid, teamIdentifier: "TEAM123"))
        XCTAssertNil(try store.loadCandidate(deviceUDID: d.udid, teamIdentifier: "TEAM123"))
    }

    func testPhoneFailureBeforePromotionKeepsPriorActiveRecord() async throws {
        let d = try device(); let store = InMemoryRemotePairingStore()
        let material = try FakePairingNative.material()
        let active = RemotePairingRecord(
            metadata: .init(deviceUDID: d.udid, teamIdentifier: "TEAM123",
                identifier: material.identifier, publicKeyFingerprint: material.publicKeyFingerprint),
            pairingData: material.pairingData
        )
        try store.save(active)
        let native = FakePairingNative()
        let delivery = FakePairingDelivery(
            native: native, device: d, team: "TEAM123", failPromotionReceipt: true
        )
        let coordinator = RemotePairingCoordinator(store: store, native: native, delivery: delivery, proof: AcceptingProof())
        do {
            _ = try await coordinator.prepare(
                device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app",
                hostname: "IOSSim-Mac", bootstrap: .init(importKey: Data(repeating: 7, count: 32)),
                forceRepair: true, releaseIdentity: "test:1"
            )
            XCTFail("Expected missing promotion receipt")
        } catch let failure as RemotePairingFailure {
            XCTAssertEqual(failure, .receiptMissing)
        }
        XCTAssertEqual(try store.load(deviceUDID: d.udid, teamIdentifier: "TEAM123"), active)
        XCTAssertNotNil(try store.loadCandidate(deviceUDID: d.udid, teamIdentifier: "TEAM123"))
    }

    func testReplayedRequestReceiptIsRejected() async throws {
        let d = try device(); let native = FakePairingNative()
        let delivery = FakePairingDelivery(
            native: native, device: d, team: "TEAM123", replayedRequestID: "old-request"
        )
        let coordinator = RemotePairingCoordinator(
            store: InMemoryRemotePairingStore(), native: native, delivery: delivery, proof: AcceptingProof()
        )
        do {
            _ = try await coordinator.prepare(
                device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app",
                hostname: "IOSSim-Mac",
                bootstrap: .init(importKey: Data(repeating: 8, count: 32), requestID: "new-request",
                    pairingGeneration: 1, releaseIdentity: "test:1"),
                releaseIdentity: "test:1"
            )
            XCTFail("Expected replay rejection")
        } catch let failure as RemotePairingFailure {
            XCTAssertEqual(failure, .receiptInvalid)
        }
    }
}

private struct AcceptingProof: RemotePairingOperationalProof {
    func verify(on device: IOSSimDeviceIdentity, pairing: RemotePairingRecord) async throws {}
}

private struct FailingProof: RemotePairingOperationalProof {
    func verify(on device: IOSSimDeviceIdentity, pairing: RemotePairingRecord) async throws {
        throw RemotePairingFailure.operationalProofFailed
    }
}

private struct ActivationFailureService: NativeApplicationServicing {
    let error: NativeDeviceBridgeError
    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] { [] }
    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {}
    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {}
    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws { throw error }
    func writeContainer(
        bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity
    ) async throws {}
    func readContainer(
        bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity
    ) async throws -> Data { throw NativeDeviceBridgeError.containerFileNotFound(relativePath) }
}

private final class FakePairingNative: RemotePairingNativeOperations, @unchecked Sendable {
    private var failNextValidation: Bool
    private(set) var createCount = 0
    init(failNextValidation: Bool = false) { self.failNextValidation = failNextValidation }
    static func material() throws -> RemotePairingMaterial {
        let publicKey = Data(repeating: 5, count: 32); let privateKey = Data(repeating: 6, count: 32)
        let plist: [String: Any] = ["public_key": publicKey, "private_key": privateKey, "identifier": "pairing-id"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let fp = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return RemotePairingMaterial(pairingData: data, identifier: "pairing-id", publicKeyFingerprint: fp)
    }
    func create(on device: IOSSimDeviceIdentity, hostname: String) async throws -> RemotePairingMaterial { createCount += 1; return try Self.material() }
    func validate(_ record: RemotePairingRecord, on device: IOSSimDeviceIdentity, hostname: String) async throws {
        if failNextValidation {
            failNextValidation = false
            throw RemotePairingFailure.pairingRejected
        }
    }
}

private final class FakePairingDelivery: RemotePairingContainerDelivery, @unchecked Sendable {
    let native: FakePairingNative; let device: IOSSimDeviceIdentity; let team: String
    let wrongDevice: Bool; let corruptProof: Bool
    let failPromotionReceipt: Bool; let replayedRequestID: String?
    var lastEnvelope: RemotePairingEnvelope?
    var possessionResponse: RemotePairingPossessionResponse?
    var promotionWritten = false
    init(native: FakePairingNative, device: IOSSimDeviceIdentity, team: String,
         wrongDevice: Bool = false, corruptProof: Bool = false,
         failPromotionReceipt: Bool = false, replayedRequestID: String? = nil) {
        self.native = native; self.device = device; self.team = team
        self.wrongDevice = wrongDevice; self.corruptProof = corruptProof
        self.failPromotionReceipt = failPromotionReceipt; self.replayedRequestID = replayedRequestID
    }
    func writeEnvelope(_ envelope: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        promotionWritten = false
        lastEnvelope = try JSONDecoder().decode(RemotePairingEnvelope.self, from: envelope)
    }
    func readReceipt(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        guard let e = lastEnvelope else { throw RemotePairingFailure.receiptMissing }
        if promotionWritten && failPromotionReceipt { throw RemotePairingFailure.receiptMissing }
        let m = try FakePairingNative.material()
        let receipt = RemotePairingReceipt(deviceUDID: wrongDevice ? "OTHER-DEVICE-001" : self.device.udid,
            teamIdentifier: team, nonce: e.nonce, status: promotionWritten ? "operational" : "candidate-stored",
            identifier: m.identifier, publicKeyFingerprint: m.publicKeyFingerprint, timestamp: .now,
            requestID: replayedRequestID ?? e.requestID, pairingGeneration: e.pairingGeneration,
            releaseIdentity: e.releaseIdentity)
        return try JSONEncoder().encode(receipt)
    }
    func writePossessionChallenge(_ challenge: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        let challenge = try JSONDecoder().decode(RemotePairingPossessionChallenge.self, from: challenge)
        let material = try FakePairingNative.material()
        let record = RemotePairingRecord(
            metadata: .init(
                schemaVersion: 2, deviceUDID: self.device.udid, teamIdentifier: team,
                identifier: material.identifier, publicKeyFingerprint: material.publicKeyFingerprint,
                pairingGeneration: challenge.pairingGeneration, releaseIdentity: challenge.releaseIdentity
            ),
            pairingData: material.pairingData
        )
        possessionResponse = RemotePairingPossessionResponse(
            deviceUDID: challenge.deviceUDID,
            teamIdentifier: challenge.teamIdentifier,
            requestID: challenge.requestID,
            pairingGeneration: challenge.pairingGeneration,
            releaseIdentity: challenge.releaseIdentity,
            nonce: challenge.nonce,
            proof: corruptProof ? "invalid-proof" : RemotePairingCoordinator.possessionProof(record: record, challenge: challenge)
        )
    }
    func readPossessionResponse(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        guard let possessionResponse else { throw RemotePairingFailure.operationalProofFailed }
        return try JSONEncoder().encode(possessionResponse)
    }
    func writePromotionRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        _ = try JSONDecoder().decode(RemotePairingPromotionRequest.self, from: request)
        promotionWritten = true
    }
}
