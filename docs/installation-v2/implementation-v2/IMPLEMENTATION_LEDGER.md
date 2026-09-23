# Installation V2 Implementation Ledger

Build remains `11` through M0-M12. Per owner direction (2026-09-21), M5-M12 proceed while M4 stays an explicit, unresolved Build 12 / production blocker. All live Apple/device mutation is excluded unless explicitly safe and ownership-proven.

| Milestone | Status | Exit gate summary |
|---|---|---|
| M0 | PASS | Pinned toolchain; deterministic baseline command and all M0 suites pass |
| M1 | PASS | Canonical state/event/failure model and atomic active/candidate journal; 13 fault/recovery tests pass |
| M2 | PASS | Canonical observer/planner/one-transition engine; lease heartbeat, connection generation, recovery semantics, lifecycle events |
| M3 | PASS | VeyaQualify + helper `engine` protocol drive the one production engine; scenario fixtures, byte-equivalent UI/CLI trace |
| M4 | DEFERRED — PRE-RELEASE SECURITY BLOCKER (development runs volatile) | Production selection fails closed (`unavailable`) without a proven team identity; Data Protection Keychain proof requires a profile-granted signed artifact |
| M5 | SOFTWARE_GATE_PASS / PHYSICAL_PASS (development) | Exact payload + golden graph sign in process and pass Apple strict verification on arm64/x86_64; physical install pending M6 credentials + device |
| M6 | SOFTWARE_GATE_PASS / PHYSICAL_PASS (live Apple, development) | Auth v2; SPKI-only certificates; `.authorization/.team/.certificate/.profile` routed through the live backend; retry-safe budget |
| M7 | SOFTWARE_GATE_PASS / PHYSICAL_PASS (install on iOS 26.6.2) | Two-bundle payload, per-team rewrite approval, exact entitlements, staging GC; composed in production |
| M8 | SOFTWARE_GATE_PASS / LEGACY_WRITE_REMOVAL_PENDING | Read-only legacy snapshot in the migration ledger; legacy key never imported (plaintext-equivalent at rest) |
| M9 | SOFTWARE_GATE_PASS / PHYSICAL_PASS (development DDI, LocalDevVPN, automatic pairing) / PRODUCTION_DDI_BLOCKED_EXTERNAL | DDI via the helper's real coordinator; pairing/VPN bound to the installed app; v2 pairing store fail-closed |
| M10 | SOFTWARE_GATE_PASS / PHYSICAL_PASS (development READY 2026-09-21 22:17, fresh bound runtime proof) | READY only from fresh bound full-chain proof; journal-aware production prover composed |
| M11 | PARTIAL / ROUTE_SWITCH_BLOCKED_HUMAN | v2 cannot reach legacy (retired identity store, subprocess guard); M11-A removed `personal-team-poc`; 14 legacy entries remain on the shipping route |
| M12 | FAIL (M4 open) | 497 Swift (1 required failure: M4), Rust 27/0 both arches, exact payload pass, baseline all other steps PASS |

## M0

- Start baseline: Build 11; Swift 384/14/0; Rust 11/0; iOS shared checks pass.
- Files changed: `rust-toolchain.toml`, `scripts/bootstrap/iossim_cli.py`.
- New evidence: `00_IMPLEMENTATION_BASELINE.md`, `baseline.json`.
- Root-cause correction: Cargo was installed but not in interactive PATH; tooling now resolves through rustup and an exact repository pin. The earlier rustfmt-missing observation is stale; it is presently installed.
- Security: build-tool changes only; no consumer runtime dependency added.
- Failures: strict clippy FFI contracts; sandboxed SwiftPM cache; artificial HOME-based Keychain skip.
- Root causes: historical FFI lacked safety docs; command sandbox blocked external caches; redirected HOME hid the default Keychain.
- Blueprint amendments: none. Cache placement was clarified as an execution detail.
- Exit evidence: `M0_RESULT.md`; all binary M0 gates pass.
- Remaining risks: required skip replacement remains assigned to M3-M5/M12.

## M1

- Status: PASS.
- Start baseline: M0 PASS; Build 11 unchanged.
- Objective: canonical versioned state, active/candidate resources, evidence, leases, recovery, and atomic persistence.
- Files created: `InstallationDomainModels.swift`, `VeyaFailure.swift`, `InstallationEvent.swift`, `InstallationJournal.swift`, `InstallationJournalRepository.swift`, and `InstallationJournalRepositoryTests.swift`.
- State behavior: schema-1 journal envelope with payload digest; `0700` directory; `0600` temporary/lock files; nonblocking advisory locks; renewable logical lease; fsynced temporary write; atomic rename; directory fsync; post-write decode verification; previous-checkpoint recovery.
- Fault evidence: normal reopen, pre-rename crash, simulated disk-full, post-rename crash, truncated/corrupt journal, old schema, live/stale leases, generation mismatch, evidence-gated promotion, candidate discard, and secret-canary rejection all pass.
- Regressions: focused journal suite 13/0/0; full Swift 397/14/0 on confirmed rerun; complete `./iossim installation-baseline` PASS including Rust, iOS, and both macOS Rust release targets.
- Failure encountered: one full-Swift run reported a single transient failure whose truncated output hid the case; an immediate diagnostic rerun executed the same 397 tests with 14 skips and zero failures. No journal test was implicated.
- Security: journal values reject secret-shaped keys/values and unsafe paths; sensitive material is represented only by relative references/digests.
- Blueprint amendments: none.
- Exit evidence: `M1_RESULT.md`.
- Remaining risks: current production stores are intentionally not routed to the new journal until migration/domain adapters are introduced by their owning milestones.

## M2

- Status: PASS.
- Start baseline: M1 PASS; Build 11 unchanged.
- Objective: pure observation/derivation/planning and one-smallest-safe-transition execution shared by future UI and qualification clients.
- Files: `ReconciliationModels.swift`, `ReconciliationPlanner.swift`, `ReconciliationProtocols.swift`, `VeyaReconciliationEngine.swift`; journal gained `JournalTransition.recovery`, evidence gained `connectionGeneration`; `ReconciliationPlannerTests.swift`; `scripts/checks/check_installation_v2_secrets.py` added to the baseline.
- Defect found earlier in M2: secret-label detection applied to identifier values (UUID containing `2fa`); corrected to field names only.
- Session gaps closed: lease renewal/ownership loss, connection-generation invalidation, exhaustive recovery semantics, `candidateCreated`/`candidateProved`/`waitingForUser` events.
- Tests: focused 36/0/0; engine suite 25x repeat green; `./iossim installation-baseline` PASS; secret scan 0 findings; diff check PASS.
- Failure classifications: one TEST_DEFECT (Swift type-checker crash on an untyped continuation closure; annotated). Scanner initially flagged 11 pre-existing synthetic sentinel fixtures; marker convention added, self-check proves real material is still caught.
- Evidence: `M2_RESULT.md`.

## M3

- Status: PASS.
- Files created: `ProvisionerProtocol.swift` (request/result schema, exit classes, capability manifest, `EngineHost`), `ProvisionerEngineClient.swift` (UI/CLI client, scenario runner/fixture schema), `ScenarioFixtureWorld.swift` (debug-only simulated boundaries), `ProductionComposition.swift`, `Sources/VeyaQualify/main.swift`, `VeyaQualifyTests.swift`, 7 `Fixtures/scenarios/m3-*.json`.
- Files modified: `IOSSimProvisioner/main.swift` (`engine --request` command), `Package.swift` (`VeyaQualify`, debug-only `VEYA_QUALIFICATION`), engine (deterministic ID source, non-mutating inspect, abandoned-transition recovery, candidate in context), repository (`recoverAbandonedTransition`, read-only `load`), planner.
- Defects found by the harness: IMPLEMENTATION_DEFECT planner applied domain allow-list before satisfaction (read-only verify reported satisfied domains blocked) - fixed with regression test; IMPLEMENTATION_DEFECT `load()` created directory/lock on a missing journal - fixed; TEST_DEFECT fixture transition count and over-broad secret marker.
- Tests: focused M2+M3 45/0/0; all 7 scenarios pass via CLI and helper; full Swift 425/14/0.
- Release helper (`swift build -c release`) refuses scenarios with `VEYA-SEC-011` exit 6 and contains no injection symbols.
- Evidence: `M3_RESULT.md`.

## M4

- Status: **BLOCKED — BLUEPRINT_CONTRADICTION / SECURITY_BLOCKER**. Build remains 11.
- Implemented: RSA-2048 generation; PKCS#8 conversion; AES-256-GCM envelope; `0700` directory and `0600` atomic ciphertext file; installation-bound authenticated data; Keychain wrapping-secret backends selected deterministically from signature class; no runtime fallback; candidate create/prove/promote/retire integration.
- Automated evidence: 11 focused tests are defined. The 10 noninteractive tests pass. The remaining real packaged-helper upgrade test is intentionally red because its cross-cdhash login-Keychain read launches SecurityAgent.
- Controlled A/B: the same packaged helper and LaunchServices mechanism produced no SecurityAgent for `protocol-info`; the cross-cdhash M4 wrapper read launched SecurityAgent, took 5.84 seconds, and unified logging reported `SC confirmation dialog detected`. This establishes causality rather than relying on process presence.
- cdhash defect: the test used `codesign -dv`, which does not emit `CDHash` on this macOS. It now uses `codesign -dvvv`, requires a successful inspection, and validates exactly 40 hexadecimal characters. Fresh ad-hoc test apps verify strictly and have distinct cdhashes.
- Journal defect: real `Date` values serialize at millisecond precision. Persistence now verifies and returns the decoded on-disk journal rather than comparing it to the higher-precision in-memory value; the real-clock regression passes.
- Root cause: Apple documents no-UI suppression as Data Protection Keychain-only on macOS; legacy login-Keychain items may activate UI. `securityd` injects a creator-cdhash partition, so a later ad-hoc artifact cannot silently read the item. Repository physical probes independently demonstrate that even an allow-any trusted-app ACL does not bypass the partition.
- Security disposition: no ACL/partition repair, password automation, SecIdentity fallback, search-list mutation, or file-only wrapping secret was added. Test items used randomized installation IDs; the controlled A/B item was deleted by its exact creating artifact. No secret bytes were logged.
- Exit gate: FAIL. M4 requires clean and upgrade matrices with zero SecurityAgent prompts. M5-M12 and Build 12 are not entered while this hard predecessor gate is unresolved.
- Evidence: `M4_RESULT.md`, amended `ADR-001_WRAPPING_SECRET_BACKEND.md`.

## M5

- Status: **SOFTWARE_GATE_PASS / PHYSICAL_BLOCKED_HUMAN** (signer dark; routing is M7).
- Defects: M5-D1 upstream `isideload-vfs` follows symlinks when classifying entries, so symlinks were sealed as files (`-67054`); bundles with symlinks are now refused pre-mutation. M5-D2 packaging could ship a host-only or pre-signer bridge; now refused. M5-D3 MPL-2.0 notices were missing; now generated from `cargo metadata`. M5-D4 lint.
- Tests: Rust 27/0 on arm64 and 27/0 on x86_64 (Rosetta) plus exact-payload 1/0 on each; Swift signer 3/0 against the universal release dylib; key store 10/0; secret scan 0 findings.
- Evidence: `M5_RESULT.md`.
- Blocked: physical install/launch (needs Apple Development certificate/profile + iPhone), clean Intel host, network-denied packaged run.

## M6

- Status: SOFTWARE_GATE_PASS (hermetic) / ROUTING_PENDING / LIVE_BLOCKED_HUMAN.
- Security fix: auth v1 stored the session key as a plaintext file beside the ciphertext (plaintext-equivalent). Auth v2 wraps it with the M4 fail-closed backend under a separate service; memory-only when unavailable; v1 files and quarantine copies purged.
- New: `CertificateReconciliation.swift` (SPKI-only ownership, `OwnedObsoleteCertificate`, 2-issue/1-revoke limits).
- Tests: auth 5/0 (incl. packaged relaunch, no SecurityAgent); certificates 10/0 incl. real-DER SPKI cross-check with OpenSSL.
- Also found: legacy `VeyaSigningKeychain` (Build 11 shipping signer) uses the same password-file-beside-keychain pattern, so the shipping iOS signing key is plaintext-equivalent at rest. It is retired by M7/M11 routing, and M8 must not import it.
- Evidence: `M6_RESULT.md`.

## M7

- Status: SOFTWARE_GATE_PASS (scripted boundaries) / ROUTING_PENDING / PHYSICAL_BLOCKED_HUMAN.
- New: `PayloadTransaction.swift` (`.payload`, `.application`). Fix in `NativeApplicationManagement.swift`: a lost install response is no longer reconciled by version/team inventory when that version was already installed.
- Tests: `PayloadTransactionTests` 8/0; existing install tests 11/0.
- Evidence: `M7_RESULT.md`.

## M8

- Status: SOFTWARE_GATE_PASS (read-only snapshot + ledger); legacy write removal is M11.
- Decision: the legacy key is never imported (its keychain password is a plaintext file); a new key is always created.
- New: `LegacyMigration.swift`; `.migration` composed in `ProductionComposition` ahead of `.signingKey`.
- Tests: `LegacyMigrationTests` 3/0; M1-M4 regression 42/0.
- Evidence: `M8_RESULT.md`.

## M9

- Status: SOFTWARE_GATE_PASS (scripted device) / PHYSICAL_BLOCKED_HUMAN / production DDI BLOCKED_EXTERNAL.
- New: `DeviceDomains.swift`; tests `DeviceDomainsTests` 6/0. Production supported DDI builds: none (enumerated explicitly).
- Evidence: `M9_RESULT.md`.

## M10

- Status: SOFTWARE_GATE_PASS / PHYSICAL_BLOCKED_HUMAN.
- New: `RuntimeReadiness.swift`; journal retention in `InstallationJournalRepository.promote`.
- Tests: `RuntimeReadinessTests` 5/0; engine regression 46/0.
- Evidence: `M10_RESULT.md`.

## M4 resolution pass

- Status: **ROOT CAUSE PROVEN / ARCHITECTURE CONFIRMED / FINAL PROOF BLOCKED_HUMAN**. M4 is not PASS.
- `-34018`: the DP Keychain needs a keychain access group, which only comes from restricted entitlements that AMFI honors only with a matching embedded provisioning profile. Matrix: team-no-entitlements `-34018`; team+restricted-no-profile and ad-hoc+restricted never launch (`amfid -413/-427`); sandbox and app groups `-34018`; no SecurityAgent in any case.
- Fallback not triggered: the DP Keychain provides isolation, no-UI, and cross-cdhash upgrade once profile-authorized.
- Gate test regression fixed: after `.migration` was composed, the packaged gate granted only `[.signingKey]` (`VEYA-STATE-012` masked the M4 signal); it now grants the stage closure and fails with the true `VEYA-KEY-001`.
- Gate extended: `VEYA_M4_SIGN_IDENTITY`/`VEYA_M4_PROFILE`/`VEYA_M4_UNRELATED_PROFILE` run the real packaged helper team-signed with an embedded profile, including the isolation negative.
- Hardening: `withUnlockedPKCS8` disables core dumps before decrypting.
- Packaging requirement for Build 12: the Keychain-accessing helper must be the main executable of a profile-carrying bundle (today it is a bare `Contents/MacOS/IOSSimProvisioner`).
- Evidence: `M4_RESOLUTION_PASS.md`, `evidence/m4-entitlement-matrix.log`, `repro/m4-entitlement-matrix/run.sh`.

## M11

- Status: PARTIAL. Packaging and baseline gates hardened; legacy removal is blocked until the new route is physically proven (spec 04/27) and M4 is resolved.
- Evidence: `M11_RESULT.md`.

## M12 / Build 12

- Evidence: `M12_RESULT.md`, `BUILD_12_GATE_EVALUATION.md`. Build 12 NOT AUTHORIZED.

## Continuation 2026-09-21 (M6-M12 production integration)

- Evidence (the continuation note was not retained in the tree): updated `M6`/`M7`/`M9`/`M10`/`M11`/`M12` results, `BUILD_12_GATE_EVALUATION.md`,
  `HUMAN_GATED_RUNBOOK.md`, `qualification/*.capabilities.json`.
- All 13 domains are composed in `ProductionComposition`; the real helper binary runs the chain through `VeyaQualify`.
- Build remains `11`. No artifact produced. M4 unchanged (fails closed with `VEYA-KEY-001`).

## Physical E2E checkpoint 2026-09-21

- Evidence: `PHYSICAL_E2E_CHECKPOINT_2026-09-21.md`.
- PHYSICAL_PASS (development): Apple auth, Personal Team, certificate, profiles, in-process signing, Installation Proxy
  install on iOS 26.6.2, development DDI, CoreDevice/RSD/RemoteXPC/AppService, main-app launch proof.
- Physical defects fixed with regressions: bridge stack overflow, missing `TeamIdentifier`, stale USB vs live wireless
  route, runner-as-launch-target.
- User actions (not defects): iOS developer trust. Onboarding gaps: LocalDevVPN never prompted; pairing manual.
- Baseline `--defer-m4` PASS: Swift 505/15 skipped/0 failed; Rust 18/0 + 12/0.

## Onboarding pass 2026-09-21

- VPN reconciled before pairing (LocalDevVPN prompt was unreachable); transition user actions reported as user
  actions; untrusted-developer launch denial → Settings trust instruction; dev UI re-observes after failures.
- Tests `DeviceDomainsTests` 9/0; focused suites 125/0; full baseline `--defer-m4` PASS (Swift 508/15 skipped/0 failed).
- Physical E2E after the change NOT_RUN (target iPhone not attached). READY not claimed. M4 DEFERRED.
- Evidence: `PHYSICAL_E2E_CHECKPOINT_2026-09-21.md` § Onboarding pass.

## Physical READY 2026-09-21

- Full chain on `Rishi Borra` (iOS 26.6.2 / 23G90) reached development READY: `runtimeFullChainProof` gen 23, connection 1.
- User actions: Apple sign-in/2FA, LocalDevVPN VPN approval, iOS automation approval. Pairing automatic.
- Fixed: VPN stale-receipt deadlock; runtime pre-approval failure → user action; blank dev status line.
- Baseline `--defer-m4` PASS (Swift 509/15/0). M4 DEFERRED; production DDI BLOCKED_EXTERNAL; Build 12 not authorized.
- Evidence: `PHYSICAL_E2E_CHECKPOINT_2026-09-21.md` § Physical E2E run.

## Clean confirmation run 2026-09-21 22:43

- Rebuilt development package; READY again from scratch: `runtimeFullChainProof` gen 39, connection 1.
- Confirmed physically: immediate VPN re-check (no 600 s wait), LocalDevVPN connect action shown, automatic
  pairing, status-line redraw. Fixed: VPN receipts older than 60 s are stale (reported satisfied while off).
- Baseline `--defer-m4` PASS (Swift 509/15/0). Evidence: `PHYSICAL_E2E_CHECKPOINT_2026-09-21.md` § Clean confirmation run.

## Production DDI investigation 2026-09-22

- Verdict: DDI is a production dependency. Phone Run Setup (DVT dtservicehub) and default Rich Drive (testmanagerd +
  XCTest) need a mounted personalized DDI; the READY probe adds none of its own. The production DDI source decision
  stays open (human/legal).
- Defect 9 fixed (`9e74ad0`): READY proof now requires Core Location to observe a DVT and a Rich Drive coordinate
  (receipt schema 2). Earlier physical READYs proved runner launch and TestManager, not location.
- M11-A (`65cddeb`): unreachable `personal-team-poc` command removed; scanner `--scope all` 16 → 14.
- Baseline `--defer-m4` PASS (Swift 509/15/0). Physical P1–P4 NOT_RUN (iPhone not attached).
- Evidence: `PHYSICAL_E2E_CHECKPOINT_2026-09-21.md` § Production DDI investigation.

## M11-A verification 2026-09-22

- Re-ran `check_legacy_signing_routes.py`: `--scope all` 14 findings/7 files (confirmed, unchanged); `--scope v2` 0.
- 13-vs-14 count discrepancy resolved: the scanner counts distinct `(file, rule-category)` rows, not raw regex
  occurrences; `PersonalTeamProvisioningPOC.swift` removed 2 rows (not 3), so 16 → 14 is correct. Detail: `M11_RESULT.md` § M11-A verification.
- `./iossim installation-baseline --defer-m4`: Overall PASS.
- `graphify update .`: no topology change; 37,066 nodes · 90,886 edges · 1,224 communities.
- M11-B unchanged: still blocked on M4 + physical proof of the route switch.

## Physical E2E confirmation 2026-09-22 23:23–23:25 EDT

- **PHYSICAL_PASS** on commit `073d4a9`, clean source tree: Install / Prepare → LocalDevVPN recovery →
  automatic pairing → READY FOR SETUP → user Run Setup → Continue / Verify Setup → READY.
- The local journal ended at revision 813 / generation 66 with no candidates: application gen 63,
  `vpnFreshObservation` gen 64, `pairingFreshObservation` gen 65, and `runtimeFullChainProof` gen 66.
- The setup receipt used the non-mutating `sessionProbed` proof; no setup-time location spoofing was performed.
- Approximately three visible Veya open/close cycles remain a UX-polish investigation. Correctness is proven;
  no reconciliation, pairing-protocol, DDI, receipt-binding, runtime, M4, distribution, or M11 change is implied.
- Evidence: `PHYSICAL_E2E_CHECKPOINT_2026-09-22.md` § Clean post-change physical confirmation.

## Safe UX polish prepared for physical retest — 2026-09-23

- The development primary action now has three presentation states — `Install / Prepare`, `Continue`,
  and `Continue / Verify Setup` — with Run Setup continuation taking precedence over any other
  recoverable user action. Every state still dispatches exactly `EngineCommand.reconcile`.
- Canonical unlock, trust, Developer Mode/restart, developer-profile trust, LocalDevVPN install/
  permission/connect, and Apple sign-in/device-selection actions use `Continue` and end with
  “then continue in Veya.” Failures without a `userAction` remain `Install / Prepare`.
- Automatic pairing now polls the bootstrap response before activation. A live inbox watcher adds no
  launch; a missing response invokes the existing destructive activation exactly once as a reliability
  fallback. Pairing cryptography, proof, promotion, receipts, and later escalation are unchanged.
- `./iossim installation-baseline --defer-m4`: **Overall PASS**. Focused presentation and pairing
  activation tests also pass. One final physical iPhone retest remains required; this entry does not
  upgrade the polish changes to `PHYSICAL_PASS`.

## Target-A private test DMG — 2026-09-23

- Packaged the exact physically proven universal `Veya Development.app` from clean source HEAD
  `6a0c7e8` without rebuilding, resigning, launching, or changing runtime behavior.
- Reused the existing `create_release_dmg()` path with optional volume/app naming; existing release
  defaults are unchanged. Focused DMG tests 3/3 PASS; full baseline `--defer-m4` PASS.
- `Veya-Test-6a0c7e8.dmg`: 33,129,986 bytes; SHA-256
  `e8bc2c0148394f105ed753f47cb7620bd6c205697670f0693d1543742848a92a`; volume `Veya Test`;
  exactly `Veya Development.app` plus `Applications -> /Applications`.
- Source, mounted, and copied-back apps all pass strict code-sign verification, universal architecture
  checks, payload integrity, and per-file byte comparison. No credentials, private keys, pairing/auth
  state, DDI cache, logs, or Application Support state are included.
- Target A remains ad-hoc/private: Gatekeeper user approval, network development-DDI acquisition,
  external LocalDevVPN installation, and M4-deferred relaunch behavior are expected.
- Evidence and clean-Mac handoff: `TARGET_A_PRIVATE_TEST_DMG_2026-09-23.md`.
