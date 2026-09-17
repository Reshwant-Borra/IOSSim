import XCTest
@testable import IOSSimMacCore

final class NativeLockdownPairingTests: XCTestCase {
    func testValidatedReceiptPassesThroughWithoutPairingMaterial() async throws {
        let selected = try descriptor()
        let expected = LockdownPairingReceipt(
            state: .lockdownSessionValidated,
            identity: selected.identity,
            pairRecordCreated: true,
            pairRecordPersisted: true,
            sessionValidated: true
        )
        let service = FakeLockdownPairingService(outcome: .success(expected))
        let receipt = try await NativeLockdownPairingCoordinator(service: service).pairOnce(
            descriptor: selected
        )

        XCTAssertEqual(receipt, expected)
        XCTAssertEqual(service.invocationCount, 1)
        let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self).lowercased()
        XCTAssertFalse(encoded.contains("privatekey"))
        XCTAssertFalse(encoded.contains("pairrecorddata"))
        XCTAssertFalse(encoded.contains("escrowbag"))
    }

    func testPendingLockedDeniedAndDisconnectedAreTypedResumeStates() async throws {
        let selected = try descriptor()
        let cases: [(NativeDeviceBridgeError, LockdownPairingState)] = [
            (.trustPromptPending, .waitingForUserTrust),
            (.deviceLocked, .waitingForUnlock),
            (.trustDenied, .denied),
            (.deviceDisconnected, .disconnected),
        ]
        for (error, state) in cases {
            let service = FakeLockdownPairingService(outcome: .failure(error))
            let receipt = try await NativeLockdownPairingCoordinator(service: service).pairOnce(
                descriptor: selected
            )
            XCTAssertEqual(receipt.state, state)
            XCTAssertFalse(receipt.pairRecordCreated)
            XCTAssertFalse(receipt.pairRecordPersisted)
            XCTAssertFalse(receipt.sessionValidated)
        }
    }

    func testWirelessOrConnectionMismatchedDescriptorNeverInvokesPairing() async throws {
        let service = FakeLockdownPairingService(outcome: .failure(.internalFailure("must not run")))
        let wireless = try descriptor(connection: .wireless, mux: 8)
        let receipt = try await NativeLockdownPairingCoordinator(service: service).pairOnce(
            descriptor: wireless
        )
        XCTAssertEqual(receipt.state, .disconnected)
        XCTAssertEqual(service.invocationCount, 0)
    }

    func testUnexpectedProtocolFailureIsNotMisreportedAsUserAction() async throws {
        let service = FakeLockdownPairingService(outcome: .failure(.protocolFailure("fixture")))
        do {
            _ = try await NativeLockdownPairingCoordinator(service: service).pairOnce(
                descriptor: try descriptor()
            )
            XCTFail("Expected protocol failure")
        } catch let error as NativeDeviceBridgeError {
            XCTAssertEqual(error, .protocolFailure("fixture"))
        }
    }

    private func descriptor(
        connection: DeviceConnectionKind = .usb,
        mux: UInt32 = 7
    ) throws -> NativeDeviceDescriptor {
        NativeDeviceDescriptor(
            identity: try IOSSimDeviceIdentity(
                udid: "PHONE-0001",
                usbmuxIdentifier: mux,
                connection: connection,
                connectionGeneration: 3
            ),
            connection: connection
        )
    }
}

private final class FakeLockdownPairingService: NativeLockdownPairingServicing, @unchecked Sendable {
    let outcome: Result<LockdownPairingReceipt, NativeDeviceBridgeError>
    private(set) var invocationCount = 0

    init(outcome: Result<LockdownPairingReceipt, NativeDeviceBridgeError>) {
        self.outcome = outcome
    }

    func pairLockdownOnce(
        on identity: IOSSimDeviceIdentity,
        hostName: String,
        timeout: Duration
    ) throws -> LockdownPairingReceipt {
        invocationCount += 1
        return try outcome.get()
    }
}
