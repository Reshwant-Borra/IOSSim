# M2 Result

Status: **PASS** (AUTOMATED_PROVEN). Build remains `11`.

## Implemented

- `ReconciliationModels.swift`, `ReconciliationPlanner.swift`, `ReconciliationProtocols.swift`, `VeyaReconciliationEngine.swift`.
- Pure planner: first unsatisfied required domain yields at most one transition; freshness-bound observations; policy denial blocks without mutation; unknown certificates never plan revocation.
- Actor engine: lease → observe → plan → persist transition → execute (bounded typed retry) → persist candidate → independent proof bound to candidate generation/identity → re-observe → promote → clear. Cancellation never promotes and preserves the candidate.

## Specification gaps closed in this session (spec 02)

| Gap | Implementation | Tests |
|---|---|---|
| Lease renewal | `whileHoldingLease` heartbeat renews the 30 s lease every 10 s during execute and prove; failed renewal cancels the operation and throws `VEYA-STATE-007`; lease also renewed each loop iteration | `testLeaseIsRenewedDuringLongRunningTransition`, `testLeaseOwnershipLossStopsTransitionWithoutPromotion`, `testCancellationAcrossLeaseRenewalPreservesCandidate` |
| Connection generation | `InstallationSnapshot.connectionGeneration`; connection-bound satisfied observations from an older connection plan replacement; proved candidates from an older connection are re-proved, not promoted; engine rejects evidence bound to a different connection; unbound evidence unaffected | `testConnectionBoundEvidenceIsInvalidAfterReconnect`, `testProofFromEarlierConnectionIsRejectedAndCandidatePreserved` |
| Rollback / irreversible effects | `TransitionRecovery.required(domain:kind:)` exhaustive switch (compile-time complete); Apple/device effects are `irreversible` with an inventory re-observation rule, never fake rollback; persisted on `JournalTransition.recovery` | `testEveryPlannedTransitionDeclaresRecoverySemantics`, recovery asserted on the live and abandoned journal transition |
| Lifecycle events | `candidateCreated` after durable candidate write, `candidateProved` after durable evidence, `waitingForUser` with domain and safe user action | `testLifecycleEventsFollowDurableStateInOrderAndAreSecretFree`, `testWaitingForUserPerformsNoTransition` |

## Gate evidence

- Focused `Reconciliation|InstallationJournalRepositoryTests`: 36 executed, 0 failed, 0 skipped.
- Engine suite repeated 25 times: 25/25 green (concurrency/heartbeat tests are deterministic).
- `./iossim installation-baseline`: Overall PASS (repository checks, Rust fmt/check/clippy/test, full macOS Swift, iOS checks, arm64 + x86_64 Rust release).
- New `scripts/checks/check_installation_v2_secrets.py` (wired into the baseline): 0 findings; self-check proves an unmarked PEM key and password literal are detected.
- `git diff --check` and untracked-file whitespace check: PASS.

## Boundary

Engine remains dark-routed: existing consumer setup route is untouched. Domain services are adapted behind `InstallationObserver`/`InstallationTransition` by their owning milestones (M4 key, M6 Apple, M7 install, M9 device, M10 runtime).
