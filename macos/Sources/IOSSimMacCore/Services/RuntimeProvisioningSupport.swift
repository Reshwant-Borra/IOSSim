import Foundation

public struct RuntimeProvisioningContext: Sendable {
    public let resourcesURL: URL
    public let runner: ProcessRunner

    public init(resourcesURL: URL, runner: ProcessRunner = ProcessRunner()) {
        self.resourcesURL = resourcesURL
        self.runner = runner
    }

    public var deviceArtifactsURL: URL {
        resourcesURL.appendingPathComponent("DeviceArtifacts", isDirectory: true)
    }

    public func loadManifest() throws -> ArtifactManifest {
        try ArtifactManifestLoader.load(resourcesURL: resourcesURL)
    }

    public func verifyArtifacts() throws -> [ArtifactVerificationResult] {
        let manifest = try loadManifest()
        let results = ArtifactManifestLoader.verify(resourcesURL: resourcesURL, manifest: manifest)
        try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: resourcesURL, manifest: manifest)
        return results
    }
}

public enum RuntimeProvisioning {
    public static let helperSchemaVersion = 2
    public static let minimumMacOS = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)

    public static func deterministicEnvironment() -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C"
        ]
        if !NSHomeDirectory().isEmpty {
            env["HOME"] = NSHomeDirectory()
        }
        return env
    }

    public static func consumerBackendSelection(
        resourcesURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ConsumerProvisioningBackendSelection {
        ConsumerProvisioningBackendSelector.select(
            preference: ConsumerProvisioningBackendPreference.selected(environment: environment),
            capabilities: ZeroXcodeCapabilityPolicy.currentCapabilities(
                resourcesURL: resourcesURL,
                fileManager: fileManager
            )
        )
    }

    public static func xcrunURL() -> URL? {
        let url = URL(fileURLWithPath: "/usr/bin/xcrun")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public static func devicectlForbidden() -> Bool {
        devicectlForbidden(environment: ProcessInfo.processInfo.environment)
    }

    public static func devicectlForbidden(environment env: [String: String]) -> Bool {
        return ["IOSSIM_FORBID_DEVICETCTL", "IOSSIM_NO_DEVICETCTL"].contains { key in
            ["1", "true", "TRUE", "yes", "YES"].contains(env[key] ?? "")
        }
    }

    public static func shortIdentifier(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        if value.count <= 10 { return value }
        let prefix = value.prefix(6)
        let suffix = value.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

public enum ProvisioningBackendKind: String, Sendable {
    case devicectl
    case idevice

    public static func selected(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProvisioningBackendKind {
        #if IOSSIM_BUNDLED_ENGINE
        // Packaged apps cannot opt into devicectl through environment state.
        // The legacy backend remains compiled only for explicit developer
        // comparisons until physical rollback parity has been qualified.
        return .idevice
        #else
        let raw = environment["IOSSIM_DEVICE_BACKEND"]?.lowercased()
        if raw == "idevice" {
            return .idevice
        }
        if raw == "devicectl" {
            return .devicectl
        }
        // The shipping consumer path is always the bundled native bridge.
        // devicectl is an explicit development-comparison backend only.
        return .idevice
        #endif
    }
}

public enum DeviceDiscoveryDiagnosticCode: String, Codable, Equatable, Sendable {
    case bridgeUnavailable = "BRIDGE_UNAVAILABLE"
    case bridgeInitializationFailed = "BRIDGE_INITIALIZATION_FAILED"
    case usbmuxUnavailable = "USBMUX_UNAVAILABLE"
    case enumerationFailed = "ENUMERATION_FAILED"
    case zeroDevicesReturned = "ZERO_DEVICES_RETURNED"
    case deviceDiscovered = "DEVICE_DISCOVERED"
    case deviceDiscoveredButFiltered = "DEVICE_DISCOVERED_BUT_FILTERED"
    case lockdownFailed = "LOCKDOWN_FAILED"
    case trustRequired = "TRUST_REQUIRED"
    case deviceLocked = "DEVICE_LOCKED"
    case developerModeUnavailable = "DEVELOPER_MODE_UNAVAILABLE"
    case unsupportedIOSVersion = "UNSUPPORTED_IOS_VERSION"
    case helperLibraryMissing = "HELPER_LIBRARY_MISSING"
    case ffiDecodingFailure = "FFI_DECODING_FAILURE"
}

public struct DeviceDiscoveryDiagnostic: Codable, Equatable, Sendable {
    public let code: DeviceDiscoveryDiagnosticCode
    public let detail: String

    public init(code: DeviceDiscoveryDiagnosticCode, detail: String) {
        self.code = code
        self.detail = Redactor.redact(detail)
    }
}

public struct DeviceDiscoverySnapshot: Codable, Equatable, Sendable {
    public let devices: [DetectedDevice]
    public let rawDeviceCount: Int
    public let diagnostics: [DeviceDiscoveryDiagnostic]

    public init(
        devices: [DetectedDevice],
        rawDeviceCount: Int,
        diagnostics: [DeviceDiscoveryDiagnostic]
    ) {
        self.devices = devices
        self.rawDeviceCount = rawDeviceCount
        self.diagnostics = diagnostics
    }

    public var primaryDiagnostic: DeviceDiscoveryDiagnostic? {
        diagnostics.first { $0.code != .deviceDiscovered }
    }
}

public protocol DeviceProvisioningBackend: Sendable {
    func discoverDevices(context: RuntimeProvisioningContext) async -> [DetectedDevice]
    func rawDeviceIdentifier(matching selector: String?, context: RuntimeProvisioningContext) async -> String?
    func signingDeviceIdentifier(matching selector: String, context: RuntimeProvisioningContext) async -> String?
    func nativeDeviceIdentity(matching rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> IOSSimDeviceIdentity?
    func isAppInstalled(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Bool?
    func installedAppCount(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Int?
    func install(component: DeviceArtifactComponent, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult
    func uninstall(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult
    func uninstall(
        bundleIdentifier: String,
        expectedTeamIdentifier: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> ProcessResult
    func launch(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult
    func readContainerFile(
        bundleIdentifier: String,
        relativePath: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> Data
}

public extension DeviceProvisioningBackend {
    func nativeDeviceIdentity(
        matching rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async -> IOSSimDeviceIdentity? {
        try? IOSSimDeviceIdentity(udid: rawDeviceIdentifier)
    }

    func installedAppCount(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Int? {
        guard let installed = await isAppInstalled(
            bundleIdentifier: bundleIdentifier,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        ) else { return nil }
        return installed ? 1 : 0
    }

    func uninstall(
        bundleIdentifier: String,
        expectedTeamIdentifier: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> ProcessResult {
        try await uninstall(
            bundleIdentifier: bundleIdentifier,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        )
    }
}

public enum DeviceProvisioningBackendError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDeviceIdentity
    case operationFailed(String)

    public var description: String {
        switch self {
        case .invalidDeviceIdentity:
            return "NATIVE_DEVICE_IDENTITY_INVALID"
        case .operationFailed(let detail):
            return detail
        }
    }
}

public enum DeviceProvisioningBackendFactory {
    public static func makeSelectedBackend() -> any DeviceProvisioningBackend {
        switch ProvisioningBackendKind.selected() {
        case .devicectl:
            return DevicectlProvisioningBackend()
        case .idevice:
            return IdeviceProvisioningBackend()
        }
    }
}

private actor NativeDeviceSelectionBindings {
    private var identitiesByUDID: [String: IOSSimDeviceIdentity] = [:]

    func bind(_ identity: IOSSimDeviceIdentity) {
        identitiesByUDID[identity.udid] = identity
    }

    func identity(forUDID udid: String) -> IOSSimDeviceIdentity? {
        identitiesByUDID[udid]
    }
}

public struct IdeviceProvisioningBackend: DeviceProvisioningBackend {
    private let bridge: IOSSimDeviceBridge
    private let applicationService: any NativeApplicationServicing
    private let bindings: NativeDeviceSelectionBindings

    public init(
        bridge: IOSSimDeviceBridge = IOSSimDeviceBridge(),
        applicationService: any NativeApplicationServicing = NativeApplicationService()
    ) {
        self.bridge = bridge
        self.applicationService = applicationService
        bindings = NativeDeviceSelectionBindings()
    }

    public func discoverDevices(context: RuntimeProvisioningContext) async -> [DetectedDevice] {
        await discoverDeviceSnapshot(context: context).devices
    }

    public func discoverDeviceSnapshot(context: RuntimeProvisioningContext) async -> DeviceDiscoverySnapshot {
        let descriptors: [NativeDeviceDescriptor]
        do {
            descriptors = try await bridge.listDevices()
        } catch {
            return DeviceDiscoverySnapshot(
                devices: [],
                rawDeviceCount: 0,
                diagnostics: [Self.diagnostic(for: error, operation: .enumeration)]
            )
        }
        guard !descriptors.isEmpty else {
            return DeviceDiscoverySnapshot(
                devices: [],
                rawDeviceCount: 0,
                diagnostics: [.init(code: .zeroDevicesReturned, detail: "usbmux returned no connected devices")]
            )
        }
        var values: [DetectedDevice] = []
        var diagnostics: [DeviceDiscoveryDiagnostic] = []
        for descriptor in descriptors {
            let inspection: NativeDeviceInspection?
            do {
                inspection = try await bridge.inspect(descriptor.identity)
            } catch {
                inspection = nil
                diagnostics.append(Self.diagnostic(for: error, operation: .inspection))
            }
            let identity = inspection?.identity ?? descriptor.identity
            await bindings.bind(identity)
            values.append(DetectedDevice(
                name: inspection?.name ?? "iPhone",
                identifier: RuntimeProvisioning.shortIdentifier(identity.udid),
                selectionIdentifier: identity.udid,
                udidRedacted: RuntimeProvisioning.shortIdentifier(identity.udid),
                osVersion: inspection?.osVersion,
                model: inspection?.model,
                developerModeStatus: inspection?.developerMode.rawValue ?? DeveloperModeReadiness.unknown.rawValue,
                pairingState: inspection?.trust == .trusted ? "paired" : inspection?.trust.rawValue ?? "unknown",
                tunnelState: "not-checked",
                isLocked: inspection?.lockState == .locked,
                provisioningEligibilityStatus: .requiresResigning,
                provisioningEligibilityDetail: "Bound to the selected phone through the bundled native device bridge."
            ))
            if inspection?.trust == .missing {
                diagnostics.append(.init(code: .trustRequired, detail: "Lockdown pairing record is unavailable"))
            }
            if inspection?.lockState == .locked {
                diagnostics.append(.init(code: .deviceLocked, detail: "Lockdown reports the connected device is locked"))
            }
            if let mode = inspection?.developerMode, [.unknown, .serviceUnavailable].contains(mode) {
                diagnostics.append(.init(code: .developerModeUnavailable, detail: "Developer Mode status could not be read"))
            }
        }
        if values.count < descriptors.count {
            diagnostics.append(.init(
                code: .deviceDiscoveredButFiltered,
                detail: "(descriptors.count - values.count) enumerated device(s) were not returned"
            ))
        }
        diagnostics.insert(.init(
            code: .deviceDiscovered,
            detail: "usbmux returned (descriptors.count) device(s); IOSSim returned (values.count) device(s)"
        ), at: 0)
        return DeviceDiscoverySnapshot(
            devices: values,
            rawDeviceCount: descriptors.count,
            diagnostics: diagnostics
        )
    }

    private enum DiscoveryOperation { case enumeration, inspection }

    private static func diagnostic(for error: Error, operation: DiscoveryOperation) -> DeviceDiscoveryDiagnostic {
        guard let bridgeError = error as? NativeDeviceBridgeError else {
            return .init(
                code: operation == .enumeration ? .enumerationFailed : .lockdownFailed,
                detail: String(describing: error)
            )
        }
        switch bridgeError {
        case .libraryUnavailable:
            return .init(code: .helperLibraryMissing, detail: "No bundled native device bridge library was found")
        case .libraryLoadFailure(let detail):
            return .init(code: .bridgeUnavailable, detail: detail)
        case .incompatibleABI:
            return .init(code: .bridgeInitializationFailed, detail: "Bundled native device bridge ABI is incompatible")
        case .decodingFailure(let detail):
            return .init(code: .ffiDecodingFailure, detail: detail)
        case .deviceLocked:
            return .init(code: .deviceLocked, detail: "The connected device is locked")
        case .trustRequired:
            return .init(code: .trustRequired, detail: "Lockdown trust is required")
        case .protocolFailure(let detail):
            let lowered = detail.lowercased()
            if operation == .enumeration,
               lowered.contains("usbmux") || lowered.contains("connection refused") || lowered.contains("no such file") {
                return .init(code: .usbmuxUnavailable, detail: detail)
            }
            return .init(code: operation == .enumeration ? .enumerationFailed : .lockdownFailed, detail: detail)
        default:
            return .init(
                code: operation == .enumeration ? .enumerationFailed : .lockdownFailed,
                detail: String(describing: bridgeError)
            )
        }
    }

    public func rawDeviceIdentifier(matching selector: String?, context: RuntimeProvisioningContext) async -> String? {
        guard let selector else { return nil }
        let matches = await discoverDevices(context: context).filter { $0.selectionIdentifier == selector }
        return matches.count == 1 ? selector : nil
    }

    public func signingDeviceIdentifier(matching selector: String, context: RuntimeProvisioningContext) async -> String? {
        await rawDeviceIdentifier(matching: selector, context: context)
    }

    public func nativeDeviceIdentity(
        matching rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async -> IOSSimDeviceIdentity? {
        await resolvedIdentity(forUDID: rawDeviceIdentifier)
    }

    public func isAppInstalled(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Bool? {
        guard let identity = await resolvedIdentity(forUDID: rawDeviceIdentifier),
              let inventory = try? await applicationService.inventory(on: identity) else { return nil }
        return inventory.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    public func install(component: DeviceArtifactComponent, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult {
        guard let identity = await resolvedIdentity(forUDID: rawDeviceIdentifier) else {
            return ProcessResult(exitCode: 64, stdout: "", stderr: "NATIVE_DEVICE_IDENTITY_INVALID")
        }
        guard let expectedTeamIdentifier = component.expectedTeamIdentifier, !expectedTeamIdentifier.isEmpty else {
            return ProcessResult(exitCode: 64, stdout: "", stderr: "NATIVE_OWNERSHIP_CONTEXT_REQUIRED")
        }
        let appURL = context.resourcesURL.appendingPathComponent(component.relativePath)
        do {
            let receipt = try await NativeApplicationManager(service: applicationService).installOrUpgradeReceipt(
                appURL: appURL,
                expectedBundleIdentifier: component.bundleIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier,
                on: identity
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let output = String(data: try encoder.encode(receipt), encoding: .utf8) ?? "native install verified"
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        } catch {
            let code = (error as? NativeApplicationManagementError) == .ownershipConflict
                ? "NATIVE_OWNERSHIP_CONFLICT" : "NATIVE_INSTALL_FAILED"
            return ProcessResult(exitCode: 70, stdout: "", stderr: "\(code): \(Redactor.redact(String(describing: error)))")
        }
    }

    public func uninstall(
        bundleIdentifier: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> ProcessResult {
        ProcessResult(exitCode: 64, stdout: "", stderr: "NATIVE_OWNERSHIP_CONTEXT_REQUIRED")
    }

    public func uninstall(
        bundleIdentifier: String,
        expectedTeamIdentifier: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> ProcessResult {
        guard let identity = await resolvedIdentity(forUDID: rawDeviceIdentifier),
              !expectedTeamIdentifier.isEmpty else {
            return ProcessResult(exitCode: 64, stdout: "", stderr: "NATIVE_DEVICE_IDENTITY_INVALID")
        }
        do {
            let inventory = try await applicationService.inventory(on: identity)
            guard let installed = inventory.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                return ProcessResult(exitCode: 0, stdout: "native app already absent", stderr: "")
            }
            guard installed.teamIdentifier == expectedTeamIdentifier else {
                return ProcessResult(exitCode: 77, stdout: "", stderr: "NATIVE_OWNERSHIP_CONFLICT")
            }
            try await applicationService.uninstall(bundleIdentifier: bundleIdentifier, on: identity)
            let after = try await applicationService.inventory(on: identity)
            guard !after.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                return ProcessResult(exitCode: 70, stdout: "", stderr: "NATIVE_UNINSTALL_INVENTORY_MISMATCH")
            }
            return ProcessResult(exitCode: 0, stdout: "native uninstall verified", stderr: "")
        } catch {
            return ProcessResult(
                exitCode: 70,
                stdout: "",
                stderr: "NATIVE_UNINSTALL_FAILED: \(Redactor.redact(String(describing: error)))"
            )
        }
    }

    public func launch(
        bundleIdentifier: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> ProcessResult {
        guard let identity = await resolvedIdentity(forUDID: rawDeviceIdentifier) else {
            return ProcessResult(exitCode: 64, stdout: "", stderr: "NATIVE_DEVICE_IDENTITY_INVALID")
        }
        do {
            try await applicationService.launch(bundleIdentifier: bundleIdentifier, on: identity)
            return ProcessResult(exitCode: 0, stdout: "native launch completed", stderr: "")
        } catch {
            let failure = Self.nativeLaunchFailure(error)
            return ProcessResult(
                exitCode: 69,
                stdout: "",
                stderr: "\(failure.code): \(failure.detail)"
            )
        }
    }

    public func readContainerFile(
        bundleIdentifier: String,
        relativePath: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> Data {
        guard let identity = await resolvedIdentity(forUDID: rawDeviceIdentifier) else {
            throw DeviceProvisioningBackendError.invalidDeviceIdentity
        }
        do {
            return try await applicationService.readContainer(
                bundleIdentifier: bundleIdentifier,
                relativePath: relativePath,
                on: identity
            )
        } catch {
            throw DeviceProvisioningBackendError.operationFailed(
                "NATIVE_CONTAINER_READ_FAILED: \(Redactor.redact(String(describing: error)))"
            )
        }
    }

    private static func nativeLaunchFailure(_ error: Error) -> (code: String, detail: String) {
        let detail = Redactor.redact(String(describing: error))
        guard let error = error as? NativeDeviceBridgeError else {
            return ("PROTOCOL_ERROR", detail)
        }
        switch error {
        case .deviceNotFound, .deviceResolutionFailed:
            return ("DEVICE_RESOLUTION_FAILED", detail)
        case .deviceDisconnected:
            return ("DEVICE_DISCONNECTED", detail)
        case .deviceLocked:
            return ("DEVICE_LOCKED", detail)
        case .trustRequired, .trustPromptPending:
            return ("COMPUTER_TRUST_REQUIRED", detail)
        case .trustDenied:
            return ("COMPUTER_TRUST_DENIED", detail)
        case .developerModeRequired:
            return ("DEVELOPER_MODE_REQUIRED", detail)
        case .coreDeviceProxyFailed:
            return ("COREDEVICE_PROXY_FAILED", detail)
        case .softwareTunnelFailed:
            return ("SOFTWARE_TUNNEL_FAILED", detail)
        case .rsdUnavailable:
            return ("RSD_UNAVAILABLE", detail)
        case .remoteXPCFailed:
            return ("REMOTEXPC_FAILED", detail)
        case .appServiceUnavailable:
            return ("APPSERVICE_UNAVAILABLE", detail)
        case .featureUnavailable:
            return ("FEATURE_UNAVAILABLE", detail)
        case .applicationNotFound:
            return ("APPLICATION_NOT_FOUND", detail)
        case .ddiRequired:
            return ("DDI_REQUIRED", detail)
        case .developerServicesNotReady:
            return ("DEVELOPER_SERVICES_NOT_READY", detail)
        case .launchRejected:
            return ("LAUNCH_REJECTED", detail)
        case .libraryUnavailable, .libraryLoadFailure, .incompatibleABI:
            return ("APPSERVICE_UNAVAILABLE", detail)
        case .cancelled:
            return ("LAUNCH_CANCELLED", detail)
        case .timedOut:
            return ("RSD_UNAVAILABLE", detail)
        case .invalidIdentity, .decodingFailure, .protocolFailure, .internalFailure,
             .containerUnavailable, .pairingRejected:
            return ("PROTOCOL_ERROR", detail)
        }
    }

    static func nativeLaunchFailureDescription(_ error: Error) -> String {
        let failure = nativeLaunchFailure(error)
        return "\(failure.code): \(failure.detail)"
    }

    private func resolvedIdentity(forUDID udid: String) async -> IOSSimDeviceIdentity? {
        if let bound = await bindings.identity(forUDID: udid) { return bound }
        guard let descriptors = try? await bridge.listDevices(),
              let descriptor = descriptors.first(where: { $0.identity.udid == udid }) else { return nil }
        await bindings.bind(descriptor.identity)
        return descriptor.identity
    }

}

public enum AppleDeviceTool {
    public static func discoverDevices(context: RuntimeProvisioningContext) async -> [DetectedDevice] {
        await discoverDeviceSnapshot(context: context).devices
    }

    public static func discoverDeviceSnapshot(context: RuntimeProvisioningContext) async -> DeviceDiscoverySnapshot {
        switch ProvisioningBackendKind.selected() {
        case .idevice:
            return await IdeviceProvisioningBackend().discoverDeviceSnapshot(context: context)
        case .devicectl:
            let devices = await DevicectlProvisioningBackend().discoverDevices(context: context)
            return DeviceDiscoverySnapshot(
                devices: devices,
                rawDeviceCount: devices.count,
                diagnostics: [.init(
                    code: devices.isEmpty ? .zeroDevicesReturned : .deviceDiscovered,
                    detail: devices.isEmpty ? "device backend returned no connected devices" : "device backend returned \(devices.count) device(s)"
                )]
            )
        }
    }

    public static func rawDeviceIdentifier(matching selector: String?, context: RuntimeProvisioningContext) async -> String? {
        await DeviceProvisioningBackendFactory.makeSelectedBackend().rawDeviceIdentifier(matching: selector, context: context)
    }

    public static func isAppInstalled(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Bool? {
        await DeviceProvisioningBackendFactory.makeSelectedBackend().isAppInstalled(
            bundleIdentifier: bundleIdentifier,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        )
    }

    public static func signingDeviceIdentifier(matching selector: String, context: RuntimeProvisioningContext) async -> String? {
        await DeviceProvisioningBackendFactory.makeSelectedBackend().signingDeviceIdentifier(
            matching: selector,
            context: context
        )
    }

    public static func installedAppCount(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Int? {
        await DeviceProvisioningBackendFactory.makeSelectedBackend().installedAppCount(
            bundleIdentifier: bundleIdentifier,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        )
    }

    public static func install(component: DeviceArtifactComponent, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult {
        try await DeviceProvisioningBackendFactory.makeSelectedBackend().install(
            component: component,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        )
    }
}

public struct DevicectlProvisioningBackend: DeviceProvisioningBackend {
    public init() {}

    public func discoverDevices(context: RuntimeProvisioningContext) async -> [DetectedDevice] {
        guard !RuntimeProvisioning.devicectlForbidden() else {
            return []
        }
        guard let xcrun = RuntimeProvisioning.xcrunURL() else {
            return []
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-devices-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            return []
        }
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let jsonURL = temporaryDirectory.appendingPathComponent("devices.json")
        let result = try? await context.runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl",
                "list",
                "devices",
                "--timeout",
                "8",
                "--json-output",
                jsonURL.path,
                "--quiet"
            ],
            workingDirectory: temporaryDirectory,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result?.exitCode == 0,
              let data = try? Data(contentsOf: jsonURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObject = raw["result"] as? [String: Any],
              let deviceItems = resultObject["devices"] as? [[String: Any]] else {
            return []
        }
        var candidates: [(device: DetectedDevice, rawIdentifier: String)] = []
        for item in deviceItems {
            let properties = item["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = item["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = item["connectionProperties"] as? [String: Any] ?? [:]
            let deviceType = hardware["deviceType"] as? String
            let platform = hardware["platform"] as? String
            guard deviceType == "iPhone" || platform == "iOS" else {
                continue
            }
            let rawIdentifier = (item["identifier"] as? String) ?? (hardware["udid"] as? String)
            guard let rawIdentifier else { continue }
            candidates.append((DetectedDevice(
                name: (properties["name"] as? String) ?? (hardware["marketingName"] as? String) ?? "iPhone",
                identifier: RuntimeProvisioning.shortIdentifier(rawIdentifier),
                selectionIdentifier: rawIdentifier,
                udidRedacted: RuntimeProvisioning.shortIdentifier(hardware["udid"] as? String),
                osVersion: properties["osVersionNumber"] as? String,
                model: hardware["marketingName"] as? String,
                developerModeStatus: properties["developerModeStatus"] as? String,
                pairingState: connection["pairingState"] as? String,
                tunnelState: connection["tunnelState"] as? String
            ), rawIdentifier))
        }
        var liveDevices: [DetectedDevice] = []
        for candidate in candidates {
            if let locked = await deviceLockState(rawDeviceIdentifier: candidate.rawIdentifier, context: context) {
                liveDevices.append(candidate.device.withLockState(locked))
            }
        }
        return liveDevices
    }

    public func rawDeviceIdentifier(matching selector: String?, context: RuntimeProvisioningContext) async -> String? {
        guard !RuntimeProvisioning.devicectlForbidden() else {
            return nil
        }
        guard let xcrun = RuntimeProvisioning.xcrunURL() else {
            return nil
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-device-select-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let jsonURL = temporaryDirectory.appendingPathComponent("devices.json")
        let result = try? await context.runner.run(
            executableURL: xcrun,
            arguments: ["devicectl", "list", "devices", "--timeout", "8", "--json-output", jsonURL.path, "--quiet"],
            workingDirectory: temporaryDirectory,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result?.exitCode == 0,
              let data = try? Data(contentsOf: jsonURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObject = raw["result"] as? [String: Any],
              let deviceItems = resultObject["devices"] as? [[String: Any]] else {
            return nil
        }
        let ready = deviceItems.compactMap { item -> (raw: String, redacted: String, name: String, ready: Bool)? in
            let properties = item["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = item["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = item["connectionProperties"] as? [String: Any] ?? [:]
            let deviceType = hardware["deviceType"] as? String
            let platform = hardware["platform"] as? String
            guard deviceType == "iPhone" || platform == "iOS",
                  let rawIdentifier = (item["identifier"] as? String) ?? (hardware["udid"] as? String) else {
                return nil
            }
            return (
                rawIdentifier,
                RuntimeProvisioning.shortIdentifier(rawIdentifier),
                (properties["name"] as? String) ?? (hardware["marketingName"] as? String) ?? "iPhone",
                connection["pairingState"] as? String == "paired" && properties["developerModeStatus"] as? String == "enabled"
            )
        }.filter { $0.ready }
        guard let selector, !selector.isEmpty else {
            return nil
        }
        guard ready.filter({ $0.raw == selector }).count == 1 else { return nil }
        return await deviceLockState(rawDeviceIdentifier: selector, context: context) == false ? selector : nil
    }

    public func signingDeviceIdentifier(matching selector: String, context: RuntimeProvisioningContext) async -> String? {
        guard !RuntimeProvisioning.devicectlForbidden(), let xcrun = RuntimeProvisioning.xcrunURL() else { return nil }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-signing-device-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let jsonURL = temporaryDirectory.appendingPathComponent("devices.json")
        let result = try? await context.runner.run(
            executableURL: xcrun,
            arguments: ["devicectl", "list", "devices", "--timeout", "8", "--json-output", jsonURL.path, "--quiet"],
            workingDirectory: temporaryDirectory,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result?.exitCode == 0,
              let data = try? Data(contentsOf: jsonURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObject = raw["result"] as? [String: Any],
              let items = resultObject["devices"] as? [[String: Any]] else { return nil }
        let matches = items.compactMap { item -> String? in
            let hardware = item["hardwareProperties"] as? [String: Any] ?? [:]
            let coreDeviceIdentifier = item["identifier"] as? String
            let udid = hardware["udid"] as? String
            guard selector == coreDeviceIdentifier || selector == udid else { return nil }
            return udid
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public func isAppInstalled(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Bool? {
        guard let count = await installedAppCount(
            bundleIdentifier: bundleIdentifier,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        ) else { return nil }
        return count > 0
    }

    public func installedAppCount(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Int? {
        guard !RuntimeProvisioning.devicectlForbidden() else {
            return nil
        }
        guard let xcrun = RuntimeProvisioning.xcrunURL() else {
            return nil
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-app-lookup-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let jsonURL = temporaryDirectory.appendingPathComponent("apps.json")
        let result = try? await context.runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl",
                "device",
                "info",
                "apps",
                "--device",
                rawDeviceIdentifier,
                "--bundle-id",
                bundleIdentifier,
                "--timeout",
                "10",
                "--json-output",
                jsonURL.path,
                "--quiet"
            ],
            workingDirectory: temporaryDirectory,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result?.exitCode == 0,
              let data = try? Data(contentsOf: jsonURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObject = raw["result"] as? [String: Any],
              let apps = resultObject["apps"] as? [[String: Any]] else {
            return nil
        }
        return apps.count
    }

    public func install(component: DeviceArtifactComponent, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult {
        guard !RuntimeProvisioning.devicectlForbidden() else {
            return ProcessResult(exitCode: 78, stdout: "", stderr: "DEVICETCTL_FORBIDDEN: devicectl backend is disabled for this run.")
        }
        guard let xcrun = RuntimeProvisioning.xcrunURL() else {
            return ProcessResult(exitCode: 127, stdout: "", stderr: "Apple development support required: /usr/bin/xcrun is unavailable.")
        }
        let appURL = context.resourcesURL.appendingPathComponent(component.relativePath)
        return try await context.runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl",
                "device",
                "install",
                "app",
                "--device",
                rawDeviceIdentifier,
                appURL.path,
                "--timeout",
                "60",
                "--quiet"
            ],
            workingDirectory: context.resourcesURL,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
    }

    public func uninstall(
        bundleIdentifier: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> ProcessResult {
        guard !RuntimeProvisioning.devicectlForbidden(), let xcrun = RuntimeProvisioning.xcrunURL() else {
            return ProcessResult(exitCode: 78, stdout: "", stderr: "DEVICETCTL_FORBIDDEN: devicectl backend is disabled for this run.")
        }
        return try await context.runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl", "device", "uninstall", "app",
                "--device", rawDeviceIdentifier,
                bundleIdentifier,
                "--timeout", "30", "--quiet"
            ],
            workingDirectory: context.resourcesURL,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
    }

    public func launch(
        bundleIdentifier: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> ProcessResult {
        guard !RuntimeProvisioning.devicectlForbidden(), let xcrun = RuntimeProvisioning.xcrunURL() else {
            return ProcessResult(exitCode: 78, stdout: "", stderr: "DEVICETCTL_FORBIDDEN: devicectl backend is disabled for this run.")
        }
        return try await context.runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl", "device", "process", "launch",
                "--device", rawDeviceIdentifier,
                bundleIdentifier,
                "--timeout", "15", "--quiet"
            ],
            workingDirectory: context.resourcesURL,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
    }

    public func readContainerFile(
        bundleIdentifier: String,
        relativePath: String,
        rawDeviceIdentifier: String,
        context: RuntimeProvisioningContext
    ) async throws -> Data {
        guard !RuntimeProvisioning.devicectlForbidden(), let xcrun = RuntimeProvisioning.xcrunURL() else {
            throw DeviceProvisioningBackendError.operationFailed("DEVICETCTL_FORBIDDEN")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-container-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("readback", isDirectory: true)
        let sourceDirectory = (relativePath as NSString).deletingLastPathComponent
        let expectedName = (relativePath as NSString).lastPathComponent
        let result = try await context.runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl", "device", "copy", "from",
                "--device", rawDeviceIdentifier,
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundleIdentifier,
                "--source", sourceDirectory,
                "--destination", destination.path,
                "--timeout", "30", "--quiet"
            ],
            workingDirectory: root,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result.exitCode == 0 else {
            throw DeviceProvisioningBackendError.operationFailed(result.combinedOutput)
        }
        guard let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil),
              let fileURL = enumerator.compactMap({ $0 as? URL }).first(where: {
                  $0.lastPathComponent == expectedName || $0.pathExtension == "plist"
              }) else {
            throw DeviceProvisioningBackendError.operationFailed("container file was not returned")
        }
        return try Data(contentsOf: fileURL)
    }

    private func deviceLockState(rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Bool? {
        guard let xcrun = RuntimeProvisioning.xcrunURL() else {
            return nil
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-lockstate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let jsonURL = temporaryDirectory.appendingPathComponent("lockstate.json")
        let result = try? await context.runner.run(
            executableURL: xcrun,
            arguments: [
                "devicectl",
                "device",
                "info",
                "lockState",
                "--device",
                rawDeviceIdentifier,
                "--timeout",
                "5",
                "--json-output",
                jsonURL.path,
                "--quiet"
            ],
            workingDirectory: temporaryDirectory,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result?.exitCode == 0,
              let data = try? Data(contentsOf: jsonURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObject = raw["result"] as? [String: Any],
              let passcodeRequired = resultObject["passcodeRequired"] as? Bool else {
            return nil
        }
        return passcodeRequired
    }
}
