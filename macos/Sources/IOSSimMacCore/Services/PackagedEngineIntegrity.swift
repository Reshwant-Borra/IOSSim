import CryptoKit
import Foundation

struct PackagedEngineIntegrityManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let relativePath = "EngineIntegrity.plist"

    let schemaVersion: Int
    let helperRelativePath: String
    let helperSHA256: String
    let helperSchemaVersion: Int
    let setupStateSchemaVersion: Int
    let artifactManifestSchemaVersion: Int
    let nativeBridgeRelativePath: String
    let nativeBridgeSHA256: String
    let nativeBridgeABI: UInt32
    let payloadManifestRelativePath: String
    let payloadManifestSHA256: String
}

enum PackagedEngineIntegrityError: Error, Equatable, Sendable, CustomStringConvertible {
    case helperMissing
    case helperNotExecutable
    case resourcesMissing
    case integrityManifestMissing
    case integrityManifestInvalid
    case helperHashMismatch
    case resourceMissing(String)
    case resourceHashMismatch(String)
    case artifactManifestInvalid
    case protocolHandshakeFailed
    case protocolMismatch(expected: String, actual: String)

    var code: String {
        switch self {
        case .helperMissing: return "VEYA-INTEGRITY-001"
        case .helperNotExecutable: return "VEYA-INTEGRITY-002"
        case .resourcesMissing, .resourceMissing: return "VEYA-INTEGRITY-003"
        case .integrityManifestMissing, .integrityManifestInvalid, .artifactManifestInvalid:
            return "VEYA-INTEGRITY-004"
        case .helperHashMismatch, .resourceHashMismatch: return "VEYA-INTEGRITY-005"
        case .protocolHandshakeFailed, .protocolMismatch: return "VEYA-INTEGRITY-006"
        }
    }

    var description: String {
        switch self {
        case .helperMissing:
            return "\(code): Required packaged setup helper is missing. Reinstall IOSSim."
        case .helperNotExecutable:
            return "\(code): Required packaged setup helper is not executable. Reinstall IOSSim."
        case .resourcesMissing:
            return "\(code): Required packaged Resources directory is missing. Reinstall IOSSim."
        case .integrityManifestMissing:
            return "\(code): Packaged engine integrity manifest is missing. Reinstall IOSSim."
        case .integrityManifestInvalid:
            return "\(code): Packaged engine integrity manifest is invalid or incompatible. Reinstall IOSSim."
        case .helperHashMismatch:
            return "\(code): Packaged setup helper identity does not match this release. Reinstall IOSSim."
        case .resourceMissing(let role):
            return "\(code): Required packaged component \(role) is missing. Reinstall IOSSim."
        case .resourceHashMismatch(let role):
            return "\(code): Packaged component \(role) does not match this release. Reinstall IOSSim."
        case .artifactManifestInvalid:
            return "\(code): Packaged payload manifest or payload content is invalid. Reinstall IOSSim."
        case .protocolHandshakeFailed:
            return "\(code): Packaged setup helper did not complete its compatibility handshake. Reinstall IOSSim."
        case .protocolMismatch(let expected, let actual):
            return "\(code): Packaged setup helper is incompatible with this app (expected \(expected), received \(actual)). Reinstall IOSSim."
        }
    }
}

struct PackagedHelperProtocolInfo: Codable, Equatable, Sendable {
    let helperSchemaVersion: Int
    let setupStateSchemaVersion: Int
    let artifactManifestSchemaVersion: Int
    let nativeBridgeABIExpected: UInt32
}

private struct PackagedHelperProtocolEnvelope: Decodable {
    let ok: Bool
    let schemaVersion: Int
    let data: PackagedHelperProtocolInfo
}

enum PackagedEngineIntegrity {
    static func loadAndValidate(
        helperURL: URL,
        resourcesURL: URL,
        fileManager: FileManager = .default
    ) throws -> PackagedEngineIntegrityManifest {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resourcesURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PackagedEngineIntegrityError.resourcesMissing
        }
        try validateHelperPresence(helperURL, fileManager: fileManager)

        let manifestURL = resourcesURL.appendingPathComponent(PackagedEngineIntegrityManifest.relativePath)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw PackagedEngineIntegrityError.integrityManifestMissing
        }
        let manifest: PackagedEngineIntegrityManifest
        do {
            manifest = try PropertyListDecoder().decode(
                PackagedEngineIntegrityManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw PackagedEngineIntegrityError.integrityManifestInvalid
        }
        guard manifest.schemaVersion == PackagedEngineIntegrityManifest.currentSchemaVersion,
              manifest.helperRelativePath == "Contents/MacOS/IOSSimProvisioner",
              manifest.nativeBridgeRelativePath == "NativeDeviceBridge/libiossim_device_bridge.dylib",
              manifest.payloadManifestRelativePath == ArtifactManifestLoader.manifestRelativePath,
              manifest.helperSchemaVersion == RuntimeProvisioning.helperSchemaVersion,
              manifest.setupStateSchemaVersion == SetupStateSnapshot.currentSchemaVersion,
              manifest.artifactManifestSchemaVersion == ArtifactManifest.currentSchemaVersion,
              manifest.nativeBridgeABI == DynamicNativeDeviceTransport.requiredABIVersion else {
            throw PackagedEngineIntegrityError.integrityManifestInvalid
        }
        try validateFiles(
            manifest,
            helperURL: helperURL,
            resourcesURL: resourcesURL,
            fileManager: fileManager
        )
        do {
            let artifactManifest = try ArtifactManifestLoader.load(resourcesURL: resourcesURL)
            guard artifactManifest.release.helperSchemaVersion == manifest.helperSchemaVersion else {
                throw PackagedEngineIntegrityError.artifactManifestInvalid
            }
            try ArtifactManifestLoader.assertArtifactsVerified(
                resourcesURL: resourcesURL,
                manifest: artifactManifest
            )
        } catch let error as PackagedEngineIntegrityError {
            throw error
        } catch {
            throw PackagedEngineIntegrityError.artifactManifestInvalid
        }
        return manifest
    }

    static func validateFiles(
        _ manifest: PackagedEngineIntegrityManifest,
        helperURL: URL,
        resourcesURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try validateHelperPresence(helperURL, fileManager: fileManager)
        guard try sha256(helperURL) == manifest.helperSHA256.lowercased() else {
            throw PackagedEngineIntegrityError.helperHashMismatch
        }
        try validateResource(
            role: "native device bridge",
            url: resourcesURL.appendingPathComponent(manifest.nativeBridgeRelativePath),
            expectedSHA256: manifest.nativeBridgeSHA256,
            fileManager: fileManager
        )
        try validateResource(
            role: "payload manifest",
            url: resourcesURL.appendingPathComponent(manifest.payloadManifestRelativePath),
            expectedSHA256: manifest.payloadManifestSHA256,
            fileManager: fileManager
        )
    }

    static func decodeAndValidateHandshake(
        _ result: ProcessResult,
        expected manifest: PackagedEngineIntegrityManifest
    ) throws {
        guard result.exitCode == 0 else {
            throw PackagedEngineIntegrityError.protocolHandshakeFailed
        }
        let envelope: PackagedHelperProtocolEnvelope
        do {
            envelope = try JSONDecoder().decode(
                PackagedHelperProtocolEnvelope.self,
                from: Data(result.stdout.utf8)
            )
        } catch {
            throw PackagedEngineIntegrityError.protocolHandshakeFailed
        }
        guard envelope.ok else { throw PackagedEngineIntegrityError.protocolHandshakeFailed }
        let expected = PackagedHelperProtocolInfo(
            helperSchemaVersion: manifest.helperSchemaVersion,
            setupStateSchemaVersion: manifest.setupStateSchemaVersion,
            artifactManifestSchemaVersion: manifest.artifactManifestSchemaVersion,
            nativeBridgeABIExpected: manifest.nativeBridgeABI
        )
        guard envelope.schemaVersion == expected.helperSchemaVersion,
              envelope.data == expected else {
            let actual = "helper=\(envelope.data.helperSchemaVersion),setup=\(envelope.data.setupStateSchemaVersion),artifact=\(envelope.data.artifactManifestSchemaVersion),bridge=\(envelope.data.nativeBridgeABIExpected)"
            let wanted = "helper=\(expected.helperSchemaVersion),setup=\(expected.setupStateSchemaVersion),artifact=\(expected.artifactManifestSchemaVersion),bridge=\(expected.nativeBridgeABIExpected)"
            throw PackagedEngineIntegrityError.protocolMismatch(expected: wanted, actual: actual)
        }
    }

    private static func validateHelperPresence(_ helperURL: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: helperURL.path) else {
            throw PackagedEngineIntegrityError.helperMissing
        }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw PackagedEngineIntegrityError.helperNotExecutable
        }
    }

    private static func validateResource(
        role: String,
        url: URL,
        expectedSHA256: String,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw PackagedEngineIntegrityError.resourceMissing(role)
        }
        guard try sha256(url) == expectedSHA256.lowercased() else {
            throw PackagedEngineIntegrityError.resourceHashMismatch(role)
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
