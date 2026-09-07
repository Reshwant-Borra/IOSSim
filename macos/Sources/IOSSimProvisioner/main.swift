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

struct ConsumerFailureOutput: Encodable {
    let ok: Bool
    let schemaVersion: Int
    let error: ConsumerProvisioningFailure
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
            case "personal-team-poc":
                let report = await personalTeamPOCReport(arguments: Array(args.dropFirst()), context: context)
                try printJSON(ProvisionerOutput(ok: true, schemaVersion: RuntimeProvisioning.helperSchemaVersion, data: report))
                return 0
            case "consumer-teams":
                let provisioner = ConsumerArtifactProvisioner(context: context)
                let teams = await provisioner.availableTeams(
                    selectedDeviceIdentifier: optionValue("--device", in: Array(args.dropFirst()))
                )
                try printJSON(ProvisionerOutput(
                    ok: true,
                    schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                    data: teams
                ))
                return 0
            case "consumer-status":
                let provisioner = ConsumerArtifactProvisioner(context: context)
                let manifest = try await provisioner.currentManifest()
                try printJSON(ProvisionerOutput(
                    ok: true,
                    schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                    data: manifest
                ))
                return 0
            case "consumer-runtime-ready":
                let manifest = try await ConsumerProvisioningStateStore().markRuntimeSetupReady()
                try printJSON(ProvisionerOutput(
                    ok: true,
                    schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                    data: manifest
                ))
                return 0
            case "consumer-provision":
                return await consumerProvision(arguments: Array(args.dropFirst()), context: context)
            case "support-bundle":
                guard let output = optionValue("--output", in: Array(args.dropFirst())) else {
                    fputs("SUPPORT_OUTPUT_REQUIRED: provide --output <path>.\n", stderr)
                    return 2
                }
                let release = try? context.loadManifest().release
                let exported = try await SupportBundleExporter.export(
                    to: URL(fileURLWithPath: output),
                    release: release,
                    runner: context.runner
                )
                try printJSON(ProvisionerOutput(
                    ok: true,
                    schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                    data: exported
                ))
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
            guard let selector, !selector.isEmpty else {
                fputs("DEVICE_SELECTION_REQUIRED: choose one connected iPhone before provisioning.\n", stderr)
                return 2
            }
            if ProvisioningBackendKind.selected() == .devicectl && RuntimeProvisioning.devicectlForbidden() {
                fputs("DEVICETCTL_FORBIDDEN: devicectl backend is disabled for this run.\n", stderr)
                return 78
            }
            guard let rawDeviceIdentifier = await AppleDeviceTool.rawDeviceIdentifier(matching: selector, context: context) else {
                fputs("IPHONE_DISCONNECTED: reconnect the selected iPhone or choose another device.\n", stderr)
                return 2
            }
            let eligibility = await ArtifactEligibilityEvaluator.summaries(
                resourcesURL: context.resourcesURL,
                manifest: manifest,
                selectedDeviceIdentifier: rawDeviceIdentifier,
                runner: context.runner
            )
            let aggregateEligibility = ArtifactEligibilityEvaluator.aggregateStatus(eligibility)
            guard aggregateEligibility == .installable else {
                fputs("ARTIFACT_ELIGIBILITY_\(aggregateEligibility.rawValue): \(uniqueDetails(from: eligibility))\n", stderr)
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
        var manifestForEligibility: ArtifactManifest?
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
        let consumerSelection = RuntimeProvisioning.consumerBackendSelection(resourcesURL: context.resourcesURL)
        let xcodePresent = consumerSelection.xcodePresent
        let usesXcodeBackend = consumerSelection.backend.map {
            [.xcodeFallback, .xcodeInvisible].contains($0)
        } == true
        var xcodeResult: ProcessResult?
        var devicectlResult: ProcessResult?
        if usesXcodeBackend {
            xcodeResult = try? await context.runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: ["-version"],
                workingDirectory: context.resourcesURL,
                environment: RuntimeProvisioning.deterministicEnvironment()
            )
            devicectlResult = try? await context.runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["--find", "devicectl"],
                workingDirectory: context.resourcesURL,
                environment: RuntimeProvisioning.deterministicEnvironment()
            )
        }
        let fullXcodeAvailable = xcodeResult?.exitCode == 0
        let devicectlUnavailable = RuntimeProvisioning.xcrunURL() == nil
            || RuntimeProvisioning.devicectlForbidden()
            || devicectlResult?.exitCode != 0
        let appleToolingReady = consumerSelection.ready
            && (!usesXcodeBackend || (fullXcodeAvailable && !devicectlUnavailable))
        checks.append(DoctorCheck(
            state: .pass,
            component: "Provisioning",
            name: "backend selection",
            detail: "preference=\(consumerSelection.preference.rawValue) backend=\(consumerSelection.backend?.rawValue ?? "NONE") zeroXcodeMode=\(consumerSelection.zeroXcodeMode)",
            requiredFor: "authorization"
        ))
        checks.append(DoctorCheck(
            state: .pass,
            component: "Provisioning",
            name: "xcodePresent",
            detail: xcodePresent ? "true" : "false",
            requiredFor: "diagnostics"
        ))
        checks.append(DoctorCheck(
            state: appleToolingReady ? .pass : .action,
            component: "Provisioning",
            name: consumerSelection.zeroXcodeMode ? "native Personal Team backend" : "headless Xcode backend",
            detail: appleToolingReady
                ? (xcodeResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ready")
                : (consumerSelection.failureCode ?? "backend unavailable"),
            action: appleToolingReady ? nil : "IOSSim could not prepare Apple authorization on this Mac.",
            requiredFor: "authorization"
        ))
        do {
            let manifest = try context.loadManifest()
            manifestForEligibility = manifest
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
        let consumerManifest = try? await ConsumerProvisioningStateStore().loadManifest()
        var devices = await AppleDeviceTool.discoverDevices(context: context)
        if let manifestForEligibility {
            var enrichedDevices: [DetectedDevice] = []
            for device in devices {
                let eligibility = await ArtifactEligibilityEvaluator.summaries(
                    resourcesURL: context.resourcesURL,
                    manifest: manifestForEligibility,
                    selectedDeviceIdentifier: device.selectionIdentifier,
                    runner: context.runner
                )
                let requiresConsumerSigning = manifestForEligibility.components.allSatisfy {
                    $0.signingMode == "personalTeamResign"
                }
                let aggregate = requiresConsumerSigning
                    ? ArtifactInstallEligibilityStatus.installable
                    : ArtifactEligibilityEvaluator.aggregateStatus(eligibility)
                let installedBundleIdentifiers = await installedProjectBundleIdentifiers(
                    for: device.selectionIdentifier,
                    manifest: manifestForEligibility,
                    consumerManifest: consumerManifest,
                    context: context
                )
                enrichedDevices.append(device.withProvisioningState(
                    status: aggregate,
                    detail: requiresConsumerSigning ? "Prepared during Personal Team install." : uniqueDetails(from: eligibility),
                    installedProjectBundleIdentifiers: installedBundleIdentifiers,
                    expectedProjectBundleCount: manifestForEligibility.components.count
                ))
            }
            devices = enrichedDevices
        }
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
                $0.pairingState == "paired" && $0.developerModeStatus == "enabled" && $0.isLocked != true
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
                    state: device.isLocked == true ? (hasReadyDevice ? .warn : .action) : .pass,
                    component: "Device",
                    name: "iPhone unlocked",
                    detail: device.isLocked == true ? "locked" : "unlocked",
                    action: device.isLocked == true && !hasReadyDevice ? "Unlock the iPhone and keep it awake." : nil,
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
                if let eligibilityStatus = device.provisioningEligibilityStatus, eligibilityStatus != .installable {
                    checks.append(DoctorCheck(
                        state: .action,
                        component: "Signing",
                        name: eligibilityStatus.rawValue,
                        detail: RuntimeProvisioning.shortIdentifier(device.selectionIdentifier),
                        action: "This iPhone is not yet authorized for this IOSSim build.",
                        requiredFor: "device"
                    ))
                }
            }
        }
        let confirmedDeviceConnected = consumerManifest.map { manifest in
            manifest.runtimeSetupStatus == .ready && devices.contains {
                PersonalTeamProvisioningPOC.deviceIdentifierHash($0.selectionIdentifier) == manifest.deviceIdentifierHash
            }
        } ?? false
        if !confirmedDeviceConnected {
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
        }
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
          personal-team-poc --json [--team <team-id>] [--team-kind personal|paid|unknown] [--device <id>]
          consumer-teams --json [--device <id>]
          consumer-status --json
          consumer-runtime-ready --json
          consumer-provision --operation install|refresh|repair --device <id> --team <team-id>
          support-bundle --output <zip-path> --json
        """)
    }

    private func consumerProvision(arguments: [String], context: RuntimeProvisioningContext) async -> Int32 {
        guard let rawOperation = optionValue("--operation", in: arguments),
              let operation = ConsumerProvisioningOperation(rawValue: rawOperation.uppercased()),
              let device = optionValue("--device", in: arguments), !device.isEmpty,
              let team = optionValue("--team", in: arguments), !team.isEmpty else {
            let failure = ConsumerProvisioningFailure(
                code: .deviceSelectionRequired,
                stage: .waitingForDeviceSelection,
                userMessage: "IOSSim needs an iPhone and Apple authorization before installing.",
                remediation: "Return to setup and make both selections.",
                developerDetail: "consumer-provision requires --operation, --device, and --team."
            )
            try? printJSON(ConsumerFailureOutput(
                ok: false,
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                error: failure
            ))
            return 2
        }
        do {
            let request = ConsumerProvisioningRequest(
                operation: operation,
                selectedDeviceIdentifier: device,
                selectedTeamIdentifier: team,
                allowFreshInstallAfterCrossTeamConflict: arguments.contains("--confirm-fresh-install")
            )
            let result = try await ConsumerArtifactProvisioner(context: context).provision(request)
            try printJSON(ProvisionerOutput(
                ok: true,
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                data: result
            ))
            return 0
        } catch let failure as ConsumerProvisioningFailure {
            try? printJSON(ConsumerFailureOutput(
                ok: false,
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                error: failure
            ))
            return 1
        } catch {
            let failure = ConsumerProvisioningFailure(
                code: .unknown,
                stage: .failed,
                userMessage: "IOSSim could not finish setup.",
                remediation: "Open Diagnostics for details, then try again.",
                developerDetail: String(describing: error)
            )
            try? printJSON(ConsumerFailureOutput(
                ok: false,
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                error: failure
            ))
            return 1
        }
    }
}

private func personalTeamPOCReport(arguments: [String], context: RuntimeProvisioningContext) async -> PersonalTeamPOCInspectionReport {
    let identities = await AppleSigningIdentityInspector.availableAppleDevelopmentIdentities(runner: context.runner)
    let explicitTeam = optionValue("--team", in: arguments)
    let selectedTeam = explicitTeam ?? singleDetectedTeamIdentifier(from: identities)
    let selectedKind = teamKind(from: optionValue("--team-kind", in: arguments))
    let selectedDevice = optionValue("--device", in: arguments)
    let source = ProtectedSourceBundleIdentifiers.default
    let derived = selectedTeam.flatMap { try? PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: $0) }
    let manifest = try? context.loadManifest()
    let profiles: [ProvisioningProfileSummary]
    let signingGraph: [SigningGraphNode]
    if let manifest {
        profiles = await ArtifactEligibilityEvaluator.summaries(
            resourcesURL: context.resourcesURL,
            manifest: manifest,
            selectedDeviceIdentifier: selectedDevice,
            runner: context.runner
        )
        signingGraph = await SigningGraphInspector.graph(
            resourcesURL: context.resourcesURL,
            manifest: manifest,
            profiles: profiles,
            runner: context.runner
        )
    } else {
        profiles = []
        signingGraph = []
    }
    let deviceHash = selectedDevice.map { PersonalTeamProvisioningPOC.deviceIdentifierHash($0) }
    let refreshPlan: RefreshPlan?
    if let selectedTeam, let deviceHash, let derived {
        let pocManifest = PersonalTeamProvisioningManifest(
            teamIdentifier: selectedTeam,
            teamKind: selectedKind,
            deviceIdentifierHash: deviceHash,
            sourceMainBundleID: source.main,
            installedMainBundleID: derived.main,
            sourceUITestBundleID: source.uiTests,
            installedUITestBundleID: derived.uiTests,
            sourceRunnerBundleID: source.runner,
            installedRunnerBundleID: derived.runner,
            sourceWitnessBundleID: source.witness,
            installedWitnessBundleID: nil,
            mainExpiration: profiles.first(where: { $0.bundleIdentifier == source.main })?.expirationDate,
            runnerExpiration: profiles.first(where: { $0.bundleIdentifier == source.runner })?.expirationDate,
            witnessExpiration: nil
        )
        refreshPlan = PersonalTeamProvisioningPOC.refreshPlan(
            manifest: pocManifest,
            currentTeamIdentifier: selectedTeam,
            currentDeviceIdentifierHash: deviceHash
        )
    } else {
        refreshPlan = nil
    }
    return PersonalTeamPOCInspectionReport(
        sourceBundleIdentifiers: source,
        derivedBundleIdentifiers: derived,
        selectedTeamIdentifier: selectedTeam,
        selectedTeamKind: selectedKind,
        appleDevelopmentIdentities: identities,
        selectedDeviceIdentifierHash: deviceHash,
        currentArtifactProfiles: profiles,
        currentSigningGraph: signingGraph,
        refreshPlan: refreshPlan
    )
}

private func singleDetectedTeamIdentifier(from identities: [AppleCodeSigningIdentity]) -> String? {
    let teams = Set(identities.compactMap(\.teamIdentifier))
    return teams.count == 1 ? teams.first : nil
}

private func teamKind(from rawValue: String?) -> ProvisioningTeamKind {
    switch rawValue?.lowercased() {
    case "personal", "personal-team", "free":
        return .personalTeam
    case "paid", "developer", "paid-development":
        return .paidDevelopment
    default:
        return .unknown
    }
}

private func uniqueDetails(from summaries: [ProvisioningProfileSummary]) -> String {
    var seen: Set<String> = []
    return summaries.compactMap { summary in
        guard !seen.contains(summary.detail) else { return nil }
        seen.insert(summary.detail)
        return summary.detail
    }.joined(separator: " ")
}

private func installedProjectBundleIdentifiers(
    for rawDeviceIdentifier: String,
    manifest: ArtifactManifest,
    consumerManifest: ConsumerProvisioningManifest?,
    context: RuntimeProvisioningContext
) async -> [String]? {
    var installed: [String] = []
    for component in manifest.components {
        let consumerStateApplies = consumerManifest?.deviceIdentifierHash
            == PersonalTeamProvisioningPOC.deviceIdentifierHash(rawDeviceIdentifier)
        let installedBundleIdentifier: String
        if consumerStateApplies, component.role == "iosMain", let consumerManifest {
            installedBundleIdentifier = consumerManifest.installedMainBundleID
        } else if consumerStateApplies, component.role == "locationControlRunner", let consumerManifest {
            installedBundleIdentifier = consumerManifest.installedRunnerBundleID
        } else {
            installedBundleIdentifier = component.bundleIdentifier
        }
        guard let isInstalled = await AppleDeviceTool.isAppInstalled(
            bundleIdentifier: installedBundleIdentifier,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        ) else {
            return nil
        }
        if isInstalled {
            installed.append(installedBundleIdentifier)
        }
    }
    return installed
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
    encoder.dateEncodingStrategy = .iso8601
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
