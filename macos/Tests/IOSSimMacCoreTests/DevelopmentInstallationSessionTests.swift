import Foundation
@testable import IOSSimMacCore
import XCTest

final class DevelopmentInstallationSessionTests: XCTestCase {
    func testVolatileSessionReusesKeyAndRestartRotatesWithoutLosingOwnershipHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-development-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: "/tmp/IOSSimProvisioner")
        let request = EngineRequest(command: .reconcile, stage: .signingKey,
            capabilities: CapabilityManifest(allowedDomains: InstallationDomain.signingKey.closure))
        let session = DevelopmentInstallationSession(root: root)
        let composition = session.composition(helperURL: helper, device: nil, connectionGeneration: 1)
        let first = await EngineHost.handle(request, composition: composition)
        XCTAssertEqual(first.exitCode, .success, "\(first.firstFailure as Any)")
        let initial = try await composition.repository.load()
        let key = try XCTUnwrap(initial.activeResource(for: .signingKey))
        let second = await EngineHost.handle(request, composition: session.composition(
            helperURL: helper, device: nil, connectionGeneration: 2))
        XCTAssertEqual(second.exitCode, .success)
        XCTAssertEqual(second.transitionsCompleted, 0)
        let restart = DevelopmentInstallationSession(root: root).composition(
            helperURL: helper, device: nil, connectionGeneration: 3)
        let recovered = await EngineHost.handle(request, composition: restart)
        XCTAssertEqual(recovered.exitCode, .success, "\(recovered.firstFailure as Any)")
        let journal = try await restart.repository.load()
        XCTAssertNotEqual(journal.activeResource(for: .signingKey)?.id, key.id)
        XCTAssertTrue((journal.retiring[InstallationDomain.signingKey.rawValue] ?? []).contains { $0.id == key.id })
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("secrets/signing-keys").path)
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".vkey") }, "only encrypted envelopes are persisted")
    }

    func testDevelopmentSessionCannotAuthorizeWithoutInteractiveAppleSignIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-development-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = DevelopmentInstallationSession(root: root)
        do {
            _ = try await session.apple.currentPersonalTeam()
            XCTFail("new development session must require sign-in")
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, .sessionExpired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("apple-session/authorization-session.v2.enc").path))
    }

    func testEngineDevicePreservesTransportAndRejectsMismatchedConnectionOrPhone() throws {
        let identity = try IOSSimDeviceIdentity(udid: "00008150-00022D581E12401C", usbmuxIdentifier: 42,
                                               connection: .usb, connectionGeneration: 3)
        let selected = EngineDeviceSelection(udid: identity.udid, name: "Fixture", transportIdentity: identity)
        XCTAssertEqual(try selected.identity(connectionGeneration: 3), identity)
        XCTAssertThrowsError(try selected.identity(connectionGeneration: 4))
        let wrongPhone = EngineDeviceSelection(udid: "00008150-001439C43EEA401C", name: "Other", transportIdentity: identity)
        XCTAssertThrowsError(try wrongPhone.identity(connectionGeneration: 3))
        let decoded = try JSONDecoder().decode(EngineDeviceSelection.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(decoded, selected)
    }
}
