import CryptoKit
import Foundation

public enum PersonalTeamProvisioningPOC {
    public static let schemaVersion = 1
    public static let refreshRecommendedInterval: TimeInterval = 48 * 60 * 60
    public static let bundleIdentifierPrefix = "com.personalteam.iossim"

    public static func derivedBundleIdentifiers(teamIdentifier: String) throws -> PersonalTeamBundleIdentifierSet {
        try PersonalTeamBundleIdentifierSet(teamIdentifier: teamIdentifier)
    }

    public static func refreshPlan(
        manifest: PersonalTeamProvisioningManifest,
        currentTeamIdentifier: String,
        currentDeviceIdentifierHash: String,
        now: Date = Date()
    ) -> RefreshPlan {
        if manifest.teamIdentifier != currentTeamIdentifier {
            return RefreshPlan(state: .teamChanged, refreshRecommended: false, earliestExpiration: nil)
        }
        if manifest.deviceIdentifierHash != currentDeviceIdentifierHash {
            return RefreshPlan(state: .deviceMismatch, refreshRecommended: false, earliestExpiration: nil)
        }
        guard let earliest = manifest.earliestExpiration else {
            return RefreshPlan(state: .refreshRequired, refreshRecommended: true, earliestExpiration: nil)
        }
        if earliest <= now {
            return RefreshPlan(state: .expired, refreshRecommended: true, earliestExpiration: earliest)
        }
        let remaining = earliest.timeIntervalSince(now)
        if remaining <= refreshRecommendedInterval {
            return RefreshPlan(state: .refreshRecommended, refreshRecommended: true, earliestExpiration: earliest)
        }
        return RefreshPlan(state: .valid, refreshRecommended: false, earliestExpiration: earliest)
    }

    public static func deviceIdentifierHash(_ rawIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(rawIdentifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func validateNoSourceBundleIdentifierMutation(_ manifest: PersonalTeamProvisioningManifest) throws {
        let expected = ProtectedSourceBundleIdentifiers.default
        guard manifest.sourceMainBundleID == expected.main else {
            throw PersonalTeamProvisioningError.sourceBundleIdentifierMutated(role: "iosMain")
        }
        guard manifest.sourceRunnerBundleID == expected.runner else {
            throw PersonalTeamProvisioningError.sourceBundleIdentifierMutated(role: "locationControlRunner")
        }
        guard manifest.sourceWitnessBundleID == expected.witness else {
            throw PersonalTeamProvisioningError.sourceBundleIdentifierMutated(role: "locationWitness")
        }
    }
}

public struct ProtectedSourceBundleIdentifiers: Codable, Equatable, Sendable {
    public static let `default` = ProtectedSourceBundleIdentifiers(
        main: "com.iossim.on-device-dvt-poc",
        witness: "com.iossim.location-witness",
        unitTests: "com.iossim.location-control-tests",
        uiTests: "com.iossim.location-control-uitests",
        runner: "com.iossim.location-control-uitests.xctrunner"
    )

    public let main: String
    public let witness: String
    public let unitTests: String
    public let uiTests: String
    public let runner: String

    public init(main: String, witness: String, unitTests: String, uiTests: String, runner: String) {
        self.main = main
        self.witness = witness
        self.unitTests = unitTests
        self.uiTests = uiTests
        self.runner = runner
    }
}

public struct PersonalTeamBundleIdentifierSet: Codable, Equatable, Sendable {
    public let main: String
    public let witness: String
    public let unitTests: String
    public let uiTests: String
    public let runner: String

    public init(teamIdentifier: String) throws {
        let token = Self.stableTeamToken(teamIdentifier)
        let prefix = "\(PersonalTeamProvisioningPOC.bundleIdentifierPrefix).\(token)"
        main = "\(prefix).on-device-dvt-poc"
        witness = "\(prefix).location-witness"
        unitTests = "\(prefix).location-control-tests"
        uiTests = "\(prefix).location-control-uitests"
        runner = "\(uiTests).xctrunner"
        try Self.validateUniqueAndWellFormed([main, witness, unitTests, uiTests, runner])
    }

    private static func stableTeamToken(_ teamIdentifier: String) -> String {
        let normalized = teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let digest = SHA256.hash(data: Data("IOSSimPersonalTeam:\(normalized)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "t\(hex.prefix(12))"
    }

    private static func validateUniqueAndWellFormed(_ identifiers: [String]) throws {
        guard Set(identifiers).count == identifiers.count else {
            throw PersonalTeamProvisioningError.duplicateDerivedBundleIdentifier
        }
        for identifier in identifiers {
            guard isValidAppleBundleIdentifier(identifier) else {
                throw PersonalTeamProvisioningError.invalidDerivedBundleIdentifier(identifier)
            }
        }
    }

    public static func isValidAppleBundleIdentifier(_ identifier: String) -> Bool {
        guard identifier.count <= 255, identifier.contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return identifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
            guard let first = component.first else { return false }
            return first.isLetter || first.isNumber
        }
    }
}

public enum ProvisioningTeamKind: String, Codable, Equatable, Sendable {
    case personalTeam = "PERSONAL_TEAM"
    case paidDevelopment = "PAID_DEVELOPMENT"
    case unknown = "UNKNOWN"
}

public struct ProvisioningIdentity: Codable, Equatable, Sendable {
    public let teamIdentifier: String
    public let kind: ProvisioningTeamKind
    public let signingCertificateCommonName: String?

    public init(teamIdentifier: String, kind: ProvisioningTeamKind, signingCertificateCommonName: String? = nil) {
        self.teamIdentifier = teamIdentifier
        self.kind = kind
        self.signingCertificateCommonName = signingCertificateCommonName
    }

    public func validateRefreshIdentity(matches prior: ProvisioningIdentity) throws {
        guard teamIdentifier == prior.teamIdentifier else {
            throw PersonalTeamProvisioningError.signingTeamChanged(expected: prior.teamIdentifier, actual: teamIdentifier)
        }
    }
}

public struct AppleCodeSigningIdentity: Codable, Equatable, Sendable {
    public let commonName: String
    public let teamIdentifier: String?
    public let kind: ProvisioningTeamKind

    public init(commonName: String, teamIdentifier: String?, kind: ProvisioningTeamKind = .unknown) {
        self.commonName = commonName
        self.teamIdentifier = teamIdentifier
        self.kind = kind
    }

    public static func parseSecurityFindIdentityOutput(_ output: String) -> [AppleCodeSigningIdentity] {
        output.split(separator: "\n").compactMap { line in
            guard let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""),
                  firstQuote != lastQuote else {
                return nil
            }
            let commonName = String(line[line.index(after: firstQuote)..<lastQuote])
            guard commonName.hasPrefix("Apple Development:") else {
                return nil
            }
            let teamIdentifier: String?
            if let open = commonName.lastIndex(of: "("),
               let close = commonName.lastIndex(of: ")"),
               open < close {
                teamIdentifier = String(commonName[commonName.index(after: open)..<close])
            } else {
                teamIdentifier = nil
            }
            return AppleCodeSigningIdentity(commonName: commonName, teamIdentifier: teamIdentifier)
        }
    }
}

public enum AppleSigningIdentityInspector {
    public static func availableAppleDevelopmentIdentities(runner: ProcessRunner = ProcessRunner()) async -> [AppleCodeSigningIdentity] {
        let securityURL = URL(fileURLWithPath: "/usr/bin/security")
        guard FileManager.default.isExecutableFile(atPath: securityURL.path),
              let result = try? await runner.run(
                executableURL: securityURL,
                arguments: ["find-identity", "-v", "-p", "codesigning"],
                workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                environment: RuntimeProvisioning.deterministicEnvironment()
              ),
              result.exitCode == 0 else {
            return []
        }
        return AppleCodeSigningIdentity.parseSecurityFindIdentityOutput(result.stdout)
    }
}

public struct PersonalTeamPOCInspectionReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceBundleIdentifiers: ProtectedSourceBundleIdentifiers
    public let derivedBundleIdentifiers: PersonalTeamBundleIdentifierSet?
    public let selectedTeamIdentifier: String?
    public let selectedTeamKind: ProvisioningTeamKind
    public let appleDevelopmentIdentities: [AppleCodeSigningIdentity]
    public let selectedDeviceIdentifierHash: String?
    public let currentArtifactProfiles: [ProvisioningProfileSummary]
    public let currentSigningGraph: [SigningGraphNode]
    public let refreshPlan: RefreshPlan?

    public init(
        schemaVersion: Int = PersonalTeamProvisioningPOC.schemaVersion,
        sourceBundleIdentifiers: ProtectedSourceBundleIdentifiers,
        derivedBundleIdentifiers: PersonalTeamBundleIdentifierSet?,
        selectedTeamIdentifier: String?,
        selectedTeamKind: ProvisioningTeamKind,
        appleDevelopmentIdentities: [AppleCodeSigningIdentity],
        selectedDeviceIdentifierHash: String?,
        currentArtifactProfiles: [ProvisioningProfileSummary],
        currentSigningGraph: [SigningGraphNode],
        refreshPlan: RefreshPlan?
    ) {
        self.schemaVersion = schemaVersion
        self.sourceBundleIdentifiers = sourceBundleIdentifiers
        self.derivedBundleIdentifiers = derivedBundleIdentifiers
        self.selectedTeamIdentifier = selectedTeamIdentifier
        self.selectedTeamKind = selectedTeamKind
        self.appleDevelopmentIdentities = appleDevelopmentIdentities
        self.selectedDeviceIdentifierHash = selectedDeviceIdentifierHash
        self.currentArtifactProfiles = currentArtifactProfiles
        self.currentSigningGraph = currentSigningGraph
        self.refreshPlan = refreshPlan
    }
}

public struct CodeSignatureSummary: Codable, Equatable, Sendable {
    public let identifier: String?
    public let teamIdentifier: String?
    public let authorities: [String]
    public var authorityTeamIdentifiers: [String] {
        authorities.compactMap { authority in
            guard let open = authority.lastIndex(of: "("),
                  let close = authority.lastIndex(of: ")"),
                  open < close else {
                return nil
            }
            return String(authority[authority.index(after: open)..<close])
        }
    }

    public init(identifier: String?, teamIdentifier: String?, authorities: [String]) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.authorities = authorities
    }

    public static func parseCodesignDisplayOutput(_ output: String) -> CodeSignatureSummary {
        var identifier: String?
        var teamIdentifier: String?
        var authorities: [String] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            if text.hasPrefix("Identifier=") {
                identifier = String(text.dropFirst("Identifier=".count))
            } else if text.hasPrefix("TeamIdentifier=") {
                teamIdentifier = String(text.dropFirst("TeamIdentifier=".count))
            } else if text.hasPrefix("Authority=") {
                authorities.append(String(text.dropFirst("Authority=".count)))
            }
        }
        return CodeSignatureSummary(identifier: identifier, teamIdentifier: teamIdentifier, authorities: authorities)
    }
}

public enum SigningGraphInspector {
    public static func graph(
        resourcesURL: URL,
        manifest: ArtifactManifest,
        profiles: [ProvisioningProfileSummary],
        runner: ProcessRunner = ProcessRunner()
    ) async -> [SigningGraphNode] {
        var nodes: [SigningGraphNode] = []
        for component in manifest.components {
            let url = resourcesURL.appendingPathComponent(component.relativePath)
            let signature = await codeSignatureSummary(url: url, runner: runner)
            let entitlements = await entitlementKeys(url: url, runner: runner)
            let nested = nestedCodePaths(appURL: url)
            let profile = profiles.first { $0.bundleIdentifier == component.bundleIdentifier }
            nodes.append(SigningGraphNode(
                role: component.role,
                bundleIdentifier: signature.identifier ?? component.bundleIdentifier,
                teamIdentifier: signature.teamIdentifier,
                signingAuthorityTeamIdentifiers: signature.authorityTeamIdentifiers,
                applicationIdentifier: profile?.applicationIdentifier,
                profileType: profile?.profileType,
                entitlements: entitlements,
                nestedCode: nested
            ))
        }
        return nodes
    }

    private static func codeSignatureSummary(url: URL, runner: ProcessRunner) async -> CodeSignatureSummary {
        let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesignURL.path),
              let result = try? await runner.run(
                executableURL: codesignURL,
                arguments: ["-dvv", url.path],
                workingDirectory: url.deletingLastPathComponent(),
                environment: RuntimeProvisioning.deterministicEnvironment()
              ) else {
            return CodeSignatureSummary(identifier: nil, teamIdentifier: nil, authorities: [])
        }
        return CodeSignatureSummary.parseCodesignDisplayOutput(result.combinedOutput)
    }

    private static func entitlementKeys(url: URL, runner: ProcessRunner) async -> [String] {
        let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesignURL.path),
              let result = try? await runner.run(
                executableURL: codesignURL,
                arguments: ["-d", "--entitlements", ":-", url.path],
                workingDirectory: url.deletingLastPathComponent(),
                environment: RuntimeProvisioning.deterministicEnvironment()
              ) else {
            return []
        }
        let combined = result.combinedOutput
        guard let xmlStart = combined.range(of: "<?xml"),
              let data = String(combined[xmlStart.lowerBound...]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let entitlements = plist as? [String: Any] else {
            return []
        }
        return entitlements.keys.sorted()
    }

    private static func nestedCodePaths(appURL: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var paths: [String] = []
        let root = appURL.path
        for case let url as URL in enumerator {
            guard ["app", "xctest", "framework", "dylib"].contains(url.pathExtension) else {
                continue
            }
            guard url.path != root, url.path.hasPrefix(root + "/") else {
                continue
            }
            paths.append(String(url.path.dropFirst(root.count + 1)))
        }
        return paths.sorted()
    }
}

public struct ProvisioningExpiration: Codable, Equatable, Sendable {
    public let creationDate: Date?
    public let expirationDate: Date?

    public init(creationDate: Date?, expirationDate: Date?) {
        self.creationDate = creationDate
        self.expirationDate = expirationDate
    }

    public func remainingInterval(now: Date = Date()) -> TimeInterval? {
        expirationDate.map { $0.timeIntervalSince(now) }
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expirationDate else { return true }
        return expirationDate <= now
    }

    public func refreshRecommended(now: Date = Date(), threshold: TimeInterval = PersonalTeamProvisioningPOC.refreshRecommendedInterval) -> Bool {
        guard let remaining = remainingInterval(now: now) else { return true }
        return remaining <= threshold
    }
}

public enum RefreshState: String, Codable, Equatable, Sendable {
    case valid = "VALID"
    case refreshRecommended = "REFRESH_RECOMMENDED"
    case refreshRequired = "REFRESH_REQUIRED"
    case expired = "EXPIRED"
    case teamChanged = "TEAM_CHANGED"
    case deviceMismatch = "DEVICE_MISMATCH"
    case signingUnavailable = "SIGNING_UNAVAILABLE"
}

public struct RefreshPlan: Codable, Equatable, Sendable {
    public let state: RefreshState
    public let refreshRecommended: Bool
    public let earliestExpiration: Date?

    public init(state: RefreshState, refreshRecommended: Bool, earliestExpiration: Date?) {
        self.state = state
        self.refreshRecommended = refreshRecommended
        self.earliestExpiration = earliestExpiration
    }
}

public struct ProvisionedArtifactIdentity: Codable, Equatable, Sendable {
    public let role: String
    public let sourceBundleIdentifier: String
    public let installedBundleIdentifier: String
    public let profile: ProvisioningExpiration

    public init(role: String, sourceBundleIdentifier: String, installedBundleIdentifier: String, profile: ProvisioningExpiration) {
        self.role = role
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.installedBundleIdentifier = installedBundleIdentifier
        self.profile = profile
    }
}

public struct PersonalTeamProvisioningManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let teamIdentifier: String
    public let teamKind: ProvisioningTeamKind
    public let deviceIdentifierHash: String
    public let sourceMainBundleID: String
    public let installedMainBundleID: String
    public let sourceRunnerBundleID: String
    public let installedRunnerBundleID: String
    public let sourceWitnessBundleID: String
    public let installedWitnessBundleID: String?
    public let mainExpiration: Date?
    public let runnerExpiration: Date?
    public let witnessExpiration: Date?
    public let artifacts: [ProvisionedArtifactIdentity]

    public init(
        schemaVersion: Int = PersonalTeamProvisioningPOC.schemaVersion,
        teamIdentifier: String,
        teamKind: ProvisioningTeamKind,
        deviceIdentifierHash: String,
        sourceMainBundleID: String,
        installedMainBundleID: String,
        sourceRunnerBundleID: String,
        installedRunnerBundleID: String,
        sourceWitnessBundleID: String,
        installedWitnessBundleID: String?,
        mainExpiration: Date?,
        runnerExpiration: Date?,
        witnessExpiration: Date?,
        artifacts: [ProvisionedArtifactIdentity] = []
    ) {
        self.schemaVersion = schemaVersion
        self.teamIdentifier = teamIdentifier
        self.teamKind = teamKind
        self.deviceIdentifierHash = deviceIdentifierHash
        self.sourceMainBundleID = sourceMainBundleID
        self.installedMainBundleID = installedMainBundleID
        self.sourceRunnerBundleID = sourceRunnerBundleID
        self.installedRunnerBundleID = installedRunnerBundleID
        self.sourceWitnessBundleID = sourceWitnessBundleID
        self.installedWitnessBundleID = installedWitnessBundleID
        self.mainExpiration = mainExpiration
        self.runnerExpiration = runnerExpiration
        self.witnessExpiration = witnessExpiration
        self.artifacts = artifacts
    }

    public var earliestExpiration: Date? {
        [mainExpiration, runnerExpiration, witnessExpiration].compactMap { $0 }.min()
    }
}

public struct SigningGraphNode: Codable, Equatable, Sendable {
    public let role: String
    public let bundleIdentifier: String
    public let teamIdentifier: String?
    public let signingAuthorityTeamIdentifiers: [String]
    public let applicationIdentifier: String?
    public let profileType: String?
    public let entitlements: [String]
    public let nestedCode: [String]

    public init(
        role: String,
        bundleIdentifier: String,
        teamIdentifier: String?,
        signingAuthorityTeamIdentifiers: [String] = [],
        applicationIdentifier: String?,
        profileType: String?,
        entitlements: [String],
        nestedCode: [String]
    ) {
        self.role = role
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.signingAuthorityTeamIdentifiers = signingAuthorityTeamIdentifiers.sorted()
        self.applicationIdentifier = applicationIdentifier
        self.profileType = profileType
        self.entitlements = entitlements.sorted()
        self.nestedCode = nestedCode.sorted()
    }
}

public struct ProvisionedArtifactSet: Codable, Equatable, Sendable {
    public let source: ProtectedSourceBundleIdentifiers
    public let installed: PersonalTeamBundleIdentifierSet
    public let signingGraph: [SigningGraphNode]

    public init(source: ProtectedSourceBundleIdentifiers, installed: PersonalTeamBundleIdentifierSet, signingGraph: [SigningGraphNode]) {
        self.source = source
        self.installed = installed
        self.signingGraph = signingGraph
    }
}

public enum PersonalTeamProvisioningError: Error, Equatable, Sendable, CustomStringConvertible {
    case signingTeamChanged(expected: String, actual: String)
    case deviceMismatch
    case sourceBundleIdentifierMutated(role: String)
    case duplicateDerivedBundleIdentifier
    case invalidDerivedBundleIdentifier(String)

    public var description: String {
        switch self {
        case .signingTeamChanged(let expected, let actual):
            return "SIGNING_TEAM_CHANGED: expected \(RuntimeProvisioning.shortIdentifier(expected)), got \(RuntimeProvisioning.shortIdentifier(actual))."
        case .deviceMismatch:
            return "DEVICE_MISMATCH: selected iPhone does not match the provisioning manifest."
        case .sourceBundleIdentifierMutated(let role):
            return "SOURCE_BUNDLE_IDENTIFIER_MUTATED: \(role) no longer matches the protected source identifier."
        case .duplicateDerivedBundleIdentifier:
            return "DUPLICATE_DERIVED_BUNDLE_IDENTIFIER: generated Personal Team bundle identifiers are not unique."
        case .invalidDerivedBundleIdentifier(let identifier):
            return "INVALID_DERIVED_BUNDLE_IDENTIFIER: \(identifier)."
        }
    }
}
