import Foundation

public enum CheckState: String, Codable, Equatable, Sendable {
    case pass = "PASS"
    case warn = "WARN"
    case fail = "FAIL"
    case action = "ACTION"
    case skip = "SKIP"
}

public struct DoctorCheck: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(component)|\(name)|\(requiredFor)|\(state.rawValue)" }
    public let state: CheckState
    public let component: String
    public let name: String
    public let detail: String
    public let action: String?
    public let requiredFor: String

    public init(
        state: CheckState,
        component: String,
        name: String,
        detail: String = "",
        action: String? = nil,
        requiredFor: String = "mac"
    ) {
        self.state = state
        self.component = component
        self.name = name
        self.detail = detail
        self.action = action
        self.requiredFor = requiredFor
    }
}

public struct MacSummary: Codable, Equatable, Sendable {
    public let ready: Bool
}

public struct DeviceSummary: Codable, Equatable, Sendable {
    public let ready: Bool
    public let connected: Bool
    public let devices: [DetectedDevice]
}

public struct DetectedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { identifier }
    public let name: String
    public let identifier: String
    public let udidRedacted: String?
    public let osVersion: String?
    public let developerModeStatus: String?
    public let pairingState: String?
    public let tunnelState: String?

    public init(
        name: String,
        identifier: String,
        udidRedacted: String? = nil,
        osVersion: String? = nil,
        developerModeStatus: String? = nil,
        pairingState: String? = nil,
        tunnelState: String? = nil
    ) {
        self.name = name
        self.identifier = identifier
        self.udidRedacted = udidRedacted
        self.osVersion = osVersion
        self.developerModeStatus = developerModeStatus
        self.pairingState = pairingState
        self.tunnelState = tunnelState
    }
}

public struct DoctorStatus: Codable, Equatable, Sendable {
    public let ready: Bool
    public let mac: MacSummary
    public let device: DeviceSummary
    public let actionsRequired: [String]
    public let checks: [DoctorCheck]

    public init(
        ready: Bool,
        mac: MacSummary,
        device: DeviceSummary,
        actionsRequired: [String],
        checks: [DoctorCheck]
    ) {
        self.ready = ready
        self.mac = mac
        self.device = device
        self.actionsRequired = actionsRequired
        self.checks = checks
    }

    public static func decode(from data: Data) throws -> DoctorStatus {
        try JSONDecoder().decode(DoctorStatus.self, from: data)
    }

    public var macBlockingChecks: [DoctorCheck] {
        checks.filter { ($0.state == .fail || $0.state == .action) && ["mac", "build"].contains($0.requiredFor) }
    }

    public var deviceActionChecks: [DoctorCheck] {
        checks.filter { $0.requiredFor == "device" && ($0.state == .fail || $0.state == .action) }
    }

    public var runtimeActionChecks: [DoctorCheck] {
        checks.filter { $0.component.caseInsensitiveCompare("Runtime") == .orderedSame && $0.state == .action }
    }

    public var provisioningReady: Bool {
        device.devices.contains { $0.pairingState == "paired" && $0.developerModeStatus == "enabled" }
    }

    public var setupCompleteForDashboard: Bool {
        mac.ready && device.connected && provisioningReady && runtimeActionChecks.isEmpty
    }

    public var primaryDevice: DetectedDevice? {
        device.devices.first
    }
}

public enum DeviceReadiness: Equatable, Sendable {
    case noDevice
    case multipleDevices
    case trustRequired
    case developerModeRequired
    case readyForInstall
    case localDevVPNRequired
    case pairingRequired
    case complete
}

public enum StatusInterpreter {
    public static func deviceReadiness(from status: DoctorStatus) -> DeviceReadiness {
        if status.device.devices.isEmpty {
            return .noDevice
        }
        if status.device.devices.count > 1 {
            return .multipleDevices
        }
        let device = status.device.devices[0]
        if device.pairingState != "paired" {
            return .trustRequired
        }
        if device.developerModeStatus != "enabled" {
            return .developerModeRequired
        }
        if status.runtimeActionChecks.contains(where: { $0.name.localizedCaseInsensitiveContains("LocalDevVPN") }) {
            return .localDevVPNRequired
        }
        if status.runtimeActionChecks.contains(where: { $0.name.localizedCaseInsensitiveContains("PAIRING") }) {
            return .pairingRequired
        }
        return status.ready ? .complete : .readyForInstall
    }

    public static func friendlyAction(for check: DoctorCheck) -> String {
        if check.component == "Xcode" {
            return "Install Xcode from Apple, open it once, and complete any prompts."
        }
        if check.name.localizedCaseInsensitiveContains("Developer Mode") {
            return "On your iPhone, open Settings > Privacy & Security > Developer Mode, enable it, then return here."
        }
        if check.name.localizedCaseInsensitiveContains("connected iPhone") {
            return "Connect your iPhone with USB, unlock it, and trust this Mac."
        }
        if check.name.localizedCaseInsensitiveContains("LocalDevVPN") {
            return "Open LocalDevVPN on your iPhone and approve Apple's VPN configuration prompt."
        }
        if check.name.localizedCaseInsensitiveContains("PAIRING") {
            return "Open IOSSim on your iPhone and complete the device pairing step."
        }
        return check.action ?? "Complete this step, then check again."
    }
}
