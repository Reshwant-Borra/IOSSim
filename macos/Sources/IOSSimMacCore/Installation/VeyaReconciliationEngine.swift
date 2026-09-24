import Foundation

private let UUID_NULL_BYTES: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

public actor VeyaReconciliationEngine {
    private let journalRepository: InstallationJournalRepository
    private let planner: ReconciliationPlanner
    private let observers: [InstallationDomain: any InstallationObserver]
    private let transitions: [InstallationDomain: any InstallationTransition]
    private let eventSink: any InstallationEventSink
    private let transitionProgress: (@Sendable (InstallationDomain) -> Void)?
    private let sleeper: any ReconciliationSleeping
    private let leaseSleeper: any ReconciliationSleeping
    private let leaseDuration: TimeInterval
    private let leaseRenewalInterval: Duration
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private var cancelledRuns: Set<RunID> = []

    public init(
        journalRepository: InstallationJournalRepository,
        observers: [any InstallationObserver],
        transitions: [any InstallationTransition],
        planner: ReconciliationPlanner = ReconciliationPlanner(),
        eventSink: any InstallationEventSink = InMemoryInstallationEventSink(),
        transitionProgress: (@Sendable (InstallationDomain) -> Void)? = nil,
        sleeper: any ReconciliationSleeping = ContinuousClockSleeper(),
        leaseSleeper: any ReconciliationSleeping = ContinuousClockSleeper(),
        leaseDuration: TimeInterval = 30,
        leaseRenewalInterval: Duration = .seconds(10),
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) throws {
        guard leaseRenewalInterval > .zero, leaseRenewalInterval < .seconds(leaseDuration) else {
            throw InstallationStateFailure.unsafeValue("lease renewal interval")
        }
        self.journalRepository = journalRepository
        self.planner = planner
        self.observers = try Self.unique(observers, key: \.domain, label: "observer")
        self.transitions = try Self.unique(transitions, key: \.domain, label: "transition")
        self.eventSink = eventSink
        self.transitionProgress = transitionProgress
        self.sleeper = sleeper
        self.leaseSleeper = leaseSleeper
        self.leaseDuration = leaseDuration
        self.leaseRenewalInterval = leaseRenewalInterval
        self.now = now
        self.makeID = makeID
    }

    /// Non-mutating: a missing journal is observed as an empty installation and is not created.
    public func inspect(_ scope: InstallationScope) async throws -> InstallationSnapshot {
        let journal: InstallationJournal
        do {
            journal = try await journalRepository.load()
        } catch InstallationStateFailure.missingJournal {
            journal = InstallationJournal(installationID: UUID(uuid: UUID_NULL_BYTES), now: now())
        }
        return try await observe(scope: scope, journal: journal)
    }

    public func plan(
        scope: InstallationScope,
        desired: DesiredInstallationState,
        policy: ReconciliationPolicy
    ) async throws -> ReconciliationPlan {
        let snapshot = try await inspect(scope)
        return try planner.plan(snapshot: snapshot, desired: desired, policy: policy)
    }

    public func reconcile(
        scope: InstallationScope,
        to desired: DesiredInstallationState,
        policy: ReconciliationPolicy,
        runID: RunID = RunID()
    ) async throws -> ReconciliationOutcome {
        _ = try await journalRepository.initialize()
        _ = try await journalRepository.acquireLease(runID: runID, duration: leaseDuration)
        _ = try await journalRepository.recoverAbandonedTransition(runID: runID)
        cancelledRuns.remove(runID)
        var completed = 0
        var activeDomain: InstallationDomain?

        do {
            while completed < policy.maximumTransitions {
                try throwIfCancelled(runID)
                let journal = try await journalRepository.renewLease(runID: runID, duration: leaseDuration)
                let snapshot = try await observe(scope: scope, journal: journal)
                let plan = try planner.plan(snapshot: snapshot, desired: desired, policy: policy)
                guard plan.disposition == .transitionRequired, let planned = plan.transitions.first else {
                    if plan.disposition == .userActionRequired, let domain = plan.domain {
                        await emitWaitingForUser(domain, plan: plan, runID: runID, generation: snapshot.generation)
                    }
                    let outcome = outcome(for: plan, runID: runID, snapshot: snapshot, completed: completed)
                    _ = try await journalRepository.releaseLease(runID: runID)
                    return outcome
                }
                activeDomain = planned.domain
                transitionProgress?(planned.domain)
                try await execute(planned, scope: scope, desired: desired, policy: policy, runID: runID)
                activeDomain = nil
                completed += 1
            }

            let finalJournal = try await journalRepository.load()
            let finalSnapshot = try await observe(scope: scope, journal: finalJournal)
            let finalPlan = try planner.plan(snapshot: finalSnapshot, desired: desired, policy: policy)
            _ = try await journalRepository.releaseLease(runID: runID)
            if finalPlan.disposition == .ready {
                return outcome(for: finalPlan, runID: runID, snapshot: finalSnapshot, completed: completed)
            }
            return ReconciliationOutcome(
                runID: runID,
                status: .advanced,
                snapshot: finalSnapshot,
                transitionsCompleted: completed,
                userAction: finalPlan.userAction,
                failure: finalPlan.failure
            )
        } catch InstallationStateFailure.cancelled {
            try? await finishCancelledTransition(runID: runID)
            _ = try? await journalRepository.releaseLease(runID: runID)
            let journal = try await journalRepository.load()
            let snapshot = try await observe(scope: scope, journal: journal)
            return ReconciliationOutcome(
                runID: runID,
                status: .cancelled,
                snapshot: snapshot,
                transitionsCompleted: completed,
                userAction: nil,
                failure: nil
            )
        } catch {
            try? await finishFailedTransition(runID: runID)
            _ = try? await journalRepository.releaseLease(runID: runID)
            if let failure = error as? VeyaFailure, let activeDomain {
                throw failure.originating(in: activeDomain)
            }
            throw error
        }
    }

    public func cancel(_ runID: RunID) {
        cancelledRuns.insert(runID)
    }

    private func observe(
        scope: InstallationScope,
        journal: InstallationJournal
    ) async throws -> InstallationSnapshot {
        var values: [DomainObservation] = []
        for domain in scope.domains {
            guard let observer = observers[domain] else { continue }
            values.append(try await observer.observe(scope: scope, journal: journal))
        }
        return try InstallationSnapshot(
            journal: journal,
            observations: values,
            capturedAt: now(),
            connectionGeneration: scope.connectionGeneration
        )
    }

    private func execute(
        _ planned: PlannedTransition,
        scope: InstallationScope,
        desired: DesiredInstallationState,
        policy: ReconciliationPolicy,
        runID: RunID
    ) async throws {
        guard let service = transitions[planned.domain] else {
            throw InstallationStateFailure.transitionUnavailable(planned.domain)
        }
        let transition = JournalTransition(
            id: makeID(),
            runID: runID,
            domain: planned.domain,
            operation: planned.kind.rawValue,
            phase: .planned,
            generation: planned.generation,
            idempotencyKey: planned.idempotencyKey,
            startedAt: now(),
            recovery: planned.recovery
        )
        let generationBeforeTransition = (try await journalRepository.load()).generation
        _ = try await journalRepository.beginTransition(
            transition,
            expectedGeneration: generationBeforeTransition,
            runID: runID
        )
        await emit(planned, runID: runID, result: .started, attempt: 1)
        _ = try await journalRepository.updateTransitionPhase(.executing, runID: runID)

        let receipt: TransitionReceipt
        do {
            receipt = try await whileHoldingLease(runID) {
                try await self.executeWithRetry(
                    service: service,
                    planned: planned,
                    scope: scope,
                    desired: desired,
                    policy: policy,
                    runID: runID
                )
            }
        } catch {
            _ = try? await journalRepository.updateTransitionPhase(.failed, runID: runID)
            await emit(
                planned,
                runID: runID,
                result: .failed,
                attempt: 1,
                errorCode: stableCode(for: error),
                retryable: (error as? VeyaFailure)?.retryable ?? false
            )
            throw error
        }
        if let candidate = receipt.candidate {
            let current = try await journalRepository.load()
            if current.candidateResource(for: planned.domain)?.id != candidate.id {
                _ = try await journalRepository.putCandidate(
                    candidate,
                    runID: runID,
                    expectedGeneration: current.generation
                )
                await emit(planned, runID: runID, result: .candidateCreated, attempt: 1)
            }
        }
        try throwIfCancelled(runID)
        _ = try await journalRepository.updateTransitionPhase(.proving, runID: runID)
        let proofJournal = try await journalRepository.load()
        let context = TransitionContext(
            runID: runID,
            installationID: proofJournal.installationID,
            scope: scope,
            desired: desired,
            planned: planned,
            attempt: 1,
            candidate: proofJournal.candidateResource(for: planned.domain),
            maximumPermission: policy.maximumPermission
        )
        let evidence = try await whileHoldingLease(runID) {
            try await service.prove(receipt, in: context)
        }
        try throwIfCancelled(runID)
        if let bound = evidence.connectionGeneration, bound != scope.connectionGeneration {
            throw InstallationStateFailure.unsafeValue("proof connection binding")
        }
        if let candidate = (try await journalRepository.load()).candidateResource(for: planned.domain) {
            guard evidence.generation == candidate.generation, evidence.subject == candidate.identity else {
                throw InstallationStateFailure.unsafeValue("proof binding")
            }
            _ = try await journalRepository.attachEvidence(evidence, runID: runID)
            await emit(
                planned,
                runID: runID,
                result: .candidateProved,
                attempt: 1,
                evidenceReference: evidence.id
            )
            let observed = try await serviceObservation(planned.domain, scope: scope)
            guard observed.state == .candidateProved || observed.state == .satisfied,
                  observed.resource == nil || observed.resource == candidate.identity else {
                throw InstallationStateFailure.candidateUnproved(planned.domain)
            }
            _ = try await journalRepository.promote(
                domain: planned.domain,
                runID: runID,
                expectedGeneration: candidate.generation
            )
            await emit(
                planned,
                runID: runID,
                result: .promoted,
                attempt: 1,
                evidenceReference: evidence.id
            )
        }
        _ = try await journalRepository.updateTransitionPhase(.proved, runID: runID)
        _ = try await journalRepository.clearTransition(runID: runID)
        await emit(planned, runID: runID, result: .succeeded, attempt: 1, evidenceReference: evidence.id)
    }

    /// Runs `operation` while a heartbeat renews the journal lease. If renewal fails (another run reclaimed
    /// an expired lease), the operation is cancelled and `leaseNotOwned` is thrown, so no further journal
    /// mutation or promotion can happen for this run.
    private func whileHoldingLease<T: Sendable>(
        _ runID: RunID,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await self.renewLeaseUntilCancelled(runID)
                return nil
            }
            defer { group.cancelAll() }
            while let value = try await group.next() {
                if let value { return value }
            }
            throw InstallationStateFailure.leaseNotOwned
        }
    }

    private func renewLeaseUntilCancelled(_ runID: RunID) async throws {
        while true {
            try await leaseSleeper.sleep(for: leaseRenewalInterval)
            try Task.checkCancellation()
            do {
                _ = try await journalRepository.renewLease(runID: runID, duration: leaseDuration)
            } catch InstallationStateFailure.lockUnavailable {
                // Another process holds the file lock briefly; the lease outlives the next attempt.
                continue
            } catch {
                throw InstallationStateFailure.leaseNotOwned
            }
        }
    }

    private func executeWithRetry(
        service: any InstallationTransition,
        planned: PlannedTransition,
        scope: InstallationScope,
        desired: DesiredInstallationState,
        policy: ReconciliationPolicy,
        runID: RunID
    ) async throws -> TransitionReceipt {
        let remote = [.authorization, .team, .certificate, .profile].contains(planned.domain)
        let retryLimit = remote ? policy.remoteRetryLimit : policy.localRetryLimit
        var attempt = 0
        while true {
            attempt += 1
            try throwIfCancelled(runID)
            let context = TransitionContext(
                runID: runID,
                installationID: (try await journalRepository.load()).installationID,
                scope: scope,
                desired: desired,
                planned: planned,
                attempt: attempt,
                candidate: (try await journalRepository.load()).candidateResource(for: planned.domain),
                maximumPermission: policy.maximumPermission
            )
            do {
                return try await service.execute(context)
            } catch let failure as VeyaFailure where failure.retryable && attempt <= retryLimit {
                await emit(
                    planned,
                    runID: runID,
                    result: .failed,
                    attempt: attempt,
                    errorCode: failure.code,
                    retryable: true
                )
                let seconds = remote ? min(8, 1 << (attempt - 1)) : 0
                if seconds > 0 { try await sleeper.sleep(for: .seconds(seconds)) }
            }
        }
    }

    private func serviceObservation(
        _ domain: InstallationDomain,
        scope: InstallationScope
    ) async throws -> DomainObservation {
        guard let observer = observers[domain] else {
            throw InstallationStateFailure.transitionUnavailable(domain)
        }
        let journal = try await journalRepository.load()
        return try await observer.observe(scope: scope, journal: journal)
    }

    private func finishCancelledTransition(runID: RunID) async throws {
        let journal = try await journalRepository.load()
        guard journal.transition?.runID == runID else { return }
        _ = try await journalRepository.updateTransitionPhase(.failed, runID: runID)
        _ = try await journalRepository.clearTransition(runID: runID)
    }

    private func finishFailedTransition(runID: RunID) async throws {
        try await finishCancelledTransition(runID: runID)
    }

    private func throwIfCancelled(_ runID: RunID) throws {
        if cancelledRuns.contains(runID) { throw InstallationStateFailure.cancelled }
    }

    private func outcome(
        for plan: ReconciliationPlan,
        runID: RunID,
        snapshot: InstallationSnapshot,
        completed: Int
    ) -> ReconciliationOutcome {
        let status: ReconciliationOutcomeStatus
        switch plan.disposition {
        case .ready: status = .ready
        case .userActionRequired: status = .userActionRequired
        case .retryableWait: status = .retryableWait
        case .blocked: status = .blocked
        case .transitionRequired: status = .advanced
        }
        return ReconciliationOutcome(
            runID: runID,
            status: status,
            snapshot: snapshot,
            transitionsCompleted: completed,
            userAction: plan.userAction,
            failure: plan.failure
        )
    }

    private func emitWaitingForUser(
        _ domain: InstallationDomain,
        plan: ReconciliationPlan,
        runID: RunID,
        generation: Generation
    ) async {
        await eventSink.record(InstallationEvent(
            schemaVersion: InstallationEvent.currentSchemaVersion,
            id: makeID(),
            runID: runID,
            stage: domain,
            operation: "awaitUserAction",
            generation: generation,
            attempt: 1,
            lifecycle: nil,
            result: .waitingForUser,
            errorCode: nil,
            retryable: false,
            userAction: plan.userAction,
            durationMilliseconds: nil,
            evidenceReference: nil,
            timestamp: now()
        ))
    }

    private func emit(
        _ transition: PlannedTransition,
        runID: RunID,
        result: InstallationEventResult,
        attempt: Int,
        errorCode: String? = nil,
        retryable: Bool = false,
        evidenceReference: String? = nil
    ) async {
        await eventSink.record(InstallationEvent(
            schemaVersion: InstallationEvent.currentSchemaVersion,
            id: makeID(),
            runID: runID,
            stage: transition.domain,
            operation: transition.kind.rawValue,
            generation: transition.generation,
            attempt: attempt,
            lifecycle: .candidate,
            result: result,
            errorCode: errorCode,
            retryable: retryable,
            userAction: nil,
            durationMilliseconds: nil,
            evidenceReference: evidenceReference,
            timestamp: now()
        ))
    }

    private func stableCode(for error: Error) -> String {
        if let failure = error as? VeyaFailure { return failure.code }
        if let failure = error as? InstallationStateFailure { return failure.code }
        return "VEYA-STATE-099"
    }

    private static func unique<Value, Key: Hashable>(
        _ values: [Value],
        key: KeyPath<Value, Key>,
        label: String
    ) throws -> [Key: Value] {
        var result: [Key: Value] = [:]
        for value in values {
            let itemKey = value[keyPath: key]
            guard result[itemKey] == nil else {
                throw InstallationStateFailure.unsafeValue("duplicate \(label)")
            }
            result[itemKey] = value
        }
        return result
    }
}
