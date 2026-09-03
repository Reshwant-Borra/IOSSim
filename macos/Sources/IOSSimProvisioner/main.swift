import Foundation
import IOSSimMacCore

struct ProvisionerOutput<T: Encodable>: Encodable {
    let ok: Bool
    let schemaVersion: Int
    let data: T
}

struct InfoOutput: Encodable {
    let release: ReleaseManifest
    let components: [DeviceArtifactComponent]
}

struct VerificationOutput: Encodable {
    let results: [ArtifactVerificationResult]
}

struct InstallComponentOutput: Encodable {
    let role: String
    let bundleIdentifier: String
    let relativePath: String
    let exitCode: Int32
}

struct InstallOutput: Encodable {
    let deviceIdentifier: String
    let installed: [InstallComponentOutput]
}

@main
enum IOSSimProvisioner {
    static func main() async {
        let tool = ProvisionerTool(arguments: Array(CommandLine.arguments.dropFirst()))
        let code = await tool.run()
        Foundation.exit(code)
    }
}

struct ProvisionerTool {
    let arguments: [String]

    func run() async -> Int32 {
        var args = arguments
        let resourcesURL = consumeResourcesOverride(arguments: &args) ?? defaultResourcesURL()
        let context = RuntimeProvisioningContext(resourcesURL: resourcesURL)
        guard let command = args.first else {
            printUsage()
            return 2
        }
        do {
            switch command {
            case "doctor":
                let json = args.contains("--json")
                let status = await doctor(context: context)
                if json {
                    try printJSON(status)
                } else {
                    printHumanDoctor(status)
                }
                return 0
            case "device-status":
                let devices = await AppleDeviceTool.discoverDevices(context: context)
                try printJSON(ProvisionerOutput(ok: true, schemaVersion: RuntimeProvisioning.helperSchemaVersion, data: devices))
                return 0
            case "verify-artifacts":
                let manifest = try context.loadManifest()
                let results = ArtifactManifestLoader.verify(resourcesURL: context.resourcesURL, manifest: manifest)
                try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: context.resourcesURL, manifest: manifest)
                try printJSON(ProvisionerOutput(ok: true, schemaVersion: RuntimeProvisioning.helperSchemaVersion, data: VerificationOutput(results: results)))
                return 0
            case "install", "repair":
                return await install(command: command, arguments: Array(args.dropFirst()), context: context)
            case "verify":
                let status = await doctor(context: context)
                try printJSON(status)
                return status.mac.ready ? 0 : 1
            case "setup":
                let status = await doctor(context: context)
                try printJSON(status)
                return status.mac.ready ? 0 : 1
            case "info":
                let manifest = try context.loadManifest()
                if args.contains("--json") {
                    try printJSON(ProvisionerOutput(
                        ok: true,
                        schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                        data: InfoOutput(release: manifest.release, components: manifest.components)
                    ))
                } else {
                    print("IOSSimProvisioner schema \(RuntimeProvisioning.helperSchemaVersion)")
                    print("Release commit: \(manifest.release.sourceCommit)")
                    for component in manifest.components {
                        print("\(component.role): \(component.bundleIdentifier) \(component.version)")
                    }
                }
                return 0
            default:
                printUsage()
                return 2
            }
        } catch {
            fputs("\(Redactor.redact(String(describing: error)))\n", stderr)
            return 1
        }
    }

    private func install(command: String, arguments: [String], context: RuntimeProvisioningContext) async -> Int32 {
        do {
            let selector = optionValue("--device", in: arguments)
            let manifest = try context.loadManifest()
            try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: context.resourcesURL, manifest: manifest)
            guard let rawDeviceIdentifier = await AppleDeviceTool.rawDeviceIdentifier(matching: selector, context: context) else {
                fputs("iPhone setup required: connect one trusted iPhone with Developer Mode enabled.\n", stderr)
                return 2
            }
            var installed: [InstallComponentOutput] = []
            var failedOutput = ""
            for component in manifest.components {
                let result = try await AppleDeviceTool.install(
                    component: component,
                    rawDeviceIdentifier: rawDeviceIdentifier,
                    context: context
                )
                installed.append(InstallComponentOutput(
                    role: component.role,
                    bundleIdentifier: component.bundleIdentifier,
                    relativePath: component.relativePath,
                    exitCode: result.exitCode
                ))
                if result.exitCode != 0 {
                    failedOutput += "\n\(component.role): \(result.combinedOutput)"
                }
            }
            let output = ProvisionerOutput(
                ok: installed.allSatisfy { $0.exitCode == 0 },
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                data: InstallOutput(
                    deviceIdentifier: RuntimeProvisioning.shortIdentifier(rawDeviceIdentifier),
                    installed: installed
                )
            )
            try printJSON(output)
            if installed.allSatisfy({ $0.exitCode == 0 }) {
                return 0
            }
            fputs(Redactor.redact(failedOutput), stderr)
            return 1
        } catch {
            fputs("\(Redactor.redact(String(describing: error)))\n", stderr)
            return 1
        }
    }

    private func doctor(context: RuntimeProvisioningContext) async -> DoctorStatus {
        var checks: [DoctorCheck] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let macSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(RuntimeProvisioning.minimumMacOS)
        checks.append(DoctorCheck(
            state: macSupported ? .pass : .fail,
            component: "Mac",
            name: "macOS supported",
            detail: osText,
            action: macSupported ? nil : "Upgrade macOS.",
            requiredFor: "mac"
        ))
        checks.append(DoctorCheck(
            state: RuntimeProvisioning.xcrunURL() == nil ? .action : .pass,
            component: "Apple Tooling",
            name: "xcrun",
            detail: RuntimeProvisioning.xcrunURL()?.path ?? "missing",
            action: RuntimeProvisioning.xcrunURL() == nil ? "Install Apple developer command line support." : nil,
            requiredFor: "mac"
        ))
        do {
            let manifest = try context.loadManifest()
            let results = ArtifactManifestLoader.verify(resourcesURL: context.resourcesURL, manifest: manifest)
            for result in results {
                checks.append(DoctorCheck(
                    state: result.state,
                    component: "Bundled Artifacts",
                    name: result.role,
                    detail: result.detail,
                    action: result.state == .pass ? nil : "Reinstall IOSSim.",
                    requiredFor: "mac"
                ))
            }
            do {
                try ArtifactManifestLoader.assertValidBundleIdentifiers(resourcesURL: context.resourcesURL, manifest: manifest)
                checks.append(DoctorCheck(state: .pass, component: "Bundled Artifacts", name: "bundle identifiers", detail: "verified"))
            } catch {
                checks.append(DoctorCheck(
                    state: .fail,
                    component: "Bundled Artifacts",
                    name: "bundle identifiers",
                    detail: Redactor.redact(String(describing: error)),
                    action: "Reinstall IOSSim.",
                    requiredFor: "mac"
                ))
            }
        } catch {
            checks.append(DoctorCheck(
                state: .fail,
                component: "Bundled Artifacts",
                name: "manifest",
                detail: Redactor.redact(String(describing: error)),
                action: "Reinstall IOSSim.",
                requiredFor: "mac"
            ))
        }
        let devices = await AppleDeviceTool.discoverDevices(context: context)
        if devices.isEmpty {
            checks.append(DoctorCheck(
                state: .action,
                component: "Device",
                name: "connected iPhone",
                detail: "not detected",
                action: "Connect and unlock an iPhone, trust this Mac, then try again.",
                requiredFor: "device"
            ))
        } else {
            let hasReadyDevice = devices.contains {
                $0.pairingState == "paired" && $0.developerModeStatus == "enabled"
            }
            for device in devices {
                checks.append(DoctorCheck(
                    state: .pass,
                    component: "Device",
                    name: "iPhone detected",
                    detail: "\(device.name) \(device.osVersion ?? "iOS unknown") id=\(device.identifier)",
                    requiredFor: "device"
                ))
                checks.append(DoctorCheck(
                    state: device.pairingState == "paired" ? .pass : (hasReadyDevice ? .warn : .action),
                    component: "Device",
                    name: "device trusted",
                    detail: device.pairingState ?? "unknown",
                    action: device.pairingState == "paired" || hasReadyDevice ? nil : "Unlock the iPhone and trust this Mac.",
                    requiredFor: "device"
                ))
                checks.append(DoctorCheck(
                    state: device.developerModeStatus == "enabled" ? .pass : (hasReadyDevice ? .warn : .action),
                    component: "Device",
                    name: "Developer Mode",
                    detail: device.developerModeStatus ?? "unknown",
                    action: device.developerModeStatus == "enabled" || hasReadyDevice ? nil : "On your iPhone, open Settings > Privacy & Security > Developer Mode.",
                    requiredFor: "device"
                ))
                checks.append(DoctorCheck(
                    state: device.tunnelState == "connected" ? .pass : .warn,
                    component: "Device",
                    name: "CoreDevice tunnel",
                    detail: device.tunnelState ?? "unknown",
                    requiredFor: "device"
                ))
            }
        }
        checks.append(DoctorCheck(
            state: .action,
            component: "Runtime",
            name: "PAIRING MATERIAL",
            detail: "stored on iPhone; never bundled",
            action: "Open IOSSim on your iPhone and complete the pairing import.",
            requiredFor: "device"
        ))
        checks.append(DoctorCheck(
            state: .action,
            component: "Runtime",
            name: "LocalDevVPN",
            detail: "external iPhone app required",
            action: "Install or open LocalDevVPN on your iPhone and approve Apple's VPN prompt.",
            requiredFor: "device"
        ))
        let macReady = !checks.contains { ($0.state == .fail || $0.state == .action) && ["mac", "build"].contains($0.requiredFor) }
        let deviceReady = !checks.contains { ($0.state == .fail || $0.state == .action) && $0.requiredFor == "device" }
        return DoctorStatus(
            ready: macReady && deviceReady,
            mac: MacSummary(ready: macReady),
            device: DeviceSummary(ready: deviceReady, connected: !devices.isEmpty, devices: devices),
            actionsRequired: checks.filter { $0.state == .action }.map { $0.action ?? $0.name },
            checks: checks
        )
    }

    private func printUsage() {
        print("""
        IOSSimProvisioner commands:
          doctor --json
          device-status --json
          install [--device <id>]
          repair [--device <id>]
          verify [--device <id>]
          verify-artifacts --json
          info --json
        """)
    }
}

private func optionValue(_ option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option),
          arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func consumeResourcesOverride(arguments: inout [String]) -> URL? {
    guard let index = arguments.firstIndex(of: "--resources"),
          arguments.indices.contains(index + 1) else {
        return nil
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return URL(fileURLWithPath: value)
}

private func defaultResourcesURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["IOSSIM_BUNDLED_RESOURCES"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let macOSURL = executableURL.deletingLastPathComponent()
    if macOSURL.lastPathComponent == "MacOS" {
        let contentsURL = macOSURL.deletingLastPathComponent()
        if contentsURL.lastPathComponent == "Contents" {
            return contentsURL.appendingPathComponent("Resources", isDirectory: true)
        }
    }
    return Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func printHumanDoctor(_ status: DoctorStatus) {
    print("IOSSim Runtime Check")
    for check in status.checks {
        var line = "[\(check.state.rawValue)] \(check.component): \(check.name)"
        if !check.detail.isEmpty {
            line += " - \(check.detail)"
        }
        print(line)
        if check.state == .action, let action = check.action {
            print("  ACTION: \(action)")
        }
    }
}
