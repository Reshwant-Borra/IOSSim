import CryptoKit
import Foundation

public struct SigningCertificateEvidence: Equatable, Sendable {
    public let commonName: String
    public let subjectTeamIdentifier: String
    public let fingerprint: String

    public init(commonName: String, subjectTeamIdentifier: String, fingerprint: String) {
        self.commonName = commonName
        self.subjectTeamIdentifier = subjectTeamIdentifier
        self.fingerprint = fingerprint.uppercased()
    }
}

struct LocalProvisioningProfileEvidence: Sendable {
    let teamIdentifier: String
    let teamName: String?
    let profileName: String?
    let creationDate: Date?
    let expirationDate: Date?
    let provisionedDevices: [String]
    let developerCertificateFingerprints: [String]
    let applicationIdentifier: String?
    let uuid: String?
    let fileURL: URL

    var isPersonalTeam: Bool {
        if [teamName, profileName]
            .compactMap({ $0 })
            .joined(separator: " ")
            .localizedCaseInsensitiveContains("personal team") {
            return true
        }
        guard let creationDate, let expirationDate else { return false }
        let lifetime = expirationDate.timeIntervalSince(creationDate)
        return lifetime > 0 && lifetime <= 8.25 * 24 * 60 * 60
    }
}

public enum ApplePersonalTeamDiscovery {
    public static func discover(
        selectedDeviceIdentifier: String?,
        runner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) async -> [PersonalTeamCandidate] {
        async let certificates = signingCertificates(runner: runner)
        async let profiles = provisioningProfiles(runner: runner, fileManager: fileManager)
        let (certificateValues, profileValues) = await (certificates, profiles)

        return certificateValues.compactMap { certificate in
            let matches = profileValues.filter {
                $0.teamIdentifier == certificate.subjectTeamIdentifier
                    && $0.developerCertificateFingerprints.contains(certificate.fingerprint)
            }
            guard matches.contains(where: \ .isPersonalTeam) else { return nil }
            let teamNames = matches.compactMap(\ .teamName)
            let account = accountName(from: certificate.commonName)
            let selectedIncluded = selectedDeviceIdentifier.map { selected in
                matches.contains { $0.provisionedDevices.contains(selected) }
            }
            return PersonalTeamCandidate(
                teamIdentifier: certificate.subjectTeamIdentifier,
                accountDisplayName: account,
                teamDisplayName: teamNames.first,
                signingIdentityCommonName: certificate.commonName,
                signingIdentityFingerprint: certificate.fingerprint,
                certificateSubjectTeamIdentifier: certificate.subjectTeamIdentifier,
                profileTeamIdentifiers: Array(Set(matches.map(\ .teamIdentifier))),
                matchingProfileCount: matches.count,
                selectedDeviceIncluded: selectedIncluded,
                personalTeam: true
            )
        }
        .sorted {
            if $0.userDisplayName == $1.userDisplayName { return $0.teamIdentifier < $1.teamIdentifier }
            return $0.userDisplayName.localizedCaseInsensitiveCompare($1.userDisplayName) == .orderedAscending
        }
    }

    public static func parseCertificateEvidence(_ output: String) -> SigningCertificateEvidence? {
        var commonName: String?
        var teamIdentifier: String?
        var fingerprint: String?
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("subject=") {
                let subject = String(line.dropFirst("subject=".count))
                commonName = subjectValue(named: "CN", in: subject)
                teamIdentifier = subjectValue(named: "OU", in: subject)
            } else if line.uppercased().contains("FINGERPRINT=") {
                fingerprint = line.split(separator: "=", maxSplits: 1).last.map {
                    $0.replacingOccurrences(of: ":", with: "").uppercased()
                }
            }
        }
        guard let commonName, commonName.hasPrefix("Apple Development:"),
              let teamIdentifier, !teamIdentifier.isEmpty,
              let fingerprint, fingerprint.count == 40 else {
            return nil
        }
        return SigningCertificateEvidence(
            commonName: commonName,
            subjectTeamIdentifier: teamIdentifier,
            fingerprint: fingerprint
        )
    }

    public static func subjectValue(named key: String, in subject: String) -> String? {
        let separator: Character = subject.contains("/") ? "/" : ","
        let normalized = subject.replacingOccurrences(of: ", ", with: ",")
        for field in normalized.split(separator: separator) {
            let pair = field.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if pair.count == 2, pair[0] == key { return pair[1] }
        }
        return nil
    }

    private static func signingCertificates(runner: ProcessRunner) async -> [SigningCertificateEvidence] {
        let security = URL(fileURLWithPath: "/usr/bin/security")
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: security.path),
              FileManager.default.isExecutableFile(atPath: openssl.path),
              let result = try? await runner.run(
                executableURL: security,
                arguments: ["find-certificate", "-a", "-p", "-c", "Apple Development"],
                workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                environment: RuntimeProvisioning.deterministicEnvironment()
              ), result.exitCode == 0 else {
            return []
        }

        let blocks = pemCertificateBlocks(result.stdout)
        var certificates: [SigningCertificateEvidence] = []
        for block in blocks {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("iossim-certificate-\(UUID().uuidString).pem")
            do {
                try block.write(to: url, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: url) }
                let inspection = try await runner.run(
                    executableURL: openssl,
                    arguments: ["x509", "-in", url.path, "-noout", "-subject", "-fingerprint", "-sha1"],
                    workingDirectory: url.deletingLastPathComponent(),
                    environment: RuntimeProvisioning.deterministicEnvironment()
                )
                if inspection.exitCode == 0, let evidence = parseCertificateEvidence(inspection.stdout) {
                    certificates.append(evidence)
                }
            } catch {
                continue
            }
        }
        return certificates
    }

    private static func provisioningProfiles(
        runner: ProcessRunner,
        fileManager: FileManager
    ) async -> [LocalProvisioningProfileEvidence] {
        let home = fileManager.homeDirectoryForCurrentUser
        let directories = [
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true),
            home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles", isDirectory: true)
        ]
        var urls: [URL] = []
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            urls.append(contentsOf: entries.filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension) })
        }
        var evidence: [LocalProvisioningProfileEvidence] = []
        for url in urls {
            if let value = await decodeProfile(url: url, runner: runner) { evidence.append(value) }
        }
        return evidence
    }

    private static func decodeProfile(url: URL, runner: ProcessRunner) async -> LocalProvisioningProfileEvidence? {
        let security = URL(fileURLWithPath: "/usr/bin/security")
        guard let result = try? await runner.run(
            executableURL: security,
            arguments: ["cms", "-D", "-i", url.path],
            workingDirectory: url.deletingLastPathComponent(),
            environment: RuntimeProvisioning.deterministicEnvironment()
        ), result.exitCode == 0,
        let data = result.stdout.data(using: .utf8),
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
        let teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first else {
            return nil
        }
        let fingerprints = (plist["DeveloperCertificates"] as? [Data] ?? []).map {
            Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined()
        }
        let entitlements = plist["Entitlements"] as? [String: Any]
        return LocalProvisioningProfileEvidence(
            teamIdentifier: teamIdentifier,
            teamName: plist["TeamName"] as? String,
            profileName: plist["Name"] as? String,
            creationDate: plist["CreationDate"] as? Date,
            expirationDate: plist["ExpirationDate"] as? Date,
            provisionedDevices: plist["ProvisionedDevices"] as? [String] ?? [],
            developerCertificateFingerprints: fingerprints,
            applicationIdentifier: entitlements?["application-identifier"] as? String,
            uuid: plist["UUID"] as? String,
            fileURL: url
        )
    }

    private static func pemCertificateBlocks(_ output: String) -> [String] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var blocks: [String] = []
        var remainder = output[...]
        while let start = remainder.range(of: begin),
              let finish = remainder.range(of: end, range: start.lowerBound..<remainder.endIndex) {
            blocks.append(String(remainder[start.lowerBound..<finish.upperBound]) + "\n")
            remainder = remainder[finish.upperBound...]
        }
        return blocks
    }

    private static func accountName(from commonName: String) -> String? {
        let suffixRemoved = commonName.replacingOccurrences(of: "Apple Development:", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let open = suffixRemoved.lastIndex(of: "(") else { return suffixRemoved }
        return String(suffixRemoved[..<open]).trimmingCharacters(in: .whitespaces)
    }
}
