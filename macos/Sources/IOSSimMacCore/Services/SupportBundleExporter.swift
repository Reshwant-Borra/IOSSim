import Foundation

public struct SupportBundleExportResult: Codable, Equatable, Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
}

private struct SupportEnvironment: Codable {
    let appVersion: String?
    let macOSVersion: String
    let xcodeVersion: String
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
    let notes: [String]
}

public enum SupportBundleExporter {
    public static func export(
        to outputURL: URL,
        stateStore: ConsumerProvisioningStateStore = ConsumerProvisioningStateStore(),
        runner: ProcessRunner = ProcessRunner(),
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
        let document = SanitizedSupportDocument(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: SupportEnvironment(
                appVersion: manifest?.appVersion,
                macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                xcodeVersion: await xcodeVersion(runner: runner),
                deviceName: manifest?.deviceName,
                deviceModel: manifest?.deviceModel,
                deviceOSVersion: manifest?.deviceOSVersion
            ),
            provisioning: manifest,
            provisioningEvents: events,
            notes: [
                "Local-only sanitized support export.",
                "Apple credentials, signing private keys, provisioning payloads, and RPPairing material are excluded.",
                "True Personal Team profile-expiration extension remains pending physical validation."
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
