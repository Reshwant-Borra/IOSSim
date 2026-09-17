import CryptoKit
import XCTest
@testable import IOSSimMacCore

final class DeveloperSupportCoordinatorTests: XCTestCase {
    func testPinnedDevelopmentProviderRealNetworkWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["IOSSIM_RUN_NETWORK_DDI_TEST"] == "1" else {
            throw XCTSkip("Pinned third-party DDI network acquisition is opt-in and LOCAL_TEST_ONLY")
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let requestedRoot = try XCTUnwrap(environment["IOSSIM_DDI_TEST_CACHE_ROOT"])
        let cacheRoot = URL(fileURLWithPath: requestedRoot, isDirectory: true).standardizedFileURL
        guard cacheRoot.path.hasPrefix(repositoryRoot.standardizedFileURL.path + "/") else {
            XCTFail("network DDI test cache must remain inside the IOSSim workspace")
            return
        }
        let provider = ThirdPartyMirrorDevelopmentProvider(cacheRoot: cacheRoot)
        let value = try await provider.artifact(productVersion: "26.0", buildVersion: "23A-LOCAL-NETWORK-TEST")
        let artifact = try XCTUnwrap(value)
        XCTAssertEqual(artifact.developerSupportBuildVersion, "27A5228h")
        XCTAssertEqual(artifact.provenance.provider.classification, .thirdPartyMirrorDevelopment)
        XCTAssertEqual(artifact.provenance.sourceRevision, ThirdPartyMirrorDevelopmentConfiguration.pinnedV030.sourceRevision)
        XCTAssertNoThrow(try DeveloperSupportIntegrity.validateFiles(artifact, expectedBuildVersion: "23A-LOCAL-NETWORK-TEST"))
    }

    func testDevelopmentMirrorAcquiresPinnedAssetsIntoEmptyVeyaCacheAndReusesThem() async throws {
        let fixture = try developmentProviderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = ThirdPartyMirrorDevelopmentProvider(
            configuration: fixture.configuration,
            cacheRoot: fixture.root,
            downloader: fixture.downloader
        )

        let firstValue = try await provider.artifact(matching: requirements())
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.provenance.provider.classification, .thirdPartyMirrorDevelopment)
        XCTAssertEqual(first.provenance.sourceRevision, fixture.configuration.sourceRevision)
        XCTAssertEqual(first.provenance.personalizationStatus, .notStarted)
        XCTAssertTrue(first.imageURL.path.hasPrefix(fixture.root.path + "/"))
        let firstRequestCount = await fixture.downloader.requestCount
        XCTAssertEqual(firstRequestCount, 3)
        XCTAssertNoThrow(try DeveloperSupportIntegrity.validate(first, for: requirements()))

        let secondValue = try await provider.artifact(matching: requirements())
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second, first)
        let secondRequestCount = await fixture.downloader.requestCount
        XCTAssertEqual(secondRequestCount, 3, "validated cache must avoid network reacquisition")
    }

    func testCorruptDevelopmentCacheIsQuarantinedThenReacquired() async throws {
        let fixture = try developmentProviderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = ThirdPartyMirrorDevelopmentProvider(
            configuration: fixture.configuration,
            cacheRoot: fixture.root,
            downloader: fixture.downloader
        )
        let firstValue = try await provider.artifact(matching: requirements())
        let first = try XCTUnwrap(firstValue)
        try Data("corrupt".utf8).write(to: first.imageURL, options: .atomic)

        let repairedValue = try await provider.artifact(matching: requirements())
        let repaired = try XCTUnwrap(repairedValue)
        XCTAssertNoThrow(try DeveloperSupportIntegrity.validate(repaired, for: requirements()))
        let requestCount = await fixture.downloader.requestCount
        XCTAssertEqual(requestCount, 6)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: repaired.imageURL.deletingLastPathComponent().deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(siblings.contains(where: { $0.lastPathComponent.hasPrefix(".quarantine-") }))
    }

    func testDevelopmentProviderRejectsWrongHashBadManifestAndRevocation() async throws {
        let wrongHashFixture = try developmentProviderFixture(declaredImageHash: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: wrongHashFixture.root) }
        let wrongHashProvider = ThirdPartyMirrorDevelopmentProvider(
            configuration: wrongHashFixture.configuration,
            cacheRoot: wrongHashFixture.root,
            downloader: wrongHashFixture.downloader
        )
        do {
            _ = try await wrongHashProvider.artifact(matching: requirements())
            XCTFail("expected hash rejection")
        } catch {
            XCTAssertEqual(error as? DeveloperSupportFailure, .corruptAsset)
        }

        let badManifestFixture = try developmentProviderFixture(manifestBuild: "WRONG")
        defer { try? FileManager.default.removeItem(at: badManifestFixture.root) }
        let badManifestProvider = ThirdPartyMirrorDevelopmentProvider(
            configuration: badManifestFixture.configuration,
            cacheRoot: badManifestFixture.root,
            downloader: badManifestFixture.downloader
        )
        do {
            _ = try await badManifestProvider.artifact(matching: requirements())
            XCTFail("expected manifest rejection")
        } catch {
            XCTAssertEqual(error as? DeveloperSupportFailure, .invalidManifest)
        }

        var revokedConfiguration = try developmentProviderFixture().configuration
        revokedConfiguration = ThirdPartyMirrorDevelopmentConfiguration(
            sourceRevision: revokedConfiguration.sourceRevision,
            baseURL: revokedConfiguration.baseURL,
            developerSupportBuildVersion: revokedConfiguration.developerSupportBuildVersion,
            minimumProductMajorVersion: revokedConfiguration.minimumProductMajorVersion,
            maximumProductMajorVersion: revokedConfiguration.maximumProductMajorVersion,
            assets: revokedConfiguration.assets,
            licensePolicyID: revokedConfiguration.licensePolicyID,
            revocationPolicyID: revokedConfiguration.revocationPolicyID,
            revokedSourceRevisions: [revokedConfiguration.sourceRevision]
        )
        let revokedDownloader = FakeDeveloperSupportDownloader(values: [:])
        let revokedProvider = ThirdPartyMirrorDevelopmentProvider(
            configuration: revokedConfiguration,
            cacheRoot: wrongHashFixture.root.appendingPathComponent("revoked"),
            downloader: revokedDownloader
        )
        do {
            _ = try await revokedProvider.artifact(matching: requirements())
            XCTFail("expected revocation rejection")
        } catch {
            XCTAssertEqual(error as? DeveloperSupportFailure, .revokedAsset)
        }
        let revokedRequestCount = await revokedDownloader.requestCount
        XCTAssertEqual(revokedRequestCount, 0)
    }

    func testDevelopmentProviderSeparatesMissingSourceFromNetworkFailure() async throws {
        let fixture = try developmentProviderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = ThirdPartyMirrorDevelopmentProvider(
            configuration: fixture.configuration,
            cacheRoot: fixture.root.appendingPathComponent("missing"),
            downloader: FakeDeveloperSupportDownloader(values: [:])
        )
        do {
            _ = try await missing.artifact(matching: requirements())
            XCTFail("expected missing-source error")
        } catch {
            XCTAssertEqual(error as? DeveloperSupportFailure, .sourceUnavailable)
        }

        let offline = ThirdPartyMirrorDevelopmentProvider(
            configuration: fixture.configuration,
            cacheRoot: fixture.root.appendingPathComponent("offline"),
            downloader: FakeDeveloperSupportDownloader(values: [:], failure: .networkUnavailable)
        )
        do {
            _ = try await offline.artifact(matching: requirements())
            XCTFail("expected network error")
        } catch {
            XCTAssertEqual(error as? DeveloperSupportFailure, .networkUnavailable)
        }
    }

    func testDevelopmentProviderIsExactBuildKeyedAndNeverPermittedInProduction() async throws {
        let fixture = try developmentProviderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = ThirdPartyMirrorDevelopmentProvider(
            configuration: fixture.configuration,
            cacheRoot: fixture.root,
            downloader: fixture.downloader
        )
        let firstValue = try await provider.artifact(matching: requirements())
        let first = try XCTUnwrap(firstValue)
        let otherRequirements = DeveloperSupportRequirements(
            productVersion: "26.0", buildVersion: "23A2", buildIdentity: "BOARD-1",
            boardID: 1, chipID: 2, ecid: 3
        )
        let secondValue = try await provider.artifact(matching: otherRequirements)
        let second = try XCTUnwrap(secondValue)
        XCTAssertNotEqual(first.provenance.cacheLocation, second.provenance.cacheLocation)
        XCTAssertEqual(second.buildVersion, "23A2")
        XCTAssertFalse(DeveloperSupportProviderPolicy.publicProduction.permits(first.provenance.provider))
        XCTAssertThrowsError(try DeveloperSupportProviderPolicy.publicProduction.validate(first.provenance.provider))

        let cacheReader = ExistingAppleCacheProvider(roots: [fixture.root])
        let rediscovered = try await cacheReader.artifact(productVersion: "26.0", buildVersion: "23A1")
        let cached = try XCTUnwrap(rediscovered)
        XCTAssertEqual(cached.provenance.provider.classification, .thirdPartyMirrorDevelopment)
        XCTAssertFalse(DeveloperSupportProviderPolicy.publicProduction.permits(cached.provenance.provider))
    }

    func testExactVersionCacheHitPersonalizesMountsAndVerifiesRSD() async throws {
        let fixture = try makeArtifact(build: "23A1", identity: "BOARD-1")
        let service = FakeDeveloperSupportService()
        let coordinator = DeveloperSupportCoordinator(
            providers: [DevelopmentFixtureProvider(fixture.artifact)],
            service: service,
            providerPolicy: .localTest
        )
        let state = await coordinator.prepare(
            device: try IOSSimDeviceIdentity(udid: "PHONE-0001"),
            requirements: requirements(),
            developerMode: .enabled
        )
        XCTAssertEqual(state.state, .mounted)
        let mountCount = await service.mountCount
        let rsdCount = await service.rsdCount
        XCTAssertEqual(mountCount, 1)
        XCTAssertEqual(rsdCount, 1)
    }

    func testMountedStateSkipsAcquisitionAndMount() async throws {
        let service = FakeDeveloperSupportService(mounted: true)
        let coordinator = DeveloperSupportCoordinator(providers: [], service: service)
        let state = await coordinator.prepare(
            device: try IOSSimDeviceIdentity(udid: "PHONE-0001"),
            requirements: requirements(),
            developerMode: .enabled
        )
        XCTAssertEqual(state.state, .mounted)
        let mountCount = await service.mountCount
        XCTAssertEqual(mountCount, 0)
    }

    func testCacheMissAndDeveloperModeAreDistinct() async throws {
        let service = FakeDeveloperSupportService()
        let coordinator = DeveloperSupportCoordinator(providers: [], service: service)
        let missing = await coordinator.prepare(
            device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), requirements: requirements(), developerMode: .enabled
        )
        XCTAssertEqual(missing.failure, .noApprovedSource)
        let disabled = await coordinator.prepare(
            device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), requirements: requirements(), developerMode: .disabled
        )
        XCTAssertEqual(disabled.failure, .developerModeDisabled)
    }

    func testWrongBuildAndCorruptAssetAreRejected() async throws {
        var fixture = try makeArtifact(build: "23A2", identity: "BOARD-1")
        XCTAssertThrowsError(try DeveloperSupportIntegrity.validate(fixture.artifact, for: requirements())) {
            XCTAssertEqual($0 as? DeveloperSupportFailure, .wrongBuildIdentity)
        }
        fixture = try makeArtifact(build: "23A1", identity: "BOARD-1", declaredImageDigest: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try DeveloperSupportIntegrity.validate(fixture.artifact, for: requirements())) {
            XCTAssertEqual($0 as? DeveloperSupportFailure, .corruptAsset)
        }
    }

    func testPersonalizationFailureAndDisconnectAreTyped() async throws {
        let fixture = try makeArtifact(build: "23A1", identity: "BOARD-1")
        let rejectedService = FakeDeveloperSupportService(personalizationFailure: true)
        let rejected = await DeveloperSupportCoordinator(
            providers: [DevelopmentFixtureProvider(fixture.artifact)], service: rejectedService, providerPolicy: .localTest
        ).prepare(device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), requirements: requirements(), developerMode: .enabled)
        XCTAssertEqual(rejected.failure, .tssUnavailable)

        let disconnectedService = FakeDeveloperSupportService(disconnectOnStatus: true)
        let disconnected = await DeveloperSupportCoordinator(providers: [], service: disconnectedService)
            .prepare(device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), requirements: requirements(), developerMode: .enabled)
        XCTAssertEqual(disconnected.failure, .deviceDisconnected)
    }

    func testTSSRequestContainsOnlyStructuralIdentifiers() throws {
        let fixture = try makeArtifact(build: "23A1", identity: "BOARD-1")
        let request = DeveloperSupportCoordinator.tssRequestMetadata(requirements: requirements(), artifact: fixture.artifact)
        XCTAssertEqual(request["RequestRule"], "LoadableTrustCache")
        XCTAssertNil(request["Password"])
        XCTAssertNil(request["Token"])
        XCTAssertEqual(request["BuildVersion"], "23A1")
    }

    func testPublicProductionRejectsDevelopmentAndFixtureProviders() throws {
        let developmentMirror = DeveloperSupportProviderDescriptor(
            providerID: "thirdPartyMirrorDevelopmentProvider",
            classification: .thirdPartyMirrorDevelopment,
            supportsFreshAcquisition: true,
            provenancePolicyID: "development-mirror-policy-v1"
        )
        let fixture = DevelopmentFixtureProvider(nil).descriptor

        XCTAssertFalse(DeveloperSupportProviderPolicy.publicProduction.permits(developmentMirror))
        XCTAssertFalse(DeveloperSupportProviderPolicy.publicProduction.permits(fixture))
        XCTAssertThrowsError(try DeveloperSupportProviderPolicy.publicProduction.validate(developmentMirror)) {
            XCTAssertEqual(
                $0 as? DeveloperSupportProviderPolicyError,
                .providerNotAllowed(providerID: developmentMirror.providerID, distribution: .publicProduction)
            )
        }
        XCTAssertTrue(DeveloperSupportProviderPolicy.localTest.permits(developmentMirror))
        XCTAssertTrue(DeveloperSupportProviderPolicy.localTest.permits(fixture))
    }

    func testPublicReleaseRequiresApprovedFreshAcquisitionProvider() throws {
        let cache = ExistingAppleCacheProvider(roots: []).descriptor
        XCTAssertThrowsError(
            try DeveloperSupportProviderPolicy.publicProduction.assertFreshAcquisitionConfigured([cache])
        ) {
            XCTAssertEqual(
                $0 as? DeveloperSupportProviderPolicyError,
                .approvedProductionProviderRequired
            )
        }

        let approved = DeveloperSupportProviderDescriptor(
            providerID: "approvedProductionProvider",
            classification: .approvedProductionSource,
            supportsFreshAcquisition: true,
            provenancePolicyID: "approved-policy-v1"
        )
        XCTAssertNoThrow(
            try DeveloperSupportProviderPolicy.publicProduction.assertFreshAcquisitionConfigured([cache, approved])
        )
    }

    func testPublicCoordinatorCannotSelectFixture() async throws {
        let fixture = try makeArtifact(build: "23A1", identity: "BOARD-1")
        let service = FakeDeveloperSupportService()
        let result = await DeveloperSupportCoordinator(
            providers: [DevelopmentFixtureProvider(fixture.artifact)],
            service: service,
            providerPolicy: .publicProduction
        ).prepare(
            device: try IOSSimDeviceIdentity(udid: "PHONE-0001"),
            requirements: requirements(),
            developerMode: .enabled
        )

        XCTAssertEqual(result.failure, .noApprovedSource)
        let mountCount = await service.mountCount
        XCTAssertEqual(mountCount, 0)
    }

    private func requirements() -> DeveloperSupportRequirements {
        DeveloperSupportRequirements(productVersion: "26.0", buildVersion: "23A1", buildIdentity: "BOARD-1", boardID: 1, chipID: 2, ecid: 3)
    }

    private func makeArtifact(
        build: String,
        identity: String,
        declaredImageDigest: String? = nil
    ) throws -> (artifact: DeveloperSupportArtifact, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("DeveloperDiskImage.dmg")
        let manifest = root.appendingPathComponent("BuildManifest.plist")
        try Data("fixture-image".utf8).write(to: image)
        try Data("fixture-manifest".utf8).write(to: manifest)
        let imageHash = try DeveloperSupportIntegrity.sha256(url: image)
        let manifestHash = try DeveloperSupportIntegrity.sha256(url: manifest)
        let trustCache = root.appendingPathComponent("Image.dmg.trustcache")
        try Data("fixture-trust-cache".utf8).write(to: trustCache)
        let trustHash = try DeveloperSupportIntegrity.sha256(url: trustCache)
        let descriptor = DevelopmentFixtureProvider(nil).descriptor
        let expected = [
            "Image.dmg": declaredImageDigest ?? imageHash.digest,
            "BuildManifest.plist": manifestHash.digest,
            "Image.dmg.trustcache": trustHash.digest,
        ]
        let provenance = DeveloperSupportProvenance(
            provider: descriptor,
            sourceURL: "https://fixture.invalid/pinned/fixture",
            sourceRevision: "fixture-revision",
            sourceAssetIdentity: "fixture-asset",
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expectedSHA256: expected,
            actualSHA256: expected,
            manifestIdentity: manifestHash.digest,
            trustCacheIdentity: trustHash.digest,
            licensePolicyID: "fixture-license-policy",
            revocationPolicyID: "fixture-revocation-policy",
            cacheLocation: root.path
        )
        return (DeveloperSupportArtifact(
            provenanceID: "fixture", productVersion: "26.0", buildVersion: build, buildIdentity: identity,
            developerSupportBuildVersion: "27A-fixture",
            imageURL: image, imageSHA256: declaredImageDigest ?? imageHash.digest, imageSize: imageHash.size,
            trustCacheURL: trustCache, trustCacheSHA256: trustHash.digest,
            buildManifestURL: manifest, buildManifestSHA256: manifestHash.digest,
            provenance: provenance
        ), root)
    }

    private func developmentProviderFixture(
        manifestBuild: String = "27A-fixture",
        declaredImageHash: String? = nil
    ) throws -> (
        root: URL,
        configuration: ThirdPartyMirrorDevelopmentConfiguration,
        downloader: FakeDeveloperSupportDownloader
    ) {
        let image = Data("fixture-image".utf8)
        let trust = Data("fixture-trust-cache".utf8)
        let manifest = try PropertyListSerialization.data(
            fromPropertyList: [
                "ProductBuildVersion": manifestBuild,
                "BuildIdentities": [[
                    "Manifest": [
                        "LoadableTrustCache": ["Info": ["Path": "Image.dmg.trustcache"]],
                        "PersonalizedDMG": ["Info": ["Path": "Image.dmg"]],
                    ],
                ]],
            ],
            format: .xml,
            options: 0
        )
        let revision = String(repeating: "a", count: 40)
        let base = URL(string: "https://fixture.invalid/\(revision)/")!
        let imageHash = declaredImageHash ?? sha256(image)
        let configuration = ThirdPartyMirrorDevelopmentConfiguration(
            sourceRevision: revision,
            baseURL: base,
            developerSupportBuildVersion: "27A-fixture",
            minimumProductMajorVersion: 17,
            maximumProductMajorVersion: 26,
            assets: [
                .init(name: "Image.dmg", sha256: imageHash, size: image.count, maximumBytes: 1_024),
                .init(name: "BuildManifest.plist", sha256: sha256(manifest), size: manifest.count, maximumBytes: 64 * 1_024),
                .init(name: "Image.dmg.trustcache", sha256: sha256(trust), size: trust.count, maximumBytes: 1_024),
            ],
            licensePolicyID: "hermetic-fixture-license-v1",
            revocationPolicyID: "hermetic-fixture-revocation-v1"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-ddi-provider-\(UUID().uuidString)", isDirectory: true)
        let downloader = FakeDeveloperSupportDownloader(values: [
            "Image.dmg": image,
            "BuildManifest.plist": manifest,
            "Image.dmg.trustcache": trust,
        ])
        return (root, configuration, downloader)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor FakeDeveloperSupportDownloader: DeveloperSupportDownloading {
    private let values: [String: Data]
    private let failure: DeveloperSupportFailure?
    private(set) var requestCount = 0

    init(values: [String: Data], failure: DeveloperSupportFailure? = nil) {
        self.values = values
        self.failure = failure
    }

    func download(_ request: DeveloperSupportDownloadRequest) async throws -> Data {
        requestCount += 1
        if let failure { throw failure }
        guard let data = values[request.url.lastPathComponent] else {
            throw DeveloperSupportFailure.sourceUnavailable
        }
        guard data.count <= request.maximumBytes else { throw DeveloperSupportFailure.corruptAsset }
        return data
    }
}

private actor FakeDeveloperSupportService: DeveloperSupportDeviceServicing {
    var mounted: Bool
    var mountCount = 0
    var rsdCount = 0
    let personalizationFailure: Bool
    let disconnectOnStatus: Bool

    init(mounted: Bool = false, personalizationFailure: Bool = false, disconnectOnStatus: Bool = false) {
        self.mounted = mounted
        self.personalizationFailure = personalizationFailure
        self.disconnectOnStatus = disconnectOnStatus
    }

    func isMounted(on device: IOSSimDeviceIdentity, requirements: DeveloperSupportRequirements) async throws -> Bool {
        if disconnectOnStatus { throw NativeDeviceBridgeError.deviceDisconnected }
        return mounted
    }

    func personalizationManifest(
        on device: IOSSimDeviceIdentity,
        artifact: DeveloperSupportArtifact,
        request: [String: String]
    ) async throws -> Data {
        if personalizationFailure { throw DeveloperSupportFailure.tssUnavailable }
        return Data("ticket".utf8)
    }

    func mount(
        on device: IOSSimDeviceIdentity,
        artifact: DeveloperSupportArtifact,
        personalizationManifest: Data
    ) async throws {
        mountCount += 1
        mounted = true
    }

    func verifyRSD(on device: IOSSimDeviceIdentity) async throws { rsdCount += 1 }
}
