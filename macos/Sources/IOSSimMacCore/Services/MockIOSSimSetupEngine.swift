import Foundation

public enum MockEngineScenario: String, CaseIterable, Sendable, Identifiable {
    case ready
    case noXcode
    case noDevice
    case lockedDevice
    case developerModeRequired
    case localDevVPNRequired
    case pairingRequired
    case installFailure
    case complete

    public var id: String { rawValue }
}

public actor MockIOSSimSetupEngine: IOSSimSetupEngine {
    public private(set) var scenario: MockEngineScenario

    public init(scenario: MockEngineScenario) {
        self.scenario = scenario
    }

    public func setScenario(_ scenario: MockEngineScenario) {
        self.scenario = scenario
    }

    public func doctor() async throws -> DoctorStatus {
        switch scenario {
        case .ready, .complete:
            return Self.status(macReady: true, device: Self.readyDevice(), runtimeActions: [])
        case .noXcode:
            return Self.status(
                macReady: false,
                device: Self.readyDevice(),
                extraChecks: [.init(state: .action, component: "Xcode", name: "Xcode version", detail: "missing", action: "Install Xcode from Apple.", requiredFor: "build")]
            )
        case .noDevice:
            return Self.status(macReady: true, device: nil)
        case .lockedDevice:
            return Self.status(macReady: true, device: Self.device(pairingState: "unpaired", developerMode: "enabled"))
        case .developerModeRequired:
            return Self.status(macReady: true, device: Self.device(pairingState: "paired", developerMode: "disabled"))
        case .localDevVPNRequired:
            return Self.status(macReady: true, device: Self.readyDevice(), runtimeActions: [.localDevVPN])
        case .pairingRequired:
            return Self.status(macReady: true, device: Self.readyDevice(), runtimeActions: [.pairing])
        case .installFailure:
            return Self.status(macReady: true, device: Self.readyDevice(), runtimeActions: [])
        }
    }

    public func setup() async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "setup ok", stderr: "")
    }

    public func build() async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "build ok", stderr: "")
    }

    public func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        if scenario == .installFailure {
            throw ProcessFailure(
                commandName: "device",
                result: ProcessResult(exitCode: 1, stdout: "", stderr: "The iPhone is locked.")
            )
        }
        return ProcessResult(exitCode: 0, stdout: "Installed artifacts: 3", stderr: "")
    }

    private enum RuntimeAction {
        case localDevVPN
        case pairing
    }

    private static func readyDevice() -> DetectedDevice {
        device(pairingState: "paired", developerMode: "enabled")
    }

    private static func device(pairingState: String, developerMode: String) -> DetectedDevice {
        DetectedDevice(
            name: "iPhone",
            identifier: "00008150-0000000000000000",
            udidRedacted: "ABC123...7890",
            osVersion: "26.0",
            developerModeStatus: developerMode,
            pairingState: pairingState,
            tunnelState: "connected"
        )
    }

    private static func status(
        macReady: Bool,
        device: DetectedDevice?,
        runtimeActions: [RuntimeAction] = [.localDevVPN, .pairing],
        extraChecks: [DoctorCheck] = []
    ) -> DoctorStatus {
        var checks: [DoctorCheck] = [
            .init(state: macReady ? .pass : .action, component: "Mac", name: "macOS supported", detail: "ready"),
            .init(state: .pass, component: "Xcode", name: "Xcode version", detail: "ready", requiredFor: "build"),
        ]
        checks.append(contentsOf: extraChecks)
        if let device {
            checks.append(.init(state: .pass, component: "Device", name: "iPhone detected", detail: "\(device.name) \(device.osVersion ?? "")", requiredFor: "device"))
            checks.append(.init(
                state: device.pairingState == "paired" ? .pass : .action,
                component: "Device",
                name: "device trusted",
                detail: device.pairingState ?? "unknown",
                action: device.pairingState == "paired" ? nil : "Unlock the iPhone and trust this Mac.",
                requiredFor: "device"
            ))
            checks.append(.init(
                state: device.developerModeStatus == "enabled" ? .pass : .action,
                component: "Device",
                name: "Developer Mode",
                detail: device.developerModeStatus ?? "unknown",
                action: device.developerModeStatus == "enabled" ? nil : "On iPhone: Settings > Privacy & Security > Developer Mode.",
                requiredFor: "device"
            ))
        } else {
            checks.append(.init(state: .action, component: "Device", name: "connected iPhone", detail: "not detected", action: "Connect and unlock an iPhone.", requiredFor: "device"))
        }
        for action in runtimeActions {
            switch action {
            case .localDevVPN:
                checks.append(.init(state: .action, component: "Runtime", name: "LocalDevVPN", detail: "external iPhone app required", action: "Install/launch LocalDevVPN on the iPhone.", requiredFor: "device"))
            case .pairing:
                checks.append(.init(state: .action, component: "Runtime", name: "PAIRING MATERIAL", detail: "configured state only", action: "Keep the iPhone unlocked while IOSSim prepares the secure connection.", requiredFor: "device"))
            }
        }
        let deviceSummary = DeviceSummary(ready: device != nil && runtimeActions.isEmpty, connected: device != nil, devices: device.map { [$0] } ?? [])
        return DoctorStatus(
            ready: macReady && deviceSummary.ready,
            mac: MacSummary(ready: macReady),
            device: deviceSummary,
            actionsRequired: checks.filter { $0.state == .action }.map { $0.action ?? $0.name },
            checks: checks
        )
    }
}
