import Foundation

public enum DeviceSelectionReason: Equatable, Sendable {
    case noConnectedDevices
    case autoSelectedOnlyDevice
    case rememberedDeviceConnected
    case selectionRequired
    case rememberedDeviceDisconnected
}

public struct DeviceSelectionResult: Equatable, Sendable {
    public let selectedIdentifier: String?
    public let reason: DeviceSelectionReason
    public let selectionRequired: Bool
    public let disconnectedRememberedName: String?

    public init(
        selectedIdentifier: String?,
        reason: DeviceSelectionReason,
        selectionRequired: Bool = false,
        disconnectedRememberedName: String? = nil
    ) {
        self.selectedIdentifier = selectedIdentifier
        self.reason = reason
        self.selectionRequired = selectionRequired
        self.disconnectedRememberedName = disconnectedRememberedName
    }
}

public enum DeviceSelectionPolicy {
    public static func resolve(
        devices: [DetectedDevice],
        rememberedIdentifier: String?,
        rememberedName: String? = nil
    ) -> DeviceSelectionResult {
        guard !devices.isEmpty else {
            return DeviceSelectionResult(
                selectedIdentifier: nil,
                reason: rememberedIdentifier == nil ? .noConnectedDevices : .rememberedDeviceDisconnected,
                disconnectedRememberedName: rememberedName
            )
        }

        if let rememberedIdentifier, !rememberedIdentifier.isEmpty {
            let matches = devices.filter { $0.selectionIdentifier == rememberedIdentifier }
            if matches.count == 1 {
                return DeviceSelectionResult(
                    selectedIdentifier: matches[0].selectionIdentifier,
                    reason: .rememberedDeviceConnected
                )
            }
        }

        if devices.count == 1 {
            return DeviceSelectionResult(
                selectedIdentifier: devices[0].selectionIdentifier,
                reason: .autoSelectedOnlyDevice
            )
        }

        return DeviceSelectionResult(
            selectedIdentifier: nil,
            reason: rememberedIdentifier == nil ? .selectionRequired : .rememberedDeviceDisconnected,
            selectionRequired: true,
            disconnectedRememberedName: rememberedName
        )
    }
}
