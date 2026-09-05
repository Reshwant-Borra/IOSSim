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
    public static let helperSchemaVersion = 1
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
        if let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !developerDir.isEmpty {
            env["DEVELOPER_DIR"] = developerDir
        }
        return env
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

    public static func selected() -> ProvisioningBackendKind {
        let raw = ProcessInfo.processInfo.environment["IOSSIM_DEVICE_BACKEND"]?.lowercased()
        if raw == "idevice" {
            return .idevice
        }
        return .devicectl
    }
}

public protocol DeviceProvisioningBackend: Sendable {
    func discoverDevices(context: RuntimeProvisioningContext) async -> [DetectedDevice]
    func rawDeviceIdentifier(matching selector: String?, context: RuntimeProvisioningContext) async -> String?
    func signingDeviceIdentifier(matching selector: String, context: RuntimeProvisioningContext) async -> String?
    func isAppInstalled(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Bool?
    func installedAppCount(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Int?
    func install(component: DeviceArtifactComponent, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult
}

public extension DeviceProvisioningBackend {
    func installedAppCount(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Int? {
        guard let installed = await isAppInstalled(
            bundleIdentifier: bundleIdentifier,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        ) else { return nil }
        return installed ? 1 : 0
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

public struct IdeviceProvisioningBackend: DeviceProvisioningBackend {
    public init() {}

    public func discoverDevices(context: RuntimeProvisioningContext) async -> [DetectedDevice] {
        []
    }

    public func rawDeviceIdentifier(matching selector: String?, context: RuntimeProvisioningContext) async -> String? {
        nil
    }

    public func signingDeviceIdentifier(matching selector: String, context: RuntimeProvisioningContext) async -> String? {
        nil
    }

    public func isAppInstalled(bundleIdentifier: String, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async -> Bool? {
        nil
    }

    public func install(component: DeviceArtifactComponent, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult {
        ProcessResult(
            exitCode: 78,
            stdout: "",
            stderr: "IDEVICE_BACKEND_UNAVAILABLE: host-side idevice provisioning requires a macOS idevice FFI library; the current bundled library is iOS-only."
        )
    }
}

public enum AppleDeviceTool {
    public static func discoverDevices(context: RuntimeProvisioningContext) async -> [DetectedDevice] {
        await DeviceProvisioningBackendFactory.makeSelectedBackend().discoverDevices(context: context)
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
