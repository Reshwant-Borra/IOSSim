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
    public let personalTeam: Bool?
    public let teamIdentifier: String?
    public let creationDate: Date?
    public let expirationDate: Date?
    public let remainingValiditySeconds: TimeInterval?
    public let provisionedDeviceCount: Int
    public let selectedDeviceEligible: Bool?
    public let applicationIdentifier: String?
    public let bundleIdentifier: String
    public let refreshRecommended: Bool
    public let detail: String

    public init(
        status: ArtifactInstallEligibilityStatus,
        profileType: String,
        personalTeam: Bool? = nil,
        teamIdentifier: String?,
        creationDate: Date? = nil,
        expirationDate: Date?,
        remainingValiditySeconds: TimeInterval? = nil,
        provisionedDeviceCount: Int,
        selectedDeviceEligible: Bool?,
        applicationIdentifier: String?,
        bundleIdentifier: String,
        refreshRecommended: Bool = false,
        detail: String
    ) {
        self.status = status
        self.profileType = profileType
        self.personalTeam = personalTeam
        self.teamIdentifier = teamIdentifier
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.remainingValiditySeconds = remainingValiditySeconds
        self.provisionedDeviceCount = provisionedDeviceCount
        self.selectedDeviceEligible = selectedDeviceEligible
        self.applicationIdentifier = applicationIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.refreshRecommended = refreshRecommended
        self.detail = detail
    }
}

public enum ProvisioningProfileInspector {
    public static func inspect(
        appURL: URL,
        bundleIdentifier: String,
        selectedDeviceIdentifier: String?
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

        guard let plist = decodeProfile(profileURL: profileURL) else {
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
        let creation = plist["CreationDate"] as? Date
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
            personalTeam: inferPersonalTeam(plist: plist, profileType: profileType, creationDate: creation, expirationDate: expiration),
            teamIdentifier: teamIdentifier,
            creationDate: creation,
            expirationDate: expiration,
            remainingValiditySeconds: expiration.map { $0.timeIntervalSince(Date()) },
            provisionedDeviceCount: provisionedDevices?.count ?? 0,
            selectedDeviceEligible: selectedEligible,
            applicationIdentifier: applicationIdentifier,
            bundleIdentifier: bundleIdentifier,
            refreshRecommended: ProvisioningExpiration(
                creationDate: creation,
                expirationDate: expiration
            ).refreshRecommended(),
            detail: detail
        )
    }

    /// Plain plist, or the signature-checked content of a CMS profile decoded in process (no `security cms`).
    private static func decodeProfile(profileURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: profileURL) else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            return plist
        }
        return try? developmentProfileContent(data)
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

    private static func inferPersonalTeam(
        plist: [String: Any],
        profileType: String,
        creationDate: Date?,
        expirationDate: Date?
    ) -> Bool? {
        let profileName = plist["Name"] as? String
        let teamName = plist["TeamName"] as? String
        let joined = [profileName, teamName].compactMap { $0 }.joined(separator: " ").lowercased()
        if joined.contains("personal team") {
            return true
        }
        guard profileType == "development", let creationDate, let expirationDate else {
            return nil
        }
        let lifetime = expirationDate.timeIntervalSince(creationDate)
        if lifetime > 0 && lifetime <= 8.25 * 24 * 60 * 60 {
            return true
        }
        return nil
    }
}

public enum ArtifactEligibilityEvaluator {
    public static func summaries(
        resourcesURL: URL,
        manifest: ArtifactManifest,
        selectedDeviceIdentifier: String?
    ) async -> [ProvisioningProfileSummary] {
        var summaries: [ProvisioningProfileSummary] = []
        for component in manifest.components {
            summaries.append(await ProvisioningProfileInspector.inspect(
                appURL: resourcesURL.appendingPathComponent(component.relativePath),
                bundleIdentifier: component.bundleIdentifier,
                selectedDeviceIdentifier: selectedDeviceIdentifier
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
