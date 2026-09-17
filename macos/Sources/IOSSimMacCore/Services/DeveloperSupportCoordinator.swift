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
    case sourceUnavailable
    case networkUnavailable
    case wrongBuildIdentity
    case invalidManifest
    case corruptAsset
    case revokedAsset
    case cacheWriteFailed
    case developerModeDisabled
    case personalizationRejected
    case tssUnavailable
    case uploadFailed
    case mountRejected
    case serviceMapUnavailable
    case deviceDisconnected
}

public enum DeveloperSupportPersonalizationStatus: String, Codable, Equatable, Sendable {
    case notStarted
    case completed
}

/// Release-policy classification for developer-support inputs. This is a
/// security boundary, not descriptive metadata: a public-production selector
/// must never execute a development mirror or test fixture.
public enum DeveloperSupportProviderClassification: String, Codable, Equatable, Sendable {
    case existingValidatedCache
    case thirdPartyMirrorDevelopment
    case testFixture
    case approvedProductionSource
}

public enum DeveloperSupportDistributionClass: String, Codable, Equatable, Sendable {
    case development
    case localTest
    case publicProduction
}

public struct DeveloperSupportProviderDescriptor: Codable, Equatable, Sendable {
    public let providerID: String
    public let classification: DeveloperSupportProviderClassification
    public let supportsFreshAcquisition: Bool
    public let provenancePolicyID: String

    public init(
        providerID: String,
        classification: DeveloperSupportProviderClassification,
        supportsFreshAcquisition: Bool,
        provenancePolicyID: String
    ) {
        self.providerID = providerID
        self.classification = classification
        self.supportsFreshAcquisition = supportsFreshAcquisition
        self.provenancePolicyID = provenancePolicyID
    }
}

public enum DeveloperSupportProviderPolicyError: Error, Equatable, Sendable {
    case invalidDescriptor(String)
    case providerNotAllowed(providerID: String, distribution: DeveloperSupportDistributionClass)
    case approvedProductionProviderRequired
}

public struct DeveloperSupportProviderPolicy: Codable, Equatable, Sendable {
    public let distribution: DeveloperSupportDistributionClass

    public init(distribution: DeveloperSupportDistributionClass) {
        self.distribution = distribution
    }

    public static let development = Self(distribution: .development)
    public static let localTest = Self(distribution: .localTest)
    public static let publicProduction = Self(distribution: .publicProduction)

    public func validate(_ descriptor: DeveloperSupportProviderDescriptor) throws {
        guard !descriptor.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !descriptor.provenancePolicyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeveloperSupportProviderPolicyError.invalidDescriptor(descriptor.providerID)
        }
        guard permits(descriptor) else {
            throw DeveloperSupportProviderPolicyError.providerNotAllowed(
                providerID: descriptor.providerID,
                distribution: distribution
            )
        }
    }

    public func permits(_ descriptor: DeveloperSupportProviderDescriptor) -> Bool {
        switch distribution {
        case .development, .localTest:
            return true
        case .publicProduction:
            switch descriptor.classification {
            case .existingValidatedCache, .approvedProductionSource:
                return true
            case .thirdPartyMirrorDevelopment, .testFixture:
                return false
            }
        }
    }

    /// A validated cache may be consumed in production, but it cannot satisfy
    /// the clean-machine public release gate by itself.
    public func assertFreshAcquisitionConfigured(
        _ descriptors: [DeveloperSupportProviderDescriptor]
    ) throws {
        for descriptor in descriptors { try validate(descriptor) }
        if distribution == .publicProduction {
            guard descriptors.contains(where: {
                $0.classification == .approvedProductionSource && $0.supportsFreshAcquisition
            }) else {
                throw DeveloperSupportProviderPolicyError.approvedProductionProviderRequired
            }
        }
    }
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

public struct DeveloperSupportProvenance: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let provider: DeveloperSupportProviderDescriptor
    public let sourceURL: String
    public let sourceRevision: String
    public let sourceAssetIdentity: String
    public let downloadedAt: Date
    public let expectedSHA256: [String: String]
    public let actualSHA256: [String: String]
    public let manifestIdentity: String
    public let trustCacheIdentity: String
    public let licensePolicyID: String
    public let revocationPolicyID: String
    public let cacheLocation: String
    public let personalizationStatus: DeveloperSupportPersonalizationStatus

    public init(
        schemaVersion: Int = DeveloperSupportProvenance.currentSchemaVersion,
        provider: DeveloperSupportProviderDescriptor,
        sourceURL: String,
        sourceRevision: String,
        sourceAssetIdentity: String,
        downloadedAt: Date,
        expectedSHA256: [String: String],
        actualSHA256: [String: String],
        manifestIdentity: String,
        trustCacheIdentity: String,
        licensePolicyID: String,
        revocationPolicyID: String,
        cacheLocation: String,
        personalizationStatus: DeveloperSupportPersonalizationStatus = .notStarted
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.sourceAssetIdentity = sourceAssetIdentity
        self.downloadedAt = downloadedAt
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.manifestIdentity = manifestIdentity
        self.trustCacheIdentity = trustCacheIdentity
        self.licensePolicyID = licensePolicyID
        self.revocationPolicyID = revocationPolicyID
        self.cacheLocation = cacheLocation
        self.personalizationStatus = personalizationStatus
    }
}

public struct DeveloperSupportArtifact: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let provenanceID: String
    public let productVersion: String
    public let buildVersion: String
    public let buildIdentity: String
    public let developerSupportBuildVersion: String
    public let imageURL: URL
    public let imageSHA256: String
    public let imageSize: UInt64
    public let trustCacheURL: URL?
    public let trustCacheSHA256: String?
    public let buildManifestURL: URL
    public let buildManifestSHA256: String
    public let minimumBridgeABI: UInt32
    public let validatedAt: Date
    public let provenance: DeveloperSupportProvenance

    public init(
        schemaVersion: Int = DeveloperSupportArtifact.currentSchemaVersion,
        provenanceID: String,
        productVersion: String,
        buildVersion: String,
        buildIdentity: String,
        developerSupportBuildVersion: String,
        imageURL: URL,
        imageSHA256: String,
        imageSize: UInt64,
        trustCacheURL: URL? = nil,
        trustCacheSHA256: String? = nil,
        buildManifestURL: URL,
        buildManifestSHA256: String,
        minimumBridgeABI: UInt32 = DynamicNativeDeviceTransport.requiredABIVersion,
        validatedAt: Date = Date(),
        provenance: DeveloperSupportProvenance
    ) {
        self.schemaVersion = schemaVersion
        self.provenanceID = provenanceID
        self.productVersion = productVersion
        self.buildVersion = buildVersion
        self.buildIdentity = buildIdentity
        self.developerSupportBuildVersion = developerSupportBuildVersion
        self.imageURL = imageURL
        self.imageSHA256 = imageSHA256.lowercased()
        self.imageSize = imageSize
        self.trustCacheURL = trustCacheURL
        self.trustCacheSHA256 = trustCacheSHA256?.lowercased()
        self.buildManifestURL = buildManifestURL
        self.buildManifestSHA256 = buildManifestSHA256.lowercased()
        self.minimumBridgeABI = minimumBridgeABI
        self.validatedAt = validatedAt
        self.provenance = provenance
    }
}

public protocol DeveloperSupportProviding: Sendable {
    var descriptor: DeveloperSupportProviderDescriptor { get }
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
        guard artifact.schemaVersion == DeveloperSupportArtifact.currentSchemaVersion,
              artifact.provenance.schemaVersion == DeveloperSupportProvenance.currentSchemaVersion,
              artifact.minimumBridgeABI <= DynamicNativeDeviceTransport.requiredABIVersion,
              artifact.productVersion == requirements.productVersion,
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
        try validateProvenance(artifact)
    }

    public static func validateFiles(
        _ artifact: DeveloperSupportArtifact,
        expectedBuildVersion: String
    ) throws {
        guard artifact.schemaVersion == DeveloperSupportArtifact.currentSchemaVersion,
              artifact.provenance.schemaVersion == DeveloperSupportProvenance.currentSchemaVersion,
              artifact.minimumBridgeABI <= DynamicNativeDeviceTransport.requiredABIVersion,
              artifact.buildVersion == expectedBuildVersion,
              !artifact.buildIdentity.isEmpty else {
            throw DeveloperSupportFailure.wrongBuildIdentity
        }
        let image = try sha256(url: artifact.imageURL)
        guard image.size == artifact.imageSize, image.digest == artifact.imageSHA256,
              try sha256(url: artifact.buildManifestURL).digest == artifact.buildManifestSHA256 else {
            throw DeveloperSupportFailure.corruptAsset
        }
        guard let trustCacheURL = artifact.trustCacheURL,
              let expectedTrustCache = artifact.trustCacheSHA256,
              try sha256(url: trustCacheURL).digest == expectedTrustCache else {
            throw DeveloperSupportFailure.corruptAsset
        }
        try validateProvenance(artifact)
    }

    private static func validateProvenance(_ artifact: DeveloperSupportArtifact) throws {
        let required = ["Image.dmg", "BuildManifest.plist", "Image.dmg.trustcache"]
        guard !artifact.provenance.provider.providerID.isEmpty,
              !artifact.provenance.sourceURL.isEmpty,
              !artifact.provenance.sourceRevision.isEmpty,
              !artifact.provenance.sourceAssetIdentity.isEmpty,
              !artifact.provenance.licensePolicyID.isEmpty,
              !artifact.provenance.revocationPolicyID.isEmpty,
              !artifact.provenance.cacheLocation.isEmpty,
              artifact.provenance.manifestIdentity == artifact.buildManifestSHA256,
              artifact.provenance.trustCacheIdentity == artifact.trustCacheSHA256,
              required.allSatisfy({ name in
                  artifact.provenance.expectedSHA256[name] == artifact.provenance.actualSHA256[name]
              }) else {
            throw DeveloperSupportFailure.corruptAsset
        }
    }
}

/// Reads only the Veya-owned validated cache. It never launches Xcode or xcrun
/// and never treats developer-machine Xcode/CoreDevice caches as a consumer
/// dependency.
public struct ExistingAppleCacheProvider: DeveloperSupportProviding {
    public let descriptor = DeveloperSupportProviderDescriptor(
        providerID: "existingAppleValidatedCache",
        classification: .existingValidatedCache,
        supportsFreshAcquisition: false,
        provenancePolicyID: "local-validated-cache-v1"
    )
    let roots: [URL]

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
            library.appendingPathComponent(
                "Application Support/IOSSim/DeveloperSupport", isDirectory: true
            )
        ]
    }
}

/// Test-only provider. Production coordinators reject it.
public struct DevelopmentFixtureProvider: DeveloperSupportProviding {
    public let descriptor = DeveloperSupportProviderDescriptor(
        providerID: "developmentFixture",
        classification: .testFixture,
        supportsFreshAcquisition: false,
        provenancePolicyID: "hermetic-test-fixture-v1"
    )
    public let value: DeveloperSupportArtifact?

    public init(_ value: DeveloperSupportArtifact?) { self.value = value }
    public func artifact(matching requirements: DeveloperSupportRequirements) async throws -> DeveloperSupportArtifact? { value }
}

public actor DeveloperSupportCoordinator {
    private let providers: [any DeveloperSupportProviding]
    private let service: any DeveloperSupportDeviceServicing
    private let providerPolicy: DeveloperSupportProviderPolicy
    public private(set) var status = DeveloperSupportStatus(.missing, safeDetail: "not checked")

    public init(
        providers: [any DeveloperSupportProviding],
        service: any DeveloperSupportDeviceServicing,
        providerPolicy: DeveloperSupportProviderPolicy = .publicProduction
    ) {
        self.providers = providers
        self.service = service
        self.providerPolicy = providerPolicy
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
            for provider in providers where providerPolicy.permits(provider.descriptor) {
                try providerPolicy.validate(provider.descriptor)
                if let candidate = try await provider.artifact(matching: requirements) {
                    guard providerPolicy.permits(candidate.provenance.provider) else { continue }
                    try providerPolicy.validate(candidate.provenance.provider)
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
            } catch let failure as DeveloperSupportFailure {
                throw failure
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
