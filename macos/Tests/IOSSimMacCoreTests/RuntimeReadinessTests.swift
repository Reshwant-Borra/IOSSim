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

    private func reconcile(connection: UInt64 = 1) async throws -> ReconciliationOutcome {
        let clock = clock!
        let upstream = RuntimeReadinessDomain.upstream.map { domain in
            CoordinatedDeviceDomain(domain: domain, observe: { _ in .satisfied() }, prepare: { _ in .satisfied() },
                                    now: { clock.now })
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
