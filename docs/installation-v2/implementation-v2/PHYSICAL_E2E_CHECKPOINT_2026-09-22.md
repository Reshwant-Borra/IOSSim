# Physical E2E Checkpoint — 2026-09-22 (Prepare → Run Setup → Continue)

Development qualification only. M4 stays **DEFERRED — PRE-RELEASE SECURITY BLOCKER**. Build `11`.
Distribution/notarization stay deferred. Nothing here is release evidence.

Target device: `Rishi Borra`, iPhone18,1, iOS 26.6.2 (23G90), UDID `00008150-00022D581E12401C`.
Artifact: `.build/iossim/development-session/Veya Development.app` (volatile wrapping key, in-memory
pairing store), iPhone payload `payloadSourceHead 272201b…`, `payloadCapabilities.runSetupInbox = 1`.

**Result: the complete Prepare → Run Setup → Continue flow reached READY on the physical iPhone.**
This is the known-good baseline. The architecture is proven; do not redesign it.

## The failure this checkpoint closes

The previous physical attempt (2026-09-22 21:26–21:29, four runs) failed with
`Installation state operation failed.` Root cause, from the live journal:

`InstallationJournalRepository.validate` requires every candidate's generation to equal
`journal.generation` (`:363-368`), and `putCandidate` is the only writer that advances the generation
(`:115`). The journal held an unproved `runtime` candidate at generation 48 from the 10:34 run, whose
prove stopped on a user action. Every later run that needed a candidate in *another* domain advanced
the generation, which put that stranded record one generation behind, so `validate` threw
`unsafeValue("candidate resource")` → `VEYA-SEC-003` **before the write**. Nothing ever cleared it, so
the installation could not be repaired again — the four runs each created a signing key
(`secrets/signing-keys/*.vkey` at 21:26:47, 21:27:54, 21:28:14, 21:29:17) and none was ever promoted.

The reported domain states were all correct observations, not causes:
`signingKey: invalid` (development session loses its in-memory wrapping key on relaunch, M4 deferred),
`payload: stale` (artifacts rebuilt → new `sourceDigest` → new plan binding),
`vpn: stale` (the phone's receipt was older than the 60 s lifetime from `11cac82`),
`pairing: missing` (`InMemoryRemotePairingStore` is emptied by relaunch),
`runtime: candidateUnproved` (the stranded candidate itself).

## What changed

| Area | Change |
|---|---|
| `InstallationJournalRepository.putCandidate` / `executeBlockingCandidateRecovery` | At the one moment a candidate from the previous generation becomes illegal, the repository executes the rollback the planner already recorded for it. Only `.rollback(.discardCandidate)` domains (artifact, migration, authorization, team, signingKey, payload, runtime) are discarded, and the discard is written to `journal.recovery`. A candidate whose creation had an irreversible effect (certificate, profile, application, developerSupport, pairing, vpn) is never discarded: the write fails with `.candidateUnproved(<domain>)` so it can be reconciled. `validate` is unchanged. |
| `RunSetupReadinessCoordinator` | Persists the issued request at `<stateRoot>/run-setup/pending-request.json`; `pendingRequest(...)` reuses it while it is under `RunSetupRequest.lifetime` (15 min, matching `RunSetupInbox`), bound to this device/team/`releaseIdentity`/app, and the phone still carries that request or a receipt for it. A bound success receipt retires Veya's copy. |
| `RunSetupReadinessCoordinator.init` | `pollCount` default 600 → 1. The five-minute human wait is gone; `awaitRunSetup` is a single read. |
| `JournalRuntimeProver.proveRuntime` | Reuses the pending request; reissues only when there is none. |
| `RuntimeReadinessDomain.prove` | Freshness guard `completedAt >= started - 5 s` → `>= started - timeToLive` (600 s). The tap legitimately precedes Continue; the old guard would have rejected every phased run. Upper bound (`now + 5 s`) and `RunSetupReceipt.satisfies` binding unchanged. |
| `RuntimeReadinessDomain` copy + `RunSetupProgress.readyForSetup` + `DevelopmentInstallationView` | `READY FOR SETUP`, and **Install / Prepare** + **Continue / Verify Setup** (enabled only while a request is outstanding). Both press the same `.reconcile` command. |

Deliberately **not** done: executing `.rollback(.discardCandidate)` in the fail/cancel path.
`ReconciliationPlannerTests.testCancellationAcrossLeaseRenewalPreservesCandidate` and
`testProofFromEarlierConnectionIsRejectedAndCandidatePreserved` both prove the candidate must survive
there; for `signingKey` the candidate is the only journal record of a `.vkey` file `createCandidate`
already wrote; and for `runtime` the preserved candidate is what lets Continue re-prove the same
binding. The recovery therefore runs at the conflict point, driven by the same recorded semantics.

## Physical chain — 2026-09-22 22:17–22:20

Evidence **J** is the development journal
(`~/Library/Application Support/Veya/development-session/installation/journal-v1.json`, revision 719,
generation 58, installation `0701D635-…`; local only, not committed). **U** is direct user observation.

| Phase | Status | Evidence |
|---|---|---|
| Journal deadlock recovery | PHYSICAL_PASS | J `recovery.reason = "blockingCandidateDiscarded:runtime"`, `recoveredFromRevision 702` — the fix fired on the real wedged journal and generation advanced past 48 |
| Apple authorization (live SRP + 2FA) | PHYSICAL_PASS | U; J gen 50 `appleInventorySPKIMatch` requires an authorized session |
| Personal Team discovery | PHYSICAL_PASS | U; J certificate/profile records are team-bound |
| Signing key (development session, volatile) | PHYSICAL_PASS / DEFERRED (M4) | J gen 49 `signingKeySignVerifyProbe` 22:17:46 |
| Certificate reconciliation (SPKI ownership) | PHYSICAL_PASS | J gen 50 22:17:49, `ownership privateKeyControl` |
| Provisioning profiles (main + runner) | PHYSICAL_PASS | J gen 51 `profileCMSBindingValidation` 22:17:52 |
| In-process signing (`veya-signing-core`) | PHYSICAL_PASS | J gen 52 `payloadIndependentVerification` 22:17:54 |
| Application install of the rebuilt payload | PHYSICAL_PASS | J gen 53 `deviceInventoryAfterInstall` 22:18:01, digest `sha256:4cf38392…`, connection generation 2 |
| DDI / developer support | PHYSICAL_PASS | J `developerSupport` stayed active at gen 45 — the live probe observed it ready, so no redundant mount |
| LocalDevVPN detection with the VPN **off** | PHYSICAL_PASS | U: Veya reported the LocalDevVPN action; see Issue 1 below |
| LocalDevVPN after the user enabled it | PHYSICAL_PASS | J gen 54 `vpnFreshObservation` 22:18:54 |
| Automatic pairing delivery | PHYSICAL_PASS | J gen 55 `pairingFreshObservation` 22:19:09 — no manual RPPairing import |
| READY FOR SETUP hand-off | PHYSICAL_PASS | U: Mac showed `READY FOR SETUP`; `run-setup.request` placed |
| User's own Run Setup tap on the iPhone | PHYSICAL_PASS | U; J gen 58 `runtimeFullChainProof` `capturedAt 22:19:23` — the receipt's own `completedAt` |
| Continue / Verify Setup | PHYSICAL_PASS | J gen 57 `vpnFreshObservation` 22:20:25 (60 s receipt re-probe), then runtime promoted at 22:20:29 |
| Proof accepted although the tap preceded Continue by ~63 s | PHYSICAL_PASS | J: runtime evidence `capturedAt 22:19:23` vs promotion 22:20:29 — the old `started - 5 s` guard would have rejected this |
| Pending request retired after the accepted receipt | PHYSICAL_PASS | `development-session/run-setup/` is empty after READY |
| Final READY / Setup Complete | PHYSICAL_PASS | J gen 58 `runtime` active, `validUntil 22:29:23`, `candidates` empty |

Veya never launched or drove the Run Setup run: the coordinator has no launch call
(`RunSetupReadinessTests.testVeyaAsksAndWaitsWithoutEverStartingTheRunItself`).

## Automated results at this commit

- `./iossim installation-baseline --defer-m4` → **Overall: PASS** (16 checks; M4 DEFERRED).
- `swift test`: 521 executed, 18 skipped, **4 failures**, all
  `SigningKeyStoreTests.testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction`
  (`VEYA-KEY-001`, Keychain wrapping unavailable, M4). Verified pre-existing by running the same
  filter in a clean worktree at `41fb3d5`: identical four failures.

New regression tests:

| Test | Covers |
|---|---|
| `InstallationJournalRepositoryTests.testUnprovedCandidateInAnotherDomainNeverWedgesTheJournal` | the exact deadlock; discard recorded in `recovery`; active records untouched |
| `…testCandidateWithAnIrreversibleEffectIsNeverDiscarded` | a certificate candidate is reported, never dropped; generation unchanged |
| `RuntimeReadinessTests.testUnprovedRuntimeCandidateNeverWedgesAnotherDomain` | failed runtime proof → VPN still repairable → the tap still reaches READY |
| `RunSetupReadinessTests.testPendingRequestIsReusedSoALateTapStillCounts` | Prepare → tap → Continue reuses the request ID, verifies, retires it; nothing launched |
| `…testExpiredOrMisboundPendingRequestIsReplaced` | expired, other device/app/team/release, wiped container |
| `ProductionWiringTests.testPairingTransitionStillDeliversAutomaticallyAndAsksTheUserForNothing` | automatic pairing delivery unchanged, into the installed payload's container |

## Preserved

Apple sign-in / 2FA / session store · Personal Team discovery · signing-key generation and
`DevelopmentMemoryWrappingStore` · certificate reconciliation and revoke handling · provisioning
profiles · in-process signing · `ApplicationDomain` install/upgrade · DDI acquisition and mounting,
`NativeDeveloperServicesCoordinator`, developer-trust handling · `LocalDevVPNSetupCoordinator` and the
60 s receipt re-probe · `RemotePairingCoordinator.reconcileAutomatically`, pairing record format,
manual RPPairing import · Rich Drive, `XCTestRichDriveLocationTransport`, testmanagerd,
`RichRuntimeReadinessCoordinator` · location functionality · device support logic · `LegacyMigration` ·
`RunSetupReceipt.satisfies` binding and every fail-closed check · M4 deferred · distribution untouched.

## Open UX observations from this run (not defects in the chain above)

Recorded here so the next pass has the physical context; investigated separately, nothing changed yet.

1. **VPN continuation wording.** With the VPN off the action text ends "…then continue", but while the
   run is stopped on a device user action `awaitingRunSetup` is false, so **Continue / Verify Setup** is
   disabled and the user must press **Install / Prepare**. Both buttons invoke the same `.reconcile`
   command, so this is an affordance/wording mismatch, not a state-routing failure.
2. **Repeated iPhone app launches.** The app visibly opened/closed roughly three times during
   preparation and again around Continue. Multiple correct stages each activate the app
   (`RemotePairingCoordinator` activates it after every inbox write, `LocalDevVPNSetupCoordinator`
   activates it before probing, `NativeDeveloperServicesCoordinator` launches it as the AppService
   proof). Every launch is currently load-bearing; none removed.
3. **Simulated location during setup.** The user observed the iPhone's location move to New York during
   the run. The Run Setup receipt requires `locationVerified` + `locationCleared`, so the coordinate is
   delivered and then cleared by the phone's own run. Whether any location mutation is still required
   now that the user's real Run Setup is the proof is the subject of the next pass.

---

# Follow-up pass — UX and zero-location setup (2026-09-22, after the passing run)

The chain above stays exactly as proven. Three targeted changes address what the physical run
exposed; nothing in the installation flow, the Run Setup architecture or the pairing protocol moved.

## 1. One phase-aware primary action (P0)

**Was:** with the VPN off the run ended as `userActionRequired` carrying `VEYA-DEVICE-031` and the
text "…then continue." `DevelopmentInstallationModel.awaitingRunSetup` is gated on
`RuntimeReadinessDomain.runSetupRequired.code`, so **Continue / Verify Setup was disabled** and only
Install / Prepare could act — while the instruction said "continue". Both buttons invoked the same
`.reconcile`, so this was wording plus enablement, never state routing.

**Now:** a single primary button, `Install / Prepare` until a Run Setup request is outstanding and
`Continue / Verify Setup` after. Every device user action reads "…then continue in Veya."
(`DeviceFailureMapping.unlock/.trust/.developerTrust`, the LocalDevVPN mappings,
`runSetupRequired`, `runSetupFailed`, `runtimeActionRequired`). No second continuation mechanism, no
polling: the engine re-observes on every run and the planner still stops at the first unsatisfied
domain, which is why the same command both prepares and verifies.

## 2. Pairing activation is an escalation, not a step (P1)

Every Veya-side launch goes through `iossim_bridge_launch_app` →
`AppServiceClient::launch_application(bundle, &[], kill_existing: true, …)`
(`native/iossim-device-bridge/src/lib.rs:1608`), so **each launch kills and restarts the app** — the
open/close cycles the user saw. `AutomaticPairingInboxController` already polls the container for
60 s at 4 Hz on `scenePhase == .active` (`IOSSimOnDeviceDVTPOCApp.swift:10-29`), so after the first
activation it picks up each later write itself; relaunching also restarts that watcher from zero.

`RemotePairingCoordinator.poll` gained an `escalate` closure that fires once, after
`activationEscalationAttempt` (8 attempts ≈ 2 s), and the three `activateApp` calls that followed the
envelope, the possession challenge and the promotion request moved into it. The bootstrap activation
that starts the watcher is unchanged, as is every byte of the pairing protocol and its cryptography.

## 3. Setup qualification no longer touches location (P1)

**Was:** `ConnectionStatusModel.completeSetupForVeya` called `setTestLocationAndVerify()`
(Times Square `40.7580,-73.9855`), waited for Core Location, then `clear()`. It existed for a real
reason: `connect()` → `startSimulation(.staticLocation(nil))` → `ensureConnected` returns early on an
established session (`LocationCoordinator.swift:525-530`), so `sessionEstablished` alone can be
satisfied from cache.

**Now:** `IdeviceOnDeviceTunnelClient.probeSession()` opens a fresh RSD remote server over the
retained tunnel (the same `adapter`/`handshake` reuse the Gate-3 XCTest path already relies on) and
performs a DeviceInfo root-directory listing — one real request to dtservicehub and one real answer,
read-only. `warmDeviceInfo()` and the probe now share `deviceInfoRoundTrip(on:)` so they cannot
drift. It is exposed as `LocationCoordinator.probeSession()` → `ExperimentRunner.probeSession()` and
runs only in the `answeringVeyaRequest` branch.

Receipt schema **1 → 2**: `locationVerified` + `locationCleared` → `sessionProbed`, on both sides
(`RunSetupInbox.swift`, `RunSetupReadiness.swift`), in `succeeded`, in `RunSetupOutcome`, and in the
packaging guards. Newly packaged payloads declare `payloadCapabilities.runSetupInbox = 2`, and the
guard now asserts the payload source carries `sessionProbed` and carries **neither**
`locationVerified` nor `locationCleared`, with `setTestLocationAndVerify` absent from the Run Setup
path. Fail-closed is preserved: `sessionProbed` is set only after the round-trip returns, the probe
throws when no session is established, and the rest of the binding is untouched.

Untouched product location functionality: `POCViewModel.setTestLocation`, `ExperimentRunner.setAndVerify`,
`LocationViewModel`/`ensureReady`, `DvtLocationClient.set`/`clear`, Drive mode,
`XCTestRichDriveLocationTransport`, and the legacy `RichRuntimeProofInbox` (still inert, still
location-based, still reachable only from the provisioner's diagnostic command).

## Tests

- `swift test`: 523 executed, 18 skipped, 4 failures — the same four M4 `SigningKeyStoreTests` cases
  that fail on a clean tree.
- `./iossim installation-baseline --defer-m4` → **Overall: PASS**.
- New: `ProductionWiringTests.testAutomaticPairingActivatesTheAppOnceWhenTheWatcherAnswers` (happy
  path activates once) and `…RelaunchesTheAppWhenTheWatcherDoesNotAnswer` (the backstop still fires,
  exactly once). `POCUnitChecks.setupSessionProbeTouchesTheDeviceAndNeverTheLocation` (the probe
  fails closed without a session, makes one round-trip, sends zero coordinates and zero clears, and
  user-requested spoofing still works). `RunSetupReadinessTests` binding case now covers
  `sessionProbed: false`.

## Expected visible iPhone launches

| Phase | Before | After |
|---|---|---|
| Install / Prepare — VPN watcher | 1 Veya + 1 LocalDevVPN | unchanged |
| Install / Prepare — automatic pairing | 4 Veya (bootstrap, envelope, challenge, promotion) | **1 Veya** (bootstrap; the other three only if the watcher stops answering) |
| Install / Prepare — pairing developer-services proof | 1 Veya | unchanged |
| Install / Prepare — runtime developer-services proof | 1 Veya | unchanged |
| **Install / Prepare total** | **≈7 Veya** | **≈4 Veya** |
| Continue / Verify Setup | 2 Veya | unchanged |

## Clean post-change physical confirmation — 2026-09-22 23:23–23:25 EDT

**PASS** on commit `073d4a9` with a clean source tree. The complete physical flow
again reached READY after the pairing-activation reduction and read-only
`sessionProbed` setup proof. Direct observation still showed approximately three
visible Veya open/close cycles, which is now tracked as a final UX investigation,
not as a correctness failure.

The local development journal ended at revision 813 / generation 66 with no
candidates. It records application generation 63, `vpnFreshObservation`
generation 64 at 23:24:53, `pairingFreshObservation` generation 65 at 23:25:05,
and `runtimeFullChainProof` generation 66 at 23:25:14. This confirms the proven
implementation remained intact. It does not authorize removal of any remaining
AppService launch; each caller must be classified before a launch-count change.

## Artifacts

- iPhone payload: `.build/iossim/self-contained/IOSSim.app/Contents/Resources/DeviceArtifacts`
  (`runSetupInbox: 2`; main binary `a249ca5b02ab` carries `sessionProbed` and carries neither
  `locationVerified` nor `setTestLocationAndVerify`).
- Development Mac app: `.build/iossim/development-session/Veya Development.app`
  (carries `Install / Prepare`, `Continue / Verify Setup`, `then continue in Veya`, `sessionProbed`).
- Both are rebuilt from this commit with a clean tree (`payloadSourceDirty: false`).
- `./iossim package-app` reports the same unrelated `ARTIFACT_IDENTITY_MISMATCH` (host-arch Mac
  products vs the universal ones only release builds produce). The iPhone payload passed every
  capability, bundle-identity and hygiene check in that run.
