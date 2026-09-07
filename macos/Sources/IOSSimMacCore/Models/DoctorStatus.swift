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

    public init(ready: Bool) {
        self.ready = ready
    }
}

public struct DeviceSummary: Codable, Equatable, Sendable {
    public let ready: Bool
    public let connected: Bool
    public let devices: [DetectedDevice]

    public init(ready: Bool, connected: Bool, devices: [DetectedDevice]) {
        self.ready = ready
        self.connected = connected
        self.devices = devices
    }
}

public struct DetectedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { selectionIdentifier }
    public let name: String
    public let identifier: String
    public let selectionIdentifier: String
    public let udidRedacted: String?
    public let osVersion: String?
    public let model: String?
    public let developerModeStatus: String?
    public let pairingState: String?
    public let tunnelState: String?
    public let isLocked: Bool?
    public let provisioningEligibilityStatus: ArtifactInstallEligibilityStatus?
    public let provisioningEligibilityDetail: String?
    public let installedProjectBundleIdentifiers: [String]?
    public let expectedProjectBundleCount: Int?

    private enum CodingKeys: String, CodingKey {
        case name
        case identifier
        case selectionIdentifier
        case udidRedacted
        case osVersion
        case model
        case developerModeStatus
        case pairingState
        case tunnelState
        case isLocked
        case provisioningEligibilityStatus
        case provisioningEligibilityDetail
        case installedProjectBundleIdentifiers
        case expectedProjectBundleCount
    }

    public init(
        name: String,
        identifier: String,
        selectionIdentifier: String? = nil,
        udidRedacted: String? = nil,
        osVersion: String? = nil,
        model: String? = nil,
        developerModeStatus: String? = nil,
        pairingState: String? = nil,
        tunnelState: String? = nil,
        isLocked: Bool? = nil,
        provisioningEligibilityStatus: ArtifactInstallEligibilityStatus? = nil,
        provisioningEligibilityDetail: String? = nil,
        installedProjectBundleIdentifiers: [String]? = nil,
        expectedProjectBundleCount: Int? = nil
    ) {
        self.name = name
        self.identifier = identifier
        self.selectionIdentifier = selectionIdentifier ?? identifier
        self.udidRedacted = udidRedacted
        self.osVersion = osVersion
        self.model = model
        self.developerModeStatus = developerModeStatus
        self.pairingState = pairingState
        self.tunnelState = tunnelState
        self.isLocked = isLocked
        self.provisioningEligibilityStatus = provisioningEligibilityStatus
        self.provisioningEligibilityDetail = provisioningEligibilityDetail
        self.installedProjectBundleIdentifiers = installedProjectBundleIdentifiers
        self.expectedProjectBundleCount = expectedProjectBundleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        identifier = try container.decode(String.self, forKey: .identifier)
        selectionIdentifier = try container.decodeIfPresent(String.self, forKey: .selectionIdentifier) ?? identifier
        udidRedacted = try container.decodeIfPresent(String.self, forKey: .udidRedacted)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        developerModeStatus = try container.decodeIfPresent(String.self, forKey: .developerModeStatus)
        pairingState = try container.decodeIfPresent(String.self, forKey: .pairingState)
        tunnelState = try container.decodeIfPresent(String.self, forKey: .tunnelState)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked)
        provisioningEligibilityStatus = try container.decodeIfPresent(ArtifactInstallEligibilityStatus.self, forKey: .provisioningEligibilityStatus)
        provisioningEligibilityDetail = try container.decodeIfPresent(String.self, forKey: .provisioningEligibilityDetail)
        installedProjectBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .installedProjectBundleIdentifiers)
        expectedProjectBundleCount = try container.decodeIfPresent(Int.self, forKey: .expectedProjectBundleCount)
    }

    public var allProjectAppsInstalled: Bool {
        guard let installedProjectBundleIdentifiers, let expectedProjectBundleCount else {
            return false
        }
        return expectedProjectBundleCount > 0 && installedProjectBundleIdentifiers.count >= expectedProjectBundleCount
    }

    public func withProvisioningState(
        status: ArtifactInstallEligibilityStatus,
        detail: String,
        installedProjectBundleIdentifiers: [String]?,
        expectedProjectBundleCount: Int?
    ) -> DetectedDevice {
        DetectedDevice(
            name: name,
            identifier: identifier,
            selectionIdentifier: selectionIdentifier,
            udidRedacted: udidRedacted,
            osVersion: osVersion,
            model: model,
            developerModeStatus: developerModeStatus,
            pairingState: pairingState,
            tunnelState: tunnelState,
            isLocked: isLocked,
            provisioningEligibilityStatus: status,
            provisioningEligibilityDetail: detail,
            installedProjectBundleIdentifiers: installedProjectBundleIdentifiers,
            expectedProjectBundleCount: expectedProjectBundleCount
        )
    }

    public func withLockState(_ isLocked: Bool) -> DetectedDevice {
        DetectedDevice(
            name: name,
            identifier: identifier,
            selectionIdentifier: selectionIdentifier,
            udidRedacted: udidRedacted,
            osVersion: osVersion,
            model: model,
            developerModeStatus: developerModeStatus,
            pairingState: pairingState,
            tunnelState: tunnelState,
            isLocked: isLocked,
            provisioningEligibilityStatus: provisioningEligibilityStatus,
            provisioningEligibilityDetail: provisioningEligibilityDetail,
            installedProjectBundleIdentifiers: installedProjectBundleIdentifiers,
            expectedProjectBundleCount: expectedProjectBundleCount
        )
    }
}

public enum RequiredActionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case connectUnlockDevice
    case trustComputer
    case enableDeveloperMode
    case enableLocalDevVPN
    case importRPPairing
    case signingRequired
    case installAppleTooling
    case reinstallIOSSim
    case verifyRuntime
    case other

    public var sortOrder: Int {
        switch self {
        case .connectUnlockDevice: return 10
        case .trustComputer: return 20
        case .enableDeveloperMode: return 30
        case .signingRequired: return 40
        case .enableLocalDevVPN: return 50
        case .importRPPairing: return 60
        case .verifyRuntime: return 70
        case .installAppleTooling: return 80
        case .reinstallIOSSim: return 90
        case .other: return 100
        }
    }

    public static func infer(from check: DoctorCheck) -> RequiredActionKind {
        let text = "\(check.component) \(check.name) \(check.action ?? "")".lowercased()
        if text.contains("connected iphone") || text.contains("connect and unlock") || text.contains("locked") {
            return .connectUnlockDevice
        }
        if text.contains("trust") || text.contains("paired") || text.contains("pairingstate") {
            return .trustComputer
        }
        if text.contains("developer mode") {
            return .enableDeveloperMode
        }
        if text.contains("localdevvpn") || text.contains("vpn") {
            return .enableLocalDevVPN
        }
        if text.contains("pairing material") || text.contains("rppairing") || text.contains("pairing import") || text.contains("device pairing") {
            return .importRPPairing
        }
        if text.contains("signing") || text.contains("provision") || text.contains("development team") {
            return .signingRequired
        }
        if text.contains("xcrun") || text.contains("devicectl") || text.contains("apple tooling") || text.contains("xcode") {
            return .installAppleTooling
        }
        if text.contains("bundled artifact") || text.contains("manifest") || text.contains("reinstall iossim") {
            return .reinstallIOSSim
        }
        if text.contains("runtime") || text.contains("verify") {
            return .verifyRuntime
        }
        return .other
    }
}

public struct RequiredAction: Equatable, Sendable, Identifiable {
    public var id: RequiredActionKind { kind }
    public let kind: RequiredActionKind
    public let check: DoctorCheck

    public init(kind: RequiredActionKind, check: DoctorCheck) {
        self.kind = kind
        self.check = check
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
        self.checks = checks
        let canonical = Self.requiredActionTexts(from: checks)
        self.actionsRequired = canonical.isEmpty ? actionsRequired : canonical
    }

    public static func decode(from data: Data) throws -> DoctorStatus {
        try JSONDecoder().decode(DoctorStatus.self, from: data)
    }

    public var macBlockingChecks: [DoctorCheck] {
        checks.filter { ($0.state == .fail || $0.state == .action) && ["mac", "build"].contains($0.requiredFor) }
    }

    public var deviceActionChecks: [DoctorCheck] {
        canonicalRequiredActions
            .map(\.check)
            .filter { $0.requiredFor == "device" && $0.component.caseInsensitiveCompare("Runtime") != .orderedSame }
    }

    public var runtimeActionChecks: [DoctorCheck] {
        canonicalRequiredActions
            .map(\.check)
            .filter { $0.component.caseInsensitiveCompare("Runtime") == .orderedSame }
    }

    public var canonicalRequiredActions: [RequiredAction] {
        Self.canonicalRequiredActions(from: checks)
    }

    public var provisioningReady: Bool {
        device.devices.contains {
            $0.pairingState == "paired" && $0.developerModeStatus == "enabled" && $0.isLocked != true
        }
    }

    public var setupCompleteForDashboard: Bool {
        mac.ready && device.connected && provisioningReady && runtimeActionChecks.isEmpty
    }

    public var primaryDevice: DetectedDevice? {
        device.devices.first
    }

    public static func canonicalRequiredActions(from checks: [DoctorCheck]) -> [RequiredAction] {
        var byKind: [RequiredActionKind: DoctorCheck] = [:]
        for check in checks where check.state == .action || check.state == .fail {
            let kind = RequiredActionKind.infer(from: check)
            if byKind[kind] == nil {
                byKind[kind] = check
            }
        }
        return byKind
            .map { RequiredAction(kind: $0.key, check: $0.value) }
            .sorted {
                if $0.kind.sortOrder == $1.kind.sortOrder {
                    return $0.check.id < $1.check.id
                }
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
    }

    public static func requiredActionTexts(from checks: [DoctorCheck]) -> [String] {
        canonicalRequiredActions(from: checks).map { action in
            StatusInterpreter.friendlyAction(for: action.check)
        }
    }
}

public enum DeviceReadiness: Equatable, Sendable {
    case noDevice
    case multipleDevices
    case unlockRequired
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
        if device.isLocked == true {
            return .unlockRequired
        }
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
        if check.component == "Xcode" || check.component == "Apple Tooling" {
            return "Install or select Apple's developer tools required for iPhone discovery and app installation."
        }
        if check.name.localizedCaseInsensitiveContains("Developer Mode") {
            return "On your iPhone, open Settings > Privacy & Security > Developer Mode, enable it, then return here."
        }
        if check.name.localizedCaseInsensitiveContains("connected iPhone") {
            return "Connect and unlock an iPhone to continue."
        }
        if check.name.localizedCaseInsensitiveContains("unlocked") {
            return "Unlock the selected iPhone, keep it awake, then return here."
        }
        if check.name.localizedCaseInsensitiveContains("LocalDevVPN") {
            return "Open LocalDevVPN on your iPhone and approve Apple's VPN configuration prompt."
        }
        if check.name.localizedCaseInsensitiveContains("PAIRING") {
            return "Keep your iPhone unlocked while IOSSim prepares the secure connection."
        }
        return check.action ?? "Complete this step, then check again."
    }
}
