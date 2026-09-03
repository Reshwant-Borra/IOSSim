import Foundation
import CryptoKit

public struct ArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let release: ReleaseManifest
    public let components: [DeviceArtifactComponent]

    public init(schemaVersion: Int, release: ReleaseManifest, components: [DeviceArtifactComponent]) {
        self.schemaVersion = schemaVersion
        self.release = release
        self.components = components
    }
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let sourceCommit: String
    public let buildTimestamp: String
    public let macVersion: String
    public let helperSchemaVersion: Int

    public init(sourceCommit: String, buildTimestamp: String, macVersion: String, helperSchemaVersion: Int) {
        self.sourceCommit = sourceCommit
        self.buildTimestamp = buildTimestamp
        self.macVersion = macVersion
        self.helperSchemaVersion = helperSchemaVersion
    }
}

public struct DeviceArtifactComponent: Codable, Equatable, Sendable, Identifiable {
    public var id: String { role }
    public let role: String
    public let bundleIdentifier: String
    public let version: String
    public let relativePath: String
    public let sha256: String

    public init(role: String, bundleIdentifier: String, version: String, relativePath: String, sha256: String) {
        self.role = role
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.relativePath = relativePath
        self.sha256 = sha256
    }
}

public struct ArtifactVerificationResult: Codable, Equatable, Sendable {
    public let role: String
    public let relativePath: String
    public let expectedSHA256: String
    public let actualSHA256: String?
    public let state: CheckState
    public let detail: String

    public init(
        role: String,
        relativePath: String,
        expectedSHA256: String,
        actualSHA256: String?,
        state: CheckState,
        detail: String
    ) {
        self.role = role
        self.relativePath = relativePath
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.state = state
        self.detail = detail
    }
}

public enum ArtifactManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingManifest(URL)
    case missingArtifact(String)
    case unreadableArtifact(String)
    case checksumMismatch(String)
    case invalidBundleIdentifier(role: String, expected: String, actual: String?)

    public var description: String {
        switch self {
        case .missingManifest(let url):
            return "Artifact manifest is missing at \(url.path)."
        case .missingArtifact(let path):
            return "Bundled artifact is missing: \(path)."
        case .unreadableArtifact(let path):
            return "Bundled artifact cannot be read: \(path)."
        case .checksumMismatch(let path):
            return "Bundled artifact checksum mismatch: \(path)."
        case .invalidBundleIdentifier(let role, let expected, let actual):
            return "Bundled artifact \(role) has bundle identifier \(actual ?? "missing"), expected \(expected)."
        }
    }
}

public enum ArtifactManifestLoader {
    public static let manifestRelativePath = "DeviceArtifacts/manifest.json"

    public static func load(resourcesURL: URL) throws -> ArtifactManifest {
        let url = resourcesURL.appendingPathComponent(manifestRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArtifactManifestError.missingManifest(url)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ArtifactManifest.self, from: data)
    }

    public static func verify(resourcesURL: URL, manifest: ArtifactManifest) -> [ArtifactVerificationResult] {
        manifest.components.map { component in
            let artifactURL = resourcesURL.appendingPathComponent(component.relativePath)
            guard FileManager.default.fileExists(atPath: artifactURL.path) else {
                return ArtifactVerificationResult(
                    role: component.role,
                    relativePath: component.relativePath,
                    expectedSHA256: component.sha256,
                    actualSHA256: nil,
                    state: .fail,
                    detail: "missing"
                )
            }
            guard let actual = sha256(url: artifactURL) else {
                return ArtifactVerificationResult(
                    role: component.role,
                    relativePath: component.relativePath,
                    expectedSHA256: component.sha256,
                    actualSHA256: nil,
                    state: .fail,
                    detail: "unreadable"
                )
            }
            let matches = actual.caseInsensitiveCompare(component.sha256) == .orderedSame
            return ArtifactVerificationResult(
                role: component.role,
                relativePath: component.relativePath,
                expectedSHA256: component.sha256,
                actualSHA256: actual,
                state: matches ? .pass : .fail,
                detail: matches ? "verified" : "checksum mismatch"
            )
        }
    }

    public static func assertValidBundleIdentifiers(resourcesURL: URL, manifest: ArtifactManifest) throws {
        for component in manifest.components {
            let infoURL = resourcesURL
                .appendingPathComponent(component.relativePath)
                .appendingPathComponent("Info.plist")
            let data = try Data(contentsOf: infoURL)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let info = plist as? [String: Any]
            let actual = info?["CFBundleIdentifier"] as? String
            if actual != component.bundleIdentifier {
                throw ArtifactManifestError.invalidBundleIdentifier(
                    role: component.role,
                    expected: component.bundleIdentifier,
                    actual: actual
                )
            }
        }
    }

    public static func assertArtifactsVerified(resourcesURL: URL, manifest: ArtifactManifest) throws {
        for result in verify(resourcesURL: resourcesURL, manifest: manifest) where result.state != .pass {
            switch result.detail {
            case "missing":
                throw ArtifactManifestError.missingArtifact(result.relativePath)
            case "unreadable":
                throw ArtifactManifestError.unreadableArtifact(result.relativePath)
            default:
                throw ArtifactManifestError.checksumMismatch(result.relativePath)
            }
        }
        try assertValidBundleIdentifiers(resourcesURL: resourcesURL, manifest: manifest)
    }

    private static func sha256(url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return directorySHA256(url: url)
        }
        do {
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private static func directorySHA256(url: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return nil
            }
            if values.isRegularFile == true || values.isSymbolicLink == true {
                files.append(fileURL)
            }
        }
        var hasher = SHA256()
        for fileURL in files.sorted(by: { $0.path < $1.path }) {
            let relative = String(fileURL.path.dropFirst(url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path) {
                hasher.update(data: Data("symlink".utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: Data(target.utf8))
            } else if let data = try? Data(contentsOf: fileURL) {
                hasher.update(data: data)
            } else {
                return nil
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
