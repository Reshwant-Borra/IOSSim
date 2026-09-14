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

    func testCoordinatorReusesValidRecordAndCompletesReceiptAndProof() async throws {
        let d = try device(); let store = InMemoryRemotePairingStore(); let native = FakePairingNative()
        let delivery = FakePairingDelivery(native: native, device: d, team: "TEAM123")
        let coordinator = RemotePairingCoordinator(store: store, native: native, delivery: delivery, proof: AcceptingProof())
        let session = RemotePairingBootstrapSession(importKey: Data(repeating: 1, count: 32))
        let first = try await coordinator.prepare(device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app", hostname: "IOSSim-Mac", bootstrap: session)
        let second = try await coordinator.prepare(device: d, teamIdentifier: "TEAM123", appBundleIdentifier: "com.iossim.app", hostname: "IOSSim-Mac", bootstrap: session)
        XCTAssertEqual(first, second)
        XCTAssertEqual(native.createCount, 1)
        XCTAssertEqual(delivery.lastEnvelope?.deviceUDID, d.udid)
    }

    func testCoordinatorRepairsOnlyWhenValidationFails() async throws {
        let d = try device(); let store = InMemoryRemotePairingStore(); let native = FakePairingNative(failValidation: true)
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
}

private struct AcceptingProof: RemotePairingOperationalProof {
    func verify(on device: IOSSimDeviceIdentity, pairing: RemotePairingRecord) async throws {}
}

private final class FakePairingNative: RemotePairingNativeOperations, @unchecked Sendable {
    let failValidation: Bool; private(set) var createCount = 0
    init(failValidation: Bool = false) { self.failValidation = failValidation }
    static func material() throws -> RemotePairingMaterial {
        let publicKey = Data(repeating: 5, count: 32); let privateKey = Data(repeating: 6, count: 32)
        let plist: [String: Any] = ["public_key": publicKey, "private_key": privateKey, "identifier": "pairing-id"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let fp = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        return RemotePairingMaterial(pairingData: data, identifier: "pairing-id", publicKeyFingerprint: fp)
    }
    func create(on device: IOSSimDeviceIdentity, hostname: String) async throws -> RemotePairingMaterial { createCount += 1; return try Self.material() }
    func validate(_ record: RemotePairingRecord, on device: IOSSimDeviceIdentity, hostname: String) async throws {
        if failValidation { throw RemotePairingFailure.operationalProofFailed }
    }
}

private final class FakePairingDelivery: RemotePairingContainerDelivery, @unchecked Sendable {
    let native: FakePairingNative; let device: IOSSimDeviceIdentity; let team: String; let wrongDevice: Bool
    var lastEnvelope: RemotePairingEnvelope?
    init(native: FakePairingNative, device: IOSSimDeviceIdentity, team: String, wrongDevice: Bool = false) { self.native = native; self.device = device; self.team = team; self.wrongDevice = wrongDevice }
    func writeEnvelope(_ envelope: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws { lastEnvelope = try JSONDecoder().decode(RemotePairingEnvelope.self, from: envelope) }
    func readReceipt(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        guard let e = lastEnvelope else { throw RemotePairingFailure.receiptMissing }
        let m = try FakePairingNative.material()
        let receipt = RemotePairingReceipt(schemaVersion: 1, deviceUDID: wrongDevice ? "OTHER-DEVICE-001" : self.device.udid,
            teamIdentifier: team, nonce: e.nonce, status: "stored", identifier: m.identifier,
            publicKeyFingerprint: m.publicKeyFingerprint, timestamp: .now)
        return try JSONEncoder().encode(receipt)
    }
}
