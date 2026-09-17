import Foundation

public protocol NativeLockdownPairingServicing: Sendable {
    func pairLockdownOnce(
        on identity: IOSSimDeviceIdentity,
        hostName: String,
        timeout: Duration
    ) throws -> LockdownPairingReceipt
}

extension DynamicNativeDeviceTransport: NativeLockdownPairingServicing {}

public actor NativeLockdownPairingCoordinator {
    private let service: any NativeLockdownPairingServicing
    private let hostName: String

    public init(
        service: any NativeLockdownPairingServicing = DynamicNativeDeviceTransport(),
        hostName: String = "IOSSim"
    ) {
        self.service = service
        self.hostName = hostName
    }

    /// Performs at most one Lockdown Pair request. Pending and locked states
    /// are observations that the UI can safely retry after the user acts;
    /// this coordinator never manufactures or bypasses Apple consent.
    public func pairOnce(
        descriptor: NativeDeviceDescriptor,
        timeout: Duration = .seconds(20)
    ) throws -> LockdownPairingReceipt {
        let identity = descriptor.identity
        guard identity.usbmuxIdentifier != nil,
              identity.connection == descriptor.connection,
              descriptor.connection == .usb else {
            return receipt(state: .disconnected, identity: identity)
        }
        do {
            return try service.pairLockdownOnce(
                on: identity,
                hostName: hostName,
                timeout: timeout
            )
        } catch NativeDeviceBridgeError.trustPromptPending {
            return receipt(state: .waitingForUserTrust, identity: identity)
        } catch NativeDeviceBridgeError.deviceLocked {
            return receipt(state: .waitingForUnlock, identity: identity)
        } catch NativeDeviceBridgeError.trustDenied {
            return receipt(state: .denied, identity: identity)
        } catch NativeDeviceBridgeError.deviceDisconnected,
                NativeDeviceBridgeError.deviceNotFound {
            return receipt(state: .disconnected, identity: identity)
        } catch {
            throw error
        }
    }

    private func receipt(
        state: LockdownPairingState,
        identity: IOSSimDeviceIdentity
    ) -> LockdownPairingReceipt {
        LockdownPairingReceipt(
            state: state,
            identity: identity,
            pairRecordCreated: false,
            pairRecordPersisted: false,
            sessionValidated: false
        )
    }
}
