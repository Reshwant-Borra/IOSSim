# Canonical Reconciliation Engine

## Contract

```swift
public actor VeyaReconciliationEngine {
  func inspect(_ scope: InstallationScope) async -> InstallationSnapshot
  func reconcile(to desired: DesiredInstallationState,
                 policy: ReconciliationPolicy) async -> ReconciliationOutcome
  func cancel(_ runID: RunID) async
}

public protocol InstallationObserver: Sendable {
  func observe(scope: InstallationScope) async -> DomainObservation
}
public protocol InstallationTransition: Sendable {
  var kind: TransitionKind { get }
  func execute(_ context: TransitionContext) async throws -> TransitionReceipt
  func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence
}
```

Core values are `InstallationSnapshot`, `DesiredInstallationState`, `ReconciliationPlan`, `PlannedTransition`, `TransitionReceipt`, `Evidence`, `Generation`, `RunID`, `Lease`, `ResourceIdentity`, `ActiveCandidate<T>`, and `VeyaFailure`. All are `Codable`, `Sendable`, versioned, and contain no secret bytes.

## Algorithm

1. Acquire the per-user journal lock and a renewable 30-second lease for one `RunID`. A second writer receives `VEYA-STATE-006`; readers remain allowed.
2. Recover an incomplete atomic write and classify any existing candidate.
3. Observe artifact, account/team, local key/certificate/profile, selected device, installed apps, DDI, pairing, VPN, and runtime. Each observation includes provenance, captured time, and resource identity.
4. Derive desired state from product policy, selected device, release manifest, and explicit user intent. Cached stage names are not inputs.
5. Pure `Planner.plan(snapshot, desired, policy)` produces ordered transitions. It may plan only operations allowed by policy (`inspect`, `safeRepair`, `interactive`, `destructiveOwned`).
6. Persist `transitionStarted`, execute exactly one smallest transition, persist receipt, then independently prove its postcondition.
7. Re-observe the affected domains. Promote only if receipt, proof, and observation agree and generation/lease still match.
8. Repeat until READY, user action, retryable wait, terminal safe failure, cancellation, or budget expiration.

The planner cannot emit `revokeCertificate` unless ownership proof is `cryptographicMatch` or stronger and policy explicitly permits owned revocation. It cannot emit READY; the readiness service supplies fresh evidence.

## Generation and identity

- A generation is a monotonically increasing `UInt64` allocated before a candidate-producing transition.
- Evidence binds generation, Mac installation ID, Apple team, device UDID hash, payload artifact hash, runner bundle/version, and connection generation where applicable.
- Observations captured before a generation-changing transition cannot prove the new generation.
- Device reconnect increments `connectionGeneration` and invalidates connection-bound evidence.

## Idempotency, retry, interruption

- Every transition has an idempotency key `SHA256(kind + resource identities + desired digest + generation)`.
- Re-execution first asks the domain service to observe the postcondition. If proven, it records recovered success; otherwise it resumes or starts a new candidate.
- Retry schedules are typed: immediate local retry max 2; Apple/network exponential 1/2/4/8 seconds max 4; device waits are user-action states, not busy retries.
- Cancellation is cooperative. The engine records `cancelRequested`, waits for the current atomic domain operation, records its candidate state, and releases the lease. It never promotes on a cancelled run.
- Process death leaves the journal recoverable. A new run may reclaim an expired lease only after recording the prior run abandoned.

## Concurrency

The engine actor serializes planning within a process; advisory file lock serializes across main app/helper/qualification processes. Independent observations may run concurrently, but mutations execute serially. UI never mutates domain state directly.

## Events

Each operation emits `started`, `succeeded`, `failed`, `waitingForUser`, `candidateCreated`, `candidateProved`, `promoted`, or `retired` through `InstallationEventSink`. Events are written after journal state, so diagnostics never claim a transition the durable state does not contain.

## Planner invariants

1. At most one candidate per domain and generation.
2. Active state is not retired before candidate promotion.
3. Unknown Apple certificates are never revoked.
4. Missing metadata cannot establish ownership.
5. A cached receipt cannot establish live runtime readiness.
6. Every mutating plan has a rollback or an explicit irreversible Apple-side effect marker.
7. All user action states name the Apple-controlled action and a re-observation condition.

