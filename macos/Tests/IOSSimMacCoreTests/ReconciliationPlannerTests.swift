import CryptoKit
import Foundation
@testable import IOSSimMacCore
import XCTest

final class ReconciliationPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEveryObservationStateProducesOneDeterministicSafeDisposition() throws {
        let desired = try desiredState()
        let policy = try ReconciliationPolicy(maximumPermission: .safeRepair)
        let expected: [DomainObservationState: ReconciliationDisposition] = [
            .satisfied: .ready,
            .missing: .transitionRequired,
            .stale: .transitionRequired,
            .invalid: .transitionRequired,
            .candidateUnproved: .transitionRequired,
            .candidateProved: .transitionRequired,
            .waitingForUser: .userActionRequired,
            .retryableFailure: .retryableWait,
            .terminalFailure: .blocked,
        ]

        for state in DomainObservationState.allCases {
            let snapshot = try snapshot(state: state)
            let first = try ReconciliationPlanner().plan(snapshot: snapshot, desired: desired, policy: policy)
            let second = try ReconciliationPlanner().plan(snapshot: snapshot, desired: desired, policy: policy)
            XCTAssertEqual(first, second, "planner was nondeterministic for \(state)")
            XCTAssertEqual(first.disposition, expected[state])
            XCTAssertLessThanOrEqual(first.transitions.count, 1)
        }
    }

    func testPlannerChoosesEarliestUnsatisfiedRequirementOnly() throws {
        let journal = InstallationJournal(now: now)
        let observations = [
            try observation(domain: .artifact, state: .satisfied),
            try observation(domain: .signingKey, state: .missing),
            try observation(domain: .certificate, state: .missing),
        ]
        let snapshot = try InstallationSnapshot(journal: journal, observations: observations, capturedAt: now)
        let desired = try DesiredInstallationState(requirements: [
            DesiredDomainState(domain: .artifact),
            DesiredDomainState(domain: .signingKey),
            DesiredDomainState(domain: .certificate),
        ])
        let plan = try ReconciliationPlanner().plan(
            snapshot: snapshot,
            desired: desired,
            policy: ReconciliationPolicy()
        )

        XCTAssertEqual(plan.transitions.map(\.domain), [.signingKey])
        XCTAssertEqual(plan.transitions.first?.kind, .createCandidate)
    }

    func testInspectOnlyPolicyBlocksMutation() throws {
        let plan = try ReconciliationPlanner().plan(
            snapshot: snapshot(state: .missing),
            desired: desiredState(),
            policy: ReconciliationPolicy(maximumPermission: .inspect)
        )
        XCTAssertEqual(plan.disposition, .blocked)
        XCTAssertEqual(plan.failure?.code, "VEYA-STATE-012")
        XCTAssertTrue(plan.transitions.isEmpty)
    }

    func testReadOnlyPolicyReportsSatisfiedDomainsReadyAndBlocksOnlyMutation() throws {
        let readOnly = try ReconciliationPolicy(maximumPermission: .inspect, allowedDomains: [])
        let ready = try ReconciliationPlanner().plan(snapshot: snapshot(state: .satisfied), desired: desiredState(), policy: readOnly)
        XCTAssertEqual(ready.disposition, .ready)
        let notAllowed = try ReconciliationPolicy(maximumPermission: .safeRepair, allowedDomains: [.artifact])
        let blocked = try ReconciliationPlanner().plan(snapshot: snapshot(state: .missing), desired: desiredState(), policy: notAllowed)
        XCTAssertEqual(blocked.disposition, .blocked)
        XCTAssertEqual(blocked.domain, .signingKey)
        XCTAssertEqual(blocked.failure?.code, "VEYA-STATE-012")
        XCTAssertTrue(blocked.transitions.isEmpty)
    }

    func testUnknownCertificateNeverPlansRevocation() throws {
        let journal = InstallationJournal(now: now)
        let snapshot = try InstallationSnapshot(
            journal: journal,
            observations: [try observation(domain: .certificate, state: .invalid, ownership: .unknown)],
            capturedAt: now
        )
        let desired = try DesiredInstallationState(requirements: [DesiredDomainState(domain: .certificate)])
        let plan = try ReconciliationPlanner().plan(
            snapshot: snapshot,
            desired: desired,
            policy: ReconciliationPolicy(maximumPermission: .destructiveOwned)
        )
        XCTAssertEqual(plan.transitions.first?.kind, .replaceCandidate)
        XCTAssertFalse(plan.transitions.contains { $0.kind == .revokeOwnedCertificate })
    }

    func testTargetMismatchPlansReplacementWithStableIdempotencyKey() throws {
        let current = try ResourceIdentity(domain: .signingKey, resourceID: "current", digest: digest("current"))
        let target = try ResourceIdentity(domain: .signingKey, resourceID: "target", digest: digest("target"))
        let journal = InstallationJournal(now: now)
        let snapshot = try InstallationSnapshot(
            journal: journal,
            observations: [try DomainObservation(
                domain: .signingKey,
                state: .satisfied,
                resource: current,
                ownership: .privateKeyControl,
                capturedAt: now
            )],
            capturedAt: now
        )
        let desired = try DesiredInstallationState(requirements: [
            DesiredDomainState(domain: .signingKey, target: target),
        ])
        let policy = try ReconciliationPolicy()
        let first = try ReconciliationPlanner().plan(snapshot: snapshot, desired: desired, policy: policy)
        let second = try ReconciliationPlanner().plan(snapshot: snapshot, desired: desired, policy: policy)
        XCTAssertEqual(first.transitions.first?.kind, .replaceCandidate)
        XCTAssertEqual(first.transitions.first?.idempotencyKey, second.transitions.first?.idempotencyKey)
    }

    func testExpiredSatisfiedEvidenceCannotProduceReady() throws {
        let journal = InstallationJournal(now: now)
        let snapshot = try InstallationSnapshot(
            journal: journal,
            observations: [try DomainObservation(
                domain: .runtime,
                state: .satisfied,
                resource: ResourceIdentity(domain: .runtime, resourceID: "proof", digest: digest("proof")),
                ownership: .activePayloadCorroboration,
                capturedAt: now.addingTimeInterval(-60),
                validUntil: now.addingTimeInterval(-1)
            )],
            capturedAt: now
        )
        let plan = try ReconciliationPlanner().plan(
            snapshot: snapshot,
            desired: DesiredInstallationState(requirements: [DesiredDomainState(domain: .runtime)]),
            policy: ReconciliationPolicy()
        )
        XCTAssertEqual(plan.disposition, .transitionRequired)
        XCTAssertEqual(plan.transitions.first?.kind, .replaceCandidate)
    }

    func testConnectionBoundEvidenceIsInvalidAfterReconnect() throws {
        let desired = try DesiredInstallationState(requirements: [DesiredDomainState(domain: .runtime)])
        func plan(observed: UInt64?, current: UInt64?, state: DomainObservationState = .satisfied) throws
            -> ReconciliationPlan {
            let snapshot = try InstallationSnapshot(
                journal: InstallationJournal(now: now),
                observations: [try DomainObservation(
                    domain: .runtime,
                    state: state,
                    resource: ResourceIdentity(domain: .runtime, resourceID: "proof", digest: digest("proof")),
                    ownership: .activePayloadCorroboration,
                    capturedAt: now,
                    connectionGeneration: observed
                )],
                capturedAt: now,
                connectionGeneration: current
            )
            return try ReconciliationPlanner().plan(snapshot: snapshot, desired: desired, policy: ReconciliationPolicy())
        }

        // Generation N evidence is valid on connection N.
        XCTAssertEqual(try plan(observed: 7, current: 7).disposition, .ready)
        // Reconnect (N+1) voids generation N evidence.
        let reconnected = try plan(observed: 7, current: 8)
        XCTAssertEqual(reconnected.disposition, .transitionRequired)
        XCTAssertEqual(reconnected.transitions.first?.kind, .replaceCandidate)
        // A candidate proved on an old connection must be re-proved, never promoted.
        XCTAssertEqual(try plan(observed: 7, current: 8, state: .candidateProved).transitions.first?.kind, .proveCandidate)
        XCTAssertEqual(try plan(observed: 8, current: 8, state: .candidateProved).transitions.first?.kind, .promoteCandidate)
        // Evidence that is not connection-bound is not invalidated by reconnect.
        XCTAssertEqual(try plan(observed: nil, current: 8).disposition, .ready)
    }

    func testEveryPlannedTransitionDeclaresRecoverySemantics() throws {
        let kinds: [TransitionKind] = [
            .createCandidate, .replaceCandidate, .proveCandidate, .promoteCandidate, .revokeOwnedCertificate,
        ]
        let appleDomains: Set<InstallationDomain> = [.certificate, .profile]
        let deviceDomains: Set<InstallationDomain> = [.application, .developerSupport, .pairing, .vpn]
        for domain in InstallationDomain.allCases {
            for kind in kinds {
                let planned = try PlannedTransition(
                    domain: domain,
                    kind: kind,
                    permission: .safeRepair,
                    generation: Generation(rawValue: 1),
                    target: nil,
                    desiredDigest: digest("desired")
                )
                XCTAssertEqual(planned.recovery, TransitionRecovery.required(domain: domain, kind: kind))
                switch (kind, planned.recovery) {
                case (.createCandidate, .irreversible(_, let reconcile)),
                     (.replaceCandidate, .irreversible(_, let reconcile)):
                    // External side effects are reconciled by observing the external inventory, never "undone".
                    if appleDomains.contains(domain) {
                        XCTAssertEqual(reconcile, .reobserveAppleInventory, "\(domain)")
                    } else {
                        XCTAssertTrue(deviceDomains.contains(domain), "\(domain) claims an external effect")
                        XCTAssertEqual(reconcile, .reobserveDeviceInventory, "\(domain)")
                    }
                case (.createCandidate, .rollback(let action)), (.replaceCandidate, .rollback(let action)):
                    XCTAssertFalse(appleDomains.union(deviceDomains).contains(domain), "fake rollback for \(domain)")
                    XCTAssertEqual(action, .discardCandidate)
                case (.proveCandidate, let recovery):
                    XCTAssertEqual(recovery, .rollback(.noSideEffect))
                case (.promoteCandidate, let recovery):
                    XCTAssertEqual(recovery, .rollback(.restorePreviousActive))
                case (.revokeOwnedCertificate, let recovery):
                    XCTAssertEqual(recovery, .irreversible(.appleCertificateRevoked, reconcile: .reobserveAppleInventory))
                }
                let encoded = try JSONEncoder().encode(planned)
                XCTAssertEqual(try JSONDecoder().decode(PlannedTransition.self, from: encoded), planned)
            }
        }
    }

    private func snapshot(state: DomainObservationState) throws -> InstallationSnapshot {
        let journal = InstallationJournal(now: now)
        return try InstallationSnapshot(
            journal: journal,
            observations: [try observation(domain: .signingKey, state: state)],
            capturedAt: now
        )
    }

    private func desiredState() throws -> DesiredInstallationState {
        try DesiredInstallationState(requirements: [DesiredDomainState(domain: .signingKey)])
    }

    private func observation(
        domain: InstallationDomain,
        state: DomainObservationState,
        ownership: OwnershipLevel = .unknown
    ) throws -> DomainObservation {
        let failure: VeyaFailure? = if state == .retryableFailure || state == .terminalFailure {
            try VeyaFailure(
                namespace: .state,
                number: state == .retryableFailure ? 20 : 21,
                operation: "observeFixture",
                safeMessage: "Synthetic observation failure.",
                retryable: state == .retryableFailure,
                underlyingSubsystem: domain.rawValue
            )
        } else { nil }
        return try DomainObservation(
            domain: domain,
            state: state,
            resource: state == .satisfied
                ? ResourceIdentity(domain: domain, resourceID: "current", digest: digest("current"))
                : nil,
            ownership: ownership,
            capturedAt: now,
            userAction: state == .waitingForUser ? "Complete the Apple-controlled action." : nil,
            failure: failure
        )
    }

    private func digest(_ value: String) -> String {
        "sha256:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private actor SimulatedInstallationDomain: InstallationObserver, InstallationTransition {
    nonisolated let domain: InstallationDomain = .signingKey
    private let now: Date
    private var initialState: DomainObservationState
    private var retryFailures: Int
    private let proofConnectionGeneration: UInt64?
    private var executeAttempts = 0
    private var shouldPause = false
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resume: CheckedContinuation<Void, Never>?

    init(
        state: DomainObservationState,
        retryFailures: Int = 0,
        pauseExecution: Bool = false,
        proofConnectionGeneration: UInt64? = nil,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) {
        initialState = state
        self.retryFailures = retryFailures
        self.proofConnectionGeneration = proofConnectionGeneration
        shouldPause = pauseExecution
        self.now = now
    }

    func observe(scope: InstallationScope, journal: InstallationJournal) throws -> DomainObservation {
        if let active = journal.activeResource(for: domain) {
            return try DomainObservation(
                domain: domain,
                state: .satisfied,
                resource: active.identity,
                ownership: active.ownership,
                capturedAt: now
            )
        }
        if let candidate = journal.candidateResource(for: domain) {
            return try DomainObservation(
                domain: domain,
                state: candidate.evidenceIDs.isEmpty ? .candidateProved : .candidateProved,
                resource: candidate.identity,
                ownership: candidate.ownership,
                capturedAt: now
            )
        }
        return try DomainObservation(
            domain: domain,
            state: initialState,
            capturedAt: now,
            userAction: initialState == .waitingForUser ? "Complete the Apple-controlled action." : nil
        )
    }

    func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        executeAttempts += 1
        if executeAttempts <= retryFailures {
            throw try VeyaFailure(
                namespace: .key,
                number: 20,
                operation: "createFixtureCandidate",
                safeMessage: "Synthetic retryable transition failure.",
                retryable: true,
                underlyingSubsystem: "fixture"
            )
        }
        if shouldPause {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() } else { resume = continuation }
                }
            } onCancel: {
                Task { await self.resumeExecution() }
            }
            try Task.checkCancellation()
        }
        let identity = try ResourceIdentity(
            domain: domain,
            resourceID: "candidate-\(context.planned.generation.rawValue)",
            digest: digest("candidate-\(context.planned.generation.rawValue)")
        )
        let candidate = try ResourceRecord(
            identity: identity,
            lifecycle: .candidate,
            generation: context.planned.generation,
            ownership: .privateKeyControl,
            createdAt: now,
            observedAt: now,
            relativeLocation: "secrets/signing-keys/candidate.vkey"
        )
        return try TransitionReceipt(
            operation: context.planned.kind.rawValue,
            generation: context.planned.generation,
            candidate: candidate
        )
    }

    func prove(_ receipt: TransitionReceipt, in context: TransitionContext) throws -> Evidence {
        guard let candidate = receipt.candidate else {
            throw InstallationStateFailure.candidateMissing(domain)
        }
        return try Evidence(
            id: digest("proof-\(candidate.id)"),
            kind: "syntheticSignVerify",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now,
            connectionGeneration: proofConnectionGeneration,
            provenance: "reconciliation-tests"
        )
    }

    func waitUntilExecutionStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resumeExecution() {
        shouldPause = false
        resume?.resume()
        resume = nil
    }

    func attempts() -> Int { executeAttempts }

    private func digest(_ value: String) -> String {
        "sha256:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// Lease heartbeat sleeper that only wakes when the test ticks it (or the sleeping task is cancelled).
private actor SteppedSleeper: ReconciliationSleeping {
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var sleeps = 0
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        sleeps += 1
        let ready = countWaiters.filter { $0.0 <= sleeps }
        countWaiters.removeAll { $0.0 <= sleeps }
        ready.forEach { $0.1.resume() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.store(continuation, id: id)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func store(_ continuation: CheckedContinuation<Void, Error>, id: UUID) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            pending[id] = continuation
        }
    }

    func waitForSleeps(_ count: Int) async {
        if sleeps >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func tick() {
        let wakes = pending.values
        pending.removeAll()
        wakes.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor RecordingSleeper: ReconciliationSleeping {
    private(set) var durations: [Duration] = []
    func sleep(for duration: Duration) { durations.append(duration) }
}

final class VeyaReconciliationEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testOneTransitionExecutesProvesReobservesAndPromotes() async throws {
        let (engine, repository, service, _) = try makeEngine(state: .missing)
        let outcome = try await engine.reconcile(
            scope: InstallationScope(domains: [.signingKey]),
            to: desired(),
            policy: ReconciliationPolicy(maximumTransitions: 1)
        )

        XCTAssertEqual(outcome.status, .ready)
        XCTAssertEqual(outcome.transitionsCompleted, 1)
        let journal = try await repository.load()
        XCTAssertNotNil(journal.activeResource(for: .signingKey))
        XCTAssertNil(journal.candidateResource(for: .signingKey))
        XCTAssertNil(journal.transition)
        let attempts = await service.attempts()
        XCTAssertEqual(attempts, 1)
    }

    func testRetryIsBoundedAndUsesTypedLocalSchedule() async throws {
        let sleeper = RecordingSleeper()
        let (engine, _, service, _) = try makeEngine(
            state: .missing,
            retryFailures: 2,
            sleeper: sleeper
        )
        let outcome = try await engine.reconcile(
            scope: InstallationScope(domains: [.signingKey]),
            to: desired(),
            policy: ReconciliationPolicy(maximumTransitions: 1, localRetryLimit: 2)
        )
        XCTAssertEqual(outcome.status, .ready)
        let attempts = await service.attempts()
        let sleepCount = await sleeper.durations.count
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleepCount, 0)
    }

    func testCancellationAfterSideEffectPreservesCandidateWithoutPromotion() async throws {
        let runID = RunID()
        let (engine, repository, service, _) = try makeEngine(state: .missing, pauseExecution: true)
        let task = Task {
            try await engine.reconcile(
                scope: InstallationScope(domains: [.signingKey]),
                to: desired(),
                policy: ReconciliationPolicy(maximumTransitions: 1),
                runID: runID
            )
        }
        await service.waitUntilExecutionStarted()
        await engine.cancel(runID)
        await service.resumeExecution()
        let outcome = try await task.value

        XCTAssertEqual(outcome.status, .cancelled)
        let journal = try await repository.load()
        XCTAssertNil(journal.activeResource(for: .signingKey))
        XCTAssertNotNil(journal.candidateResource(for: .signingKey))
        XCTAssertNil(journal.transition)
        XCTAssertNil(journal.lease)
    }

    func testLeaseIsRenewedDuringLongRunningTransition() async throws {
        let clock = TestClock(now)
        let heartbeat = SteppedSleeper()
        let (engine, repository, service, _) = try makeEngine(
            state: .missing,
            pauseExecution: true,
            clock: clock,
            leaseSleeper: heartbeat
        )
        let runID = RunID()
        let task = Task {
            try await engine.reconcile(
                scope: InstallationScope(domains: [.signingKey]),
                to: desired(),
                policy: ReconciliationPolicy(maximumTransitions: 1),
                runID: runID
            )
        }
        await service.waitUntilExecutionStarted()
        await heartbeat.waitForSleeps(1)
        clock.advance(20)
        await heartbeat.tick()
        await heartbeat.waitForSleeps(2)
        let renewed = try await repository.load()
        XCTAssertEqual(renewed.lease?.runID, runID)
        XCTAssertEqual(renewed.lease?.expiresAt, clock.now.addingTimeInterval(30))
        XCTAssertEqual(renewed.transition?.recovery, .rollback(.discardCandidate))
        // Past the original 30-second expiry; ownership holds only because of renewal.
        clock.advance(20)
        await heartbeat.tick()
        await heartbeat.waitForSleeps(3)
        await service.resumeExecution()
        let outcome = try await task.value

        XCTAssertEqual(outcome.status, .ready)
        let journal = try await repository.load()
        XCTAssertNotNil(journal.activeResource(for: .signingKey))
        XCTAssertNil(journal.lease)
    }

    func testLeaseOwnershipLossStopsTransitionWithoutPromotion() async throws {
        let clock = TestClock(now)
        let heartbeat = SteppedSleeper()
        let (engine, repository, service, events) = try makeEngine(
            state: .missing,
            pauseExecution: true,
            clock: clock,
            leaseSleeper: heartbeat
        )
        let runID = RunID()
        let task = Task {
            try await engine.reconcile(
                scope: InstallationScope(domains: [.signingKey]),
                to: desired(),
                policy: ReconciliationPolicy(maximumTransitions: 1),
                runID: runID
            )
        }
        await service.waitUntilExecutionStarted()
        await heartbeat.waitForSleeps(1)
        // The stalled owner's lease expires and a second process reclaims the journal.
        clock.advance(31)
        let other = RunID()
        let reclaimed = try await repository.acquireLease(runID: other)
        XCTAssertEqual(reclaimed.recovery.reason, "staleLeaseRecovered")
        await heartbeat.tick()

        do {
            _ = try await task.value
            XCTFail("a run that lost its lease must not complete")
        } catch {
            XCTAssertEqual(error as? InstallationStateFailure, .leaseNotOwned)
        }
        let journal = try await repository.load()
        XCTAssertEqual(journal.lease?.runID, other)
        XCTAssertNil(journal.activeResource(for: .signingKey))
        XCTAssertNil(journal.candidateResource(for: .signingKey))
        // The abandoned transition record is left for the new owner's recovery, with its recovery semantics.
        XCTAssertEqual(journal.transition?.runID, runID)
        XCTAssertEqual(journal.transition?.recovery, .rollback(.discardCandidate))
        let results = await events.events.map(\.result)
        XCTAssertFalse(results.contains(.promoted))
        XCTAssertFalse(results.contains(.candidateCreated))
    }

    func testCancellationAcrossLeaseRenewalPreservesCandidate() async throws {
        let clock = TestClock(now)
        let heartbeat = SteppedSleeper()
        let (engine, repository, service, _) = try makeEngine(
            state: .missing,
            pauseExecution: true,
            clock: clock,
            leaseSleeper: heartbeat
        )
        let runID = RunID()
        let task = Task {
            try await engine.reconcile(
                scope: InstallationScope(domains: [.signingKey]),
                to: desired(),
                policy: ReconciliationPolicy(maximumTransitions: 1),
                runID: runID
            )
        }
        await service.waitUntilExecutionStarted()
        await heartbeat.waitForSleeps(1)
        await engine.cancel(runID)
        clock.advance(15)
        await heartbeat.tick()
        await heartbeat.waitForSleeps(2)
        await service.resumeExecution()
        let outcome = try await task.value

        XCTAssertEqual(outcome.status, .cancelled)
        let journal = try await repository.load()
        XCTAssertNil(journal.activeResource(for: .signingKey))
        XCTAssertNotNil(journal.candidateResource(for: .signingKey))
        XCTAssertNil(journal.transition)
        XCTAssertNil(journal.lease)
    }

    func testProofFromEarlierConnectionIsRejectedAndCandidatePreserved() async throws {
        let (engine, repository, _, events) = try makeEngine(state: .missing, proofConnectionGeneration: 1)
        do {
            _ = try await engine.reconcile(
                scope: InstallationScope(domains: [.signingKey], connectionGeneration: 2),
                to: desired(),
                policy: ReconciliationPolicy(maximumTransitions: 1)
            )
            XCTFail("proof bound to connection 1 must not satisfy connection 2")
        } catch {
            XCTAssertEqual(error as? InstallationStateFailure, .unsafeValue("proof connection binding"))
        }
        let journal = try await repository.load()
        XCTAssertNil(journal.activeResource(for: .signingKey))
        XCTAssertNotNil(journal.candidateResource(for: .signingKey))
        XCTAssertNil(journal.transition)
        XCTAssertNil(journal.lease)
        let results = await events.events.map(\.result)
        XCTAssertFalse(results.contains(.candidateProved))
        XCTAssertFalse(results.contains(.promoted))
    }

    func testLifecycleEventsFollowDurableStateInOrderAndAreSecretFree() async throws {
        let (engine, _, _, events) = try makeEngine(state: .missing)
        _ = try await engine.reconcile(
            scope: InstallationScope(domains: [.signingKey]),
            to: desired(),
            policy: ReconciliationPolicy(maximumTransitions: 1)
        )
        let recorded = await events.events
        XCTAssertEqual(recorded.map(\.result), [.started, .candidateCreated, .candidateProved, .promoted, .succeeded])
        XCTAssertEqual(Set(recorded.map(\.generation)), [Generation(rawValue: 1)])
        XCTAssertNotNil(recorded.first { $0.result == .candidateProved }?.evidenceReference)
        try assertSecretFree(recorded)
    }

    func testWaitingForUserPerformsNoTransition() async throws {
        let (engine, repository, service, events) = try makeEngine(state: .waitingForUser)
        let outcome = try await engine.reconcile(
            scope: InstallationScope(domains: [.signingKey]),
            to: desired(),
            policy: ReconciliationPolicy()
        )
        XCTAssertEqual(outcome.status, .userActionRequired)
        let attempts = await service.attempts()
        let journal = try await repository.load()
        XCTAssertEqual(attempts, 0)
        XCTAssertNil(journal.transition)
        let recorded = await events.events
        XCTAssertEqual(recorded.map(\.result), [.waitingForUser])
        XCTAssertEqual(recorded.first?.stage, .signingKey)
        XCTAssertEqual(recorded.first?.userAction, "Complete the Apple-controlled action.")
        try assertSecretFree(recorded)
    }

    private func assertSecretFree(_ events: [InstallationEvent]) throws {
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self).lowercased()
        for marker in ["password", "privatekey", "private_key", "token", "cookie", "-----begin"] {
            XCTAssertFalse(json.contains(marker), "event payload contains \(marker)")
        }
    }

    func testEngineRejectsDuplicateDomainOwners() throws {
        let root = makeRoot()
        let serviceA = SimulatedInstallationDomain(state: .missing)
        let serviceB = SimulatedInstallationDomain(state: .missing)
        XCTAssertThrowsError(try VeyaReconciliationEngine(
            journalRepository: InstallationJournalRepository(rootURL: root),
            observers: [serviceA, serviceB],
            transitions: [serviceA]
        )) { error in
            XCTAssertEqual(error as? InstallationStateFailure, .unsafeValue("duplicate observer"))
        }
    }

    private func makeEngine(
        state: DomainObservationState,
        retryFailures: Int = 0,
        pauseExecution: Bool = false,
        proofConnectionGeneration: UInt64? = nil,
        sleeper: any ReconciliationSleeping = RecordingSleeper(),
        clock: TestClock? = nil,
        leaseSleeper: any ReconciliationSleeping = ContinuousClockSleeper()
    ) throws -> (
        VeyaReconciliationEngine,
        InstallationJournalRepository,
        SimulatedInstallationDomain,
        InMemoryInstallationEventSink
    ) {
        let root = makeRoot()
        let fixed = now
        let currentTime: @Sendable () -> Date = clock.map { clock in { clock.now } } ?? { fixed }
        let repository = InstallationJournalRepository(rootURL: root, now: currentTime)
        let service = SimulatedInstallationDomain(
            state: state,
            retryFailures: retryFailures,
            pauseExecution: pauseExecution,
            proofConnectionGeneration: proofConnectionGeneration,
            now: now
        )
        let events = InMemoryInstallationEventSink()
        let engine = try VeyaReconciliationEngine(
            journalRepository: repository,
            observers: [service],
            transitions: [service],
            eventSink: events,
            sleeper: sleeper,
            leaseSleeper: leaseSleeper,
            now: currentTime
        )
        return (engine, repository, service, events)
    }

    private func desired() throws -> DesiredInstallationState {
        try DesiredInstallationState(requirements: [DesiredDomainState(domain: .signingKey)])
    }

    private func makeRoot() -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/installation-v2-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        roots.append(root)
        return root
    }
}
