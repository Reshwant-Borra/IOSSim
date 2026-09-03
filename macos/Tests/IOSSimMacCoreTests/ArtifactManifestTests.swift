import CryptoKit
import XCTest
@testable import IOSSimMacCore

final class ArtifactManifestTests: XCTestCase {
    func testManifestDecodingAndChecksumVerification() throws {
        let root = try makeArtifactFixture(bundleIdentifier: "com.iossim.on-device-dvt-poc")
        let artifact = root.appendingPathComponent("DeviceArtifacts/IOSSim DVT POC.app")
        let manifest = ArtifactManifest(
            schemaVersion: 1,
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
            schemaVersion: 1,
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
            schemaVersion: 1,
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
        for file in files.sorted(by: { $0.path < $1.path }) {
            let relative = String(file.path.dropFirst(url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try! Data(contentsOf: file))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
