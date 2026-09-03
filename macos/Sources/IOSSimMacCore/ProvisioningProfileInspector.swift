import Foundation

public enum ArtifactInstallEligibilityStatus: String, Codable, Equatable, Sendable {
    case installable = "INSTALLABLE"
    case deviceNotInProfile = "DEVICE_NOT_IN_PROFILE"
    case profileExpired = "PROFILE_EXPIRED"
    case signatureInvalid = "SIGNATURE_INVALID"
    case requiresResigning = "REQUIRES_RESIGNING"
    case unknown = "UNKNOWN"
}

public struct ProvisioningProfileSummary: Codable, Equatable, Sendable {
    public let status: ArtifactInstallEligibilityStatus
    public let profileType: String
    public let teamIdentifier: String?
    public let expirationDate: Date?
    public let provisionedDeviceCount: Int
    public let selectedDeviceEligible: Bool?
    public let applicationIdentifier: String?
    public let bundleIdentifier: String
    public let detail: String

    public init(
        status: ArtifactInstallEligibilityStatus,
        profileType: String,
        teamIdentifier: String?,
        expirationDate: Date?,
        provisionedDeviceCount: Int,
        selectedDeviceEligible: Bool?,
        applicationIdentifier: String?,
        bundleIdentifier: String,
        detail: String
    ) {
        self.status = status
        self.profileType = profileType
        self.teamIdentifier = teamIdentifier
        self.expirationDate = expirationDate
        self.provisionedDeviceCount = provisionedDeviceCount
        self.selectedDeviceEligible = selectedDeviceEligible
        self.applicationIdentifier = applicationIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.detail = detail
    }
}

public enum ProvisioningProfileInspector {
    public static func inspect(
        appURL: URL,
        bundleIdentifier: String,
        selectedDeviceIdentifier: String?,
        runner: ProcessRunner = ProcessRunner()
    ) async -> ProvisioningProfileSummary {
        let profileURL = appURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            return ProvisioningProfileSummary(
                status: .requiresResigning,
                profileType: "missing",
                teamIdentifier: nil,
                expirationDate: nil,
                provisionedDeviceCount: 0,
                selectedDeviceEligible: nil,
                applicationIdentifier: nil,
                bundleIdentifier: bundleIdentifier,
                detail: "No embedded.mobileprovision found."
            )
        }

        guard let plist = await decodeProfile(profileURL: profileURL, runner: runner) else {
            return ProvisioningProfileSummary(
                status: .signatureInvalid,
                profileType: "unreadable",
                teamIdentifier: nil,
                expirationDate: nil,
                provisionedDeviceCount: 0,
                selectedDeviceEligible: nil,
                applicationIdentifier: nil,
                bundleIdentifier: bundleIdentifier,
                detail: "embedded.mobileprovision could not be decoded."
            )
        }

        let provisionedDevices = plist["ProvisionedDevices"] as? [String]
        let provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        let expiration = plist["ExpirationDate"] as? Date
        let entitlements = plist["Entitlements"] as? [String: Any]
        let applicationIdentifier = entitlements?["application-identifier"] as? String
        let teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first
        let selectedEligible = selectedDeviceIdentifier.map { selected in
            provisionsAllDevices || provisionedDevices?.contains(selected) == true
        }
        let profileType = classifyProfile(plist: plist, provisionedDevices: provisionedDevices, provisionsAllDevices: provisionsAllDevices)

        let status: ArtifactInstallEligibilityStatus
        let detail: String
        if let expiration, expiration < Date() {
            status = .profileExpired
            detail = "Provisioning profile is expired."
        } else if selectedEligible == false {
            status = .deviceNotInProfile
            detail = "Selected iPhone is not included in the provisioning profile."
        } else {
            status = .installable
            detail = selectedEligible == true ? "Selected iPhone is included in the provisioning profile." : "Profile decoded; no device selected."
        }

        return ProvisioningProfileSummary(
            status: status,
            profileType: profileType,
            teamIdentifier: teamIdentifier,
            expirationDate: expiration,
            provisionedDeviceCount: provisionedDevices?.count ?? 0,
            selectedDeviceEligible: selectedEligible,
            applicationIdentifier: applicationIdentifier,
            bundleIdentifier: bundleIdentifier,
            detail: detail
        )
    }

    private static func decodeProfile(profileURL: URL, runner: ProcessRunner) async -> [String: Any]? {
        if let data = try? Data(contentsOf: profileURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            return plist
        }
        let securityURL = URL(fileURLWithPath: "/usr/bin/security")
        guard FileManager.default.isExecutableFile(atPath: securityURL.path),
              let result = try? await runner.run(
                executableURL: securityURL,
                arguments: ["cms", "-D", "-i", profileURL.path],
                workingDirectory: profileURL.deletingLastPathComponent(),
                environment: RuntimeProvisioning.deterministicEnvironment()
              ),
              result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    private static func classifyProfile(
        plist: [String: Any],
        provisionedDevices: [String]?,
        provisionsAllDevices: Bool
    ) -> String {
        let entitlements = plist["Entitlements"] as? [String: Any]
        let getTaskAllow = entitlements?["get-task-allow"] as? Bool
        if provisionsAllDevices {
            return "enterprise"
        }
        if provisionedDevices?.isEmpty == false {
            return getTaskAllow == true ? "development" : "ad-hoc"
        }
        if plist["ProvisionedDevices"] == nil {
            return "app-store"
        }
        return "unknown"
    }
}

public enum ArtifactEligibilityEvaluator {
    public static func summaries(
        resourcesURL: URL,
        manifest: ArtifactManifest,
        selectedDeviceIdentifier: String?,
        runner: ProcessRunner = ProcessRunner()
    ) async -> [ProvisioningProfileSummary] {
        var summaries: [ProvisioningProfileSummary] = []
        for component in manifest.components {
            summaries.append(await ProvisioningProfileInspector.inspect(
                appURL: resourcesURL.appendingPathComponent(component.relativePath),
                bundleIdentifier: component.bundleIdentifier,
                selectedDeviceIdentifier: selectedDeviceIdentifier,
                runner: runner
            ))
        }
        return summaries
    }

    public static func aggregateStatus(_ summaries: [ProvisioningProfileSummary]) -> ArtifactInstallEligibilityStatus {
        for status in [ArtifactInstallEligibilityStatus.signatureInvalid, .profileExpired, .deviceNotInProfile, .requiresResigning, .unknown] {
            if summaries.contains(where: { $0.status == status }) {
                return status
            }
        }
        return .installable
    }
}
