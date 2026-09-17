import CryptoKit
import XCTest
@testable import IOSSimMacCore

final class ArtifactManifestTests: XCTestCase {
    func testReleaseProvenanceRoundTrips() throws {
        let release = ReleaseManifest(
            sourceCommit: "abc123",
            sourceDirty: false,
            buildTimestamp: "2026-09-05T12:00:00Z",
            macVersion: "0.1.0",
            buildNumber: "1",
            variant: "PRODUCTION",
            helperSchemaVersion: 1,
            payloadSourceHead: "abc123",
            payloadSourceDirty: true,
            payloadSourceTreeSHA256: String(repeating: "a", count: 64),
            payloadBuildTimestamp: "2026-09-05T12:00:00Z",
            payloadBuildVariant: "DEVICE_PAYLOAD_RELEASE"
        )

        let data = try JSONEncoder().encode(release)
        let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: data)

        XCTAssertEqual(decoded, release)
        XCTAssertEqual(decoded.sourceDirty, false)
        XCTAssertEqual(decoded.buildNumber, "1")
        XCTAssertEqual(decoded.variant, "PRODUCTION")
        XCTAssertEqual(decoded.payloadSourceHead, "abc123")
        XCTAssertEqual(decoded.payloadSourceDirty, true)
        XCTAssertEqual(decoded.payloadSourceTreeSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(decoded.payloadBuildVariant, "DEVICE_PAYLOAD_RELEASE")
    }

    func testManifestDecodingAndChecksumVerification() throws {
        let root = try makeArtifactFixture(bundleIdentifier: "com.iossim.on-device-dvt-poc")
        let artifact = root.appendingPathComponent("DeviceArtifacts/IOSSim DVT POC.app")
        let manifest = ArtifactManifest(
            schemaVersion: ArtifactManifest.currentSchemaVersion,
            release: ReleaseManifest(sourceCommit: "abc123", buildTimestamp: "2026-09-03T00:00:00Z", macVersion: "0.1", helperSchemaVersion: 1),
            components: [
                DeviceArtifactComponent(
                    role: "iosMain",
                    bundleIdentifier: "com.iossim.on-device-dvt-poc",
                    version: "0.1",
                    relativePath: "DeviceArtifacts/IOSSim DVT POC.app",
                    sha256: sha256Tree(artifact)
                )
            ]
        )
        try writeManifest(manifest, root: root)

        let decoded = try ArtifactManifestLoader.load(resourcesURL: root)
        XCTAssertEqual(decoded.components.first?.role, "iosMain")
        let results = ArtifactManifestLoader.verify(resourcesURL: root, manifest: decoded)
        XCTAssertEqual(results.first?.state, .pass)
        XCTAssertNoThrow(try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: root, manifest: decoded))
    }

    func testCorruptArtifactFailsChecksumVerification() throws {
        let root = try makeArtifactFixture(bundleIdentifier: "com.iossim.on-device-dvt-poc")
        let manifest = ArtifactManifest(
            schemaVersion: ArtifactManifest.currentSchemaVersion,
            release: ReleaseManifest(sourceCommit: "abc123", buildTimestamp: "2026-09-03T00:00:00Z", macVersion: "0.1", helperSchemaVersion: 1),
            components: [
                DeviceArtifactComponent(
                    role: "iosMain",
                    bundleIdentifier: "com.iossim.on-device-dvt-poc",
                    version: "0.1",
                    relativePath: "DeviceArtifacts/IOSSim DVT POC.app",
                    sha256: String(repeating: "0", count: 64)
                )
            ]
        )
        try writeManifest(manifest, root: root)

        let results = ArtifactManifestLoader.verify(resourcesURL: root, manifest: manifest)
        XCTAssertEqual(results.first?.state, .fail)
        XCTAssertThrowsError(try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: root, manifest: manifest))
    }

    func testWrongBundleIdentifierFailsVerification() throws {
        let root = try makeArtifactFixture(bundleIdentifier: "com.example.wrong")
        let artifact = root.appendingPathComponent("DeviceArtifacts/IOSSim DVT POC.app")
        let manifest = ArtifactManifest(
            schemaVersion: ArtifactManifest.currentSchemaVersion,
            release: ReleaseManifest(sourceCommit: "abc123", buildTimestamp: "2026-09-03T00:00:00Z", macVersion: "0.1", helperSchemaVersion: 1),
            components: [
                DeviceArtifactComponent(
                    role: "iosMain",
                    bundleIdentifier: "com.iossim.on-device-dvt-poc",
                    version: "0.1",
                    relativePath: "DeviceArtifacts/IOSSim DVT POC.app",
                    sha256: sha256Tree(artifact)
                )
            ]
        )

        XCTAssertThrowsError(try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: root, manifest: manifest))
    }

    func testStalePayloadWithoutRequiredCapabilitiesFailsVerification() throws {
        let root = try makeArtifactFixture(bundleIdentifier: "com.iossim.on-device-dvt-poc")
        let artifact = root.appendingPathComponent("DeviceArtifacts/IOSSim DVT POC.app")
        let manifest = ArtifactManifest(
            schemaVersion: ArtifactManifest.currentSchemaVersion,
            release: ReleaseManifest(
                sourceCommit: "bc339b3",
                buildTimestamp: "2026-09-03T00:00:00Z",
                macVersion: "0.1",
                helperSchemaVersion: 1
            ),
            components: [
                DeviceArtifactComponent(
                    role: "iosMain",
                    bundleIdentifier: "com.iossim.on-device-dvt-poc",
                    version: "0.1",
                    relativePath: "DeviceArtifacts/IOSSim DVT POC.app",
                    sha256: sha256Tree(artifact)
                )
            ],
            payloadCapabilities: nil
        )

        XCTAssertThrowsError(try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: root, manifest: manifest)) { error in
            guard case ArtifactManifestError.missingPayloadCapability(let name, _, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(name, "automaticPairingInbox")
        }
    }

    func testStaleManifestSchemaFailsVerification() throws {
        let root = try makeArtifactFixture(bundleIdentifier: "com.iossim.on-device-dvt-poc")
        let artifact = root.appendingPathComponent("DeviceArtifacts/IOSSim DVT POC.app")
        let manifest = ArtifactManifest(
            schemaVersion: ArtifactManifest.currentSchemaVersion - 1,
            release: ReleaseManifest(
                sourceCommit: "abc123",
                buildTimestamp: "2026-09-03T00:00:00Z",
                macVersion: "0.1",
                helperSchemaVersion: 1
            ),
            components: [
                DeviceArtifactComponent(
                    role: "iosMain",
                    bundleIdentifier: "com.iossim.on-device-dvt-poc",
                    version: "0.1",
                    relativePath: "DeviceArtifacts/IOSSim DVT POC.app",
                    sha256: sha256Tree(artifact)
                )
            ]
        )

        XCTAssertThrowsError(try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: root, manifest: manifest)) { error in
            XCTAssertEqual(
                error as? ArtifactManifestError,
                .incompatibleManifestSchema(
                    expected: ArtifactManifest.currentSchemaVersion,
                    actual: ArtifactManifest.currentSchemaVersion - 1
                )
            )
        }
    }

    private func makeArtifactFixture(bundleIdentifier: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-artifact-test-\(UUID().uuidString)", isDirectory: true)
        let artifact = root.appendingPathComponent("DeviceArtifacts/IOSSim DVT POC.app", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: artifact.appendingPathComponent("IOSSim DVT POC"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": "0.1",
            "CFBundleVersion": "1"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: artifact.appendingPathComponent("Info.plist"))
        return root
    }

    private func writeManifest(_ manifest: ArtifactManifest, root: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent(ArtifactManifestLoader.manifestRelativePath))
    }

    private func sha256Tree(_ url: URL) -> String {
        var hasher = SHA256()
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )!
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try! file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true || values.isSymbolicLink == true {
                files.append(file)
            }
        }
        let rootPath = normalizedPathForRelativeHash(url.path)
        for file in files.sorted(by: { $0.path < $1.path }) {
            let filePath = normalizedPathForRelativeHash(file.path)
            let relative = String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try! Data(contentsOf: file))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedPathForRelativeHash(_ path: String) -> String {
        if path == "/private/var" {
            return "/var"
        }
        if path.hasPrefix("/private/var/") {
            return "/var/" + path.dropFirst("/private/var/".count)
        }
        return path
    }
}
