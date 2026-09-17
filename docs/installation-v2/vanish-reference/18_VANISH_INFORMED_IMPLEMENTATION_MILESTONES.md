# Vanish-informed implementation milestones

Milestones are dependency ordered. A milestone may be developed in parallel only when its acceptance gate does not consume an unsettled interface. `DS` is intentionally blocked until the DDI source decision.

## V0 — Freeze contracts and the DDI product decision
- **Objective / why / Vanish behavior:** approve this behavioral reference, release authority, LocalDevVPN external policy, and a DDI source option; Vanish makes each dependency concrete.
- **Components/files/new files:** docs/ADRs and dependency/license register only; create implementation ADRs and provider threat model.
- **Dependencies / steps:** none; product/legal/security review the observed doronz88 mechanism and alternatives; choose supported OS/device range.
- **Tests:** evidence-link and contradiction review; no code/physical test.
- **Acceptance/failure gate:** signed decisions with owner/SLA/license/provenance. Failure or defer keeps `DS` and shipping readiness blocked.
- **Rollback/security/migration/UX:** decisions can be superseded by ADR; no user change.

## V1 — Canonical artifact truth
- **Objective / why / Vanish behavior:** make one identifiable self-contained artifact before changing setup; matches Vanish's packaged resource boundary.
- **Files/new files:** `ArtifactManifest.swift`, `iossim_cli.py`, `build_app.sh`; add release auditor/manifest schema/SBOM fixtures.
- **Dependencies / steps:** V0 naming/authority; unify assembler, derive facts from final mounted DMG, verify nested artifacts, then sign/notarize/publish later.
- **Tests:** mutated architecture/schema/hash/signature/commit fixtures; artifact tests on local DMG.
- **Acceptance/failure:** no desired value can disagree with bytes; current arm64/universal and schema mismatches are caught. Any unknown component fails closed.
- **Rollback/security/migration/UX:** old builder read-only for one release; supply-chain manifest signed; user sees version/build/commit/hash.

## V2 — Hermetic installation regression harness
- **Objective / behavior:** protect existing capability while refactoring; models Vanish's separable commands without running vendor code.
- **Files/new files:** Mac tests, `POCUnitChecks`, check scripts; add fake Apple/device/Keychain/process/filesystem clocks and artifact fixtures.
- **Dependencies/steps:** V1 schemas; eliminate real-store defaults, encode current pass/fail baseline, add saved-log failure ownership.
- **Tests:** all safe unit/synthetic/source tests; no real account/device/Keychain.
- **Acceptance/failure:** zero accidental external access and deterministic parallel runs; unexplained failure blocks downstream merge.
- **Rollback/security/migration/UX:** test-only; provides safety net, no UX.

## V3 — Production engine and helper integrity boundary
- **Objective / behavior:** packaged app always uses its bundled installer like Vanish resolves packaged resources.
- **Files/new files:** `IOSSimSetupEngine`, `BundledProvisioningEngine`, `SetupStore`, provisioner main, doctor models; add protocol envelope.
- **Dependencies/steps:** V1–V2; implement handshake/integrity/framing/cancel; normalize helper-unavailable errors; keep legacy adapter.
- **Tests:** tamper/path/protocol/timeout and packaged source scans; mounted DMG helper invocation.
- **Acceptance/failure:** no consumer repo/Xcode/dev engine route; helper mismatch yields `VEYA-INTEGRITY`, never “find doctor.”
- **Rollback/security/migration/UX:** prior protocol adapter one release; bounded JSON/no secrets; clearer repair action.

## V4 — Durable keyed state and cross-process lease
- **Objective / behavior:** resume safely after crash/reboot and isolate device/team/release.
- **Files/new files:** state/artifact stores, `ConsumerProvisioning.swift`, provisioner; add lease/journal/migrator.
- **Dependencies/steps:** V2–V3; define setup key, atomic storage, CAS, invalidation, schema-4 import, operation recovery.
- **Tests:** concurrent helpers, SIGKILL boundaries, disk full/corruption, multi-device/team, migration.
- **Acceptance/failure:** one writer per key, no lost update/cross-key read, live reconciliation restores state.
- **Rollback/security/migration/UX:** preserved schema-4 backup; 0700/no secrets; user resumes smallest step.

## V5 — Native first-time computer Trust
- **Objective / behavior:** complete a never-trusted iPhone without Xcode while preserving Apple's prompt, matching Vanish's guided Trust.
- **Files/new files:** bridge Swift/header/Rust, models/tests; add pair ABI receipts.
- **Dependencies/steps:** V3–V4; exact mux selection, `pair_once`, wait/poll, persist, session validate, denial/disconnect mapping.
- **Tests:** fake records and Rust/ABI tests; physical never-trusted, denial, passcode, reconnect, multi-record.
- **Acceptance/failure:** `NO_PAIR_RECORD -> PAIR_REQUESTED -> WAITING_FOR_USER_TRUST -> PAIRED -> VALIDATED`; no prompt bypass or pair-record export.
- **Rollback/security/migration/UX:** existing valid pair record untouched; ABI v1 retained; exact Trust instruction.

## V6 — Approved developer-support provider (`DS`, blocking)
- **Objective / behavior:** reproduce Vanish's on-demand DDI outcome through an approved Veya source.
- **Files/new files:** developer-support coordinators/provider implementations/cache/provenance; provider-specific policy and fixtures.
- **Dependencies/steps:** V0 approval, V4, V5; readiness-first, exact-build acquire/verify, TSS/mount, quarantine/revocation, receipt.
- **Tests:** provider/TSS/cache failure corpus and artifact tampering; physical cleared cache, new supported build, offline cache, outage.
- **Acceptance/failure:** source/provenance/rights/license approved and clean-machine RSD/AppService works. Mirror fallback or developer-Mac cache dependence fails.
- **Rollback/security/migration/UX:** provider kill switch and cached-known-good policy; no unverified execution; “online Apple setup” progress.

## V7 — Exact native device and install parity
- **Objective / behavior:** ensure current native backend matches Vanish's reliable device selection/install responsibility.
- **Files/new files:** bridge, `NativeApplicationManagement`, provisioner tests.
- **Dependencies/steps:** V4–V5; fix `(UDID,mux)` selection; operation/artifact receipts; inventory before/after; reconcile interrupted staging.
- **Tests:** duplicate USB/Wi-Fi order, staged install faults, unknown app; physical install/upgrade/disconnect.
- **Acceptance/failure:** exact selected device and exact signed bundle verified; any ambiguous connection or unknown ownership blocks mutation.
- **Rollback/security/migration/UX:** retain installed known-good when possible; no uninstall fallback; repair only stale bundle.

## V8 — Apple Personal Team adapter hardening
- **Objective / behavior:** provide in-app account/2FA/team/provisioning like Vanish while containing private-protocol risk.
- **Files/new files:** Personal Team experimental/live, models; add stable service and versioned adapter modules/fixtures.
- **Dependencies/steps:** V2–V4; extract adapter, fingerprint schemas, classify errors/idempotency, kill switch, read-before-create.
- **Tests:** offline response/error fixtures, redaction, retry; opt-in Personal Team physical/service matrix.
- **Acceptance/failure:** SetupStore sees only stable domains; protocol drift produces compatibility error without resource churn.
- **Rollback/security/migration/UX:** previous adapter disabled fallback; ephemeral secrets/Keychain sessions; explicit 2FA and limits.

## V9 — Signing identity, profile, and artifact lifecycle
- **Objective / behavior:** deterministic reuse and staged renewal, matching Vanish's automated sign/install.
- **Files/new files:** signing resolver, provisioner, profile/artifact stores; add candidate lifecycle/renewal scheduler.
- **Dependencies/steps:** V4, V8; inventory active resources, create candidates, verify codesign access, prepare profiles, sign nested-first, validate recursively, promote after install proof.
- **Tests:** mocked Security/profile limits/entitlement mutations/expiry; isolated Keychain and physical renewal.
- **Acceptance/failure:** no active key/profile removed before candidate success; exact team/device/App IDs verified.
- **Rollback/security/migration/UX:** managed tags/reference cleanup; old active retained through grace; show expiry/repair precisely.

## V10 — Staged automatic RemotePairing
- **Objective / behavior:** preserve Vanish-like automatic repair with stronger Veya proof.
- **Files/new files:** `RemotePairingLifecycle`, `AutomaticPairingInbox`, app lifecycle, wire models/tests.
- **Dependencies/steps:** V4, V7; candidate slots, fresh request material, bound transcript/receipt, phone challenge, operational proof, atomic promotion, grace deletion.
- **Tests:** crypto vectors, replay/wrong phone/request, every crash edge; physical initial/forced repair/reboot.
- **Acceptance/failure:** active record survives all pre-promotion failures; selected phone proves possession and developer-service use.
- **Rollback/security/migration/UX:** import current record as active; abort candidate; pairing secrets never exported.

## V11 — LocalDevVPN consumer lifecycle
- **Objective / behavior:** make the external dependency visible and resumable instead of mysterious.
- **Files/new files:** coordinator/inbox/app lifecycle/models; add inventory/action/authenticated readiness interfaces.
- **Dependencies/steps:** V4, V7, V10; detect version, guide App Store, launch, request setup, wait Apple consent, verify endpoint and developer path.
- **Tests:** missing/version/permission/replay/scene lifecycle; physical App Store install, approve/deny, restart.
- **Acceptance/failure:** six-state lifecycle is observable; TCP reachability alone cannot mark ready.
- **Rollback/security/migration/UX:** existing VPN config untouched; no consent bypass; exact user action displayed.

## V12 — Developer-services and AppService operational proof
- **Objective / behavior:** turn DDI/tunnel readiness into a verified launch path as Vanish does before runtime.
- **Files/new files:** native coordinator/bridge/application management/provisioner; add expiring receipts.
- **Dependencies/steps:** V6–V7; verify CoreDeviceProxy, tunnel, RSD, RemoteXPC, AppService feature, launch exact main/runner and classify profile trust.
- **Tests:** each staged error and receipt expiry; physical main and runner AppService launches.
- **Acceptance/failure:** live complete receipt bound to device/build/release; manual phone launch is insufficient.
- **Rollback/security/migration/UX:** reconnect invalidates only dependent states; guided profile trust.

## V13 — Rich runtime readiness proof
- **Objective / behavior:** READY means Veya's actual value path works, beyond Vanish's generic connection-ready signal.
- **Files/new files:** `DvtLocationClient`, runtime support, provisioner/models; add `RuntimeVerificationService`.
- **Dependencies/steps:** V10–V12; start exact runner via retained RSD, reach TestManager control, perform bounded location write/observe/clear, stop and sign receipt.
- **Tests:** fake stage/timeouts/cleanup and scheduler regressions; physical Rich run.
- **Acceptance/failure:** proof bound to device/release/pairing/profile with TTL; any un-cleared location or fallback-only result fails READY.
- **Rollback/security/migration/UX:** always clear/stop; preserve current runtime semantics; READY becomes honest.

## V14 — Repair, refresh, and renewal orchestration
- **Objective / behavior:** answer what failed and repair only it, matching Vanish's reconnect/repair polish.
- **Files/new files:** provisioner, state models, SetupStore; add domain invalidation/recovery scheduler.
- **Dependencies/steps:** V4–V13; implement expiry watches, reconciliation on launch/reconnect, candidate renewals, old-version/wrong-team policy.
- **Tests:** time travel, session/profile expiry, update, crash/reboot/disconnect; physical expiry/renewal/reinstall.
- **Acceptance/failure:** every scenario in doc 15 preserves independent good state and resumes deterministically.
- **Rollback/security/migration/UX:** disable background repair while retaining manual reconcile; no silent destructive fix.

## V15 — Error and support-bundle contract
- **Objective / behavior:** match Vanish's actionable domain errors while exceeding its secret-safety guarantees.
- **Files/new files:** DoctorStatus, SupportBundleExporter, SetupStore; add stable catalog/schema 8/scanner.
- **Dependencies/steps:** V3–V14 error sources; map codes/actions, allowlist diagnostics, alias identities.
- **Tests:** catalog completeness, snapshots, golden bundles, adversarial secrets.
- **Acceptance/failure:** every terminal path has stable code/action/correlation; zero forbidden material.
- **Rollback/security/migration/UX:** support schema versioned; exporter refuses unsafe output; support can identify release.

## V16 — Legacy isolation and removal
- **Objective / behavior:** enforce Vanish-like self-contained consumer boundary.
- **Files/new files:** factory/backend/runtime/helper/build/checks; development-only compatibility target if required.
- **Dependencies/steps:** V3, V5–V15 parity; remove consumer DevelopmentCLIEngine, repo lookup, Xcode/devicectl/xcodebuild, env selectors, ambiguous helper fallback; retain migration readers.
- **Tests:** source/binary string/dependency scans and full regression/physical matrix.
- **Acceptance/failure:** canonical app cannot route to legacy mechanisms; removal waits for native physical parity.
- **Rollback/security/migration/UX:** signed prior release is rollback; no runtime hidden fallback; simpler failures.

## V17 — Canonical signed/notarized distribution and update
- **Objective / behavior:** deliver one Vanish-like identifiable app/DMG and verified update.
- **Files/new files:** release tooling/manifests/docs; add publisher/download verifier/update feed policy.
- **Dependencies/steps:** V1 and all shipping components; universal vs per-architecture ADR, sign nested-out, notarize/staple, mount/audit, draft publish, download/re-audit, promote.
- **Tests:** release mutation suite and final artifact checks; clean Macs/minimum OS/Gatekeeper/update/rollback.
- **Acceptance/failure:** `Veya-<semver>-build<build>-<sha>.dmg`; actual facts match signed manifest; any mismatch fails release.
- **Rollback/security/migration/UX:** immutable prior release; protected credentials; one authority/support identity.

## V18 — IOSSim-to-Veya migration
- **Objective / behavior:** change product identity only after installation reliability is proven.
- **Files/new files:** bundle/display names, paths, manifests, migrations, docs; exact list approved separately.
- **Dependencies/steps:** V14–V17; inventory identifiers/signing assumptions, preserve bundle IDs initially unless separate ADR, copy/migrate state transactionally, support rollback.
- **Tests:** old-to-new upgrade, side-by-side conflicts, Keychain access, installed phone artifacts, support identity.
- **Acceptance/failure:** no lost pairing/signing/profile/user state and no ambiguous release identity.
- **Rollback/security/migration/UX:** migration journal/backups; signed prior app can recover; user sees one Veya identity.

## V19 — Final physical qualification
- **Objective / behavior:** establish evidence Vanish static analysis cannot provide.
- **Files/new files:** qualification records only unless defects found.
- **Dependencies/steps:** V17–V18 and approved DDI; execute clean Mac/user/device/account/network/expiry/update matrix.
- **Tests:** fresh Trust, cleared DDI cache, AppService, pairing repair, VPN approval, Rich proof, reboot, renewal, final DMG.
- **Acceptance/failure:** every required row has artifact/release-bound evidence; any blocker returns to owning milestone.
- **Rollback/security/migration/UX:** use controlled accounts/devices and scrub records; produces release go/no-go.
