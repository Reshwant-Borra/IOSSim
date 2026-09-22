# Physical E2E Checkpoint — 2026-09-21

Development qualification only. M4 is **DEFERRED — PRE-RELEASE SECURITY BLOCKER**. Build remains `11`.
Nothing here is release evidence.

Target device: `Rishi Borra`, iPhone18,1, iOS 26.6.2 (23G90), UDID `00008150-00022D581E12401C`.
Artifact: `.build/iossim/development-session/Veya Development.app` (volatile wrapping key, in-memory pairing store).

Status vocabulary: AUTOMATED_PASS, PHYSICAL_PASS, PARTIAL, BLOCKED_EXTERNAL, DEFERRED, NOT_RUN.

## Evidence sources

- **J**: the development installation journal (`~/Library/Application Support/Veya/development-session/installation/journal-v1.json`,
  revision 162, generation 14, installation `0701D635-…`). Local only; not committed.
- **S**: physical opt-in test runs from the previous session (results reported in that session's handoff; not re-run
  in this checkpoint session because the target iPhone was not attached — see "Checkpoint session device state").
- **U**: direct user observation on the iPhone.

## Chain

| Phase | Status | Evidence |
|---|---|---|
| Apple authorization (live SRP + 2FA) | PHYSICAL_PASS | S; J gen 3/7/11 `appleInventorySPKIMatch` from `apple-developer-services` requires an authorized session |
| Personal Team discovery | PHYSICAL_PASS | S; J certificate/profile records are team-bound |
| Device registration | PHYSICAL_PASS | S; J gen 12 `profileCMSBindingValidation` (profile contains the physical UDID) |
| Signing key (development session, volatile) | PHYSICAL_PASS / DEFERRED (M4) | J gen 10 `signingKeySignVerifyProbe`; relaunch deliberately loses the wrapping key |
| Certificate reconciliation (SPKI ownership) | PHYSICAL_PASS | J gen 11 `appleInventorySPKIMatch`, ownership `privateKeyControl` |
| Provisioning profiles (main + runner) | PHYSICAL_PASS | J gen 12 `profileCMSBindingValidation`, `cms-offline-validation` |
| In-process signing (`veya-signing-core`) | PHYSICAL_PASS | J gen 13 `payloadIndependentVerification` |
| Application install/upgrade (Installation Proxy) | PHYSICAL_PASS | J gen 14 `deviceInventoryAfterInstall`, connection generation 1; S `testOptInPhysicalSignedApplicationInstallBoundary` |
| iOS developer trust (Settings → General → VPN & Device Management) | USER_ACTION_REQUIRED → PHYSICAL_PASS | U: "Untrusted Developer" until trusted; app launched and worked afterwards |
| Development DDI acquire + mount | PHYSICAL_PASS (development provider) | S |
| CoreDeviceProxy / tunnel / RSD / RemoteXPC / AppService | PHYSICAL_PASS | S `testOptInPhysicalDeveloperServicesLaunchBoundary` |
| Developer-services launch proof (main app) | PHYSICAL_PASS | S; `ProductionWiringTests.testDeveloperSupportLaunchProofTargetsTheMainAppInsteadOfPlainLaunchingTheXCTestRunner` |
| RemotePairing record | PARTIAL — manual import; automation DEFERRED | No `pairing` active record in J; dev session uses `InMemoryRemotePairingStore` |
| LocalDevVPN | NOT_RUN — onboarding gap | No `vpn` record in J; the user was never prompted (see below) |
| Runtime full-chain proof / READY | NOT_RUN | No `runtime` record in J; depends on pairing + VPN |
| Production/public DDI distribution | BLOCKED_EXTERNAL | `config/release.json` `UNRESOLVED_PRODUCTION_PROVIDER` |

## Defects found physically and fixed (all with regression tests)

1. **Rust future overflowed the Swift cooperative-thread stack** during a developer-services probe. Device futures
   now poll on a bounded native thread with a larger stack. Test: `device_future_polling_does_not_use_the_swift_sized_caller_stack` (Rust).
2. **Installation Proxy omits top-level `TeamIdentifier` on iOS 26.6.2**, which was misread as a foreign-team
   conflict. The bridge requests entitlements/application-identifier and derives the team with strict bundle
   matching. Ownership safety unchanged. Test: `inventory_team_uses_signed_entitlements_when_top_level_field_is_absent` (Rust).
3. **Stale USB usbmux record hid a live wireless route** (`deviceNotFound`). Same-generation alternatives are kept;
   the preferred route falls back only on connection-loss/not-found; stale generations fail closed. Tests:
   `NativeDeviceBridgeTests.testInspectionFallsBackToLiveWirelessRecordWhenPreferredUSBRecordIsStale`,
   `testInspectionDoesNotUseAlternativesFromANewerDiscoveryGeneration`, `testUSBAndWirelessDuplicatePreferUSB`.
4. **Developer-services proof plain-launched the XCTest runner**, which AppService rejects. Proof contexts now launch
   the main app; runner/XCTest evidence stays with M10. Test: `ProductionWiringTests` (above).

## Onboarding gaps identified (Phase B input)

- **Developer trust**: a legitimate iOS security action, not a Veya defect. Veya must present it as a user action.
- **LocalDevVPN**: required for the runtime path, but the user was never prompted before the app worked.
- **Pairing**: the development session's pairing store is in memory; manual import stays for now.
- **Stale-looking observations** (`waitingForUser`/`invalid`/`missing` after success): expected in part from the
  volatile M4 session (relaunch loses the signing key), plus missing re-observation after actions.

## Checkpoint validation (this session)

- `./iossim installation-baseline --defer-m4`: **Overall PASS**. macOS Swift 505 executed / 15 skipped / 0 failed;
  Rust bridge 18/0, signer 12/0 (+1 ignored exact-payload); fmt, clippy, both release targets, iOS shared checks,
  secret scan, v2 legacy guard all PASS; M4 step DEFERRED.
- `check_legacy_signing_routes.py --scope all`: 16 findings on the legacy shipping route (M11, unchanged).
- Graphify `update .`: 37,043 nodes, 90,861 edges, 1,218 communities. `graphify-out/` is local-only (now gitignored).

## Checkpoint session device state

Only the second iPhone (`iPhone`, iOS 26.6.1, UDID `…001439C43EEA401C`) was attached. It is not the qualification
target, so no physical test or mutation was run against it.

## Repository hygiene

- Live-qualification screenshots (`docs/installation-v2/implementation/live-qualification/*.png`) are excluded and
  gitignored: they are full-screen captures containing unrelated personal content, and the repository is public.
- Stray shell-redirect file `:-` (codesign requirement text) is left untracked.

## Onboarding pass (after checkpoint commit `94d9e76`)

Failure/state classification of the device chain:

| Domain / state | Class | Veya behavior now |
|---|---|---|
| Untrusted Personal Team developer (AppService launch denied, "profile has not been explicitly trusted") | PLATFORM_SECURITY_REQUIREMENT | `waitingForUser` with the Settings → General → VPN & Device Management instruction, from both the developer-services launch and the LocalDevVPN step's launch of Veya |
| LocalDevVPN absent | USER_ACTION_REQUIRED | "Install LocalDevVPN from the App Store on the iPhone." (inventory-proven by the coordinator) |
| LocalDevVPN VPN permission / not connected | USER_ACTION_REQUIRED | approve / tap Connect instructions (existing mappings) |
| LocalDevVPN `running` without endpoint | STALE_OBSERVATION / incomplete | never satisfies; only `runtimeEndpointReachable` does (unchanged) |
| Pairing record absent on the Mac | DEFERRED_FEATURE | engine runs the existing automatic bootstrap/delivery transition; not physically proven |
| Apple session / signing key after relaunch | DEFERRED (M4 volatile) | shows `waitingForUser` / `invalid`; the dev UI now explains this |
| Device locked / trust prompt / Developer Mode | USER_ACTION_REQUIRED | existing mappings, unchanged |

Defects fixed:

1. **LocalDevVPN prompt unreachable (root cause of "never prompted").** The planner stops at the first
   unsatisfied domain in `reconciliationOrder`, and `.pairing` preceded `.vpn`. While pairing was unsatisfied
   every reconcile ended at pairing. `.vpn` now precedes `.pairing`; the phone-side LocalDevVPN check never reads
   RPPairing (`LocalDevVPNSetupInbox`), and runtime still requires both. READY semantics unchanged.
2. **User actions raised inside a transition were reported as product failures** (`EngineHost.failureResult`
   dropped `VeyaFailure.userAction`). They now return exit `userAction`, status `userActionRequired`, and the action.
3. **Untrusted developer was a generic device/transport failure.** `NativeDeviceBridgeError.isDeveloperTrustRejection`
   reuses the physically observed `ConsumerProvisioningErrorClassifier`; `LocalDevVPNSetupFailure.developerTrustRequired`
   carries it out of the VPN coordinator (legacy route maps it to its existing `developerProfileTrustRequired`).
4. **Blank/stale observation list after a failed action.** A thrown transition returns no snapshot; the dev UI now
   re-inspects so the list reflects current state, shows each observation's user action, and labels M4-volatile states.

Regression tests (`DeviceDomainsTests`, 9/0): VPN-before-pairing order; trust rejection → user action from bridge and
VPN coordinator, non-trust rejection stays retryable; transition user action → `userAction` result.

Truthful limits:

- **Manual pairing import on the iPhone does not satisfy the Mac-side `.pairing` domain.** The development session
  keeps pairing in `InMemoryRemotePairingStore`, and `JournalRuntimeProver` requires the Mac-side record's
  generation. So READY via the v2 engine needs the existing automatic delivery to succeed physically. No "import
  manually" prompt was added, because it would not unblock READY.
- The iOS trust-denial text through idevice's AppService error is assumed to carry the FBS phrase the classifier
  matches (as observed via devicectl). Physical confirmation pending.

Physical E2E after these changes: **NOT_RUN** — the qualification iPhone was not attached (only `…001439C43EEA401C`).
Development artifact rebuilt: `.build/iossim/development-session/Veya Development.app`.
Graphify: 37,059 nodes, 90,894 edges, 1,203 communities.

Onboarding-pass validation: `./iossim installation-baseline --defer-m4` **Overall PASS** — Swift 508 executed / 15
skipped / 0 failed (a first run caught `ProductionComposition` still composing pairing before VPN; fixed to match
`reconciliationOrder`, asserted by `LegacyMigrationTests`). Rust, secret scan, v2 legacy guard all PASS; M4 DEFERRED.

## Physical E2E run — 2026-09-21 21:53–22:17 (after `b0ee224`)

Target verified before any mutation via usbmux + lockdown `GetValue`: `Rishi Borra`, iOS 26.6.2, **23G90**,
UDID `00008150-00022D581E12401C` (USB + network). The second iPhone (`…001439C43EEA401C`, 26.6.1) was attached on
network only and never used.

| Phase | Result | Evidence (development journal) |
|---|---|---|
| Developer-services launch boundary (opt-in test) | PHYSICAL_PASS | `testOptInPhysicalDeveloperServicesLaunchBoundary` against the rebuilt bridge |
| Apple sign-in + 2FA in Veya | USER_ACTION_REQUIRED → PHYSICAL_PASS | user entered credentials in Veya only |
| Signing key / certificate / profiles / signing | AUTOMATIC → PHYSICAL_PASS | gen 15–18 (21:55:10–21:55:25) |
| Install (Installation Proxy) | AUTOMATIC → PHYSICAL_PASS | gen 19 `deviceInventoryAfterInstall`, connection 1 |
| Developer support (DDI + AppService) | AUTOMATIC → PHYSICAL_PASS | gen 20 `developerSupportFreshObservation` — first time recorded |
| LocalDevVPN | USER_ACTION_REQUIRED ("Open LocalDevVPN … allow the VPN configuration") → PHYSICAL_PASS | gen 21 `vpnFreshObservation` 22:08:09 |
| Pairing | AUTOMATIC (existing bootstrap/delivery; **no manual import**) → PHYSICAL_PASS | gen 22 `pairingFreshObservation` 22:08:35 |
| Runtime (testmanagerd + XCTest runner + location probe + cleanup) | USER_ACTION_REQUIRED (iOS automation approval) → PHYSICAL_PASS | gen 23 `runtimeFullChainProof` 22:17:03, `rich-runtime-inbox`, connection 1, valid until 22:27:03 |
| **READY** | **PHYSICAL_PASS (development)** | all 10 required domains active; runtime evidence fresh and bound to the current connection and upstream records |

Physical defects found in this run and fixed (with regression tests):

5. **VPN deadlock on a stale action receipt.** The observer treated the phone's last LocalDevVPN receipt
   (`vpnPermissionRequired`, ≤ 600 s old) as current `waitingForUser`, so after the user approved, Veya never
   re-probed. The receipt now yields `invalid` with the action as a hint, so the transition re-probes and re-raises
   the action only if still needed. Workaround used live: waiting out the 600 s receipt lifetime.
   Test: `ProductionWiringTests.testVPNObservationIsReadOnlyAndAcceptsOnlyAFreshBoundReachableReceipt`.
6. **First runtime proof failed while iOS asked to allow automation.** The phone writes a receipt per app
   activation. The run before approval wrote a failed receipt, which the Mac read and rejected at 22:08:46. The
   post-approval run succeeded (22:08:52), after the Mac had stopped. `proofFailed`/`receiptUnavailable` now raise a
   retryable user action (`VEYA-RUNTIME-010`); `cleanupFailed` stays a product failure. An isolated Mac-side
   reproduction of the coordinator passed (`ready=true`, 6.5 s). Test:
   `RuntimeReadinessTests.testOnDeviceRunBeforeAutomationApprovalIsAUserActionAndRetryReachesReady`.
7. **Blank status line in the development UI** after runs (selectable `Text` not relaid out); forced with `.id`.
   Not yet visually re-verified (needs a relaunch).

Corrections to earlier statements in this document:

- Pairing: the existing automatic delivery **works physically**; manual import was not needed for READY.
- The development artifact that reached READY predates fixes 5–7 (VPN needed the 600 s wait; runtime needed one retry).

Validation: `./iossim installation-baseline --defer-m4` **Overall PASS** — Swift 509 / 15 skipped / 0 failed.

## Clean confirmation run — 2026-09-21 22:25–22:43

Fresh development package from `1821a32` (+ fix 8 below), app quit and relaunched (volatile Apple session and
signing key discarded, M4 deferred). Target re-verified before mutation: `Rishi Borra`, 26.6.2 / 23G90,
`00008150-00022D581E12401C`.

First attempt (22:26–22:28, LocalDevVPN still connected): whole chain automatic through runtime, `ready` shown.
The user then disconnected LocalDevVPN; a later click still showed `vpn satisfied`.

8. **VPN satisfied minutes after LocalDevVPN was turned off.** The observer accepted a bound `ready` receipt for
   600 s. A live product probe at 22:33 correctly returned `vpnNotRunning` while the stored receipt (22:27:41) still
   said reachable. Bound receipts older than 60 s are now `stale` and force a re-probe; the runtime proof TTL (600 s,
   M10) is unchanged. Because `.vpn` precedes `.runtime`, a stale/failed VPN blocks READY.
   Test: `ProductionWiringTests.testVPNObservationIsReadOnlyAndAcceptsOnlyAFreshBoundReachableReceipt`.

Confirmation run after rebuilding with fix 8 (LocalDevVPN disconnected at start):

| Step | Class | Result |
|---|---|---|
| Select iPhone (two phones attached: no auto-select, by design) | USER_ACTION_REQUIRED | selected `Rishi Borra - 26.6.2` |
| Apple sign-in | USER_ACTION_REQUIRED → PHYSICAL_PASS | status "Authorized: Rishi Borra" |
| Signing key / certificate / profiles / signing | AUTOMATIC → PHYSICAL_PASS | gen 32–35 (22:39:58–22:40:14) |
| Install | AUTOMATIC → PHYSICAL_PASS | gen 36 `deviceInventoryAfterInstall` 22:40:48, connection 1 |
| LocalDevVPN off | USER_ACTION_REQUIRED | status "ACTION REQUIRED: Open LocalDevVPN on the iPhone and tap Connect, then continue." (run ended 22:41:07) |
| LocalDevVPN reconnected, immediate retry | AUTOMATIC → PHYSICAL_PASS | gen 37 `vpnFreshObservation` 22:42:29 — **no 600 s wait** |
| Pairing | AUTOMATIC → PHYSICAL_PASS | gen 38 `pairingFreshObservation` 22:42:55, no manual import |
| Runtime | AUTOMATIC → PHYSICAL_PASS | gen 39 `runtimeFullChainProof` 22:43:08, connection 1, valid until 22:53:08 |
| **READY** | **PHYSICAL_PASS (development)** | status line "ready" (redraw fix 7 confirmed) |

Not re-exercised physically: the automation-approval action (fix 6) — iOS did not prompt again because approval was
already granted; covered by `RuntimeReadinessTests`.

Validation: `./iossim installation-baseline --defer-m4` **Overall PASS** — Swift 509 / 15 skipped / 0 failed;
Rust bridge 18/0, signer 12/0 (+1 ignored); M4 DEFERRED.
