import Foundation
@testable import IOSSimMacCore
import XCTest

/// The post-install Trust Developer step, end to end through the real engine, planner, the
/// production `.developerSupport` adapter, the structured classifier and the presentation.
/// Only the phone is scripted: its DDI state and how it answers a launch of the installed app.
final class TrustDeveloperFlowTests: XCTestCase {
    private var root: URL!
    private var repository: InstallationJournalRepository!
    private let device = try! IOSSimDeviceIdentity(udid: "00008150-00022D581E12401C", connectionGeneration: 3)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-trust-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private struct Run {
        let status: String
        let userAction: String?
        let firstFailure: EngineFailureSummary?
        var stage: DevelopmentInstallationStage {
            .resolve(firstFailureCode: firstFailure?.code, failureDomain: firstFailure?.domain,
                     userAction: userAction, status: status, issuedRunSetupRequest: false)
        }
    }

    /// One Install / Prepare or Continue press: the same `.reconcile` the development UI sends,
    /// reported the way `EngineHost` reports it.
    private func press(_ phone: ScriptedPhone, vpn: VPNState, appSeed: String = "a",
                       proveSigningChain: Bool = true, later: LaterDomains? = nil) async -> Run {
        let seeds: [SeedProvenDomain] = [
            .init(domain: .certificate, kind: proveSigningChain ? "appleInventorySPKIMatch" : "seed"),
            .init(domain: .profile, kind: proveSigningChain ? "profileCMSBindingValidation" : "seed"),
            .init(domain: .payload, kind: proveSigningChain ? "payloadIndependentVerification" : "seed"),
            .init(domain: .application, kind: "deviceInventoryAfterInstall", seed: appSeed),
        ]
        let developerSupport = ProductionDeviceDomains.developerSupport(
            probe: phone, coordinator: phone, repository: repository, device: { self.device })
        let lvpn = CoordinatedDeviceDomain(
            domain: .vpn,
            observe: { _ in vpn.connected ? .satisfied() : .actionable(DeviceDomainFailure.vpnNotRunning) },
            prepare: { _ in vpn.connected ? .satisfied() : .actionable(DeviceDomainFailure.vpnNotRunning) })
        let extra = later.map { [$0.pairing, $0.runtime] } ?? []
        let domains: [InstallationDomain] = [.certificate, .profile, .payload, .application, .developerSupport, .vpn]
            + extra.map(\.domain)
        let target = EngineDeviceSelection(udid: device.udid, name: "iPhone", transportIdentity: device)
        do {
            let engine = try VeyaReconciliationEngine(
                journalRepository: repository, observers: seeds + [developerSupport, lvpn] + extra,
                transitions: seeds + [developerSupport, lvpn] + extra, sleeper: InstantSleep(), leaseSleeper: InstantSleep())
            let outcome = try await engine.reconcile(
                scope: try InstallationScope(domains: domains, selectedDeviceIDHash: target.idHash,
                                             connectionGeneration: device.connectionGeneration),
                to: DesiredInstallationState(requirements: domains.map { DesiredDomainState(domain: $0) }),
                policy: ReconciliationPolicy(allowedDomains: domains, maximumTransitions: 64))
            return Run(status: outcome.status.rawValue, userAction: outcome.userAction,
                       firstFailure: outcome.failure.map {
                           EngineFailureSummary(code: $0.code, safeMessage: $0.safeMessage, domain: $0.originatingDomain)
                       })
        } catch {
            let result = EngineHost.failureResult(EngineRequest(command: .reconcile), error: error,
                                                  identity: EngineIdentity(packaged: false, qualificationBuild: true))
            return Run(status: result.status, userAction: result.userAction, firstFailure: result.firstFailure)
        }
    }

    // MARK: - Fresh install

    func testFreshInstallUntrustedThenTrustedThenLocalDevVPN() async throws {
        let phone = ScriptedPhone(launch: .untrustedDeveloper)
        let vpn = VPNState()

        // Install / Prepare: the app is installed, Veya mounts its own DDI and launches the app.
        var run = await press(phone, vpn: vpn)
        var launches = await phone.launches
        XCTAssertEqual(launches, 1, "a fresh install is followed by the controlled launch probe")
        XCTAssertEqual(run.userAction, DeviceFailureMapping.developerTrust)
        XCTAssertEqual(run.stage, .trustDeveloper, "trust is the earliest actionable prerequisite")
        XCTAssertEqual(run.stage.primaryAction, .continueUserAction)

        // Continue without trusting: the click proves nothing; the app is launched again and
        // is still refused, so the user stays on Trust Developer.
        run = await press(phone, vpn: vpn)
        launches = await phone.launches
        XCTAssertEqual(launches, 2, "Continue re-probes the installed app")
        XCTAssertEqual(run.stage, .trustDeveloper)

        // The user trusts the developer on the iPhone, then Continue.
        await phone.set(launch: .launches)
        run = await press(phone, vpn: vpn)
        launches = await phone.launches
        XCTAssertEqual(launches, 3)
        XCTAssertNotEqual(run.userAction, DeviceFailureMapping.developerTrust)
        XCTAssertEqual(run.stage, .connectLocalDevVPN, "LocalDevVPN is the next fresh-phone prerequisite")
        let installs = await phone.mounts
        XCTAssertEqual(installs, 1, "trust recovery never reinstalls, re-signs or remounts")

        // LocalDevVPN connected with a real proof: nothing further is asked of the user.
        vpn.connected = true
        run = await press(phone, vpn: vpn)
        XCTAssertEqual(run.status, ReconciliationOutcomeStatus.ready.rawValue)
        XCTAssertEqual(run.stage, .ready)
    }

    func testFreshInstallThatAlreadyLaunchesSkipsTrustDeveloper() async throws {
        let phone = ScriptedPhone(launch: .launches)
        let run = await press(phone, vpn: VPNState())
        let launches = await phone.launches
        XCTAssertEqual(launches, 1)
        XCTAssertNotEqual(run.stage, .trustDeveloper)
        XCTAssertEqual(run.stage, .connectLocalDevVPN)
    }

    // MARK: - Already installed

    func testAlreadyInstalledAppIsProbedRatherThanAssumedUntrusted() async throws {
        // Trusted: established setup, VPN proven; every user gate is skipped.
        let trusted = ScriptedPhone(launch: .launches, mounted: true)
        let vpn = VPNState()
        vpn.connected = true
        let run = await press(trusted, vpn: vpn)
        XCTAssertEqual(run.stage, .ready)
        let mounts = await trusted.mounts
        XCTAssertEqual(mounts, 0, "an already-mounted image is used, not remounted")

        // A reinstall on the same connection makes the old launch proof stale: the new app is
        // launched again, and an untrusted result surfaces Trust Developer.
        await trusted.set(launch: .untrustedDeveloper)
        let reinstalled = await press(trusted, vpn: vpn, appSeed: "b")
        let launches = await trusted.launches
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(reinstalled.stage, .trustDeveloper)
    }

    // MARK: - Whole sequence

    func testFreshPhoneFromDeveloperModeToReady() async throws {
        // Developer Mode: hidden, revealed, enabled with Apple's restart, re-bound by UDID.
        let before = try inspection(.disabled, generation: 1)
        let gateServices = GatePhone(inspection: before)
        let gate = DeveloperModeGateCoordinator(services: gateServices)
        var progress = await gate.adopt(inspection: before)
        XCTAssertEqual(progress.phase, .reveal)
        progress = await gate.reveal(on: before.identity)
        XCTAssertEqual(progress.phase, .enable)
        await gateServices.set(try inspection(.enabled, generation: 2))
        progress = await gate.verify(stableUDID: before.identity.udid)
        XCTAssertEqual(progress.phase, .verified)
        XCTAssertEqual(progress.device?.connectionGeneration, 2, "the restarted phone, same UDID")

        // Install / Prepare through READY.
        let phone = ScriptedPhone(launch: .untrustedDeveloper)
        let vpn = VPNState()
        let later = LaterDomains()
        var run = await press(phone, vpn: vpn, later: later)
        XCTAssertEqual(run.stage, .trustDeveloper)
        run = await press(phone, vpn: vpn, later: later)
        XCTAssertEqual(run.stage, .trustDeveloper, "Continue while still untrusted")
        await phone.set(launch: .launches)
        run = await press(phone, vpn: vpn, later: later)
        XCTAssertEqual(run.stage, .connectLocalDevVPN)
        XCTAssertEqual(later.pairingAttempts, 0, "pairing never runs against an unproven app or VPN")

        vpn.connected = true
        run = await press(phone, vpn: vpn, later: later)
        XCTAssertEqual(later.pairingAttempts, 1, "automatic pairing follows the VPN proof")
        XCTAssertEqual(run.firstFailure?.code, RuntimeReadinessDomain.runSetupRequired.code)
        XCTAssertEqual(DevelopmentInstallationStage.resolve(
            firstFailureCode: run.firstFailure?.code, failureDomain: run.firstFailure?.domain,
            userAction: run.userAction, status: run.status, issuedRunSetupRequest: true), .readyForSetup)

        later.runSetupTapped = true
        run = await press(phone, vpn: vpn, later: later)
        XCTAssertEqual(run.stage, .ready)
    }

    func testEstablishedPhoneSkipsEveryUserGate() async throws {
        let ready = try inspection(.enabled, generation: 5)
        let gate = DeveloperModeGateCoordinator(services: GatePhone(inspection: ready))
        let progress = await gate.adopt(inspection: ready)
        XCTAssertTrue(progress.allowsEnginePipeline)

        let vpn = VPNState()
        vpn.connected = true
        let later = LaterDomains()
        later.runSetupTapped = true
        let run = await press(ScriptedPhone(launch: .launches, mounted: true), vpn: vpn, later: later)
        XCTAssertEqual(run.stage, .ready)
        XCTAssertNil(run.userAction)
    }

    private func inspection(_ mode: DeveloperModeReadiness, generation: UInt64) throws -> NativeDeviceInspection {
        NativeDeviceInspection(
            identity: try IOSSimDeviceIdentity(udid: device.udid, usbmuxIdentifier: UInt32(10 + generation),
                                               connection: .usb, connectionGeneration: generation),
            connection: .usb, name: "iPhone", osVersion: "26.6.2", osBuild: "23G90",
            trust: .trusted, lockState: .unlocked, developerMode: mode)
    }

    // MARK: - Never trust

    func testOtherLaunchAndDeviceFailuresAreNeverTrustDeveloper() async throws {
        let cases: [(String, ScriptedPhone.Launch)] = [
            ("generic launch refusal", .fails(NativeDeviceBridgeError.launchRejected("appservice: refused"))),
            ("bad executable", .fails(.launchRejectedStructured(NativeLaunchRejection(
                schemaVersion: 1, envelope: .coreDeviceErrorEnvelope,
                chain: [.init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
                        .init(domain: "FBSOpenApplicationErrorDomain", code: 5, bsDescription: "BadExecutable")],
                chainComplete: true)))),
            ("developer mode", .fails(.developerModeRequired)),
            ("locked", .fails(.deviceLocked)),
            ("disconnected", .fails(.deviceDisconnected)),
            ("app missing", .fails(.applicationNotFound("com.personalteam.iossim.main"))),
            ("DDI unavailable", .ddiFails),
        ]
        for (name, launch) in cases {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let run = await press(ScriptedPhone(launch: launch), vpn: VPNState())
            XCTAssertNotEqual(run.userAction, DeviceFailureMapping.developerTrust, name)
            XCTAssertNotEqual(run.stage, .trustDeveloper, name)
        }
    }

    func testUnprovenSigningChainKeepsTheSecurityDenialOutOfTrust() async throws {
        // Signing/profile/certificate not proven: the same Security denial is a typed launch
        // failure with its Apple chain, never Trust Developer.
        let run = await press(ScriptedPhone(launch: .untrustedDeveloper), vpn: VPNState(), proveSigningChain: false)
        XCTAssertNotEqual(run.stage, .trustDeveloper)
        XCTAssertEqual(run.firstFailure?.code, "VEYA-DDI-032")
        XCTAssertTrue(run.firstFailure?.safeMessage.contains("FBSOpenApplicationErrorDomain 3 Security") == true)
    }
}

private final class VPNState: @unchecked Sendable { var connected = false }

/// Pairing and runtime stand-ins that only record ordering: their real proofs are covered by
/// their own suites and are unchanged here.
private final class LaterDomains: @unchecked Sendable {
    var pairingAttempts = 0
    var paired = false
    var runSetupTapped = false

    lazy var pairing = CoordinatedDeviceDomain(
        domain: .pairing,
        observe: { [unowned self] _ in self.paired ? .satisfied() : .missing() },
        prepare: { [unowned self] _ in
            self.pairingAttempts += 1
            self.paired = true
            return .satisfied()
        })
    lazy var runtime = CoordinatedDeviceDomain(
        domain: .runtime,
        observe: { [unowned self] _ in
            self.runSetupTapped ? .satisfied() : .actionable(RuntimeReadinessDomain.runSetupRequired)
        },
        prepare: { [unowned self] _ in
            self.runSetupTapped ? .satisfied() : .actionable(RuntimeReadinessDomain.runSetupRequired)
        })
}

private actor GatePhone: DeveloperModeGateServicing {
    private var inspection: NativeDeviceInspection
    init(inspection: NativeDeviceInspection) { self.inspection = inspection }
    func set(_ inspection: NativeDeviceInspection) { self.inspection = inspection }
    func revealDeveloperMode(on device: IOSSimDeviceIdentity) async throws {}
    func rebind(stableUDID: String) async throws -> NativeDeviceInspection {
        guard stableUDID == inspection.identity.udid else { throw NativeDeviceBridgeError.deviceNotFound }
        return inspection
    }
    func personalizedImageMounted(on device: IOSSimDeviceIdentity) async -> Bool { false }
    func developerServicesTransportReady(on device: IOSSimDeviceIdentity) async -> Bool { false }
}

/// A phone with no pre-mounted image (as after the Developer Mode restart) unless told otherwise.
private actor ScriptedPhone: DeveloperServicesProbing, DeveloperServicesPreparing {
    enum Launch { case launches, untrustedDeveloper, fails(NativeDeviceBridgeError), ddiFails }
    private var launch: Launch
    private var mounted: Bool
    private(set) var launches = 0
    private(set) var mounts = 0

    init(launch: Launch, mounted: Bool = false) {
        self.launch = launch
        self.mounted = mounted
    }

    func set(launch: Launch) { self.launch = launch }

    func readiness(_ device: IOSSimDeviceIdentity) async throws -> DeveloperServicesReadinessReceipt {
        guard mounted else { throw NativeDeviceBridgeError.ddiRequired("image not mounted") }
        return Self.receipt
    }

    func prepare(device: IOSSimDeviceIdentity, context: DeveloperServicesProofContext,
                 progress: @escaping @Sendable (ConsumerProvisioningStage) async -> Void)
        async throws -> DeveloperServicesReadinessReceipt {
        if !mounted {
            if case .ddiFails = launch { throw DeveloperSupportFailure.mountRejected }
            mounts += 1
            mounted = true
        }
        launches += 1
        switch launch {
        case .launches: return Self.receipt
        case .ddiFails: throw DeveloperSupportFailure.mountRejected
        case .fails(let error): throw error
        case .untrustedDeveloper:
            throw NativeDeviceBridgeError.launchRejectedStructured(NativeLaunchRejection(
                schemaVersion: 1, envelope: .coreDeviceErrorEnvelope,
                chain: [
                    .init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
                    .init(domain: "FBSOpenApplicationServiceErrorDomain", code: 1, bsDescription: "RequestDenied"),
                    .init(domain: "FBSOpenApplicationErrorDomain", code: 3, bsDescription: "Security"),
                ],
                chainComplete: true))
        }
    }

    private static let receipt = DeveloperServicesReadinessReceipt(
        coreDeviceProxyReady: true, softwareTunnelReady: true, rsdReady: true, remoteXPCReady: true,
        appServiceReady: true, launchFeatureReady: true, ddiMounted: true)
}

/// Promotes a record for an upstream domain with the evidence kind its real domain records, so
/// the classifier's journal prerequisites are read exactly as in production.
private struct SeedProvenDomain: InstallationObserver, InstallationTransition {
    let domain: InstallationDomain
    let kind: String
    var seed = "a"
    private var digest: String { VeyaSigningKeyStore.sha256(Data("\(domain.rawValue)|\(seed)".utf8)) }

    func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        if let candidate = journal.candidateResource(for: domain) {
            let proved = journal.evidence.contains { candidate.evidenceIDs.contains($0.id) }
            return try DomainObservation(domain: domain, state: proved ? .candidateProved : .candidateUnproved,
                                         resource: candidate.identity, capturedAt: Date())
        }
        let active = journal.activeResource(for: domain)
        return try DomainObservation(
            domain: domain,
            state: active?.identity.digest == digest ? .satisfied : (active == nil ? .missing : .stale),
            resource: active?.identity, capturedAt: Date())
    }

    func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        if let candidate = context.candidate {
            return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: candidate.generation,
                                         candidate: candidate)
        }
        let metadata = domain == .application
            ? ["teamIdentifier": "ABCDEFGHIJ", "bundle.main": "com.personalteam.iossim.main",
               "bundle.runner": "com.personalteam.iossim.uitests.xctrunner", "roles": "main,runner"]
            : [:]
        let record = try ResourceRecord(
            id: "\(domain.rawValue)-\(context.planned.generation.rawValue)",
            identity: ResourceIdentity(domain: domain, resourceID: "\(domain.rawValue)-seed", digest: digest),
            lifecycle: .candidate, generation: context.planned.generation, ownership: .activePayloadCorroboration,
            createdAt: Date(), observedAt: Date(), metadata: metadata)
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation,
                                     candidate: record)
    }

    func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        let candidate = try XCTUnwrap(receipt.candidate ?? context.candidate)
        return try Evidence(id: VeyaSigningKeyStore.sha256(Data("\(kind)|\(candidate.id)".utf8)), kind: kind,
                            generation: candidate.generation, subject: candidate.identity, capturedAt: Date(),
                            provenance: "test")
    }
}
