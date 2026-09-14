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

private struct SanitizedSupportDocument: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let environment: SupportEnvironment
    let provisioning: ConsumerProvisioningManifest?
    let provisioningEvents: [ProvisioningLogEvent]
    let nativePersonalTeam: ApplePersonalTeamDiagnosticSnapshot?
    let deviceDiscovery: SupportDeviceDiscovery?
    let notes: [String]
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
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let preference = ConsumerProvisioningBackendPreference.selected()
        let xcodePresent = XcodePresenceDetector.isPresent(fileManager: fileManager)
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: preference,
            capabilities: ConsumerProvisioningCapabilities(
                bundledDeviceBridgeReady: false,
                nativeAppleAuthenticationReady: ZeroXcodeCapabilityPolicy.livePersonalTeamExperimentEnabled,
                nativePersonalTeamProvisioningReady: ZeroXcodeCapabilityPolicy.livePersonalTeamExperimentEnabled,
                directSigningReady: ZeroXcodeCapabilityPolicy.livePersonalTeamExperimentEnabled,
                xcodePresent: xcodePresent
            )
        )
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
        let document = SanitizedSupportDocument(
            schemaVersion: 4,
            generatedAt: Date(),
            environment: SupportEnvironment(
                iPhoneAppVersion: manifest?.appVersion,
                macAppVersion: release?.macVersion,
                macBuildNumber: release?.buildNumber,
                releaseVariant: release?.variant,
                sourceCommit: release?.sourceCommit,
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
            nativePersonalTeam: nativeDiagnostics,
            deviceDiscovery: deviceDiscovery,
            notes: [
                "Local-only sanitized support export.",
                "Apple credentials, signing private keys, provisioning payloads, and RPPairing material are excluded.",
                "Physical Personal Team provisioning, signing, main installation, runner installation, and setup completion have been observed on the current test Mac and iPhone.",
                "This evidence does not claim clean-Mac, no-Xcode, runtime-location, or public-release qualification."
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: folder.appendingPathComponent("support.json"), options: [.atomic])

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

    private static func runtimeWriteStatus(
        manifest: ConsumerProvisioningManifest?,
        events: [ProvisioningLogEvent]
    ) -> String {
        if let checkpoint = manifest?.effectiveSetupCheckpoint,
           [.runtimeConfigurationWritten, .runtimeConfigurationVerified, .complete].contains(checkpoint) {
            return "SUCCEEDED"
        }
        return events.last(where: { $0.errorCode == .runtimeConfigurationWriteFailed }) == nil
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
        return events.last(where: { $0.errorCode == .runtimeConfigurationReadbackFailed }) == nil
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
