import Foundation
@testable import IOSSimMacCore
import XCTest

/// Production wiring seams: the device domains wrap the coordinators the shipping helper uses
/// (DDI via `NativeDeveloperServicesCoordinator`, not the unrouted `DeveloperSupportCoordinator`), device
/// state is bound to the installed application, the v2 pairing store never prompts, and the full
/// production composition observes every domain and fails closed where M4 is unresolved.
final class ProductionWiringTests: XCTestCase {
    private var root: URL!
    private var repository: InstallationJournalRepository!
    private let device = try! IOSSimDeviceIdentity(udid: "00008150-00022D581E12401C", connectionGeneration: 3)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-wiring-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var scope: InstallationScope {
        try! InstallationScope(domains: [.application, .developerSupport, .pairing, .vpn],
                               selectedDeviceIDHash: EngineDeviceSelection(udid: device.udid, name: "x").idHash,
                               connectionGeneration: 3)
    }

    /// Promotes an `.application` record shaped like `ApplicationDomain`'s (team, main, runner).
    private func install(digestSeed: String) async throws {
        let seed = SeedApplication(seed: digestSeed)
        let engine = try VeyaReconciliationEngine(journalRepository: repository, observers: [seed], transitions: [seed],
                                                  sleeper: InstantSleep(), leaseSleeper: InstantSleep())
        let outcome = try await engine.reconcile(
            scope: try InstallationScope(domains: [.application]),
            to: DesiredInstallationState(requirements: [.init(domain: .application)]),
            policy: ReconciliationPolicy(allowedDomains: [.application], maximumTransitions: 4))
        XCTAssertEqual(outcome.status, .ready)
    }

    func testDeveloperSupportObservationUsesTheProductionReadinessProbeAndMapsItsFailures() async throws {
        try await install(digestSeed: "a")
        let probe = ScriptedProbe()
        let domain = ProductionDeviceDomains.developerSupport(probe: probe, coordinator: ScriptedDeveloperServices(),
                                                              repository: repository, device: { self.device })
        let journal = try await repository.load()
        for (result, expected) in [
            (ScriptedProbe.Result.ready, DomainObservationState.missing), // ready but no active record yet
            (.error(NativeDeviceBridgeError.ddiRequired("x")), .missing),
            (.error(NativeDeviceBridgeError.developerModeRequired), .waitingForUser),
            (.error(NativeDeviceBridgeError.deviceLocked), .waitingForUser),
            (.error(DeveloperSupportFailure.noApprovedSource), .terminalFailure),
            (.error(NativeDeviceBridgeError.timedOut), .retryableFailure),
        ] {
            probe.result = result
            let observation = try await domain.observe(scope: scope, journal: journal)
            XCTAssertEqual(observation.state, expected, "\(result)")
        }
        probe.result = .error(DeveloperSupportFailure.wrongBuildIdentity)
        let incompatible = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(incompatible.failure?.code, DeviceDomainFailure.ddiIncompatible.code)
    }

    func testDeveloperSupportLaunchProofTargetsTheMainAppInsteadOfPlainLaunchingTheXCTestRunner() async throws {
        try await install(digestSeed: "a")
        let services = RecordingDeveloperServices()
        let domain = ProductionDeviceDomains.developerSupport(
            probe: services,
            coordinator: services,
            repository: repository,
            device: { self.device }
        )
        let engine = try VeyaReconciliationEngine(
            journalRepository: repository,
            observers: [domain],
            transitions: [domain],
            sleeper: InstantSleep(),
            leaseSleeper: InstantSleep()
        )

        let outcome = try await engine.reconcile(
            scope: scope,
            to: DesiredInstallationState(requirements: [.init(domain: .developerSupport)]),
            policy: ReconciliationPolicy(allowedDomains: [.developerSupport], maximumTransitions: 4)
        )

        XCTAssertEqual(outcome.status, .ready)
        let capturedTarget = await services.capturedTarget()
        XCTAssertEqual(capturedTarget, "com.personalteam.iossim.main")
    }

    func testPairingIsProvenPerInstalledApplicationAndReplacedAfterAnAppReinstall() async throws {
        try await install(digestSeed: "a")
        let store = InMemoryRemotePairingStore()
        let native = ScriptedPairingNative()
        let coordinator = RemotePairingCoordinator(store: store, native: native, delivery: NoDelivery())
        let domain = ProductionDeviceDomains.pairing(store: store, native: native, coordinator: coordinator,
                                                     repository: repository, device: { self.device })
        var journal = try await repository.load()
        var observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .missing, "no Mac-side record")

        let payload = try XCTUnwrap(InstalledPayloadIdentity(journal: journal))
        try store.save(try ScriptedPairingNative.record(udid: device.udid, team: payload.teamIdentifier))
        observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .missing, "validated on the device, but never proven for this app/connection")

        native.rejectValidation = true
        observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .invalid, "a rejected record is repaired, never trusted")

        // Promote a pairing proven for app A, then reinstall (app B): the pairing is stale and must be re-delivered.
        native.rejectValidation = false
        let prepared = ClockOffset()
        let dependent = CoordinatedDeviceDomain(
            domain: .pairing,
            observe: { _ in prepared.seconds > 0 ? .satisfied() : .missing() },
            prepare: { _ in prepared.seconds = 1; return .satisfied() },
            dependsOn: [.application], repository: repository)
        let engine = try VeyaReconciliationEngine(journalRepository: repository, observers: [dependent], transitions: [dependent],
                                                  sleeper: InstantSleep(), leaseSleeper: InstantSleep())
        let ready = try await engine.reconcile(scope: scope, to: DesiredInstallationState(requirements: [.init(domain: .pairing)]),
                                               policy: ReconciliationPolicy(allowedDomains: [.pairing], maximumTransitions: 4))
        XCTAssertEqual(ready.status, .ready)
        journal = try await repository.load()
        observation = try await dependent.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .satisfied)
        try await install(digestSeed: "b")
        journal = try await repository.load()
        observation = try await dependent.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .stale, "a reinstalled app has an empty container: pairing is re-delivered")
    }

    /// Setup completion moved to the user's Run Setup tap; pairing delivery did not. The pairing
    /// transition still bootstraps the record into the app container itself, bound to the installed
    /// payload, and never asks the user to import a file.
    func testPairingTransitionStillDeliversAutomaticallyAndAsksTheUserForNothing() async throws {
        try await install(digestSeed: "a")
        let store = InMemoryRemotePairingStore()
        let native = ScriptedPairingNative()
        let delivery = RecordingDelivery()
        let domain = ProductionDeviceDomains.pairing(
            store: store, native: native,
            coordinator: RemotePairingCoordinator(store: store, native: native, delivery: delivery),
            repository: repository, device: { self.device })
        let journal = try await repository.load()
        let payload = try XCTUnwrap(InstalledPayloadIdentity(journal: journal))
        let digest = "sha256:" + String(repeating: "7", count: 64)

        do {
            _ = try await domain.execute(TransitionContext(
                runID: RunID(), installationID: UUID(), scope: scope,
                desired: try DesiredInstallationState(requirements: [.init(domain: .pairing)]),
                planned: try PlannedTransition(domain: .pairing, kind: .createCandidate, permission: .safeRepair,
                                               generation: Generation(rawValue: 1), target: nil,
                                               desiredDigest: digest),
                attempt: 1, candidate: nil, maximumPermission: .safeRepair))
            XCTFail("the scripted phone never answers the bootstrap")
        } catch {}

        XCTAssertEqual(delivery.calls.first, "writeBootstrapRequest", "delivery is automatic, not a user import")
        XCTAssertEqual(delivery.appBundleIdentifiers, [payload.mainBundleIdentifier],
                       "delivered into the installed payload's own container")
        XCTAssertFalse(delivery.calls.contains { $0.contains("runSetup") })
    }

    func testVPNObservationIsReadOnlyAndAcceptsOnlyAFreshBoundReachableReceipt() async throws {
        try await install(digestSeed: "a")
        let journal = try await repository.load()
        let payload = try XCTUnwrap(InstalledPayloadIdentity(journal: journal))
        let service = ContainerService()
        let clock = ClockOffset()
        let domain = ProductionDeviceDomains.vpn(
            service: service, coordinator: LocalDevVPNSetupCoordinator(service: service), repository: repository,
            device: { self.device }, now: { Date().addingTimeInterval(clock.seconds) })

        func receipt(state: LocalDevVPNLifecycleState, reachable: Bool, release: String? = nil, udid: String? = nil) throws {
            let value = LocalDevVPNSetupReceiptPayload(
                requestID: "r", status: state == .runtimeEndpointReachable ? "ready" : "action_required",
                endpoint: LocalDevVPNEndpoint(), interfaceVisible: true, endpointReachable: reachable, errorCode: nil,
                timestamp: Date(), lifecycleState: state, deviceUDID: udid ?? device.udid,
                teamIdentifier: payload.teamIdentifier, releaseIdentity: release ?? payload.releaseIdentity)
            service.files[LocalDevVPNSetupCoordinator.receiptPath] = try JSONEncoder().encode(value)
        }
        var observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .missing, "no receipt")
        try receipt(state: .vpnPermissionRequired, reachable: false)
        observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .invalid, "a reported action is re-probed, never waited on")
        XCTAssertEqual(observation.userAction, "Open LocalDevVPN on the iPhone and allow the VPN configuration.")
        try receipt(state: .running, reachable: false)
        observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .invalid, "running is never ready")
        try receipt(state: .runtimeEndpointReachable, reachable: true, release: "veya-v2:another-payload")
        observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .missing, "a receipt for another payload proves nothing")
        try receipt(state: .runtimeEndpointReachable, reachable: true, udid: "00008030-001A2B3C4D5E6F70")
        observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .missing, "a receipt from another iPhone proves nothing")
        try receipt(state: .runtimeEndpointReachable, reachable: true)
        observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .missing, "a fresh reachable receipt without a proven record is not satisfied")
        clock.seconds = 61
        observation = try await domain.observe(scope: scope, journal: journal)
        XCTAssertEqual(observation.state, .stale, "a minute-old receipt must be re-probed: LocalDevVPN may be off now")
        XCTAssertEqual(service.writes, 0, "observation never writes to the device")
        XCTAssertEqual(service.launches, 0, "observation never launches apps")
    }

    func testInstallationV2PairingStoreFailsClosedWithoutTouchingTheKeychain() throws {
        let store = KeychainRemotePairingStore.installationV2(backend: .unavailable)
        XCTAssertThrowsError(try store.load(deviceUDID: device.udid, teamIdentifier: "TEAM")) {
            XCTAssertEqual($0 as? RemotePairingFailure, .secureStorageUnavailable)
        }
        XCTAssertThrowsError(try store.delete(deviceUDID: device.udid, teamIdentifier: "TEAM")) {
            XCTAssertEqual($0 as? RemotePairingFailure, .secureStorageUnavailable)
        }
        XCTAssertEqual(DeviceFailureMapping.map(RemotePairingFailure.secureStorageUnavailable).failure?.code,
                       DeviceFailureMapping.secureStorageUnavailable.code, "never mistaken for a corrupt record")
        XCTAssertEqual(DeviceFailureMapping.map(RemotePairingFailure.invalidRecord).state, .invalid)
    }

    func testRetiredLegacyIdentityStoreRefusesEveryCall() {
        let retired = RetiredLegacyIdentityKeychain()
        XCTAssertThrowsError(try retired.installationIdentifier())
        XCTAssertThrowsError(try retired.createPrivateKey(applicationTag: Data()))
        XCTAssertThrowsError(try retired.load(teamIdentifier: "T"))
        XCTAssertNil(retired.lookupPrivateKey(applicationTag: Data()).key)
    }

    func testFullProductionCompositionObservesEveryDomainAndFailsClosedAtTheUnavailableKeyStore() async throws {
        let resources = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEYA_EXACT_PAYLOAD_RESOURCES"]
            ?? "/Applications/Veya.app/Contents/Resources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("DeviceArtifacts").path) else {
            throw XCTSkip("INTEGRATION_REQUIRED: set VEYA_EXACT_PAYLOAD_RESOURCES to a Veya Resources directory")
        }
        guard WrappingSecretBackendKind.forRunningCode() == .unavailable else {
            throw XCTSkip("This check targets builds without a profile-granted key store (M4 unresolved)")
        }
        let portal = try SimulatedApplePortal(workspace: root.appendingPathComponent("portal", isDirectory: true))
        let backend = LiveApplePersonalTeamBackend(
            transport: portal, machineIdentity: FixtureMachineIdentity(),
            sessionStore: MemoryAuthorizationSessionStore(session: fixtureSession()),
            diagnostics: ApplePersonalTeamDiagnosticsStore(url: root.appendingPathComponent("diagnostics.json")))
        let composition = ProductionComposition.make(
            helperURL: URL(fileURLWithPath: "/tmp/IOSSimProvisioner"), stateRoot: root,
            device: EngineDeviceSelection(udid: device.udid, name: "Fixture"), connectionGeneration: 3,
            resourcesURL: resources, appleServices: backend)

        let inspected = await EngineHost.handle(EngineRequest(command: .inspect), composition: composition)
        XCTAssertEqual(inspected.skippedProofs, [], "every domain has a production observer")
        XCTAssertEqual(Set(inspected.observations.map(\.domain)), Set(InstallationDomain.allCases))
        XCTAssertEqual(inspected.observations.first { $0.domain == .artifact }?.state, .satisfied)

        let all = CapabilityManifest(allowedDomains: InstallationDomain.allCases, maximumTransitions: 32)
        let result = await EngineHost.handle(EngineRequest(command: .reconcile, capabilities: all), composition: composition)
        XCTAssertEqual(result.firstFailure?.code, SigningKeyFailure.wrappingStoreUnavailable.code,
                       "the new route fails closed at the key store; nothing downstream runs")
        let calls = await portal.calls
        XCTAssertFalse(calls.contains("submitDevelopmentCSR"), "no certificate without a key")
        XCTAssertFalse(calls.contains("addDevice"))
        let journal = try await repository.load()
        XCTAssertNotNil(journal.activeResource(for: .migration))
        XCTAssertNil(journal.activeResource(for: .signingKey))
    }
}

private struct SeedApplication: InstallationObserver, InstallationTransition {
    let domain: InstallationDomain = .application
    let seed: String
    private var digest: String { VeyaSigningKeyStore.sha256(Data(seed.utf8)) }

    func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        if let candidate = journal.candidateResource(for: domain) {
            let proved = journal.evidence.contains { candidate.evidenceIDs.contains($0.id) }
            return try DomainObservation(domain: domain, state: proved ? .candidateProved : .candidateUnproved,
                                         resource: candidate.identity, capturedAt: Date())
        }
        let active = journal.activeResource(for: domain)
        return try DomainObservation(domain: domain, state: active?.identity.digest == digest ? .satisfied : (active == nil ? .missing : .stale),
                                     resource: active?.identity, capturedAt: Date())
    }

    func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        if let candidate = context.candidate {
            return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: candidate.generation, candidate: candidate)
        }
        let record = try ResourceRecord(
            id: "application-\(context.planned.generation.rawValue)",
            identity: ResourceIdentity(domain: domain, resourceID: "com.personalteam.iossim.main", digest: digest),
            lifecycle: .candidate, generation: context.planned.generation, ownership: .activePayloadCorroboration,
            createdAt: Date(), observedAt: Date(),
            metadata: ["teamIdentifier": "ABCDEFGHIJ", "bundle.main": "com.personalteam.iossim.main",
                       "bundle.runner": "com.personalteam.iossim.uitests.xctrunner", "roles": "main,runner"])
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
    }

    func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        let candidate = try XCTUnwrap(receipt.candidate ?? context.candidate)
        return try Evidence(id: VeyaSigningKeyStore.sha256(Data("seed|\(candidate.id)".utf8)), kind: "seed",
                            generation: candidate.generation, subject: candidate.identity, capturedAt: Date(), provenance: "test")
    }
}

private final class ScriptedProbe: DeveloperServicesProbing, @unchecked Sendable {
    enum Result { case ready, error(Error) }
    var result: Result = .ready
    func readiness(_ device: IOSSimDeviceIdentity) async throws -> DeveloperServicesReadinessReceipt {
        switch result {
        case .ready:
            return DeveloperServicesReadinessReceipt(coreDeviceProxyReady: true, softwareTunnelReady: true, rsdReady: true,
                                                     remoteXPCReady: true, appServiceReady: true, launchFeatureReady: true,
                                                     ddiMounted: true)
        case .error(let error):
            throw error
        }
    }
}

private struct ScriptedDeveloperServices: DeveloperServicesPreparing {
    func prepare(device: IOSSimDeviceIdentity, context: DeveloperServicesProofContext,
                 progress: @escaping @Sendable (ConsumerProvisioningStage) async -> Void) async throws -> DeveloperServicesReadinessReceipt {
        throw NativeDeviceBridgeError.timedOut
    }
}

private actor RecordingDeveloperServices: DeveloperServicesProbing, DeveloperServicesPreparing {
    private var prepared = false
    private var target: String?

    func readiness(_ device: IOSSimDeviceIdentity) async throws -> DeveloperServicesReadinessReceipt {
        guard prepared else { throw NativeDeviceBridgeError.ddiRequired("not prepared") }
        return readyReceipt()
    }

    func prepare(
        device: IOSSimDeviceIdentity,
        context: DeveloperServicesProofContext,
        progress: @escaping @Sendable (ConsumerProvisioningStage) async -> Void
    ) async throws -> DeveloperServicesReadinessReceipt {
        target = context.targetBundleIdentifier
        prepared = true
        return readyReceipt()
    }

    func capturedTarget() -> String? { target }

    private func readyReceipt() -> DeveloperServicesReadinessReceipt {
        DeveloperServicesReadinessReceipt(
            coreDeviceProxyReady: true,
            softwareTunnelReady: true,
            rsdReady: true,
            remoteXPCReady: true,
            appServiceReady: true,
            launchFeatureReady: true,
            ddiMounted: true
        )
    }
}

private final class ScriptedPairingNative: RemotePairingNativeOperations, @unchecked Sendable {
    var rejectValidation = false
    func create(on device: IOSSimDeviceIdentity, hostname: String) async throws -> RemotePairingMaterial {
        throw RemotePairingFailure.transientTransport
    }
    func validate(_ record: RemotePairingRecord, on device: IOSSimDeviceIdentity, hostname: String) async throws {
        if rejectValidation { throw RemotePairingFailure.pairingRejected }
    }
    static func record(udid: String, team: String) throws -> RemotePairingRecord {
        RemotePairingRecord(metadata: RemotePairingRecordMetadata(deviceUDID: udid, teamIdentifier: team, identifier: "pair",
                                                                  publicKeyFingerprint: String(repeating: "a", count: 64)),
                            pairingData: Data("synthetic".utf8))
    }
}

/// Records what the pairing transition actually does to the phone, then stops the run at the
/// first point the scripted phone would have to answer.
private final class RecordingDelivery: RemotePairingContainerDelivery, @unchecked Sendable {
    private(set) var calls: [String] = []
    private(set) var appBundleIdentifiers: Set<String> = []
    private func record(_ name: String, _ appBundleIdentifier: String) {
        calls.append(name)
        appBundleIdentifiers.insert(appBundleIdentifier)
    }
    func writeEnvelope(_ envelope: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        record("writeEnvelope", appBundleIdentifier)
    }
    func readReceipt(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        record("readReceipt", appBundleIdentifier)
        throw RemotePairingFailure.receiptMissing
    }
    func writeBootstrapRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        record("writeBootstrapRequest", appBundleIdentifier)
    }
    func readBootstrap(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        record("readBootstrap", appBundleIdentifier)
        throw RemotePairingFailure.bootstrapInvalid
    }
    func activateApp(on device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        record("activateApp", appBundleIdentifier)
    }
    func writePossessionChallenge(_ challenge: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        record("writePossessionChallenge", appBundleIdentifier)
    }
    func readPossessionResponse(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data {
        record("readPossessionResponse", appBundleIdentifier)
        throw RemotePairingFailure.receiptMissing
    }
    func writePromotionRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws {
        record("writePromotionRequest", appBundleIdentifier)
    }
}

/// Observation must never deliver anything; every delivery call fails the test.
private struct NoDelivery: RemotePairingContainerDelivery {
    private func refuse() -> Error { XCTFail("observation delivered to the device"); return RemotePairingFailure.deliveryFailed }
    func writeEnvelope(_ envelope: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws { throw refuse() }
    func readReceipt(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data { throw refuse() }
    func writeBootstrapRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws { throw refuse() }
    func readBootstrap(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data { throw refuse() }
    func activateApp(on device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws { throw refuse() }
    func writePossessionChallenge(_ challenge: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws { throw refuse() }
    func readPossessionResponse(from device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws -> Data { throw refuse() }
    func writePromotionRequest(_ request: Data, to device: IOSSimDeviceIdentity, appBundleIdentifier: String) async throws { throw refuse() }
}

private final class ContainerService: NativeApplicationServicing, @unchecked Sendable {
    var files: [String: Data] = [:]
    private(set) var writes = 0
    private(set) var launches = 0
    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] { [] }
    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {}
    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {}
    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws { launches += 1 }
    func writeContainer(bundleIdentifier: String, relativePath: String, data: Data, on device: IOSSimDeviceIdentity) async throws {
        writes += 1
    }
    func readContainer(bundleIdentifier: String, relativePath: String, on device: IOSSimDeviceIdentity) async throws -> Data {
        guard let data = files[relativePath] else { throw NativeDeviceBridgeError.containerUnavailable("missing") }
        return data
    }
}
