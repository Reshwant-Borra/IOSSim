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
