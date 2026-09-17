import Foundation

public struct SupportBundleExportResult: Codable, Equatable, Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
}

private struct SupportEnvironment: Codable {
    let iPhoneAppVersion: String?
    let macAppVersion: String?
    let macBuildNumber: String?
    let releaseVariant: String?
    let sourceCommit: String?
    let sourceCommitComponent: String
    let payloadSourceCommit: String?
    let guiSourceCommit: String?
    let helperSourceCommit: String?
    let sourceDirty: Bool?
    let guiSourceHead: String?
    let guiSourceDirty: Bool?
    let helperSourceHead: String?
    let helperSourceDirty: Bool?
    let payloadSourceHead: String?
    let payloadSourceDirty: Bool?
    let payloadSourceTreeSHA256: String?
    let payloadBuildTimestamp: String?
    let payloadBuildVariant: String?
    let bridgeVersion: String?
    let ideviceRevision: String?
    let buildVariant: String?
    let setupEngine: String?
    let discoveryBackend: String?
    let installationBackend: String?
    let launchBackend: String?
    let developerServicesBackend: String?
    let houseArrestBackend: String?
    let pairingBackend: String?
    let ddiBackend: String?
    let payloadSource: String?
    let payloadManifestVersion: String?
    let setupStateSchemaVersion: Int?
    let provisioningManifestSchemaVersion: Int?
    let setupCheckpoint: String?
    let derivedCheckpoint: String?
    let checkpointDerivedOrPersisted: String
    let reconciliationResult: String?
    let selectedDeviceIdentityType: String
    let legacyFallbackUsed: Bool
    let consumerBuildAttempted: Bool
    let buildTimestamp: String?
    let runningExecutablePathCategory: String
    let macOSVersion: String
    let provisioningBackend: String
    let xcodePresent: Bool
    let zeroXcodeMode: Bool
    let authMethodCategory: String?
    let authSessionValid: Bool
    let authClientIdentityVersion: String?
    let authSessionExpiration: Date?
    let lastProvisioningStage: String?
    let resumeCheckpoint: String?
    let deviceLock: String
    let computerTrust: String
    let developerMode: String
    let developerModeStatus: String
    let ddiStatus: String
    let ddiAssetVersion: String?
    let ddiMountStatus: String
    let coreDeviceProxyStatus: String
    let softwareTunnelStatus: String
    let rsdStatus: String
    let remoteXPCStatus: String
    let appServiceStatus: String
    let appLaunchStatus: String
    let runtimeConfigStatus: String
    let houseArrestStatus: String
    let pairingStatus: String
    let pairingDeliveryStatus: String
    let pairingReceiptStatus: String
    let setupReadyForRuntime: Bool
    let developerProfileTrust: String?
    let installationInventoryRetryCount: Int?
    let installationInventoryElapsedMilliseconds: Int?
    let installationInventoryReason: String?
    let installationSelectedDeviceMatches: Bool?
    let installationMainPresent: Bool?
    let installationRunnerPresent: Bool?
    let runtimeConfigurationWrite: String
    let runtimeConfigurationVerification: String
    let xcodeVersion: String?
    let deviceName: String?
    let deviceModel: String?
    let deviceOSVersion: String?
}

private struct EmbeddedBuildProvenance: Decodable {
    let guiSourceCommit: String
    let helperSourceCommit: String
    let sourceDirty: Bool
    let bridgeVersion: String
    let ideviceRevision: String
    let buildVariant: String
    let setupEngine: String
    let discoveryBackend: String
    let installationBackend: String
    let launchBackend: String?
    let developerServicesBackend: String?
    let houseArrestBackend: String?
    let pairingBackend: String?
    let ddiBackend: String?
    let payloadSource: String?
    let payloadManifestVersion: String?
    let payloadSourceCommit: String?
    let guiSourceHead: String?
    let guiSourceDirty: Bool?
    let helperSourceHead: String?
    let helperSourceDirty: Bool?
    let payloadSourceHead: String?
    let payloadSourceDirty: Bool?
    let payloadSourceTreeSHA256: String?
    let payloadBuildTimestamp: String?
    let payloadBuildVariant: String?
    let setupStateSchema: Int?
    let legacyFallbackUsed: Bool?
    let consumerBuildAttempted: Bool?
    let buildTimestamp: String

    static func load(resourcesURL: URL?, fileManager: FileManager) -> Self? {
        guard let url = resourcesURL?.appendingPathComponent("BuildProvenance.plist"),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Self.self, from: data)
    }
}

private struct SanitizedSupportDocument: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let includedFiles: [String]
    let environment: SupportEnvironment
    let provisioning: ConsumerProvisioningManifest?
    let provisioningEvents: [ProvisioningLogEvent]
    let diagnostics: [SupportDiagnosticEvent]
    let nativePersonalTeam: ApplePersonalTeamDiagnosticSnapshot?
    let deviceDiscovery: SupportDeviceDiscovery?
    let notes: [String]
}

private struct SupportDiagnosticEvent: Codable {
    let timestamp: Date
    let descriptor: VeyaDiagnosticDescriptor
}

private struct SupportDeviceDiscovery: Codable {
    let rawDeviceCount: Int
    let returnedDeviceCount: Int
    let diagnostics: [DeviceDiscoveryDiagnostic]
}

public enum SupportBundleExporter {
    public static func export(
        to outputURL: URL,
        release: ReleaseManifest? = nil,
        stateStore: ConsumerProvisioningStateStore = ConsumerProvisioningStateStore(),
        authorizationSessionStore: any AppleAuthorizationSessionStoring = KeychainAppleAuthorizationSessionStore(),
        runner: ProcessRunner = ProcessRunner(),
        resourcesURL: URL? = nil,
        fileManager: FileManager = .default
    ) async throws -> SupportBundleExportResult {
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("iossim-support-\(UUID().uuidString)", isDirectory: true)
        let folder = workspace.appendingPathComponent("IOSSim Support", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let manifest = try? await stateStore.loadManifest()
        let events = await stateStore.loadEvents(limit: 500)
        let latestReconciliation = events.last(where: { $0.stage == .physicalReconciliationResult })
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let preference = ConsumerProvisioningBackendPreference.selected()
        let xcodePresent = XcodePresenceDetector.isPresent(fileManager: fileManager)
        let selection = resourcesURL.map {
            RuntimeProvisioning.consumerBackendSelection(resourcesURL: $0, fileManager: fileManager)
        } ?? ConsumerProvisioningBackendSelector.select(
            preference: preference,
            capabilities: ConsumerProvisioningCapabilities(
                bundledDeviceBridgeReady: false,
                nativeAppleAuthenticationReady: ZeroXcodeCapabilityPolicy.livePersonalTeamExperimentEnabled,
                nativePersonalTeamProvisioningReady: ZeroXcodeCapabilityPolicy.livePersonalTeamExperimentEnabled,
                directSigningReady: ZeroXcodeCapabilityPolicy.livePersonalTeamExperimentEnabled,
                xcodePresent: xcodePresent
            )
        )
        let buildProvenance = EmbeddedBuildProvenance.load(resourcesURL: resourcesURL, fileManager: fileManager)
        let authMetadata = try? authorizationSessionStore.loadMetadata()
        let nativeDiagnostics = ApplePersonalTeamDiagnosticsStore().load()
        let authSessionValid = nativeDiagnostics?.sessionValid
            ?? authMetadata.map { $0.expiresAt.map { $0 > Date() } ?? true }
            ?? false
        let deviceDiscovery: SupportDeviceDiscovery?
        if let resourcesURL {
            let snapshot = await AppleDeviceTool.discoverDeviceSnapshot(
                context: RuntimeProvisioningContext(resourcesURL: resourcesURL, runner: runner)
            )
            deviceDiscovery = SupportDeviceDiscovery(
                rawDeviceCount: snapshot.rawDeviceCount,
                returnedDeviceCount: snapshot.devices.count,
                diagnostics: snapshot.diagnostics
            )
        } else {
            deviceDiscovery = nil
        }
        let diagnostics = events.compactMap { event -> SupportDiagnosticEvent? in
            guard let code = event.errorCode else { return nil }
            return SupportDiagnosticEvent(
                timestamp: event.timestamp,
                descriptor: VeyaErrorTaxonomy.descriptor(
                    for: code,
                    stage: event.stage,
                    developerDetail: event.detail ?? ""
                )
            )
        }
        let document = SanitizedSupportDocument(
            schemaVersion: 8,
            generatedAt: Date(),
            includedFiles: ["support.json"],
            environment: SupportEnvironment(
                iPhoneAppVersion: manifest?.appVersion,
                macAppVersion: release?.macVersion,
                macBuildNumber: release?.buildNumber,
                releaseVariant: release?.variant,
                sourceCommit: buildProvenance?.guiSourceCommit ?? release?.sourceCommit,
                sourceCommitComponent: buildProvenance == nil ? "DEVICE_PAYLOAD_LEGACY" : "GUI",
                payloadSourceCommit: buildProvenance?.payloadSourceCommit ?? release?.sourceCommit,
                guiSourceCommit: buildProvenance?.guiSourceCommit,
                helperSourceCommit: buildProvenance?.helperSourceCommit,
                sourceDirty: buildProvenance?.sourceDirty,
                guiSourceHead: buildProvenance?.guiSourceHead ?? buildProvenance?.guiSourceCommit,
                guiSourceDirty: buildProvenance?.guiSourceDirty ?? buildProvenance?.sourceDirty,
                helperSourceHead: buildProvenance?.helperSourceHead ?? buildProvenance?.helperSourceCommit,
                helperSourceDirty: buildProvenance?.helperSourceDirty ?? buildProvenance?.sourceDirty,
                payloadSourceHead: buildProvenance?.payloadSourceHead ?? release?.payloadSourceHead ?? release?.sourceCommit,
                payloadSourceDirty: buildProvenance?.payloadSourceDirty ?? release?.payloadSourceDirty ?? release?.sourceDirty,
                payloadSourceTreeSHA256: buildProvenance?.payloadSourceTreeSHA256 ?? release?.payloadSourceTreeSHA256,
                payloadBuildTimestamp: buildProvenance?.payloadBuildTimestamp ?? release?.payloadBuildTimestamp ?? release?.buildTimestamp,
                payloadBuildVariant: buildProvenance?.payloadBuildVariant ?? release?.payloadBuildVariant,
                bridgeVersion: buildProvenance?.bridgeVersion,
                ideviceRevision: buildProvenance?.ideviceRevision,
                buildVariant: buildProvenance?.buildVariant,
                setupEngine: buildProvenance?.setupEngine,
                discoveryBackend: buildProvenance?.discoveryBackend,
                installationBackend: buildProvenance?.installationBackend,
                launchBackend: buildProvenance?.launchBackend,
                developerServicesBackend: buildProvenance?.developerServicesBackend,
                houseArrestBackend: buildProvenance?.houseArrestBackend,
                pairingBackend: buildProvenance?.pairingBackend,
                ddiBackend: buildProvenance?.ddiBackend,
                payloadSource: buildProvenance?.payloadSource,
                payloadManifestVersion: buildProvenance?.payloadManifestVersion,
                setupStateSchemaVersion: buildProvenance?.setupStateSchema ?? SetupStateSnapshot.currentSchemaVersion,
                provisioningManifestSchemaVersion: manifest?.schemaVersion,
                setupCheckpoint: manifest?.effectiveSetupCheckpoint.rawValue,
                derivedCheckpoint: latestReconciliation?.resumeCheckpoint?.rawValue,
                checkpointDerivedOrPersisted: latestReconciliation == nil ? "PERSISTED_HINT" : "PHYSICAL_RECONCILED",
                reconciliationResult: latestReconciliation?.detail,
                selectedDeviceIdentityType: "LOCKDOWN_UDID",
                legacyFallbackUsed: buildProvenance?.legacyFallbackUsed ?? false,
                consumerBuildAttempted: buildProvenance?.consumerBuildAttempted ?? false,
                buildTimestamp: buildProvenance?.buildTimestamp,
                runningExecutablePathCategory: resourcesURL == nil ? "UNKNOWN" : "BUNDLED_APP_HELPER",
                macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                provisioningBackend: selection.backend?.rawValue ?? "NONE",
                xcodePresent: xcodePresent,
                zeroXcodeMode: selection.zeroXcodeMode,
                authMethodCategory: authMetadata == nil ? nil : AppleAuthorizationMethodCategory.privateGrandSlamSRP.rawValue,
                authSessionValid: authSessionValid,
                authClientIdentityVersion: authMetadata?.clientIdentityVersion,
                authSessionExpiration: authMetadata?.expiresAt,
                lastProvisioningStage: events.last?.stage.rawValue,
                resumeCheckpoint: manifest?.effectiveSetupCheckpoint.rawValue,
                deviceLock: prerequisiteStatus(events: events, requiredCode: .deviceLocked),
                computerTrust: prerequisiteStatus(events: events, requiredCode: .computerTrustRequired),
                developerMode: prerequisiteStatus(events: events, requiredCode: .developerModeRequired),
                developerModeStatus: prerequisiteStatus(events: events, requiredCode: .developerModeRequired),
                ddiStatus: ddiStatus(events: events),
                ddiAssetVersion: nil,
                ddiMountStatus: stageStatus(.ddiMountSucceeded, events: events),
                coreDeviceProxyStatus: stageOrFailureStatus(
                    .coreDeviceProxyReady, failure: .coreDeviceProxyFailed, events: events
                ),
                softwareTunnelStatus: stageOrFailureStatus(
                    .softwareTunnelReady, failure: .softwareTunnelFailed, events: events
                ),
                rsdStatus: stageOrFailureStatus(.rsdReady, failure: .rsdUnavailable, events: events),
                remoteXPCStatus: stageOrFailureStatus(.remoteXPCReady, failure: .remoteXPCFailed, events: events),
                appServiceStatus: stageOrFailureStatus(
                    .appServiceReady, failure: .appServiceUnavailable, events: events
                ),
                appLaunchStatus: stageStatus(.mainNativeLaunchSucceeded, events: events),
                runtimeConfigStatus: runtimeVerificationStatus(manifest: manifest, events: events),
                houseArrestStatus: stageOrFailureStatus(
                    .houseArrestReady, failure: .houseArrestUnavailable, events: events
                ),
                pairingStatus: pairingStatus(manifest: manifest, events: events),
                pairingDeliveryStatus: stageOrFailureStatus(
                    .pairingDeliverySucceeded, failure: .pairingDeliveryFailed, events: events
                ),
                pairingReceiptStatus: stageOrFailureStatus(
                    .pairingReceiptVerified, failure: .pairingReceiptFailed, events: events
                ),
                setupReadyForRuntime: manifest?.effectiveSetupCheckpoint.setupIsReadyForRuntime == true,
                developerProfileTrust: manifest?.developerProfileTrustStatus?.rawValue,
                installationInventoryRetryCount: manifest?.installationInventory?.retryCount,
                installationInventoryElapsedMilliseconds: manifest?.installationInventory?.elapsedMilliseconds,
                installationInventoryReason: manifest?.installationInventory?.safeReason,
                installationSelectedDeviceMatches: manifest?.installationInventory?.selectedDeviceMatches,
                installationMainPresent: manifest?.installationInventory?.mainPresent,
                installationRunnerPresent: manifest?.installationInventory?.runnerPresent,
                runtimeConfigurationWrite: runtimeWriteStatus(manifest: manifest, events: events),
                runtimeConfigurationVerification: runtimeVerificationStatus(manifest: manifest, events: events),
                xcodeVersion: selection.backend.map {
                    [.xcodeFallback, .xcodeInvisible].contains($0)
                } == true
                    ? await xcodeVersion(runner: runner)
                    : nil,
                deviceName: manifest?.deviceName,
                deviceModel: manifest?.deviceModel,
                deviceOSVersion: manifest?.deviceOSVersion
            ),
            provisioning: manifest,
            provisioningEvents: events,
            diagnostics: diagnostics,
            nativePersonalTeam: nativeDiagnostics,
            deviceDiscovery: deviceDiscovery,
            notes: [
                "Local-only sanitized support export.",
                "Apple credentials, signing private keys, provisioning payloads, and RPPairing material are excluded.",
                "No-Xcode physical device discovery has been observed on the current test Mac and iPhone.",
                "Native installation, native app launch, runtime-location, renewal, clean-Mac, and public-release qualification require separate physical evidence."
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(document)
        guard let encodedText = String(data: encoded, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let sanitizedData = Data(Redactor.redact(encodedText).utf8)
        let secretFindings = SupportSecretScanner.findings(in: sanitizedData)
        guard secretFindings.isEmpty else {
            throw ConsumerProvisioningFailure(
                code: .artifactInvalid,
                stage: .failed,
                userMessage: "IOSSim could not create a safe support report.",
                remediation: "Try exporting the support report again. No report was saved.",
                developerDetail: "VEYA-INTEGRITY-007: support export rejected by secret scanner categories=\(secretFindings.joined(separator: ","))"
            )
        }
        try sanitizedData.write(to: folder.appendingPathComponent("support.json"), options: [.atomic])

        if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, outputURL.path],
            workingDirectory: workspace,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result.exitCode == 0 else { throw ProcessFailure(commandName: "support-bundle", result: result) }
        return SupportBundleExportResult(url: outputURL)
    }

    private static func prerequisiteStatus(
        events: [ProvisioningLogEvent],
        requiredCode: ConsumerProvisioningErrorCode
    ) -> String {
        events.last(where: { $0.errorCode == requiredCode }) == nil ? "UNKNOWN" : "LAST_OBSERVED_REQUIRED"
    }

    private static func stageStatus(
        _ stage: ConsumerProvisioningStage,
        events: [ProvisioningLogEvent]
    ) -> String {
        guard let event = events.last(where: { $0.stage == stage }) else { return "NOT_OBSERVED" }
        return event.result.rawValue
    }

    private static func stageOrFailureStatus(
        _ stage: ConsumerProvisioningStage,
        failure: ConsumerProvisioningErrorCode,
        events: [ProvisioningLogEvent]
    ) -> String {
        let success = events.last(where: { $0.stage == stage })
        let failed = events.last(where: { $0.errorCode == failure })
        if let success, failed == nil || success.timestamp > failed!.timestamp { return success.result.rawValue }
        if failed != nil { return "FAILED" }
        return "NOT_OBSERVED"
    }

    private static func ddiStatus(events: [ProvisioningLogEvent]) -> String {
        if events.last(where: { $0.stage == .ddiMountSucceeded && $0.result == .passed }) != nil {
            return "DDI_MOUNTED"
        }
        if events.last(where: { $0.stage == .ddiNotRequired && $0.result == .passed }) != nil {
            return "DDI_NOT_REQUIRED"
        }
        if events.last(where: { $0.stage == .ddiRequired }) != nil { return "DDI_REQUIRED" }
        return "DDI_UNKNOWN"
    }

    private static func pairingStatus(
        manifest: ConsumerProvisioningManifest?,
        events: [ProvisioningLogEvent]
    ) -> String {
        if manifest?.effectiveSetupCheckpoint.remotePairingIsVerified == true { return "VERIFIED" }
        if events.last(where: { $0.errorCode == .remotePairingFailed }) != nil { return "FAILED" }
        if events.last(where: { $0.stage == .pairingCreated && $0.result == .passed }) != nil { return "CREATED" }
        if events.last(where: { $0.stage == .pairingReused && $0.result == .passed }) != nil { return "REUSED" }
        return "NOT_OBSERVED"
    }

    private static func runtimeWriteStatus(
        manifest: ConsumerProvisioningManifest?,
        events: [ProvisioningLogEvent]
    ) -> String {
        if let checkpoint = manifest?.effectiveSetupCheckpoint,
           [.runtimeConfigurationWritten, .runtimeConfigurationVerified, .complete].contains(checkpoint) {
            return "SUCCEEDED"
        }
        return events.last(where: {
            [.runtimeConfigurationWriteFailed, .nativeLaunchUnavailable].contains($0.errorCode)
        }) == nil
            ? "NOT_STARTED"
            : "FAILED"
    }

    private static func runtimeVerificationStatus(
        manifest: ConsumerProvisioningManifest?,
        events: [ProvisioningLogEvent]
    ) -> String {
        if manifest?.effectiveSetupCheckpoint.runtimeConfigurationIsVerified == true {
            return "SUCCEEDED"
        }
        return events.last(where: {
            [.runtimeConfigurationReadbackFailed, .nativeContainerReadFailed].contains($0.errorCode)
        }) == nil
            ? "NOT_STARTED"
            : "FAILED"
    }

    private static func xcodeVersion(runner: ProcessRunner) async -> String {
        guard let result = try? await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-version"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: RuntimeProvisioning.deterministicEnvironment()
        ), result.exitCode == 0 else { return "Unavailable" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
