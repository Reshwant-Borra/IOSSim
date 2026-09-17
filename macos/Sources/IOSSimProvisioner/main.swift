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

struct ProtocolInfoOutput: Encodable {
    let helperSchemaVersion: Int
    let setupStateSchemaVersion: Int
    let provisioningManifestSchemaVersion: Int
    let artifactManifestSchemaVersion: Int
    let nativeBridgeABIExpected: UInt32
    let developerSupportProviderClassification: String
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

struct DeviceDiagnosticOutput: Encodable {
    let rawDeviceCount: Int
    let returnedDeviceCount: Int
    let devices: [DetectedDevice]
    let diagnostics: [DeviceDiscoveryDiagnostic]
}

struct ConsumerFailureOutput: Encodable {
    let ok: Bool
    let schemaVersion: Int
    let error: ConsumerProvisioningFailure
    let diagnostic: VeyaDiagnosticDescriptor

    init(ok: Bool, schemaVersion: Int, error: ConsumerProvisioningFailure) {
        self.ok = ok
        self.schemaVersion = schemaVersion
        self.error = error
        diagnostic = error.diagnosticDescriptor
    }
}

struct DeveloperServicesDiagnosticOutput: Encodable {
    let selectedDevice: String
    let receipt: DeveloperServicesReadinessReceipt
}

private struct KeyedProvisioningState: Sendable {
    let identity: SetupIdentity
    let coordinator: KeyedSetupStateStore
    let domainStore: ConsumerProvisioningStateStore
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
            case "protocol-info":
                try printJSON(ProvisionerOutput(
                    ok: true,
                    schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                    data: ProtocolInfoOutput(
                        helperSchemaVersion: RuntimeProvisioning.helperSchemaVersion,
                        setupStateSchemaVersion: SetupStateSnapshot.currentSchemaVersion,
                        provisioningManifestSchemaVersion: ConsumerProvisioningManifest.currentSchemaVersion,
                        artifactManifestSchemaVersion: ArtifactManifest.currentSchemaVersion,
                        nativeBridgeABIExpected: DynamicNativeDeviceTransport.requiredABIVersion,
                        developerSupportProviderClassification: Self.developerSupportProviderClassification
                    )
                ))
                return 0
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
            case "pair-device":
                return await pairDevice(arguments: Array(args.dropFirst()), context: context)
            case "device-diagnostics":
                let snapshot = await AppleDeviceTool.discoverDeviceSnapshot(context: context)
                try printJSON(ProvisionerOutput(
                    ok: snapshot.primaryDiagnostic?.code != .bridgeUnavailable
                        && snapshot.primaryDiagnostic?.code != .bridgeInitializationFailed
                        && snapshot.primaryDiagnostic?.code != .helperLibraryMissing
                        && snapshot.primaryDiagnostic?.code != .ffiDecodingFailure
                        && snapshot.primaryDiagnostic?.code != .usbmuxUnavailable
                        && snapshot.primaryDiagnostic?.code != .enumerationFailed,
                    schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                    data: DeviceDiagnosticOutput(
                        rawDeviceCount: snapshot.rawDeviceCount,
                        returnedDeviceCount: snapshot.devices.count,
                        devices: snapshot.devices,
                        diagnostics: snapshot.diagnostics
                    )
                ))
                return 0
            case "developer-services-debug":
                return await developerServicesDebug(arguments: Array(args.dropFirst()))
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
                let provisioner = nativeConsumerProvisioner(context: context)
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
                let commandArguments = Array(args.dropFirst())
                let manifest: ConsumerProvisioningManifest?
                if let device = optionValue("--device", in: commandArguments), !device.isEmpty,
                   let team = optionValue("--team", in: commandArguments), !team.isEmpty {
                    manifest = try await keyedProvisioningState(
                        context: context,
                        device: device,
                        team: team
                    ).domainStore.loadManifest()
                } else if let device = optionValue("--device", in: commandArguments), !device.isEmpty {
                    manifest = try await currentManifestForDevice(context: context, device: device)
                } else {
                    manifest = try await ConsumerProvisioningStateStore().loadManifest()
                }
                try printJSON(ProvisionerOutput(
                    ok: true,
                    schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                    data: manifest
                ))
                return 0
            case "consumer-runtime-ready":
                let commandArguments = Array(args.dropFirst())
                guard let device = optionValue("--device", in: commandArguments), !device.isEmpty,
                      let team = optionValue("--team", in: commandArguments), !team.isEmpty else {
                    throw ConsumerProvisioningFailure(
                        code: .deviceSelectionRequired,
                        stage: .verifyingRuntimeReadiness,
                        userMessage: "IOSSim needs the current iPhone and Personal Team to confirm runtime setup.",
                        remediation: "Return to setup, select the iPhone and Personal Team, then try again.",
                        developerDetail: "consumer-runtime-ready requires --device and --team for keyed state."
                    )
                }
                let keyed = try keyedProvisioningState(context: context, device: device, team: team)
                let result: SetupMutationResult<ConsumerProvisioningManifest> = try await keyed.coordinator.withMutation(
                    identity: keyed.identity,
                    domain: "runtimeReadiness",
                    safeDetail: "Recorded bound AppService, XCTest, Rich location, clear, and cleanup readiness evidence."
                ) { _ in
                    guard let manifest = try await keyed.domainStore.loadManifest() else {
                        throw ConsumerProvisioningFailure(
                            code: .runnerMappingMissing,
                            stage: .verifyingRuntimeReadiness,
                            userMessage: "IOSSim installation information is missing.",
                            remediation: "Choose Repair before completing iPhone setup.",
                            developerDetail: "Runtime proof requires the selected keyed manifest."
                        )
                    }
                    let transport = DynamicNativeDeviceTransport()
                    let applicationService = NativeApplicationService(transport: transport)
                    let deviceBackend = IdeviceProvisioningBackend(applicationService: applicationService)
                    guard let identity = await deviceBackend.nativeDeviceIdentity(
                        matching: device, context: context
                    ) else {
                        throw ConsumerProvisioningFailure(
                            code: .deviceUnavailable,
                            stage: .verifyingRuntimeReadiness,
                            userMessage: "IOSSim cannot find the selected iPhone connection.",
                            remediation: "Reconnect and unlock the same iPhone, then click Try Again.",
                            developerDetail: "VEYA-RUNTIME-001: exact device identity unavailable."
                        )
                    }
                    guard let pairing = try KeychainRemotePairingStore().load(
                        deviceUDID: identity.udid, teamIdentifier: team
                    ), let pairingGeneration = pairing.metadata.pairingGeneration,
                       pairingGeneration > 0 else {
                        throw ConsumerProvisioningFailure(
                            code: .remotePairingFailed,
                            stage: .verifyingRuntimeReadiness,
                            userMessage: "IOSSim needs to repair its secure device connection.",
                            remediation: "Run Repair with the same unlocked iPhone, then try again.",
                            developerDetail: "VEYA-RUNTIME-001: current pairing generation unavailable."
                        )
                    }
                    #if IOSSIM_LOCAL_TEST_ONLY
                    let developerServices = NativeDeveloperServicesCoordinator(
                        transport: transport,
                        providers: [ThirdPartyMirrorDevelopmentProvider()],
                        providerPolicy: .localTest
                    )
                    #else
                    let developerServices = NativeDeveloperServicesCoordinator(
                        transport: transport,
                        providers: [ExistingAppleCacheProvider()],
                        providerPolicy: .publicProduction
                    )
                    #endif
                    let releaseIdentity = "\(manifest.appVersion):\(manifest.provisionerVersion)"
                    let proofContext = DeveloperServicesProofContext(
                        releaseIdentity: releaseIdentity,
                        pairingGeneration: pairingGeneration,
                        targetBundleIdentifier: manifest.installedRunnerBundleID
                    )
                    let developerReceipt = try await developerServices.prepare(
                        device: identity, context: proofContext
                    ) { _ in }
                    guard developerReceipt.isCurrent(
                        for: identity,
                        releaseIdentity: releaseIdentity,
                        pairingGeneration: pairingGeneration,
                        targetBundleIdentifier: manifest.installedRunnerBundleID
                    ), let developerSession = developerReceipt.sessionIdentifier,
                       let developerSupportIdentity = developerReceipt.developerSupportIdentity else {
                        throw ConsumerProvisioningFailure(
                            code: .developerServicesNotReady,
                            stage: .verifyingRuntimeReadiness,
                            userMessage: "IOSSim could not verify current iPhone developer services.",
                            remediation: "Keep the same iPhone unlocked with LocalDevVPN running, then try again.",
                            developerDetail: "VEYA-RUNTIME-001: developer-services receipt not current."
                        )
                    }
                    let request = RichRuntimeProofRequest(
                        deviceUDID: identity.udid,
                        teamIdentifier: team,
                        releaseIdentity: releaseIdentity,
                        artifactSetIdentity: RichRuntimeProofIdentity.artifactSet(manifest: manifest),
                        profileSetIdentity: RichRuntimeProofIdentity.profiles(manifest: manifest),
                        pairingGeneration: pairingGeneration,
                        developerServicesSession: developerSession,
                        developerSupportIdentity: developerSupportIdentity,
                        runnerBundleIdentifier: manifest.installedRunnerBundleID
                    )
                    let receipt = try await RichRuntimeReadinessCoordinator(
                        service: applicationService
                    ).prove(
                        request: request,
                        device: identity,
                        appBundleIdentifier: manifest.installedMainBundleID
                    )
                    return try await keyed.domainStore.markRuntimeSetupReady(
                        receipt: receipt, request: request
                    )
                }
                let manifest = result.value
                try printJSON(ProvisionerOutput(
                    ok: true,
                    schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                    data: manifest
                ))
                return 0
            case "consumer-provision":
                return await consumerProvision(arguments: Array(args.dropFirst()), context: context)
            case "consumer-resume-setup":
                return await consumerProvision(arguments: Array(args.dropFirst()), context: context, resume: true)
            case "consumer-reconcile":
                return await consumerReconcile(arguments: Array(args.dropFirst()), context: context)
            case "support-bundle":
                guard let output = optionValue("--output", in: Array(args.dropFirst())) else {
                    fputs("SUPPORT_OUTPUT_REQUIRED: provide --output <path>.\n", stderr)
                    return 2
                }
                let release = try? context.loadManifest().release
                let exported = try await SupportBundleExporter.export(
                    to: URL(fileURLWithPath: output),
                    release: release,
                    runner: context.runner,
                    resourcesURL: context.resourcesURL
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

    private static var developerSupportProviderClassification: String {
        #if IOSSIM_LOCAL_TEST_ONLY
        "THIRD_PARTY_MIRROR_DEVELOPMENT_PINNED_V030"
        #else
        "UNRESOLVED_PRODUCTION_PROVIDER"
        #endif
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
        let discovery = await AppleDeviceTool.discoverDeviceSnapshot(context: context)
        var devices = discovery.devices
        for diagnostic in discovery.diagnostics where diagnostic.code != .deviceDiscovered && diagnostic.code != .zeroDevicesReturned {
            checks.append(DoctorCheck(
                state: devices.isEmpty ? .action : .warn,
                component: "Device Bridge",
                name: diagnostic.code.rawValue,
                detail: diagnostic.detail,
                action: devices.isEmpty ? "Open Diagnostics and include a support bundle when reporting this device-discovery failure." : nil,
                requiredFor: "diagnostics"
            ))
        }
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
            let discoveryDetail = discovery.primaryDiagnostic?.code.rawValue ?? DeviceDiscoveryDiagnosticCode.zeroDevicesReturned.rawValue
            checks.append(DoctorCheck(
                state: .action,
                component: "Device",
                name: "connected iPhone",
                detail: discoveryDetail,
                action: discovery.primaryDiagnostic?.code == .zeroDevicesReturned
                    ? "Connect and unlock an iPhone, then try again."
                    : "IOSSim could not query the native device bridge. Open Diagnostics for the exact failure.",
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
                action: "Keep your iPhone unlocked while IOSSim prepares and verifies the secure connection.",
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
          device-diagnostics
          pair-device --device <id> --json
          install [--device <id>]
          repair [--device <id>]
          verify [--device <id>]
          verify-artifacts --json
          info --json
          personal-team-poc --json [--team <team-id>] [--team-kind personal|paid|unknown] [--device <id>]
          consumer-teams --json [--device <id>]
          consumer-status --json
          consumer-runtime-ready --json
          consumer-provision --operation install|refresh|repair --device <id> --team <team-id> [--backend NATIVE_PERSONAL_TEAM|XCODE_FALLBACK]
          consumer-resume-setup --operation install|refresh|repair --device <id> --team <team-id> [--generation <id>]
          consumer-reconcile --json --device <id> --team <team-id> [--trigger SETUP_START|TRY_AGAIN|RESUME_BOUNDARY]
          support-bundle --output <zip-path> --json
        """)
    }

    private func consumerProvision(
        arguments: [String],
        context: RuntimeProvisioningContext,
        resume: Bool = false
    ) async -> Int32 {
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
            let backend: ConsumerProvisioningBackendIdentifier
            if let rawBackend = optionValue("--backend", in: arguments) {
                guard let parsed = ConsumerProvisioningBackendIdentifier(rawValue: rawBackend) else {
                    throw ConsumerProvisioningFailure(
                        code: .unsupported,
                        stage: .preparingIdentities,
                        userMessage: "IOSSim could not select its signing pipeline.",
                        remediation: "Reinstall IOSSim and try again.",
                        developerDetail: "Unknown consumer provisioning backend."
                    )
                }
                backend = parsed
            } else {
                backend = .nativePersonalTeam
            }
            guard backend == .nativePersonalTeam else {
                throw ConsumerProvisioningFailure(
                    code: .unsupported,
                    stage: .preparingIdentities,
                    userMessage: "This IOSSim consumer build supports only native Personal Team setup.",
                    remediation: "Use the bundled IOSSim app; Xcode fallback is developer tooling only.",
                    developerDetail: "LEGACY_CONSUMER_BACKEND_FORBIDDEN: \(backend.rawValue)"
                )
            }
            let request = ConsumerProvisioningRequest(
                operation: operation,
                selectedDeviceIdentifier: device,
                selectedTeamIdentifier: team,
                allowFreshInstallAfterCrossTeamConflict: arguments.contains("--confirm-fresh-install"),
                backend: backend,
                generation: optionValue("--generation", in: arguments).flatMap(UInt64.init),
                reconciliationTrigger: optionValue("--trigger", in: arguments).flatMap(ConsumerReconciliationTrigger.init(rawValue:))
            )
            let keyed = try keyedProvisioningState(context: context, device: device, team: team)
            let result: SetupMutationResult<ConsumerProvisioningResult> = try await keyed.coordinator.withMutation(
                identity: keyed.identity,
                domain: resume ? "consumerResume" : "consumerProvision",
                safeDetail: "Provisioner mutation for the selected release, team, device, and artifact set."
            ) { _ in
                try await migrateMatchingLegacyStateIfNeeded(
                    into: keyed.domainStore,
                    device: device,
                    team: team
                )
                let provisioner = nativeConsumerProvisioner(context: context, stateStore: keyed.domainStore)
                return try await (resume ? provisioner.resumeSetup(request) : provisioner.provision(request))
            }
            try printJSON(ProvisionerOutput(
                ok: true,
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                data: result.value
            ))
            return 0
        } catch let failure as ConsumerProvisioningFailure {
            try? printJSON(ConsumerFailureOutput(
                ok: false,
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                error: failure
            ))
            return 1
        } catch let stateError as SetupStateError {
            let failure = setupStateFailure(stateError, stage: .failed)
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

    private func pairDevice(
        arguments: [String],
        context: RuntimeProvisioningContext
    ) async -> Int32 {
        guard let selectedIdentifier = optionValue("--device", in: arguments),
              !selectedIdentifier.isEmpty else {
            fputs("VEYA-DEVICE-001: choose one connected iPhone before requesting Trust.\n", stderr)
            return 2
        }
        do {
            let transport = DynamicNativeDeviceTransport()
            let bridge = IOSSimDeviceBridge(transport: transport)
            let matches = try await bridge.listDevices(timeout: .seconds(8)).filter {
                $0.identity.udid == selectedIdentifier
            }
            guard matches.count == 1, let descriptor = matches.first else {
                fputs("VEYA-DEVICE-002: the selected iPhone connection is missing or ambiguous.\n", stderr)
                return 2
            }
            guard descriptor.connection == .usb,
                  descriptor.identity.usbmuxIdentifier != nil else {
                fputs("VEYA-TRUST-001: connect the selected iPhone using USB for first computer Trust.\n", stderr)
                return 2
            }
            let artifactManifest = try context.loadManifest()
            let setupIdentity = try SetupIdentity.provisioning(
                manifest: artifactManifest,
                teamIdentifier: "preauthorization",
                deviceIdentifier: descriptor.identity.udid
            )
            let state = KeyedSetupStateStore()
            let result: SetupMutationResult<LockdownPairingReceipt> = try await state.withMutation(
                identity: setupIdentity,
                domain: "lockdownTrust",
                safeDetail: "Performed one Apple Lockdown Trust request on the exact USB connection."
            ) { _ in
                try await NativeLockdownPairingCoordinator(service: transport).pairOnce(
                    descriptor: descriptor
                )
            }
            try printJSON(ProvisionerOutput(
                ok: true,
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                data: result.value
            ))
            return 0
        } catch let stateError as SetupStateError {
            fputs("\(stateError.description)\n", stderr)
            return 1
        } catch NativeDeviceBridgeError.trustDenied {
            fputs("VEYA-TRUST-003: computer Trust was declined on the iPhone.\n", stderr)
            return 1
        } catch {
            fputs("VEYA-TRUST-005: \(Redactor.redact(String(describing: error)))\n", stderr)
            return 1
        }
    }

    private func consumerReconcile(
        arguments: [String],
        context: RuntimeProvisioningContext
    ) async -> Int32 {
        guard let device = optionValue("--device", in: arguments), !device.isEmpty,
              let team = optionValue("--team", in: arguments), !team.isEmpty else {
            let failure = ConsumerProvisioningFailure(
                code: .deviceSelectionRequired,
                stage: .physicalReconciliationStarted,
                userMessage: "IOSSim needs the selected iPhone and Personal Team to inspect setup.",
                remediation: "Reconnect the selected iPhone and try again.",
                developerDetail: "consumer-reconcile requires --device and --team."
            )
            try? printJSON(ConsumerFailureOutput(ok: false, schemaVersion: RuntimeProvisioning.helperSchemaVersion, error: failure))
            return 2
        }
        do {
            if let backend = optionValue("--backend", in: arguments),
               backend != ConsumerProvisioningBackendIdentifier.nativePersonalTeam.rawValue {
                throw ConsumerProvisioningFailure(
                    code: .unsupported,
                    stage: .physicalReconciliationStarted,
                    userMessage: "IOSSim physical reconciliation requires the native device backend.",
                    remediation: "Use the bundled IOSSim app.",
                    developerDetail: "LEGACY_CONSUMER_BACKEND_FORBIDDEN: \(backend)"
                )
            }
            let request = ConsumerProvisioningRequest(
                operation: .repair,
                selectedDeviceIdentifier: device,
                selectedTeamIdentifier: team,
                backend: .nativePersonalTeam,
                generation: optionValue("--generation", in: arguments).flatMap(UInt64.init),
                reconciliationTrigger: optionValue("--trigger", in: arguments)
                    .flatMap(ConsumerReconciliationTrigger.init(rawValue:)) ?? .setupStart
            )
            let keyed = try keyedProvisioningState(context: context, device: device, team: team)
            let result: SetupMutationResult<ConsumerSetupReconciliationResult> = try await keyed.coordinator.withMutation(
                identity: keyed.identity,
                domain: "consumerReconcile",
                safeDetail: "Reconciled exact physical inventory for the selected setup domain."
            ) { _ in
                try await migrateMatchingLegacyStateIfNeeded(
                    into: keyed.domainStore,
                    device: device,
                    team: team
                )
                return try await nativeConsumerProvisioner(
                    context: context,
                    stateStore: keyed.domainStore
                ).reconcileSetup(request)
            }
            try printJSON(ProvisionerOutput(ok: true, schemaVersion: RuntimeProvisioning.helperSchemaVersion, data: result.value))
            return 0
        } catch let failure as ConsumerProvisioningFailure {
            try? printJSON(ConsumerFailureOutput(ok: false, schemaVersion: RuntimeProvisioning.helperSchemaVersion, error: failure))
            return 1
        } catch let stateError as SetupStateError {
            let failure = setupStateFailure(stateError, stage: .physicalReconciliationResult)
            try? printJSON(ConsumerFailureOutput(ok: false, schemaVersion: RuntimeProvisioning.helperSchemaVersion, error: failure))
            return 1
        } catch {
            let failure = ConsumerProvisioningFailure(
                code: .unknown,
                stage: .physicalReconciliationResult,
                userMessage: "IOSSim could not reconcile setup.",
                remediation: "Reconnect the selected iPhone and try again.",
                developerDetail: String(describing: error)
            )
            try? printJSON(ConsumerFailureOutput(ok: false, schemaVersion: RuntimeProvisioning.helperSchemaVersion, error: failure))
            return 1
        }
    }

    private func nativeConsumerProvisioner(
        context: RuntimeProvisioningContext,
        stateStore: ConsumerProvisioningStateStore = ConsumerProvisioningStateStore()
    ) -> ConsumerArtifactProvisioner {
        let transport = DynamicNativeDeviceTransport()
        let applicationService = NativeApplicationService(transport: transport)
        let deviceBackend = IdeviceProvisioningBackend(applicationService: applicationService)
        let localDevVPNCoordinator = LocalDevVPNSetupCoordinator(service: applicationService)
        #if IOSSIM_LOCAL_TEST_ONLY
        let developerSupportCoordinator = NativeDeveloperServicesCoordinator(
            transport: transport,
            providers: [ThirdPartyMirrorDevelopmentProvider()],
            providerPolicy: .localTest
        )
        #else
        let developerSupportCoordinator = NativeDeveloperServicesCoordinator(
            transport: transport,
            providers: [ExistingAppleCacheProvider()],
            providerPolicy: .publicProduction
        )
        #endif
        let nativePairingOperations = NativeRemotePairingOperations(transport: transport)
        let pairingCoordinator = RemotePairingCoordinator(
            native: nativePairingOperations,
            delivery: NativeRemotePairingContainerDelivery(service: applicationService),
            proof: NativeDeveloperServicesRemotePairingProof(
                native: nativePairingOperations,
                developerServices: developerSupportCoordinator
            )
        )
        return ConsumerArtifactProvisioner(
            context: context,
            stateStore: stateStore,
            inventoryReader: NativeApplicationInventoryReader(
                service: applicationService,
                deviceBackend: deviceBackend
            ),
            deviceBackend: deviceBackend,
            runtimeConfigurationManager: NativeApplicationManager(service: applicationService),
            remotePairingCoordinator: pairingCoordinator,
            localDevVPNCoordinator: localDevVPNCoordinator,
            developerServicesCoordinator: developerSupportCoordinator
        )
    }

    private func keyedProvisioningState(
        context: RuntimeProvisioningContext,
        device: String,
        team: String
    ) throws -> KeyedProvisioningState {
        let artifactManifest = try context.loadManifest()
        let identity = try SetupIdentity.provisioning(
            manifest: artifactManifest,
            teamIdentifier: team,
            deviceIdentifier: device
        )
        let coordinator = KeyedSetupStateStore()
        let domainDirectory = coordinator.directory(for: identity)
            .appendingPathComponent("provisioning-domain-v4", isDirectory: true)
        return KeyedProvisioningState(
            identity: identity,
            coordinator: coordinator,
            domainStore: ConsumerProvisioningStateStore(directoryURL: domainDirectory)
        )
    }

    private func migrateMatchingLegacyStateIfNeeded(
        into destination: ConsumerProvisioningStateStore,
        device: String,
        team: String
    ) async throws {
        guard try await destination.loadManifest() == nil,
              let legacy = try await ConsumerProvisioningStateStore().loadManifest(),
              legacy.teamID == team,
              legacy.deviceIdentifierHash == PersonalTeamProvisioningPOC.deviceIdentifierHash(device) else {
            return
        }
        try await destination.saveManifest(legacy)
    }

    private func currentManifestForDevice(
        context: RuntimeProvisioningContext,
        device: String
    ) async throws -> ConsumerProvisioningManifest? {
        let expectedDeviceHash = PersonalTeamProvisioningPOC.deviceIdentifierHash(device)
        let root = KeyedSetupStateStore.defaultRootURL()
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var matches: [ConsumerProvisioningManifest] = []
        let artifactManifest = try context.loadManifest()
        for directory in directories {
            let domain = ConsumerProvisioningStateStore(
                directoryURL: directory.appendingPathComponent("provisioning-domain-v4", isDirectory: true)
            )
            guard let candidate = try? await domain.loadManifest(),
                  candidate.deviceIdentifierHash == expectedDeviceHash,
                  let expectedIdentity = try? SetupIdentity.provisioning(
                    manifest: artifactManifest,
                    teamIdentifier: candidate.teamID,
                    deviceIdentifier: device
                  ),
                  directory.lastPathComponent == expectedIdentity.key else {
                continue
            }
            matches.append(candidate)
        }
        if matches.count == 1 { return matches[0] }
        guard matches.isEmpty,
              let legacy = try await ConsumerProvisioningStateStore().loadManifest(),
              legacy.deviceIdentifierHash == expectedDeviceHash else {
            return nil
        }
        return legacy
    }

    private func setupStateFailure(
        _ error: SetupStateError,
        stage: ConsumerProvisioningStage
    ) -> ConsumerProvisioningFailure {
        ConsumerProvisioningFailure(
            code: error == .leaseHeld ? .operationInProgress : .manifestCorrupt,
            stage: stage,
            userMessage: error == .leaseHeld
                ? "IOSSim setup is already changing this iPhone."
                : "IOSSim setup state needs a safe repair.",
            remediation: error == .leaseHeld
                ? "Wait for the current setup operation to finish, then try again."
                : "Open Diagnostics and use Repair; IOSSim stopped before overwriting uncertain state.",
            developerDetail: error.description
        )
    }

    private func developerServicesDebug(arguments: [String]) async -> Int32 {
        let transport = DynamicNativeDeviceTransport()
        do {
            let devices = try await transport.listDevices(timeout: .seconds(8))
            let selector = optionValue("--device", in: arguments)
            let selected: NativeDeviceDescriptor?
            if let selector {
                selected = devices.first {
                    $0.identity.udid == selector
                        || RuntimeProvisioning.shortIdentifier($0.identity.udid) == selector
                }
            } else {
                selected = devices.count == 1 ? devices[0] : nil
            }
            guard let selected else {
                fputs("DEVICE_SELECTION_REQUIRED: connect exactly one iPhone or pass --device.\n", stderr)
                return 2
            }
            let receipt = try transport.developerServicesReadiness(on: selected.identity)
            try printJSON(ProvisionerOutput(
                ok: receipt.transportReady,
                schemaVersion: RuntimeProvisioning.helperSchemaVersion,
                data: DeveloperServicesDiagnosticOutput(
                    selectedDevice: RuntimeProvisioning.shortIdentifier(selected.identity.udid),
                    receipt: receipt
                )
            ))
            return receipt.transportReady ? 0 : 1
        } catch {
            fputs("\(Redactor.redact(String(describing: error)))\n", stderr)
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
