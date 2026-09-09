import Foundation

public struct NativeProvisioningProfileArtifact: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    /// SHA-256 of the DER development certificate selected by the native backend.
    public let certificateFingerprint: String
    public let provisionedDeviceIdentifierHash: String
    public let applicationIdentifierEntitlement: String
    public let applicationIdentifierPrefix: String
    public let getTaskAllow: Bool
    public let profileType: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let profileData: Data
}

public struct NativeProvisioningArtifacts: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let teamIdentifier: String
    /// SHA-256 of the certificate whose private key remains in the IOSSim-managed keychain item.
    public let certificateFingerprint: String
    /// Non-secret application tag used to query only the IOSSim-owned private key.
    /// Optional for schema-1 artifacts written before this continuity field existed.
    public let keyApplicationTagIdentifier: String?
    public let certificateExpiresAt: Date
    public let deviceIdentifierHash: String
    public let identifiers: PersonalTeamBundleIdentifierSet
    public let preparedAt: Date
    public let profiles: [NativeProvisioningProfileArtifact]

    public init(
        preparation: ExperimentalProvisioningPreparation,
        selectedDeviceIdentifier: String,
        preparedAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        teamIdentifier = preparation.team.id
        certificateFingerprint = preparation.identity.certificateFingerprint.uppercased()
        keyApplicationTagIdentifier = preparation.identity.keyApplicationTagIdentifier
        certificateExpiresAt = preparation.identity.certificateExpiration
        deviceIdentifierHash = PersonalTeamProvisioningPOC.deviceIdentifierHash(selectedDeviceIdentifier)
        identifiers = preparation.derivedIdentifiers
        self.preparedAt = preparedAt
        profiles = preparation.profiles.map {
            NativeProvisioningProfileArtifact(
                bundleIdentifier: $0.bundleIdentifier,
                teamIdentifier: $0.teamIdentifier,
                certificateFingerprint: $0.certificateFingerprint.uppercased(),
                provisionedDeviceIdentifierHash: PersonalTeamProvisioningPOC.deviceIdentifierHash(selectedDeviceIdentifier),
                applicationIdentifierEntitlement: $0.applicationIdentifierEntitlement,
                applicationIdentifierPrefix: $0.applicationIdentifierPrefix,
                getTaskAllow: $0.getTaskAllow,
                profileType: $0.profileType,
                issuedAt: $0.issuedAt,
                expiresAt: $0.expiresAt,
                profileData: $0.profileData
            )
        }
    }
}

/// Process-boundary handoff for native Personal Team output. Provisioning profile
/// payloads are sensitive local signing material, so they are kept out of command
/// line arguments and stored in an owner-only Application Support file. The
/// private key is never exported; it remains in the keychain.
public actor NativeProvisioningArtifactStore {
    public static let fileName = "native-provisioning-artifacts.json"

    private let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directoryURL = support.appendingPathComponent("IOSSim", isDirectory: true)
        }
    }

    public var artifactURL: URL {
        directoryURL.appendingPathComponent(Self.fileName)
    }

    public func save(
        _ preparation: ExperimentalProvisioningPreparation,
        selectedDeviceIdentifier: String,
        preparedAt: Date = Date()
    ) throws {
        let artifacts = NativeProvisioningArtifacts(
            preparation: preparation,
            selectedDeviceIdentifier: selectedDeviceIdentifier,
            preparedAt: preparedAt
        )
        try validateEnvelope(
            artifacts,
            teamIdentifier: preparation.team.id,
            selectedDeviceIdentifier: selectedDeviceIdentifier,
            now: preparedAt
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let temporaryURL = directoryURL.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifacts)
        try data.write(to: temporaryURL, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        if fileManager.fileExists(atPath: artifactURL.path) {
            _ = try fileManager.replaceItemAt(artifactURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: artifactURL)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifactURL.path)
    }

    public func load(
        teamIdentifier: String,
        selectedDeviceIdentifier: String,
        now: Date = Date()
    ) throws -> NativeProvisioningArtifacts {
        guard fileManager.fileExists(atPath: artifactURL.path) else {
            throw unavailable("Native Personal Team profiles were not preserved after provisioning.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: artifactURL)
        } catch {
            throw unavailable("Native Personal Team artifact handoff could not be read: \(error)")
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw unavailable("Native Personal Team artifact handoff exceeds the size limit.")
        }
        let artifacts: NativeProvisioningArtifacts
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            artifacts = try decoder.decode(NativeProvisioningArtifacts.self, from: data)
        } catch {
            throw unavailable("Native Personal Team artifact handoff is corrupt: \(error)")
        }
        try validateEnvelope(
            artifacts,
            teamIdentifier: teamIdentifier,
            selectedDeviceIdentifier: selectedDeviceIdentifier,
            now: now
        )
        return artifacts
    }

    /// Loads the single prepared native context for local-only work while its
    /// iPhone is temporarily disconnected. Device-bound operations still use
    /// the normal overload and revalidate the physical UDID after reconnect.
    public func load(teamIdentifier: String, now: Date = Date()) throws -> NativeProvisioningArtifacts {
        guard fileManager.fileExists(atPath: artifactURL.path) else {
            throw unavailable("Native Personal Team profiles were not preserved after provisioning.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: artifactURL)
        } catch {
            throw unavailable("Native Personal Team artifact handoff could not be read: \(error)")
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw unavailable("Native Personal Team artifact handoff exceeds the size limit.")
        }
        let artifacts: NativeProvisioningArtifacts
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            artifacts = try decoder.decode(NativeProvisioningArtifacts.self, from: data)
        } catch {
            throw unavailable("Native Personal Team artifact handoff is corrupt: \(error)")
        }
        try validateEnvelope(
            artifacts,
            teamIdentifier: teamIdentifier,
            selectedDeviceIdentifier: nil,
            now: now
        )
        return artifacts
    }

    private func validateEnvelope(
        _ artifacts: NativeProvisioningArtifacts,
        teamIdentifier: String,
        selectedDeviceIdentifier: String?,
        now: Date
    ) throws {
        let expectedIdentifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: teamIdentifier)
        let expectedDeviceHash = selectedDeviceIdentifier.map(PersonalTeamProvisioningPOC.deviceIdentifierHash)
        let requiredBundles = Set([expectedIdentifiers.main, expectedIdentifiers.runner])
        guard artifacts.schemaVersion == NativeProvisioningArtifacts.currentSchemaVersion,
              artifacts.teamIdentifier == teamIdentifier,
              artifacts.identifiers == expectedIdentifiers,
              artifacts.deviceIdentifierHash.count == 64,
              artifacts.deviceIdentifierHash.allSatisfy(\.isHexDigit),
              expectedDeviceHash.map({ artifacts.deviceIdentifierHash == $0 }) ?? true,
              artifacts.certificateFingerprint.count == 64,
              artifacts.certificateFingerprint.allSatisfy(\.isHexDigit),
              artifacts.keyApplicationTagIdentifier.map({
                  canonicalManagedKeyTag(Data($0.utf8), teamIdentifier: teamIdentifier) != nil
              }) ?? true,
              artifacts.certificateExpiresAt > now,
              Set(artifacts.profiles.map(\.bundleIdentifier)) == requiredBundles,
              artifacts.profiles.allSatisfy({
                  $0.teamIdentifier == teamIdentifier
                      && $0.certificateFingerprint == artifacts.certificateFingerprint
                      && $0.provisionedDeviceIdentifierHash == artifacts.deviceIdentifierHash
                      && $0.applicationIdentifierEntitlement == "\(teamIdentifier).\($0.bundleIdentifier)"
                      && $0.applicationIdentifierPrefix == teamIdentifier
                      && $0.getTaskAllow
                      && $0.profileType == "development"
                      && $0.issuedAt <= now
                      && $0.issuedAt >= artifacts.preparedAt.addingTimeInterval(-300)
                      && $0.expiresAt > now
                      && !$0.profileData.isEmpty
              }) else {
            throw unavailable("Native Personal Team artifacts do not match the current team, device, identity, or bundle IDs.")
        }
    }

    private func unavailable(_ detail: String) -> ConsumerProvisioningFailure {
        ConsumerProvisioningFailure(
            code: .profileUnavailable,
            stage: .preparingIdentities,
            userMessage: "IOSSim could not use its prepared iPhone signing profiles.",
            remediation: "Try Personal Team provisioning again; your Apple authorization remains valid.",
            developerDetail: detail
        )
    }
}
