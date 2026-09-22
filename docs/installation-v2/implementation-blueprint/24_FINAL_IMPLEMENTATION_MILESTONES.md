# Final Implementation Milestones

Every exit gate is binary. "Mostly passes" means blocked.

The exact production/test paths for every module are listed in doc 22. The manifest below makes every required milestone field explicit; detailed algorithms and binary exit tests follow it.

| Milestone | Files modified / created / removed | Public interfaces | State migration | Integration, regression, failure, security | Blocker / rollback |
|---|---|---|---|---|---|
| M0 | bootstrap/check scripts; create toolchain pin; remove none | baseline command | none | all existing Swift/Rust/iOS/check suites, missing-tool faults, dependency audit | tool incompatibility / revert tooling only |
| M1 | create domain/event/failure/journal files/tests; current stores untouched | models, event sink, journal repository | adapters read current schemas | journal concurrency/crash/corrupt/disk-full + secret tests | schema flaw / new modules unrouted |
| M2 | create engine/planner/observer/transition files/tests; modify service protocols | inspect/reconcile/cancel, observer/transition | current state observed through adapters | property/idempotency/cancel/retry regression; destructive-policy review | unsafe plan / retain current route |
| M3 | modify provisioner/package/client; create protocol/qualifier/tests; replace Python logic later | provisioner commands + qualify CLI | none | packaged helper, capability refusal, resume, UI/CLI equivalence | protocol issue / remove unrouted CLI |
| M4 | create key store/envelope/tests; legacy keychain becomes reader | inventory/create/withUnlocked/import/retire | candidate import only | real packaged create/reopen/upgrade/corruption/no-UI + permissions/zeroization | prompt/access failure / no candidate promotion |
| M5 | create Rust workspace/signing core/FFI/tests; modify bridge/header/lock | sign/inspect/verify/cancel ABI | none | golden nested bundles, fuzz/malformed, both arches, exact physical install; MPL review | signer mismatch / keep path dark |
| M6 | split Apple live code; create auth/team/cert/profile services/tests | observe/auth/team/reconcile/profile APIs | AUTH v1 read; cert metadata hints | all Apple fixtures, 7460 limits, unknown safety, schema drift, secret review | Apple behavior / unrouted services |
| M7 | split artifact provisioner; create transaction/tests; modify installer composition | transact/observe/prove | current manifest read into journal | actual signer + fake/physical install, disconnect/expiry/rollback | restore limitation / active remains |
| M8 | create migration reader/coordinator/tests; modify ProductBrand; remove legacy writes | inventory/migrate/resume | full item ledger | Build1-11 fixtures, partial/downgrade/no dual write, prompt prohibition | unknown legacy state / pre-promotion old active |
| M9 | modify bridge/DDI/pair/VPN; add provider/envelope tests | bounded domain observe/transition APIs | pairing service import | ABI + safe device + replay/reboot/endpoint/DDI integrity, pairing secret review | DDI source / scope builds or stop |
| M10 | modify Rich/readiness/provisioner; add chain tests | prove/invalidate readiness | old READY ignored | every broken link/wrong target/stale/cleanup/restart + physical proof | service drift / report not ready |
| M11 | modify package/build/check/SBOM; remove signer files/helpers/fallback | artifact gate reports | require migration completion before cleanup | universal/mounted/no-tool/static/runtime/secret/license/security audit | Intel/package defect / no release artifact |
| M12 | scenario fixtures/reports/tests only | scenario campaign | exercises all migration states | complete master matrix, repeatability, P0/P1 triage | any required failure / return to owner milestone |
| M13 | release metadata/package scripts only after authorization | immutable artifact identity | none | rerun M11 against mounted Build 12 | gate revoked / withdraw build, never reuse number |
| M14 | qualification reports only | physical result schema | exercises live migrations/reinstalls | doc 26 matrix and security/user-interaction observation | Apple/external defect / block release |

## M0 Development Environment

- Objective: reproducible Swift/Rust/iOS baseline.
- Entry: frozen Build 11 tree. Files: new `rust-toolchain.toml`; modify bootstrap checks. No state migration.
- Steps/tests: pin tools; fix rustup discovery; run all baselines, formats, lints, both host targets and iOS target.
- Security/faults: dependency/license/SBOM baseline; missing tool/target tests.
- Exit: every item in `00_DEVELOPMENT_ENVIRONMENT_GATE.md` passes.
- Rollback/risk: revert tooling files; risk is Xcode/Rust compatibility.

## M1 Canonical State, Event, Journal

- Objective: one durable model and atomic repository.
- Entry: M0. Create domain/event/failure/journal files and tests; do not route UI yet.
- Steps: schemas, invariants, lock/lease, atomic writes, migration adapter for current stores.
- Tests/faults: model encoding, concurrency, disk full, partial write, corruption, stale lease, secret canaries.
- Exit: exhaustive journal fault suite proves old-or-new valid state and stable first failure.
- Rollback: unused new module removal. Risk: schema overreach.

## M2 Reconciliation Engine

- Objective: pure observer/planner/one-transition loop.
- Entry: M1. Create planner/engine/transitions; adapt existing services behind protocols.
- Tests: all state edges, property/idempotency/cancellation/retry/generation tests; no external mutation.
- Exit: every modeled reinstall/failure snapshot produces a deterministic safe plan and passes invariants.
- Rollback: keep existing route while engine is dark. Risk: duplicate ownership during transition.

## M3 Production-Driven Qualification Harness

- Objective: UI and CLI use same provisioner/engine protocol.
- Entry: M2. Create `VeyaQualify`, protocol, packaged contract tests; modify provisioner/client.
- Tests/faults: command/JSON/exit/capability/resume/actual packaged helper tests.
- Exit: a scenario trace is byte-equivalent whether initiated by UI test client or CLI.
- Rollback: CLI target removal. Risk: helper protocol compatibility.

## M4 Signing Key Store

- Objective: encrypted PKCS#8 candidates with wrapping-only Keychain.
- Entry: M1/M3 packaged harness. Create key store/envelope; legacy store remains read-only.
- Tests/faults: generate/reopen/sign probe/corrupt/missing wrapper/file/upgrade/reinstall/no UI; real packaged helper.
- Security: permissions, symlink, zeroization, dump, multi-user review.
- Exit: clean and upgrade test matrices show zero SecurityAgent prompts and noninteractive failure semantics.
- Rollback: no promotion; legacy active untouched. Blocker: data-protection Keychain upgrade access failure.

## M5 In-Process Signer

- Objective: actual Rust signing path for complete bundle graph.
- Entry: M0. Add workspace/signing core/FFI and license/SBOM.
- Tests/faults: all golden bundles, malformed graph, nested code, entitlements, verification, both Mac arches, network-off packaged test.
- Exit: exact Veya payload independently verifies and physically installs/launches on qualification device under controlled test certificate; no codesign call.
- Rollback: signer stays dark; old product unchanged. Risk: apple-codesign nested code behavior.

## M6 Apple Auth, Team, Certificate, Profile Reconciliation

- Objective: narrow services and ownership-safe bounded recovery.
- Entry: M2/M4. Split live backend; implement certificate planner and auth v2 storage.
- Tests/faults: auth/2FA/session, no team, 7460, stale inventory, unknown/owned/second Mac, API ambiguity, profile fixtures.
- Exit: hermetic scenario campaign passes exact call limits; no unknown revocation is expressible.
- Rollback: new APIs unrouted. Risk: private Apple API drift.

## M7 Profile-Sign-Install Transaction

- Objective: production candidate pipeline and independent proof.
- Entry: M2/M5/M6/device install primitives.
- Tests: staging/sign/verify/install ambiguity/inventory/launch/rollback, profile expiry, disconnect.
- Exit: production engine completes synthetic and permitted device candidate transaction while preserving active on every injected failure.
- Rollback: leave candidate, current active remains. Risk: same-bundle iOS replacement rollback.

## M8 IOSSim Migration

- Objective: one-way readers, no legacy writes/fallback.
- Entry: M7. Add migration ledger/readers; route Veya v2 persistence.
- Tests: every legacy combination and crash boundary, nonexportable keys, partial migration, downgrade.
- Exit: sanitized Build 1-11 fixtures migrate idempotently and legacy write audit is empty.
- Rollback: pre-promotion legacy remains. Risk: unknown historic identifiers.

## M9 Device, DDI, Pairing, VPN Reconciliation

- Objective: integrate surviving domains into canonical engine.
- Entry: M2/M3. Narrow bridge, provider, candidate pairing, exact VPN states.
- Tests: ABI, safe physical observations, exact DDI fixtures, replay/wrong device, reboot/restart, endpoint challenge.
- Exit: all domain scenarios pass; production DDI supported-build policy is explicit.
- Rollback: active pairing/VPN retained. Blocker: production DDI source may remain external.

## M10 Runtime Readiness

- Objective: only fresh full-chain proof yields READY.
- Entry: M7/M9. Bind receipts/generation and remove cached READY paths.
- Tests: every broken link, wrong target/runner, stale evidence, clear failure, restart invalidation.
- Exit: READY is unreachable in tests without live proof object; permitted device full proof succeeds.
- Rollback: report not ready. Risk: physical TestManager/AppService drift.

## M11 Packaging and Legacy Removal

- Objective: release composition contains only new production signer/state path.
- Entry: M8/M10. Modify package/scripts/SBOM; delete old writes/fallbacks after tests.
- Tests: universal, mounted-copy-equivalent staging audit, no tools/repo, strings/static call audit, secret scan.
- Exit: all gates in doc 20 pass; source search and runtime trace show no payload codesign/SecIdentity/search-list path.
- Rollback: before deletion use source branch, not runtime fallback. Risk: Intel-only packaging defects.

## M12 Automated Scenario Campaign

- Objective: full failure/reinstall/migration campaign on production engine.
- Entry: M11. Run master matrix in isolated roots, clean users/VMs, both architectures where available.
- Exit: 100% required scenarios pass, zero unexplained skips, zero P0/P1, deterministic reports archived.
- Rollback: fix responsible milestone; no Build 12.

## M13 Build 12

- Objective: create one deliberate qualification candidate.
- Entry: signed approval that doc 25 is satisfied. Increment/package once; do not change architecture here.
- Exit: mounted artifact identity/gates reproduce M11 and is archived.
- Rollback: withdraw candidate; never silently rebuild same build number.

## M14 Physical Qualification

- Objective: execute doc 26 matrix.
- Entry: immutable Build 12 artifact. Tests include fresh/reinstall/migration/reboots/capacity/second Mac/expiry recovery.
- Exit: all P0/P1 rows pass; deviations produce defects and a new gated candidate, never an in-place Build 12 mutation.
- Risk: Apple/device/environment limits; confidence is scoped to tested matrix.
