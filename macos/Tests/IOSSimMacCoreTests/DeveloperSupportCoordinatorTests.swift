import CryptoKit
import XCTest
@testable import IOSSimMacCore

final class DeveloperSupportCoordinatorTests: XCTestCase {
    func testExactVersionCacheHitPersonalizesMountsAndVerifiesRSD() async throws {
        let fixture = try makeArtifact(build: "23A1", identity: "BOARD-1")
        let service = FakeDeveloperSupportService()
        let coordinator = DeveloperSupportCoordinator(
            providers: [DevelopmentFixtureProvider(fixture.artifact)],
            service: service,
            allowDevelopmentFixtures: true
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
            providers: [DevelopmentFixtureProvider(fixture.artifact)], service: rejectedService, allowDevelopmentFixtures: true
        ).prepare(device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), requirements: requirements(), developerMode: .enabled)
        XCTAssertEqual(rejected.failure, .personalizationRejected)

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
        return (DeveloperSupportArtifact(
            provenanceID: "fixture", buildVersion: build, buildIdentity: identity,
            imageURL: image, imageSHA256: declaredImageDigest ?? imageHash.digest, imageSize: imageHash.size,
            buildManifestURL: manifest, buildManifestSHA256: manifestHash.digest
        ), root)
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
