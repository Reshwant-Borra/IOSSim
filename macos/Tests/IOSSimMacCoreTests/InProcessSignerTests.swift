import Foundation
import XCTest
@testable import IOSSimMacCore

final class InProcessSignerTests: XCTestCase {
    private func signer() throws -> InProcessSigner {
        guard let path = ProcessInfo.processInfo.environment["VEYA_SIGNING_TEST_LIBRARY"] else {
            throw XCTSkip("INTEGRATION_REQUIRED: build native bridge and set VEYA_SIGNING_TEST_LIBRARY")
        }
        return try InProcessSigner(libraryURL: URL(fileURLWithPath: path))
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-sign-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.veya.fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
        return root
    }
    func testNativeInspectionAndExpectedGraphRoundTrip() throws {
        let signer = try signer(), root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = try signer.inspect(root)
        XCTAssertEqual(graph.rootBundleId, "com.veya.fixture")
        XCTAssertEqual(graph.schemaVersion, 1)
        XCTAssertEqual(graph.inventorySha256.count, 64)
        XCTAssertEqual(graph, try signer.inspect(root))
        XCTAssertEqual(graph.expected.rootBundleId, graph.rootBundleId)
        XCTAssertThrowsError(try signer.verify(root)) { error in
            XCTAssertEqual(error as? InProcessSignerFailure, .native(code: "VEYA-SIGN-REQUEST"))
        }
    }
    func testNativeSignRejectsProfileWithoutPublishingAndNeverReturnsKey() throws {
        let signer = try signer(), root = try fixture()
        let output = root.deletingLastPathComponent().appendingPathComponent("signed-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: output) }
        let graph = try signer.inspect(root)
        let request = InProcessSigningRequest(inputBundle: root, outputBundle: output,
            certificateChainDER: [Data([1])], profiles: [:], entitlements: [:], expected: graph.expected)
        var sentinel = Array("PRIVATE_KEY_CANARY_TEST_ONLY".utf8)
        defer { VeyaSigningKeyStore.zero(&sentinel) }
        XCTAssertThrowsError(try sentinel.withUnsafeBytes { try signer.signForQualification(request, key: $0) }) { error in
            XCTAssertEqual(error as? InProcessSignerFailure, .native(code: "VEYA-SIGN-REQUEST"))
            XCTAssertFalse(String(describing: error).contains("CANARY"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(graph, try signer.inspect(root))
        let encoded = try JSONEncoder().encode(request)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).lowercased().contains("pkcs8"))
    }
    func testMissingLibraryFailsClosed() {
        XCTAssertThrowsError(try InProcessSigner(libraryURL: URL(fileURLWithPath: "/not-present/veya.dylib"))) { error in
            XCTAssertEqual(error as? InProcessSignerFailure, .libraryUnavailable)
        }
    }
}
