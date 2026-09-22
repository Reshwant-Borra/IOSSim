import Foundation
@testable import IOSSimMacCore
import XCTest

/// M7: the production engine drives `.payload` then `.application` through real journal persistence.
/// Signer and device are scripted boundaries (labelled SIMULATED); the real signer's positive path is
/// qualified in veya-signing-core. Every injected failure must leave the active payload/app in place.
final class PayloadTransactionTests: XCTestCase {
    private var root: URL!
    private var repository: InstallationJournalRepository!
    private var signer: ScriptedSigner!
    private var device: ScriptedDevice!
    private var plans: ScriptedPlans!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-m7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
        let source = root.appendingPathComponent("Source/Veya Payload.app", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writeInfo(to: source, version: "1.0")
        try Data("profile".utf8).write(to: source.appendingPathComponent("embedded.mobileprovision"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        try Data("seal".utf8).write(to: source.appendingPathComponent("_CodeSignature/CodeResources"))
        signer = ScriptedSigner()
        device = ScriptedDevice()
        plans = ScriptedPlans(source: source)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writeInfo(to bundle: URL, version: String) throws {
        let info: [String: Any] = ["CFBundleIdentifier": "com.veya.payload", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
    }

    private func reconcile(connection: UInt64 = 7, maximumTransitions: Int = 8) async throws -> ReconciliationOutcome {
        let payload = PayloadDomain(rootURL: root, repository: repository, planProvider: plans, signing: signer)
        let deviceBox = device!
        let application = ApplicationDomain(
            payload: payload, repository: repository, applications: deviceBox,
            device: { try IOSSimDeviceIdentity(udid: "00008110-000000000000001E", connectionGeneration: connection) }
        )
        let engine = try VeyaReconciliationEngine(
            journalRepository: repository, observers: [payload, application], transitions: [payload, application],
            sleeper: NoSleep(), leaseSleeper: NoSleep()
        )
        return try await engine.reconcile(
            scope: InstallationScope(domains: [.payload, .application], connectionGeneration: connection),
            to: DesiredInstallationState(requirements: [.init(domain: .payload), .init(domain: .application)]),
            policy: ReconciliationPolicy(allowedDomains: [.payload, .application], maximumTransitions: maximumTransitions,
                                         localRetryLimit: 0, remoteRetryLimit: 0)
        )
    }

    private func journal() async throws -> InstallationJournal { try await repository.load() }

    func testSignsVerifiesInstallsAndPromotesBothDomains() async throws {
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready, "\(String(describing: outcome.failure))")
        let state = try await journal()
        let signed = try XCTUnwrap(state.activeResource(for: .payload))
        let app = try XCTUnwrap(state.activeResource(for: .application))
        XCTAssertEqual(app.identity.digest, signed.identity.digest, "installed app is bound to the signed payload digest")
        XCTAssertEqual(device.installs, 1)
        XCTAssertEqual(device.installed?.version, "1.0")
        XCTAssertTrue(state.evidence.contains { $0.kind == "deviceInventoryAfterInstall" && $0.connectionGeneration == 7 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(signed.relativeLocation!)/../source").standardized.path),
                       "the immutable source copy is removed after signing")
        let again = try await reconcile()
        XCTAssertEqual(again.transitionsCompleted, 0, "a satisfied transaction is idempotent")
        XCTAssertEqual(device.installs, 1)
    }

    func testSigningFailureCreatesNothingAndCleansStaging() async throws {
        signer.failSign = true
        await XCTAssertThrowsAsync(try await self.reconcile())
        let state = try await journal()
        XCTAssertNil(state.activeResource(for: .payload))
        XCTAssertNil(state.candidateResource(for: .payload))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path), [])
        XCTAssertEqual(device.installs, 0)
    }

    func testFailuresAfterSuccessPreserveKnownGoodPayloadAndApplication() async throws {
        _ = try await reconcile()
        let good = try await journal()
        let goodPayload = try XCTUnwrap(good.activeResource(for: .payload))
        let goodApp = try XCTUnwrap(good.activeResource(for: .application))

        // New certificate → payload stale → re-sign; the re-signed candidate then fails verification.
        plans.certificateGeneration += 1
        signer.corruptNextOutput = true
        await XCTAssertThrowsAsync(try await self.reconcile())
        var state = try await journal()
        XCTAssertEqual(state.activeResource(for: .payload), goodPayload)
        XCTAssertEqual(state.activeResource(for: .application), goodApp)

        // Re-sign succeeds, but the device install fails outright: the device keeps the old app.
        device.failInstall = .notInstalled
        await XCTAssertThrowsAsync(try await self.reconcile())
        state = try await journal()
        XCTAssertNotEqual(state.activeResource(for: .payload), goodPayload, "the proven re-signed payload is promoted")
        XCTAssertEqual(state.activeResource(for: .application), goodApp, "the app is not promoted without inventory proof")
        XCTAssertEqual(device.installed?.version, "1.0")

        // Install claims success but the device reports a different version: never promoted.
        device.failInstall = .wrongVersionInstalled
        await XCTAssertThrowsAsync(try await self.reconcile())
        let hoisted1 = try await journal()
        XCTAssertEqual(hoisted1.activeResource(for: .application), goodApp)

        // Recovery: a clean install proves and promotes.
        device.failInstall = nil
        let recovered = try await reconcile()
        XCTAssertEqual(recovered.status, .ready)
        state = try await journal()
        XCTAssertEqual(state.activeResource(for: .application)?.identity.digest, state.activeResource(for: .payload)?.identity.digest)
    }

    func testInterruptedInstallResponseIsDecidedByInventory() async throws {
        device.failInstall = .installedButResponseLost
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready)
        XCTAssertEqual(device.installs, 1, "no blind reinstall after an ambiguous response")
    }

    func testDisconnectBetweenInstallAndProofResumesOnNextConnection() async throws {
        device.failInventoryAfterInstall = true
        await XCTAssertThrowsAsync(try await self.reconcile(connection: 7))
        let hoisted2 = try await journal()
        XCTAssertNil(hoisted2.activeResource(for: .application))

        // Inventory cannot identify the signature, so the resumed run reinstalls the same artifact
        // (idempotent) and proves it on the new connection instead of trusting the earlier call.
        device.failInventoryAfterInstall = false
        let resumed = try await reconcile(connection: 8)
        XCTAssertEqual(resumed.status, .ready)
        XCTAssertEqual(device.installs, 2)
        let hoisted3 = try await journal()
        XCTAssertTrue(hoisted3.evidence.contains { $0.kind == "deviceInventoryAfterInstall" && $0.connectionGeneration == 8 })
    }

    func testLostResponseForSameVersionResignIsNotMistakenForSuccess() async throws {
        _ = try await reconcile()
        let before = try await journal()
        let goodApp = try XCTUnwrap(before.activeResource(for: .application))
        // Renewal: new certificate, same app version. The device already reports 1.0/TESTTEAM01, so a
        // lost install response proves nothing and must not promote the re-signed app.
        plans.certificateGeneration += 1
        device.failInstall = .notInstalled
        await XCTAssertThrowsAsync(try await self.reconcile())
        let hoisted4 = try await journal()
        XCTAssertEqual(hoisted4.activeResource(for: .application), goodApp)
        device.failInstall = nil
        let hoisted5 = try await reconcile()
        XCTAssertEqual(hoisted5.status, .ready)
        let hoisted6 = try await journal()
        XCTAssertNotEqual(hoisted6.activeResource(for: .application)?.identity, goodApp.identity)
    }

    func testDeviceLosingTheAppIsReinstalledFromTheActivePayload() async throws {
        _ = try await reconcile()
        device.installed = nil
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready)
        XCTAssertEqual(device.installs, 2)
    }

    private func makeRunner() throws -> URL {
        let runner = root.appendingPathComponent("Source/Runner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: runner, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.veya.runner", "CFBundleShortVersionString": "2.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: runner.appendingPathComponent("Info.plist"))
        try Data("profile".utf8).write(to: runner.appendingPathComponent("embedded.mobileprovision"))
        try FileManager.default.createDirectory(at: runner.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        try Data("seal".utf8).write(to: runner.appendingPathComponent("_CodeSignature/CodeResources"))
        return runner
    }

    func testMainAndRunnerAreSignedInstalledInOrderAndBothRequiredForProof() async throws {
        plans.runner = try makeRunner()
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready, "\(String(describing: outcome.failure))")
        XCTAssertEqual(device.installOrder, ["com.veya.payload", "com.veya.runner"])
        let state = try await journal()
        let signed = try XCTUnwrap(state.activeResource(for: .payload))
        XCTAssertEqual(PayloadDomain.roles(of: signed), ["main", "runner"])
        // The runner disappears from the device: the application is invalid and both are reinstalled.
        device.apps["com.veya.runner"] = nil
        let repaired = try await reconcile()
        XCTAssertEqual(repaired.status, .ready)
        XCTAssertNotNil(device.apps["com.veya.runner"])
        let after = try await journal()
        XCTAssertEqual(state.activeResource(for: .payload), after.activeResource(for: .payload), "no re-sign")
    }

    func testPlannedIdentifierRewriteIsAppliedToTheStagedCopyOnly() async throws {
        plans.rewrites = ["Info.plist": ["CFBundleIdentifier": "com.veya.payload", "VeyaMarker": "rewritten"]]
        _ = try await reconcile()
        let current = try await journal()
        let signed = try XCTUnwrap(current.activeResource(for: .payload))
        let bundle = root.appendingPathComponent(signed.relativeLocation!).appendingPathComponent("Veya Payload.app/Info.plist")
        XCTAssertEqual(NSDictionary(contentsOf: bundle)?["VeyaMarker"] as? String, "rewritten")
        let source = root.appendingPathComponent("Source/Veya Payload.app/Info.plist")
        XCTAssertNil(NSDictionary(contentsOf: source)?["VeyaMarker"], "the shipped source is never edited")
    }

    func testRewriteThatChangesTheSignableGraphIsRefusedBeforeSigning() async throws {
        signer.stagedGraphGainsNode = true
        do { _ = try await reconcile(); XCTFail("expected refusal") } catch let failure as VeyaFailure {
            XCTAssertEqual(failure.code, PayloadFailure.sourceGraphChanged.code)
        }
        XCTAssertEqual(signer.signs, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path), [])
    }

    func testRewriteToAnUnplannedRootIdentifierIsRefused() async throws {
        plans.rewrites = ["Info.plist": ["CFBundleIdentifier": "com.attacker.other"]]
        do { _ = try await reconcile(); XCTFail("expected refusal") } catch let failure as VeyaFailure {
            XCTAssertEqual(failure.code, PayloadFailure.sourceGraphChanged.code)
        }
        XCTAssertEqual(signer.signs, 0)
    }

    func testUnreferencedStagingIsCollectedWhileActiveAndRetiringPayloadsAreKept() async throws {
        _ = try await reconcile()
        let initial = try await journal()
        let first = try XCTUnwrap(initial.activeResource(for: .payload))
        let orphan = root.appendingPathComponent("staging/999", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        plans.certificateGeneration += 1
        _ = try await reconcile()
        let state = try await journal()
        let second = try XCTUnwrap(state.activeResource(for: .payload))
        XCTAssertNotEqual(first.relativeLocation, second.relativeLocation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "a generation the journal never recorded is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(second.relativeLocation!).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.relativeLocation!).path),
                      "the retiring payload remains available as rollback evidence")
    }

    func testPrerequisiteFailureBlocksWithoutMutation() async throws {
        plans.failure = CertificateFailure.capacityRequiresUser
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .blocked)
        XCTAssertEqual(outcome.failure?.code, CertificateFailure.capacityRequiresUser.code)
        XCTAssertEqual(signer.signs, 0)
        XCTAssertEqual(device.installs, 0)
    }
}

private struct NoSleep: ReconciliationSleeping {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: .milliseconds(1)) }
}

private func XCTAssertThrowsAsync<T>(_ body: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await body(); XCTFail("expected an error", file: file, line: line) } catch {}
}

private final class ScriptedPlans: PayloadSigningPlanProviding, @unchecked Sendable {
    let source: URL
    var runner: URL?
    var rewrites: [String: [String: String]] = [:]
    var certificateGeneration = 1
    var failure: VeyaFailure?
    init(source: URL) { self.source = source }

    func plan(journal: InstallationJournal) async throws -> PayloadSigningPlan {
        if let failure { throw failure }
        var components = [PayloadSigningPlan.Component(
            role: "main", sourceBundle: source, bundleIdentifier: "com.veya.payload", infoPlistRewrites: rewrites,
            profiles: ["com.veya.payload": Data("profile".utf8)], entitlements: [:]
        )]
        if let runner {
            components.append(.init(role: "runner", sourceBundle: runner, bundleIdentifier: "com.veya.runner", infoPlistRewrites: [:],
                                    profiles: ["com.veya.runner": Data("profile".utf8)], entitlements: [:]))
        }
        return PayloadSigningPlan(
            components: components,
            sourceDigest: VeyaSigningKeyStore.sha256(Data("source".utf8)),
            certificateChainDER: [Data("certificate-\(certificateGeneration)".utf8)],
            keyID: "key-1",
            teamIdentifier: "TESTTEAM01"
        )
    }
}

/// Scripted signer: "signs" by copying and records a per-output inventory; verification can be corrupted.
private final class ScriptedSigner: PayloadSigning, @unchecked Sendable {
    var failSign = false
    var corruptNextOutput = false
    /// Extra signable node reported for staged copies only (a rewrite that changed the graph).
    var stagedGraphGainsNode = false

    func inspect(_ bundle: URL) throws -> SigningBundleGraph {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist"))
        var nodes = [SigningBundleNode(relativePath: "", kind: "bundle", bundleId: info?["CFBundleIdentifier"] as? String,
                                       sha256: nil, mode: nil, symlinkTarget: nil)]
        if stagedGraphGainsNode, bundle.path.contains("/staging/") {
            nodes.append(SigningBundleNode(relativePath: "Injected", kind: "mach_o", bundleId: nil, sha256: nil, mode: nil, symlinkTarget: nil))
        }
        return SigningBundleGraph(schemaVersion: 1, rootBundleId: info?["CFBundleIdentifier"] as? String ?? "",
                                  nodes: nodes, inventorySha256: String(repeating: "0", count: 64))
    }
    private(set) var signs = 0
    private var digests: [String: String] = [:]

    func sign(_ request: InProcessSigningRequest, keyID: String, installationID: UUID) async throws -> InProcessSigningReceipt {
        signs += 1
        if failSign { throw InProcessSignerFailure.native(code: "VEYA-SIGN-003") }
        let input = URL(fileURLWithPath: request.inputBundle), output = URL(fileURLWithPath: request.outputBundle)
        try FileManager.default.copyItem(at: input, to: output)
        let digest = String(format: "%064x", signs)
        digests[output.standardizedFileURL.path] = corruptNextOutput ? String(repeating: "f", count: 64) : digest
        corruptNextOutput = false
        return try JSONDecoder().decode(InProcessSigningReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "signingCore": "scripted", "inputInventorySha256": String(repeating: "0", count: 64),
            "outputInventorySha256": digest, "rootBundleId": request.expected.rootBundleId, "verifiedMachos": [],
            "embeddedProfileBundleIds": ["com.veya.payload"], "entitlementBundleIds": ["com.veya.payload"],
        ]))
    }

    func verify(_ bundle: URL) throws -> InProcessVerificationReceipt {
        guard FileManager.default.fileExists(atPath: bundle.path),
              let digest = digests[bundle.standardizedFileURL.path] else { throw InProcessSignerFailure.native(code: "VEYA-SIGN-009") }
        return try JSONDecoder().decode(InProcessVerificationReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "rootBundleId": "-", "inventorySha256": digest, "verifiedMachos": [],
        ]))
    }
}

private final class ScriptedDevice: NativeApplicationServicing, @unchecked Sendable {
    enum InstallFailure { case notInstalled, installedButResponseLost, wrongVersionInstalled }
    var apps: [String: NativeInstalledApplication] = [:]
    /// The main app, which most cases reason about.
    var installed: NativeInstalledApplication? {
        get { apps["com.veya.payload"] }
        set { apps["com.veya.payload"] = newValue }
    }
    var failInstall: InstallFailure?
    var failInventoryAfterInstall = false
    private(set) var installs = 0
    private(set) var installOrder: [String] = []
    private var installedOnce = false

    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] {
        if failInventoryAfterInstall && installedOnce { throw NativeApplicationManagementError.serviceUnavailable }
        return apps.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {
        installs += 1
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String
        let bundle = info?["CFBundleIdentifier"] as? String ?? "?"
        installOrder.append(bundle)
        switch failInstall {
        case .notInstalled:
            throw NativeApplicationManagementError.serviceUnavailable
        case .wrongVersionInstalled:
            apps[bundle] = .init(bundleIdentifier: bundle, version: "0.9", teamIdentifier: "TESTTEAM01")
        case .installedButResponseLost:
            apps[bundle] = .init(bundleIdentifier: bundle, version: version, teamIdentifier: "TESTTEAM01")
            throw NativeApplicationManagementError.serviceUnavailable
        case nil:
            apps[bundle] = .init(bundleIdentifier: bundle, version: version, teamIdentifier: "TESTTEAM01")
        }
        installedOnce = true
    }

    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws { XCTFail("known-good app must never be uninstalled") }
    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {}
    func writeContainer(bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity) async throws {}
    func readContainer(bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity) async throws -> Data { Data() }
}
