import CryptoKit
import Foundation

public enum DeveloperSupportState: String, Codable, Equatable, Sendable {
    case notNeeded
    case missing
    case acquisitionNeeded
    case available
    case personalizationRequired
    case personalizing
    case mountRequired
    case mounting
    case mounted
    case incompatible
    case failed
}

public enum DeveloperSupportFailure: String, Error, Codable, Equatable, Sendable {
    case noApprovedSource
    case wrongBuildIdentity
    case corruptAsset
    case developerModeDisabled
    case personalizationRejected
    case tssUnavailable
    case uploadFailed
    case mountRejected
    case serviceMapUnavailable
    case deviceDisconnected
}

public struct DeveloperSupportRequirements: Codable, Equatable, Sendable {
    public let productVersion: String
    public let buildVersion: String
    public let buildIdentity: String
    public let boardID: UInt64
    public let chipID: UInt64
    public let ecid: UInt64
    public let securityMode: Bool

    public init(
        productVersion: String,
        buildVersion: String,
        buildIdentity: String,
        boardID: UInt64,
        chipID: UInt64,
        ecid: UInt64,
        securityMode: Bool = true
    ) {
        self.productVersion = productVersion
        self.buildVersion = buildVersion
        self.buildIdentity = buildIdentity
        self.boardID = boardID
        self.chipID = chipID
        self.ecid = ecid
        self.securityMode = securityMode
    }
}

public struct DeveloperSupportArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let provenanceID: String
    public let buildVersion: String
    public let buildIdentity: String
    public let imageURL: URL
    public let imageSHA256: String
    public let imageSize: UInt64
    public let trustCacheURL: URL?
    public let trustCacheSHA256: String?
    public let buildManifestURL: URL
    public let buildManifestSHA256: String
    public let minimumBridgeABI: UInt32
    public let validatedAt: Date

    public init(
        schemaVersion: Int = 1,
        provenanceID: String,
        buildVersion: String,
        buildIdentity: String,
        imageURL: URL,
        imageSHA256: String,
        imageSize: UInt64,
        trustCacheURL: URL? = nil,
        trustCacheSHA256: String? = nil,
        buildManifestURL: URL,
        buildManifestSHA256: String,
        minimumBridgeABI: UInt32 = 1,
        validatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.provenanceID = provenanceID
        self.buildVersion = buildVersion
        self.buildIdentity = buildIdentity
        self.imageURL = imageURL
        self.imageSHA256 = imageSHA256.lowercased()
        self.imageSize = imageSize
        self.trustCacheURL = trustCacheURL
        self.trustCacheSHA256 = trustCacheSHA256?.lowercased()
        self.buildManifestURL = buildManifestURL
        self.buildManifestSHA256 = buildManifestSHA256.lowercased()
        self.minimumBridgeABI = minimumBridgeABI
        self.validatedAt = validatedAt
    }
}

public protocol DeveloperSupportProviding: Sendable {
    var productionEligible: Bool { get }
    func artifact(matching requirements: DeveloperSupportRequirements) async throws -> DeveloperSupportArtifact?
}

public protocol DeveloperSupportDeviceServicing: Sendable {
    func isMounted(on device: IOSSimDeviceIdentity, requirements: DeveloperSupportRequirements) async throws -> Bool
    func personalizationManifest(
        on device: IOSSimDeviceIdentity,
        artifact: DeveloperSupportArtifact,
        request: [String: String]
    ) async throws -> Data
    func mount(
        on device: IOSSimDeviceIdentity,
        artifact: DeveloperSupportArtifact,
        personalizationManifest: Data
    ) async throws
    func verifyRSD(on device: IOSSimDeviceIdentity) async throws
}

public struct DeveloperSupportStatus: Codable, Equatable, Sendable {
    public let state: DeveloperSupportState
    public let failure: DeveloperSupportFailure?
    public let safeDetail: String

    public init(_ state: DeveloperSupportState, failure: DeveloperSupportFailure? = nil, safeDetail: String) {
        self.state = state
        self.failure = failure
        self.safeDetail = safeDetail
    }
}

public enum DeveloperSupportIntegrity {
    public static func sha256(url: URL, maximumBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024) throws -> (digest: String, size: UInt64) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0, UInt64(size) <= maximumBytes else {
            throw DeveloperSupportFailure.corruptAsset
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var observed: UInt64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            observed += UInt64(data.count)
            guard observed <= maximumBytes else { throw DeveloperSupportFailure.corruptAsset }
            hasher.update(data: data)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), observed)
    }

    public static func validate(_ artifact: DeveloperSupportArtifact, for requirements: DeveloperSupportRequirements) throws {
        guard artifact.schemaVersion == 1,
              artifact.minimumBridgeABI <= 1,
              artifact.buildVersion == requirements.buildVersion,
              artifact.buildIdentity == requirements.buildIdentity else {
            throw DeveloperSupportFailure.wrongBuildIdentity
        }
        let image = try sha256(url: artifact.imageURL)
        guard image.size == artifact.imageSize, image.digest == artifact.imageSHA256 else {
            throw DeveloperSupportFailure.corruptAsset
        }
        guard try sha256(url: artifact.buildManifestURL).digest == artifact.buildManifestSHA256 else {
            throw DeveloperSupportFailure.corruptAsset
        }
        if let trustCacheURL = artifact.trustCacheURL, let expected = artifact.trustCacheSHA256,
           try sha256(url: trustCacheURL).digest != expected {
            throw DeveloperSupportFailure.corruptAsset
        }
    }
}

/// Reads pre-authorized Apple caches only. It never launches Xcode or xcrun.
public struct ExistingAppleCacheProvider: DeveloperSupportProviding {
    public let productionEligible = true
    private let roots: [URL]

    public init(roots: [URL] = ExistingAppleCacheProvider.defaultRoots()) {
        self.roots = roots
    }

    public func artifact(matching requirements: DeveloperSupportRequirements) async throws -> DeveloperSupportArtifact? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for root in roots {
            let metadata = root
                .appendingPathComponent(requirements.buildVersion, isDirectory: true)
                .appendingPathComponent(requirements.buildIdentity, isDirectory: true)
                .appendingPathComponent("iossim-developer-support.json")
            guard let data = try? Data(contentsOf: metadata), data.count <= 1_048_576,
                  let artifact = try? decoder.decode(DeveloperSupportArtifact.self, from: data) else { continue }
            try DeveloperSupportIntegrity.validate(artifact, for: requirements)
            return artifact
        }
        return nil
    }

    public static func defaultRoots(fileManager: FileManager = .default) -> [URL] {
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return [
            library.appendingPathComponent("Developer/DeveloperDiskImages", isDirectory: true),
            library.appendingPathComponent("Developer/CoreDevice/Caches", isDirectory: true)
        ]
    }
}

/// Test-only provider. Production coordinators reject it.
public struct DevelopmentFixtureProvider: DeveloperSupportProviding {
    public let productionEligible = false
    public let value: DeveloperSupportArtifact?

    public init(_ value: DeveloperSupportArtifact?) { self.value = value }
    public func artifact(matching requirements: DeveloperSupportRequirements) async throws -> DeveloperSupportArtifact? { value }
}

public actor DeveloperSupportCoordinator {
    private let providers: [any DeveloperSupportProviding]
    private let service: any DeveloperSupportDeviceServicing
    private let allowDevelopmentFixtures: Bool
    public private(set) var status = DeveloperSupportStatus(.missing, safeDetail: "not checked")

    public init(
        providers: [any DeveloperSupportProviding],
        service: any DeveloperSupportDeviceServicing,
        allowDevelopmentFixtures: Bool = false
    ) {
        self.providers = providers
        self.service = service
        self.allowDevelopmentFixtures = allowDevelopmentFixtures
    }

    public func prepare(
        device: IOSSimDeviceIdentity,
        requirements: DeveloperSupportRequirements,
        developerMode: DeveloperModeReadiness
    ) async -> DeveloperSupportStatus {
        guard developerMode == .enabled else {
            status = DeveloperSupportStatus(.failed, failure: .developerModeDisabled, safeDetail: "Developer Mode requires user action")
            return status
        }
        do {
            if try await service.isMounted(on: device, requirements: requirements) {
                try await service.verifyRSD(on: device)
                status = DeveloperSupportStatus(.mounted, safeDetail: "developer services verified")
                return status
            }
            status = DeveloperSupportStatus(.acquisitionNeeded, safeDetail: "exact developer-support asset required")
            var selected: DeveloperSupportArtifact?
            for provider in providers where provider.productionEligible || allowDevelopmentFixtures {
                if let candidate = try await provider.artifact(matching: requirements) {
                    selected = candidate
                    break
                }
            }
            guard let artifact = selected else {
                status = DeveloperSupportStatus(.failed, failure: .noApprovedSource, safeDetail: "no approved exact-build source is available")
                return status
            }
            try DeveloperSupportIntegrity.validate(artifact, for: requirements)
            status = DeveloperSupportStatus(.personalizing, safeDetail: "requesting device-specific personalization")
            let request = Self.tssRequestMetadata(requirements: requirements, artifact: artifact)
            let manifest: Data
            do {
                manifest = try await service.personalizationManifest(on: device, artifact: artifact, request: request)
            } catch {
                throw DeveloperSupportFailure.personalizationRejected
            }
            guard !manifest.isEmpty, manifest.count <= 16 * 1_024 * 1_024 else {
                throw DeveloperSupportFailure.personalizationRejected
            }
            status = DeveloperSupportStatus(.mounting, safeDetail: "mounting exact developer-support image")
            do { try await service.mount(on: device, artifact: artifact, personalizationManifest: manifest) }
            catch { throw DeveloperSupportFailure.mountRejected }
            guard try await service.isMounted(on: device, requirements: requirements) else {
                throw DeveloperSupportFailure.mountRejected
            }
            do { try await service.verifyRSD(on: device) }
            catch { throw DeveloperSupportFailure.serviceMapUnavailable }
            status = DeveloperSupportStatus(.mounted, safeDetail: "developer services verified")
        } catch let failure as DeveloperSupportFailure {
            status = DeveloperSupportStatus(.failed, failure: failure, safeDetail: failure.rawValue)
        } catch {
            status = DeveloperSupportStatus(.failed, failure: .deviceDisconnected, safeDetail: "device service interrupted")
        }
        return status
    }

    /// Non-secret structural metadata passed to the native TSS implementation.
    public static func tssRequestMetadata(
        requirements: DeveloperSupportRequirements,
        artifact: DeveloperSupportArtifact
    ) -> [String: String] {
        [
            "@ApImg4Ticket": "true",
            "@ApProductionMode": "true",
            "@ApSecurityMode": requirements.securityMode ? "true" : "false",
            "ApBoardID": String(requirements.boardID),
            "ApChipID": String(requirements.chipID),
            "ApECID": String(requirements.ecid),
            "BuildIdentity": requirements.buildIdentity,
            "BuildVersion": requirements.buildVersion,
            "ImageSHA256": artifact.imageSHA256,
            "RequestRule": "LoadableTrustCache"
        ]
    }
}

public protocol RSDReadinessProbing: Sendable {
    func verifyRSD(on device: IOSSimDeviceIdentity) async throws
}

public struct AwaitingPhysicalRSDProbe: RSDReadinessProbing {
    public init() {}
    public func verifyRSD(on device: IOSSimDeviceIdentity) async throws {
        throw DeveloperSupportFailure.serviceMapUnavailable
    }
}

/// Production adapter for the native image-mounter flow. The pinned Rust
/// bridge performs device queries, TSS personalization, upload, and mount.
/// RSD proof is injected by the pairing/tunnel layer so a mount alone can
/// never be reported as READY.
public struct NativeDeveloperSupportDeviceService: DeveloperSupportDeviceServicing {
    private let transport: DynamicNativeDeviceTransport
    private let rsdProbe: any RSDReadinessProbing

    public init(
        transport: DynamicNativeDeviceTransport = DynamicNativeDeviceTransport(),
        rsdProbe: any RSDReadinessProbing = AwaitingPhysicalRSDProbe()
    ) {
        self.transport = transport
        self.rsdProbe = rsdProbe
    }

    public func isMounted(on device: IOSSimDeviceIdentity, requirements: DeveloperSupportRequirements) async throws -> Bool {
        try transport.developerSupportMounted(on: device)
    }

    public func personalizationManifest(
        on device: IOSSimDeviceIdentity,
        artifact: DeveloperSupportArtifact,
        request: [String: String]
    ) async throws -> Data {
        // The native mount operation performs the nonce/query/TSS sequence and
        // never exposes the device ticket across FFI.
        Data("native-personalization-pending".utf8)
    }

    public func mount(
        on device: IOSSimDeviceIdentity,
        artifact: DeveloperSupportArtifact,
        personalizationManifest: Data
    ) async throws {
        try transport.mountDeveloperSupport(on: device, artifact: artifact)
    }

    public func verifyRSD(on device: IOSSimDeviceIdentity) async throws {
        try await rsdProbe.verifyRSD(on: device)
    }
}
