import CryptoKit
import Foundation

public struct DeveloperSupportDownloadRequest: Equatable, Sendable {
    public let url: URL
    public let maximumBytes: Int

    public init(url: URL, maximumBytes: Int) {
        self.url = url
        self.maximumBytes = maximumBytes
    }
}

public protocol DeveloperSupportDownloading: Sendable {
    func download(_ request: DeveloperSupportDownloadRequest) async throws -> Data
}

public struct URLSessionDeveloperSupportDownloader: DeveloperSupportDownloading, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(_ request: DeveloperSupportDownloadRequest) async throws -> Data {
        guard request.url.scheme?.lowercased() == "https", request.maximumBytes > 0 else {
            throw DeveloperSupportFailure.sourceUnavailable
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.timeoutInterval = 60
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url?.scheme?.lowercased() == "https",
                  http.url?.host?.lowercased() == request.url.host?.lowercased() else {
                throw DeveloperSupportFailure.sourceUnavailable
            }
            guard data.count <= request.maximumBytes else {
                throw DeveloperSupportFailure.corruptAsset
            }
            return data
        } catch let failure as DeveloperSupportFailure {
            throw failure
        } catch {
            throw DeveloperSupportFailure.networkUnavailable
        }
    }
}

public struct DeveloperSupportPinnedAsset: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let size: Int
    public let maximumBytes: Int

    public init(name: String, sha256: String, size: Int, maximumBytes: Int) {
        self.name = name
        self.sha256 = sha256.lowercased()
        self.size = size
        self.maximumBytes = maximumBytes
    }
}

public struct ThirdPartyMirrorDevelopmentConfiguration: Codable, Equatable, Sendable {
    public let sourceRevision: String
    public let baseURL: URL
    public let developerSupportBuildVersion: String
    public let minimumProductMajorVersion: Int
    public let maximumProductMajorVersion: Int
    public let assets: [DeveloperSupportPinnedAsset]
    public let licensePolicyID: String
    public let revocationPolicyID: String
    public let revokedSourceRevisions: Set<String>
    public let revokedArtifactSHA256: Set<String>

    public init(
        sourceRevision: String,
        baseURL: URL,
        developerSupportBuildVersion: String,
        minimumProductMajorVersion: Int,
        maximumProductMajorVersion: Int,
        assets: [DeveloperSupportPinnedAsset],
        licensePolicyID: String,
        revocationPolicyID: String,
        revokedSourceRevisions: Set<String> = [],
        revokedArtifactSHA256: Set<String> = []
    ) {
        self.sourceRevision = sourceRevision.lowercased()
        self.baseURL = baseURL
        self.developerSupportBuildVersion = developerSupportBuildVersion
        self.minimumProductMajorVersion = minimumProductMajorVersion
        self.maximumProductMajorVersion = maximumProductMajorVersion
        self.assets = assets
        self.licensePolicyID = licensePolicyID
        self.revocationPolicyID = revocationPolicyID
        self.revokedSourceRevisions = Set(revokedSourceRevisions.map { $0.lowercased() })
        self.revokedArtifactSHA256 = Set(revokedArtifactSHA256.map { $0.lowercased() })
    }

    /// Development/local-test evidence only. The repository does not declare
    /// an Apple-asset redistribution grant, so this policy must never be used
    /// by a public-production composition and no asset is bundled in Veya.app.
    public static let pinnedV030 = Self(
        sourceRevision: "1daa8aa4adf12ab6974c2fac378685ce55dd3907",
        baseURL: URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/1daa8aa4adf12ab6974c2fac378685ce55dd3907/PersonalizedImages/Xcode_iOS_DDI_Personalized/")!,
        developerSupportBuildVersion: "27A5228h",
        minimumProductMajorVersion: 17,
        maximumProductMajorVersion: 26,
        assets: [
            .init(name: "Image.dmg", sha256: "05fd807da5e19f030fa4941f24800c965c6c77982ab572dd5d1ef778fb69f9ca", size: 15_733_248, maximumBytes: 64 * 1_024 * 1_024),
            .init(name: "BuildManifest.plist", sha256: "8edd4a2f4f4ef1fbd7bfe49785d8badc673d1395d1d94d85b132ca8ab5ecaf54", size: 801_505, maximumBytes: 4 * 1_024 * 1_024),
            .init(name: "Image.dmg.trustcache", sha256: "36af60889ff5a737874a26daeb8e1a0139ebfebec6ec2e4d8f6a3c1bf1dce35c", size: 1_895, maximumBytes: 1 * 1_024 * 1_024),
        ],
        licensePolicyID: "development-evaluation-only-apple-asset-rights-unresolved-v1",
        revocationPolicyID: "pinned-source-and-hash-denylist-v1"
    )

    public func validate() throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard sourceRevision.count == 40,
              sourceRevision.unicodeScalars.allSatisfy(hex.contains),
              baseURL.scheme?.lowercased() == "https",
              baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.pathComponents.contains(sourceRevision),
              !developerSupportBuildVersion.isEmpty,
              minimumProductMajorVersion >= 17,
              maximumProductMajorVersion >= minimumProductMajorVersion,
              !licensePolicyID.isEmpty,
              !revocationPolicyID.isEmpty else {
            throw DeveloperSupportFailure.sourceUnavailable
        }
        let required = Set(["Image.dmg", "BuildManifest.plist", "Image.dmg.trustcache"])
        guard Set(assets.map(\.name)) == required,
              assets.allSatisfy({ asset in
                  asset.sha256.count == 64
                      && asset.sha256.unicodeScalars.allSatisfy(hex.contains)
                      && asset.size > 0
                      && asset.maximumBytes >= asset.size
              }) else {
            throw DeveloperSupportFailure.corruptAsset
        }
    }
}

/// A deliberately development/local-test-only provider matching the consumer
/// behavior observed in Vanish: acquire three pinned personalized DDI inputs,
/// verify them before cache commit, then let Veya's native bridge perform TSS
/// personalization and mount. It has no production fallback mode.
public actor ThirdPartyMirrorDevelopmentProvider: DeveloperSupportProviding, DeveloperSupportBuildProviding {
    public nonisolated let descriptor = DeveloperSupportProviderDescriptor(
        providerID: "thirdPartyMirrorDevelopmentProvider",
        classification: .thirdPartyMirrorDevelopment,
        supportsFreshAcquisition: true,
        provenancePolicyID: "immutable-revision-and-sha256-v1"
    )

    private let configuration: ThirdPartyMirrorDevelopmentConfiguration
    private let cacheRoot: URL
    private let downloader: any DeveloperSupportDownloading
    private let fileManager: FileManager

    public init(
        configuration: ThirdPartyMirrorDevelopmentConfiguration = .pinnedV030,
        cacheRoot: URL = ExistingAppleCacheProvider.defaultRoots()[0],
        downloader: any DeveloperSupportDownloading = URLSessionDeveloperSupportDownloader(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.cacheRoot = cacheRoot
        self.downloader = downloader
        self.fileManager = fileManager
    }

    public func artifact(matching requirements: DeveloperSupportRequirements) async throws -> DeveloperSupportArtifact? {
        try await artifact(
            productVersion: requirements.productVersion,
            buildVersion: requirements.buildVersion,
            buildIdentity: requirements.buildIdentity
        )
    }

    public func artifact(productVersion: String, buildVersion: String) async throws -> DeveloperSupportArtifact? {
        try await artifact(
            productVersion: productVersion,
            buildVersion: buildVersion,
            buildIdentity: "personalized-\(configuration.developerSupportBuildVersion)"
        )
    }

    private func artifact(
        productVersion: String,
        buildVersion: String,
        buildIdentity: String
    ) async throws -> DeveloperSupportArtifact? {
        try configuration.validate()
        guard let major = Int(productVersion.split(separator: ".").first ?? ""),
              (configuration.minimumProductMajorVersion...configuration.maximumProductMajorVersion).contains(major),
              !buildVersion.isEmpty,
              !buildIdentity.isEmpty else {
            return nil
        }
        guard !configuration.revokedSourceRevisions.contains(configuration.sourceRevision),
              configuration.assets.allSatisfy({ !configuration.revokedArtifactSHA256.contains($0.sha256) }) else {
            throw DeveloperSupportFailure.revokedAsset
        }

        let finalDirectory = cacheDirectory(
            productVersion: productVersion,
            buildVersion: buildVersion,
            buildIdentity: buildIdentity
        )
        let metadataURL = finalDirectory.appendingPathComponent("iossim-developer-support.json")
        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                let cached = try loadMetadata(at: metadataURL, constrainedTo: finalDirectory)
                try DeveloperSupportIntegrity.validateFiles(cached, expectedBuildVersion: buildVersion)
                try assertMatchesConfiguration(cached)
                return cached
            } catch {
                try quarantine(finalDirectory)
            }
        }

        try fileManager.createDirectory(
            at: finalDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let candidate = finalDirectory.deletingLastPathComponent()
            .appendingPathComponent(".candidate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var actual: [String: String] = [:]
            for asset in configuration.assets {
                let data = try await downloader.download(.init(
                    url: configuration.baseURL.appendingPathComponent(asset.name),
                    maximumBytes: asset.maximumBytes
                ))
                let digest = Self.sha256(data)
                guard data.count == asset.size, digest == asset.sha256 else {
                    throw DeveloperSupportFailure.corruptAsset
                }
                actual[asset.name] = digest
                let target = candidate.appendingPathComponent(asset.name)
                try data.write(to: target, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            try validateBuildManifest(candidate.appendingPathComponent("BuildManifest.plist"))

            let finalImage = finalDirectory.appendingPathComponent("Image.dmg")
            let finalManifest = finalDirectory.appendingPathComponent("BuildManifest.plist")
            let finalTrust = finalDirectory.appendingPathComponent("Image.dmg.trustcache")
            let expected = Dictionary(uniqueKeysWithValues: configuration.assets.map { ($0.name, $0.sha256) })
            let provenance = DeveloperSupportProvenance(
                provider: descriptor,
                sourceURL: configuration.baseURL.absoluteString,
                sourceRevision: configuration.sourceRevision,
                sourceAssetIdentity: Self.assetIdentity(expected),
                downloadedAt: Date(),
                expectedSHA256: expected,
                actualSHA256: actual,
                manifestIdentity: expected["BuildManifest.plist"]!,
                trustCacheIdentity: expected["Image.dmg.trustcache"]!,
                licensePolicyID: configuration.licensePolicyID,
                revocationPolicyID: configuration.revocationPolicyID,
                cacheLocation: finalDirectory.path
            )
            let image = configuration.assets.first(where: { $0.name == "Image.dmg" })!
            let artifact = DeveloperSupportArtifact(
                provenanceID: provenance.sourceAssetIdentity,
                productVersion: productVersion,
                buildVersion: buildVersion,
                buildIdentity: buildIdentity,
                developerSupportBuildVersion: configuration.developerSupportBuildVersion,
                imageURL: finalImage,
                imageSHA256: image.sha256,
                imageSize: UInt64(image.size),
                trustCacheURL: finalTrust,
                trustCacheSHA256: expected["Image.dmg.trustcache"],
                buildManifestURL: finalManifest,
                buildManifestSHA256: expected["BuildManifest.plist"]!,
                provenance: provenance
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let metadata = try encoder.encode(artifact)
            let candidateMetadata = candidate.appendingPathComponent("iossim-developer-support.json")
            try metadata.write(to: candidateMetadata, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidateMetadata.path)
            try fileManager.moveItem(at: candidate, to: finalDirectory)
            let committed = try loadMetadata(
                at: finalDirectory.appendingPathComponent("iossim-developer-support.json"),
                constrainedTo: finalDirectory
            )
            try DeveloperSupportIntegrity.validateFiles(committed, expectedBuildVersion: buildVersion)
            try assertMatchesConfiguration(committed)
            return committed
        } catch let failure as DeveloperSupportFailure {
            try? quarantine(candidate)
            throw failure
        } catch {
            try? quarantine(candidate)
            throw DeveloperSupportFailure.cacheWriteFailed
        }
    }

    private func loadMetadata(at url: URL, constrainedTo directory: URL) throws -> DeveloperSupportArtifact {
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw DeveloperSupportFailure.corruptAsset }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artifact = try decoder.decode(DeveloperSupportArtifact.self, from: data)
        let prefix = directory.standardizedFileURL.path + "/"
        let paths = [artifact.imageURL, artifact.buildManifestURL] + (artifact.trustCacheURL.map { [$0] } ?? [])
        guard paths.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(prefix) }) else {
            throw DeveloperSupportFailure.corruptAsset
        }
        return artifact
    }

    private func assertMatchesConfiguration(_ artifact: DeveloperSupportArtifact) throws {
        guard artifact.provenance.provider == descriptor,
              artifact.provenance.sourceRevision == configuration.sourceRevision,
              artifact.developerSupportBuildVersion == configuration.developerSupportBuildVersion,
              artifact.provenance.licensePolicyID == configuration.licensePolicyID,
              artifact.provenance.revocationPolicyID == configuration.revocationPolicyID else {
            throw DeveloperSupportFailure.wrongBuildIdentity
        }
    }

    private func validateBuildManifest(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["ProductBuildVersion"] as? String == configuration.developerSupportBuildVersion,
              let identities = plist["BuildIdentities"] as? [[String: Any]],
              !identities.isEmpty,
              identities.contains(where: { identity in
                  guard let manifest = identity["Manifest"] as? [String: Any],
                        let trust = manifest["LoadableTrustCache"] as? [String: Any],
                        let trustInfo = trust["Info"] as? [String: Any],
                        let dmg = manifest["PersonalizedDMG"] as? [String: Any],
                        let dmgInfo = dmg["Info"] as? [String: Any] else { return false }
                  return trustInfo["Path"] as? String == "Image.dmg.trustcache"
                      && dmgInfo["Path"] as? String == "Image.dmg"
              }) else {
            throw DeveloperSupportFailure.invalidManifest
        }
    }

    private func cacheDirectory(productVersion: String, buildVersion: String, buildIdentity: String) -> URL {
        let key = Self.sha256(Data("\(productVersion)\u{0}\(buildVersion)\u{0}\(buildIdentity)\u{0}\(configuration.sourceRevision)".utf8))
        return cacheRoot
            .appendingPathComponent(buildVersion, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private func quarantine(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(".quarantine-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: url, to: destination)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func assetIdentity(_ hashes: [String: String]) -> String {
        let material = hashes.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        return sha256(Data(material.utf8))
    }
}
