import Foundation
@testable import IOSSimMacCore
import XCTest

/// M10: READY (runtime satisfied) is unreachable without a fresh, connection- and identity-bound proof.
final class RuntimeReadinessTests: XCTestCase {
    private var root: URL!
    private var clock: Clock!
    private var prover: ScriptedProver!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-m10-\(UUID().uuidString)", isDirectory: true)
        clock = Clock()
        prover = ScriptedProver(clock: clock)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_900_000_000) }

    private final class ScriptedProver: RuntimeProving, @unchecked Sendable {
        let clock: Clock
        var failure: Error?
        var proofs = 0
        init(clock: Clock) { self.clock = clock }
        func proveRuntime(binding: String, scope: InstallationScope) async throws -> RuntimeProofResult {
            proofs += 1
            if let failure { throw failure }
            return RuntimeProofResult(receiptDigest: VeyaSigningKeyStore.sha256(Data("\(binding)|\(proofs)".utf8)),
                                      completedAt: clock.now)
        }
    }

    private var repository: InstallationJournalRepository {
        InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
    }

    /// One upstream domain reports stale until it is repaired, so a run has to create a candidate
    /// in a domain other than `.runtime`.
    private final class StaleOnce: @unchecked Sendable {
        var domain: InstallationDomain?
        func state(_ candidate: InstallationDomain) -> NativeDomainMapping {
            guard domain == candidate else { return .satisfied() }
            domain = nil
            return NativeDomainMapping(state: .stale, userAction: nil, failure: nil)
        }
    }

    private func reconcile(connection: UInt64 = 1, stale: InstallationDomain? = nil) async throws -> ReconciliationOutcome {
        let clock = clock!
        let staleOnce = StaleOnce()
        staleOnce.domain = stale
        let upstream = RuntimeReadinessDomain.upstream.map { domain in
            CoordinatedDeviceDomain(domain: domain, observe: { _ in staleOnce.state(domain) },
                                    prepare: { _ in .satisfied() }, now: { clock.now })
        }
        let runtime = RuntimeReadinessDomain(repository: repository, prover: prover, now: { clock.now })
        let domains = RuntimeReadinessDomain.upstream + [.runtime]
        let engine = try VeyaReconciliationEngine(
            journalRepository: repository, observers: upstream + [runtime], transitions: upstream + [runtime],
            now: { clock.now }
        )
        return try await engine.reconcile(
            scope: InstallationScope(domains: domains, selectedDeviceIDHash: "sha256:" + String(repeating: "2", count: 64),
                                     connectionGeneration: connection),
            to: DesiredInstallationState(requirements: domains.map { .init(domain: $0) }),
            policy: ReconciliationPolicy(allowedDomains: domains, maximumTransitions: 12, localRetryLimit: 0)
        )
    }

    func testReadyRequiresFreshProofAndExpires() async throws {
        let first = try await reconcile()
        XCTAssertEqual(first.status, .ready)
        XCTAssertEqual(prover.proofs, 1)
        let steady = try await reconcile()
        XCTAssertEqual(steady.transitionsCompleted, 0, "within TTL the proof is reused")

        clock.now += 601
        let expired = try await reconcile()
        XCTAssertEqual(expired.status, .ready)
        XCTAssertEqual(prover.proofs, 2, "an expired proof is re-proven, never assumed")
    }

    func testOnDeviceRunBeforeAutomationApprovalIsAUserActionAndRetryReachesReady() async throws {
        prover.failure = RichRuntimeProofFailure.proofFailed
        do {
            _ = try await reconcile()
            XCTFail("an incomplete on-device run is never READY")
        } catch let failure as VeyaFailure {
            XCTAssertEqual(failure, RuntimeReadinessDomain.runtimeActionRequired)
            XCTAssertNotNil(failure.userAction)
        }
        prover.failure = RichRuntimeProofFailure.cleanupFailed
        do {
            _ = try await reconcile()
            XCTFail("cleanup failure is never READY")
        } catch let failure as RichRuntimeProofFailure {
            XCTAssertEqual(failure, .cleanupFailed, "cleanup failure stays a product failure, not a user action")
        }
        prover.failure = nil
        let retried = try await reconcile()
        XCTAssertEqual(retried.status, .ready)
    }

    /// Setup completion waits on the user's own Run Setup tap: until it lands the run
    /// reports a user action, never success, and the tap alone turns it into READY.
    func testUntappedRunSetupIsAUserActionAndTheTapReachesReady() async throws {
        prover.failure = RunSetupFailure.notTapped
        do {
            _ = try await reconcile()
            XCTFail("waiting on the user is never READY")
        } catch let failure as VeyaFailure {
            XCTAssertEqual(failure, RuntimeReadinessDomain.runSetupRequired)
            XCTAssertTrue(failure.retryable)
            XCTAssertEqual(failure.userAction,
                           "Tap Run Setup on your iPhone, then continue in Veya.")
        }
        // A failed run keeps the phone's own error instead of claiming success.
        prover.failure = RunSetupFailure.reportedOnPhone(code: "ENDPOINT_UNREACHABLE", message: "LocalDevVPN is not connected.")
        do {
            _ = try await reconcile()
            XCTFail("a failed Run Setup is never READY")
        } catch let failure as VeyaFailure {
            XCTAssertTrue(failure.safeMessage.contains("ENDPOINT_UNREACHABLE"))
            XCTAssertTrue(failure.safeMessage.contains("LocalDevVPN is not connected."))
        }
        prover.failure = nil
        let tapped = try await reconcile()
        XCTAssertEqual(tapped.status, .ready)
    }

    func testReconnectInvalidatesReadiness() async throws {
        _ = try await reconcile(connection: 1)
        let outcome = try await reconcile(connection: 2)
        XCTAssertEqual(outcome.status, .ready)
        XCTAssertEqual(prover.proofs, 2)
    }

    func testFailedCleanupIsNeverReadyAndStoredStateCannotStandIn() async throws {
        _ = try await reconcile()
        clock.now += 601
        prover.failure = RichRuntimeProofFailure.cleanupFailed
        do { _ = try await reconcile(); XCTFail("cleanup failure must not be READY") } catch {}
        // The previous proof is stored, but expired: inspection must not report runtime satisfied.
        let journal = try await repository.load()
        let runtime = RuntimeReadinessDomain(repository: repository, prover: prover, now: { [clock] in clock!.now })
        let scope = try InstallationScope(domains: [.runtime], selectedDeviceIDHash: "sha256:" + String(repeating: "2", count: 64),
                                          connectionGeneration: 1)
        let observation = try await runtime.observe(scope: scope, journal: journal)
        XCTAssertFalse(observation.state == .satisfied && observation.isFresh(at: clock.now))
    }

    func testRuntimeCannotBeSatisfiedWithoutUpstreamActives() async throws {
        let runtime = RuntimeReadinessDomain(repository: repository, prover: prover)
        let scope = try InstallationScope(domains: [.runtime], connectionGeneration: 1)
        let observation = try await runtime.observe(scope: scope, journal: InstallationJournal())
        XCTAssertEqual(observation.state, .missing)
        XCTAssertEqual(prover.proofs, 0)
    }

    /// A runtime proof that stops on a user action leaves its candidate behind on purpose, so the
    /// next run re-proves the same binding instead of rebuilding it. Physically observed: that
    /// candidate then blocked every other domain from ever creating one (`VEYA-SEC-003`), so the
    /// whole installation deadlocked and could not even replace a signing key.
    func testUnprovedRuntimeCandidateNeverWedgesAnotherDomain() async throws {
        prover.failure = RunSetupFailure.notTapped
        do {
            _ = try await reconcile()
            XCTFail("waiting on the user is never READY")
        } catch {}
        let wedged = try await repository.load()
        XCTAssertNotNil(wedged.candidateResource(for: .runtime), "the candidate is kept for the next proof")

        // The phone's LocalDevVPN receipt goes stale while the tap is still outstanding.
        do {
            _ = try await reconcile(stale: .vpn)
            XCTFail("the tap is still outstanding")
        } catch let failure as VeyaFailure {
            XCTAssertEqual(failure, RuntimeReadinessDomain.runSetupRequired)
        }
        let repaired = try await repository.load()
        XCTAssertNotNil(repaired.activeResource(for: .vpn), "VPN was repaired, not blocked")

        // And the tap still reaches READY afterwards.
        prover.failure = nil
        let ready = try await reconcile()
        XCTAssertEqual(ready.status, .ready)
    }

    func testRepeatedReproofsKeepTheJournalBounded() async throws {
        for _ in 0..<12 {
            clock.now += 601
            _ = try await reconcile()
        }
        let journal = try await repository.load()
        XCTAssertLessThanOrEqual(journal.retiring["runtime"]?.count ?? 0, InstallationJournalRepository.retainedRetiringRecords)
        XCTAssertLessThanOrEqual(journal.evidence.count, (InstallationJournalRepository.retainedRetiringRecords + 1) * 5)
    }
}
