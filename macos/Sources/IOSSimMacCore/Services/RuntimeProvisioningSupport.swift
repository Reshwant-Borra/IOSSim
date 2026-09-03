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

    public static func shortIdentifier(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        if value.count <= 10 { return value }
        let prefix = value.prefix(6)
        let suffix = value.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

public enum AppleDeviceTool {
    public static func discoverDevices(context: RuntimeProvisioningContext) async -> [DetectedDevice] {
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
        return deviceItems.compactMap { item -> DetectedDevice? in
            let properties = item["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = item["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = item["connectionProperties"] as? [String: Any] ?? [:]
            let deviceType = hardware["deviceType"] as? String
            let platform = hardware["platform"] as? String
            guard deviceType == "iPhone" || platform == "iOS" else {
                return nil
            }
            let rawIdentifier = (item["identifier"] as? String) ?? (hardware["udid"] as? String)
            return DetectedDevice(
                name: (properties["name"] as? String) ?? (hardware["marketingName"] as? String) ?? "iPhone",
                identifier: RuntimeProvisioning.shortIdentifier(rawIdentifier),
                udidRedacted: RuntimeProvisioning.shortIdentifier(hardware["udid"] as? String),
                osVersion: properties["osVersionNumber"] as? String,
                developerModeStatus: properties["developerModeStatus"] as? String,
                pairingState: connection["pairingState"] as? String,
                tunnelState: connection["tunnelState"] as? String
            )
        }
    }

    public static func rawDeviceIdentifier(matching selector: String?, context: RuntimeProvisioningContext) async -> String? {
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
        guard !ready.isEmpty else { return nil }
        guard let selector, !selector.isEmpty else {
            return ready.count == 1 ? ready[0].raw : nil
        }
        let wanted = selector.lowercased()
        return ready.first {
            $0.redacted.lowercased().contains(wanted) ||
            $0.raw.lowercased().contains(wanted) ||
            $0.name.lowercased() == wanted
        }?.raw
    }

    public static func install(component: DeviceArtifactComponent, rawDeviceIdentifier: String, context: RuntimeProvisioningContext) async throws -> ProcessResult {
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
}
