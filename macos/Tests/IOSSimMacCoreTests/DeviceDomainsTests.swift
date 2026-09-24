import Foundation
@testable import IOSSimMacCore
import XCTest

/// M9: DDI / RemotePairing / LocalDevVPN native states through the canonical engine (scripted device).
final class DeviceDomainsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-m9-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private final class Script: @unchecked Sendable {
        var observed: NativeDomainMapping
        var afterPrepare: NativeDomainMapping
        var prepares = 0
        init(observed: NativeDomainMapping, afterPrepare: NativeDomainMapping) {
            self.observed = observed
            self.afterPrepare = afterPrepare
        }
    }

    private func run(_ domain: InstallationDomain, _ script: Script, connection: UInt64 = 1) async throws -> ReconciliationOutcome {
        let adapter = CoordinatedDeviceDomain(
            domain: domain,
            observe: { _ in script.observed },
            prepare: { _ in script.prepares += 1; script.observed = script.afterPrepare; return script.afterPrepare }
        )
        let repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
        let engine = try VeyaReconciliationEngine(journalRepository: repository, observers: [adapter], transitions: [adapter])
        return try await engine.reconcile(
            scope: InstallationScope(domains: [domain], selectedDeviceIDHash: "sha256:" + String(repeating: "1", count: 64),
                                     connectionGeneration: connection),
            to: DesiredInstallationState(requirements: [.init(domain: domain)]),
            policy: ReconciliationPolicy(allowedDomains: [domain], maximumTransitions: 4, localRetryLimit: 0)
        )
    }

    func testDeveloperSupportMountsProvesAndIsReprovenAfterReconnect() async throws {
        let script = Script(observed: DeviceDomainMapping.developerSupport(.init(.acquisitionNeeded, safeDetail: "x")),
                            afterPrepare: DeviceDomainMapping.developerSupport(.init(.mounted, safeDetail: "rsd verified")))
        let result1 = try await run(.developerSupport, script)
        XCTAssertEqual(result1.status, .ready)
        let result2 = try await run(.developerSupport, script)
        XCTAssertEqual(result2.transitionsCompleted, 0, "same connection: satisfied")
        let reconnected = try await run(.developerSupport, script, connection: 2)
        XCTAssertEqual(reconnected.status, .ready)
        XCTAssertEqual(reconnected.transitionsCompleted, 1, "a new connection generation requires fresh proof")
        XCTAssertEqual(script.prepares, 2)
    }

    func testDeveloperSupportUserActionAndIncompatibleBuildAreTyped() async throws {
        let modeOff = Script(observed: DeviceDomainMapping.developerSupport(.init(.failed, failure: .developerModeDisabled, safeDetail: "x")),
                             afterPrepare: .missing())
        let waiting = try await run(.developerSupport, modeOff)
        XCTAssertEqual(waiting.status, .userActionRequired)
        XCTAssertEqual(modeOff.prepares, 0)
        try? FileManager.default.removeItem(at: root)
        let incompatible = Script(observed: DeviceDomainMapping.developerSupport(.init(.incompatible, safeDetail: "x")),
                                  afterPrepare: .missing())
        let blocked = try await run(.developerSupport, incompatible)
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.failure?.code, DeviceDomainFailure.ddiIncompatible.code)
    }

    func testVPNRunningWithoutEndpointChallengeNeverSatisfies() async throws {
        let script = Script(observed: DeviceDomainMapping.localDevVPN(.configured),
                            afterPrepare: DeviceDomainMapping.localDevVPN(.running))
        do { _ = try await run(.vpn, script); XCTFail("running must not prove the VPN") } catch {}
        let journal = try await InstallationJournalRepository(rootURL: root.appendingPathComponent("installation")).load()
        XCTAssertNil(journal.activeResource(for: .vpn))

        script.afterPrepare = DeviceDomainMapping.localDevVPN(.runtimeEndpointReachable)
        let result3 = try await run(.vpn, script)
        XCTAssertEqual(result3.status, .ready)
    }

    func testVPNPermissionIsAUserActionNotARetry() async throws {
        let script = Script(observed: DeviceDomainMapping.localDevVPN(.vpnPermissionRequired), afterPrepare: .missing())
        let outcome = try await run(.vpn, script)
        XCTAssertEqual(outcome.status, .userActionRequired)
        XCTAssertEqual(script.prepares, 0)
    }

    func testPairingIncompleteStatesResumeAndOperationalProves() async throws {
        let script = Script(observed: DeviceDomainMapping.remotePairing(.awaitingReceipt),
                            afterPrepare: DeviceDomainMapping.remotePairing(.operational))
        let result4 = try await run(.pairing, script)
        XCTAssertEqual(result4.status, .ready)
        script.observed = DeviceDomainMapping.remotePairing(.failed)
        let result5 = try await run(.pairing, script)
        XCTAssertEqual(result5.status, .retryableWait)
    }

    func testOnlyFullyProvenNativeStatesAreSatisfied() {
        let ddi = ["notNeeded", "missing", "acquisitionNeeded", "available", "personalizationRequired", "personalizing",
                   "mountRequired", "mounting", "mounted", "incompatible", "failed"].compactMap(DeveloperSupportState.init(rawValue:))
        XCTAssertEqual(ddi.count, 11)
        XCTAssertEqual(ddi.filter { DeviceDomainMapping.developerSupport(.init($0, safeDetail: "x")).state == .satisfied },
                       [.notNeeded, .mounted])
        let vpn = ["MISSING", "INSTALLED_UNSUPPORTED", "INSTALLED", "VPN_PERMISSION_REQUIRED", "CONFIGURED", "RUNNING",
                   "RUNTIME_ENDPOINT_REACHABLE"].compactMap(LocalDevVPNLifecycleState.init(rawValue:))
        XCTAssertEqual(vpn.count, 7)
        XCTAssertEqual(vpn.filter { DeviceDomainMapping.localDevVPN($0).state == .satisfied }, [.runtimeEndpointReachable])
        let pairing = ["missing", "creating", "candidateStored", "delivering", "awaitingReceipt", "provingPossession",
                       "provingDeveloperServices", "promoting", "stored", "validating", "operational", "repairable", "failed"]
            .compactMap(RemotePairingLifecycleState.init(rawValue:))
        XCTAssertEqual(pairing.count, 13)
        XCTAssertEqual(pairing.filter { DeviceDomainMapping.remotePairing($0).state == .satisfied }, [.operational])
    }

    // Onboarding: legitimate Apple/iPhone actions surface as user actions, not product failures.

    func testLocalDevVPNIsReconciledBeforePairingSoItsPromptIsReachable() {
        let order = InstallationDomain.reconciliationOrder
        XCTAssertLessThan(order.firstIndex(of: .vpn)!, order.firstIndex(of: .pairing)!)
        XCTAssertEqual(order.last, .runtime)
    }

    func testUntrustedDeveloperLaunchRejectionIsAUserActionEverywhere() {
        let untrusted = NativeDeviceBridgeError.launchRejected(
            "launchapplication: Unable to launch because its profile has not been explicitly trusted by the user.")
        XCTAssertTrue(untrusted.isDeveloperTrustRejection)
        XCTAssertFalse(NativeDeviceBridgeError.launchRejected("launchapplication: invalid signature").isDeveloperTrustRejection)
        XCTAssertFalse(NativeDeviceBridgeError.deviceLocked.isDeveloperTrustRejection)

        let direct = DeviceFailureMapping.map(untrusted)
        XCTAssertEqual(direct.state, .waitingForUser)
        XCTAssertEqual(direct.userAction, DeviceFailureMapping.developerTrust)
        // The VPN coordinator's launch of Veya is often the first launch after DDI is already mounted.
        XCTAssertEqual(DeviceFailureMapping.map(LocalDevVPNSetupFailure.developerTrustRequired), direct)
        XCTAssertEqual(DeviceFailureMapping.map(RemotePairingFailure.developerTrustRequired), direct)
        XCTAssertEqual(
            DeviceFailureMapping.map(LocalDevVPNSetupFailure.developerModeRequired).userAction,
            DeviceFailureMapping.developerMode
        )
        XCTAssertEqual(
            DeviceFailureMapping.map(RemotePairingFailure.developerModeRequired).userAction,
            DeviceFailureMapping.developerMode
        )
        XCTAssertEqual(DeviceFailureMapping.map(NativeDeviceBridgeError.launchRejected("invalid signature")).state,
                       .retryableFailure)
    }

    func testTransitionStoppedOnUserActionIsReportedAsUserActionNotProductFailure() async throws {
        let failure: VeyaFailure
        do {
            _ = try await DeviceFailureMapping.prepare { throw LocalDevVPNSetupFailure.appMissing }
            return XCTFail("expected a user action")
        } catch let value as VeyaFailure { failure = value }
        let result = EngineHost.failureResult(EngineRequest(command: .reconcile), error: failure,
                                              identity: EngineIdentity(packaged: false, qualificationBuild: true))
        XCTAssertEqual(result.exitCode, .userAction)
        XCTAssertEqual(result.status, "userActionRequired")
        XCTAssertEqual(result.userAction, "Install LocalDevVPN on your iPhone, then continue in Veya.")
        XCTAssertEqual(result.firstFailure?.code, DeviceDomainFailure.vpnMissing.code)
        XCTAssertEqual(result.firstFailure?.domain, .vpn)
    }

    func testVPNCoordinatorFailuresPreserveDistinctTypedFailuresAndGuidance() async throws {
        let cases: [(LocalDevVPNSetupFailure, VeyaFailure, String)] = [
            (.endpointUnavailable, DeviceDomainFailure.vpnEndpointUnavailable,
             "LocalDevVPN is active, but Veya cannot reach the developer connection. Keep LocalDevVPN connected and try Continue again."),
            (.receiptInvalid, DeviceDomainFailure.vpnReceiptInvalid,
             "Keep the iPhone connected and try Continue again."),
            (.transportUnavailable, DeviceDomainFailure.vpnTransportUnavailable,
             "Reconnect and unlock the iPhone, then try Continue again."),
        ]

        for (source, expected, action) in cases {
            let mapped = DeviceFailureMapping.map(source)
            XCTAssertEqual(mapped.failure?.code, expected.code)
            XCTAssertEqual(mapped.userAction, action)
            XCTAssertNotEqual(mapped.failure?.code, DeviceDomainFailure.observationFailed.code)

            do {
                _ = try await DeviceFailureMapping.prepare { throw source }
                XCTFail("expected \(source)")
            } catch let failure as VeyaFailure {
                XCTAssertEqual(failure.code, expected.code)
                XCTAssertEqual(failure.userAction, action)
            }
        }
    }

    func testVPNFailureStopsBeforeAutomaticPairingTransition() async throws {
        let repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("ordered-failure", isDirectory: true))
        let pairingPrepares = Counter()
        let vpn = CoordinatedDeviceDomain(
            domain: .vpn,
            observe: { _ in .missing() },
            prepare: { _ in throw DeviceDomainFailure.vpnEndpointUnavailable }
        )
        let pairing = CoordinatedDeviceDomain(
            domain: .pairing,
            observe: { _ in .missing() },
            prepare: { _ in
                pairingPrepares.value += 1
                return .satisfied()
            }
        )
        let engine = try VeyaReconciliationEngine(
            journalRepository: repository,
            observers: [vpn, pairing],
            transitions: [vpn, pairing]
        )
        do {
            _ = try await engine.reconcile(
                scope: InstallationScope(domains: [.vpn, .pairing], selectedDeviceIDHash: "sha256:" + String(repeating: "2", count: 64), connectionGeneration: 1),
                to: DesiredInstallationState(requirements: [.init(domain: .vpn), .init(domain: .pairing)]),
                policy: ReconciliationPolicy(allowedDomains: [.vpn, .pairing], maximumTransitions: 4, localRetryLimit: 0)
            )
            XCTFail("VPN failure must stop reconciliation")
        } catch let failure as VeyaFailure {
            XCTAssertEqual(failure.code, DeviceDomainFailure.vpnEndpointUnavailable.code)
        }
        XCTAssertEqual(pairingPrepares.value, 0)
    }

    func testVPNSuccessAllowsAutomaticPairingTransition() async throws {
        let repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("ordered-success", isDirectory: true))
        let vpnState = Script(observed: .missing(), afterPrepare: .satisfied())
        let pairingState = Script(observed: .missing(), afterPrepare: .satisfied())
        let vpn = CoordinatedDeviceDomain(
            domain: .vpn,
            observe: { _ in vpnState.observed },
            prepare: { _ in
                vpnState.prepares += 1
                vpnState.observed = vpnState.afterPrepare
                return vpnState.afterPrepare
            }
        )
        let pairing = CoordinatedDeviceDomain(
            domain: .pairing,
            observe: { _ in pairingState.observed },
            prepare: { _ in
                pairingState.prepares += 1
                pairingState.observed = pairingState.afterPrepare
                return pairingState.afterPrepare
            }
        )
        let engine = try VeyaReconciliationEngine(
            journalRepository: repository,
            observers: [vpn, pairing],
            transitions: [vpn, pairing]
        )
        let outcome = try await engine.reconcile(
            scope: InstallationScope(domains: [.vpn, .pairing], selectedDeviceIDHash: "sha256:" + String(repeating: "3", count: 64), connectionGeneration: 1),
            to: DesiredInstallationState(requirements: [.init(domain: .vpn), .init(domain: .pairing)]),
            policy: ReconciliationPolicy(allowedDomains: [.vpn, .pairing], maximumTransitions: 8, localRetryLimit: 0)
        )
        XCTAssertEqual(outcome.status, .ready)
        XCTAssertEqual(vpnState.prepares, 1)
        XCTAssertEqual(pairingState.prepares, 1)
    }

    func testGenericDeviceFailureRetainsOriginatingVPNDomain() async throws {
        let repository = InstallationJournalRepository(
            rootURL: root.appendingPathComponent("originating-domain", isDirectory: true)
        )
        let vpn = CoordinatedDeviceDomain(
            domain: .vpn,
            observe: { _ in .missing() },
            prepare: { _ in throw DeviceDomainFailure.observationFailed }
        )
        let engine = try VeyaReconciliationEngine(
            journalRepository: repository,
            observers: [vpn], transitions: [vpn]
        )
        do {
            _ = try await engine.reconcile(
                scope: InstallationScope(
                    domains: [.vpn],
                    selectedDeviceIDHash: "sha256:" + String(repeating: "4", count: 64),
                    connectionGeneration: 1
                ),
                to: DesiredInstallationState(requirements: [.init(domain: .vpn)]),
                policy: ReconciliationPolicy(
                    allowedDomains: [.vpn], maximumTransitions: 1, localRetryLimit: 0
                )
            )
            XCTFail("expected transport failure")
        } catch let failure as VeyaFailure {
            XCTAssertEqual(failure.namespace, .device)
            XCTAssertEqual(failure.originatingDomain, .vpn)
            let result = EngineHost.failureResult(
                EngineRequest(command: .reconcile),
                error: failure,
                identity: EngineIdentity(packaged: false, qualificationBuild: true)
            )
            XCTAssertEqual(result.firstFailure?.code, DeviceDomainFailure.observationFailed.code)
            XCTAssertEqual(result.firstFailure?.domain, .vpn)
        }
    }
}

private final class Counter: @unchecked Sendable {
    var value = 0
}
