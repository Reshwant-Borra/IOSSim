# Consolidated implementation plan

Build 12 is deliberately absent. A new integration build is authorized only after Milestones 1-8 and their lower-layer gates pass.

## Milestone 1: canonical engine, journal and events

- **Objective:** make one production reconciliation engine authoritative and emit the observability envelope before changing behavior.
- **Production files:** refactor `SetupStore.swift`, `IOSSimSetupEngine.swift`, `KeyedSetupStateStore.swift`, `ConsumerProvisioningStateStore.swift`, `ReadinessRecovery.swift`, `ConsumerProvisioning.swift`, `VeyaDiagnostics.swift`, `BundledProvisioningEngine.swift`, `IOSSimProvisioner/main.swift`.
- **New files:** `InstallationEngine.swift`, `InstallationJournal.swift`, `InstallationOperationEvent.swift`, `InstallationPorts.swift`.
- **Test files:** replace state-order assertions in `SetupStoreTests.swift`/`ConsumerProvisioningTests.swift`; add `InstallationEngineTests.swift`, `InstallationJournalTests.swift`, `InstallationEventCompletenessTests.swift`.
- **Old paths removed:** UI-owned transition decisions; test-local stage enum as source of truth; top-level error collapse without terminal operation event.
- **Migration:** current manifests/journals are read into a compatibility snapshot, not rewritten yet.
- **Unit/integration/physical:** exhaustive transition/crash tests; packaged helper event smoke test; no device mutation.
- **Entry gate:** architecture documents accepted; current tests captured.
- **Exit gate:** all canonical edges/errors covered; UI/CLI only project engine state; first-failure invariant enforced.
- **Rollback:** feature flag selects old orchestration while new engine runs inspect-only shadow mode.
- **Risks:** temporary dual-engine drift; mitigate by prohibiting new behavior in shadow path and differential tests.

## Milestone 2: production-driven qualification harness

- **Objective:** stage execution, fixtures and fault injection drive Milestone 1 production code.
- **Production files:** `macos/Package.swift`, engine composition, `IOSSimProvisioner/main.swift` as shared command library.
- **New files:** `Sources/VeyaQualification/main.swift`, `QualificationRunStore.swift`, `QualificationScenario.swift`; `tools/qualification/scenarios/*.json`.
- **Test files:** replace `HermeticInstallationHarnessTests.swift` internals with `InstallationQualificationScenarioTests.swift`; add run/redaction/prompt-sentinel tests.
- **Old paths removed:** test-local `HermeticInstallationEngine`; hard-coded Build 3 status generation in `VeyaPhysicalQualification.py` after parity.
- **Migration:** historical live reports remain read-only; new runs use unique directories/run IDs.
- **Unit/integration/physical:** all fixture scenarios; safe `inspect` and device discovery on current phone; no Apple/device destructive changes.
- **Entry gate:** Milestone 1 stable ports/events.
- **Exit gate:** A-W and failure matrix address production transitions; run report proves executable hashes and first failure.
- **Rollback:** CLI can be removed without changing app flow; event schema retained.
- **Risks:** accidentally using live adapters; live mutation requires explicit scenario permissions and exact device alias.

## Milestone 3: in-process signer and secure key store

- **Objective:** implement the ADR behind a disabled feature flag and qualify it independently.
- **Production files:** native bridge Cargo manifest/source, Swift native bridge wrapper, `ApplePersonalTeamLive.swift` interfaces, artifact preparation/signing abstractions.
- **New files:** Rust signer module and C ABI; `InProcessPayloadSigner.swift`, `VeyaSigningIdentityStore.swift`, `SignedArtifactManifest.swift`, dependency/security record.
- **Test files:** `InProcessPayloadSignerTests.swift`, `SigningIdentityStoreTests.swift`, native Rust tests, synthetic nested iOS fixture and tamper tests.
- **Old paths removed:** none yet; no production default change.
- **Migration:** none; new store uses isolated test roots and fixture identities.
- **Unit/integration/physical:** deterministic bundle traversal, entitlements/profile validation, independent `/usr/bin/codesign` verification as test oracle, Intel/Apple Silicon; safe signing does not touch phone/account.
- **Entry gate:** Milestones 1-2; signer dependency/license/security approval.
- **Exit gate:** exact shipped signer passes synthetic nested fixture on both architectures with no Keychain search-list change or prompt.
- **Rollback:** feature flag off; old signer untouched.
- **Risks:** apple-codesign compatibility, ABI/memory handling, license/supply chain, unusual nested code.

## Milestone 4: identity and certificate reconciliation

- **Objective:** adapt Apple issuance/reuse/capacity logic to encrypted key fingerprints and complete the recovery matrix.
- **Production files:** `ApplePersonalTeamLive.swift`, `ApplePersonalTeamExperimental.swift`, diagnostics, journal/resource ledger.
- **New files:** `CertificateReconciler.swift`, `CertificateOwnershipLedger.swift`, `SigningIdentityTransaction.swift`.
- **Test files:** extend Apple/Capacity tests; add every missing-key/metadata/cert/multi-Mac/7460/crash cell through production engine.
- **Old paths removed:** fresh production calls to `SecKeyCreateRandomKey`, SecIdentity persistence assumptions, metadata as sole join. ACL code remains legacy-only.
- **Migration:** legacy identity inventoried read-only; target identity created as candidate; exact ownership markers preserved.
- **Unit/integration/physical:** hermetic Apple fixtures first; live Apple path only with explicit account scenario and before/after inventory, no unknown revoke.
- **Entry gate:** signer/store proof passes.
- **Exit gate:** all identity Cartesian states yield deterministic reuse/repair/replace/fail-safe decisions; same-CSR 7460 retry bounded.
- **Rollback:** retain legacy active identity and old installed apps; do not promote candidate until usable.
- **Risks:** Apple private API drift, propagation delay, certificate quota, other-Mac harm. Fail closed on ownership uncertainty.

## Milestone 5: profiles, signing and install transaction

- **Objective:** make the new signer the candidate path from profiles through authoritative installation.
- **Production files:** `ConsumerArtifactProvisioner.swift`, `NativeSigningIdentityResolver.swift`, `NativeApplicationManagement.swift`, `NativeProvisioningArtifactStore.swift`, engine.
- **New files:** `ArtifactSigningTransaction.swift`, `InstallationTransaction.swift` if separation cannot be achieved cleanly in existing owners.
- **Test files:** signing integration, profile matrices, interrupted upload/install and inventory reconciliation.
- **Old paths removed:** production `/usr/bin/codesign` and SecIdentity lookup/probe; Xcode signing fallback from consumer composition; global signing Keychain search-list mutation.
- **Migration:** legacy installed app stays active until target-signed upgrade inventories and launches.
- **Unit/integration/physical:** synthetic signing; safe install on designated phone only after signed-output gate; profile trust classification.
- **Entry gate:** Milestone 4 identity candidate ready.
- **Exit gate:** new signed main/runner install, inventory, entitlements/team/profile and launch prove on supported iOS; no SecurityAgent.
- **Rollback:** preserve prior phone app/data and legacy identity through validation; rollback app feature flag before promotion.
- **Risks:** signature format accepted by local verifier but rejected by iOS; mitigate with actual device gate before default.

## Milestone 6: IOSSim/Veya one-time migration

- **Objective:** stop indefinite dual-location compatibility behavior.
- **Production files:** `ProductBrand.swift`, state stores, authorization/pairing/signing stores, packaging manifests.
- **New files:** `LegacyIOSSimInventory.swift`, `VeyaMigrationCoordinator.swift`, `MigrationReceipt.swift`.
- **Test files:** every retained identifier/schema; corrupt/missing/partial legacy combinations; rollback and second-run idempotency.
- **Old paths removed:** writes to legacy signing metadata and signing Keychain; active use of ProvisioningWork/Xcode caches; repeated compatibility migration on every launch.
- **Migration:** inventory, validate, import, candidate reinstall/runtime proof, promote; retain read-only legacy rollback state for one window.
- **Unit/integration/physical:** fixture legacy roots, a real prior IOSSim/Veya contaminated account, reinstall and upgrade on clean account.
- **Entry gate:** new install path ready.
- **Exit gate:** migration runs once, is idempotent, no prompt, no unknown deletion/revoke, and current runtime works.
- **Rollback:** migration receipt points to untouched legacy roots and installed app version.
- **Risks:** ambiguous pairing services and bundle-ID coupling; resolve inventory before code removal.

## Milestone 7: unify device-to-runtime readiness

- **Objective:** put Trust, Developer Mode, install, DDI, pairing, VPN, RSD, AppService and Rich proof under canonical domains.
- **Production files:** `NativeDeviceBridge.swift`, `NativeLockdownPairing.swift`, `DeveloperSupportCoordinator.swift`, `NativeDeveloperServicesCoordinator.swift`, `RemotePairingLifecycle.swift`, `LocalDevVPNSetupCoordinator.swift`, `RichRuntimeReadiness.swift`, engine/UI.
- **New files:** domain proof DTOs only where existing results cannot express proof expiry/binding.
- **Test files:** port existing native/pairing/VPN/runtime tests to engine scenarios; add reboot/disconnect/locked/wrong-device and pending-clear tests.
- **Old paths removed:** any direct UI/helper READY assignment and cached-boolean success route.
- **Migration:** import pairing/runtime references, then re-prove live.
- **Unit/integration/physical:** fake faults; current-phone read/proof; controlled install/reboot/repair matrix later.
- **Entry gate:** Milestone 5 installed artifacts and Milestone 1 canonical engine.
- **Exit gate:** READY cannot be reached with any stale/unknown domain; smallest repair resumes without reprovisioning.
- **Rollback:** durable install/signing state is independent; volatile runtime can fall back to old UI while not claiming READY.
- **Risks:** iOS version protocol differences, DDI legal/source blocker, LocalDevVPN external dependency.

## Milestone 8: packaging and clean-machine gates

- **Objective:** qualify exact packaged bytes before any next numbered DMG.
- **Production files:** `macos/scripts/build_app.sh`, bootstrap/artifact scripts, release config and manifests only after all prior gates.
- **New files:** packaged qualification runner, prompt monitor, clean-machine run manifests.
- **Test files:** artifact identity tests, packaged helper/signing scenario, Intel/Apple Silicon clean-user automation.
- **Old paths removed:** release script paths that can increment/package without a current qualification manifest.
- **Migration:** test clean install, reinstall, upgrade, IOSSim migration, other-Mac and expiry scenarios separately.
- **Unit/integration/physical:** mounted-byte audit; quarantine/Gatekeeper; no-Xcode; exact signer; physical matrix below.
- **Entry gate:** Milestones 1-7 exit; production DDI source decision; dependency/security review.
- **Exit gate:** clean Intel and Apple Silicon machines reach READY; reinstall/reboot paths pass; no unexpected prompts; diagnostics identify first failure.
- **Rollback:** do not publish; preserve prior artifact and state; candidate failure cannot revoke/delete unknown resources.
- **Risks:** ad-hoc results differ from Developer ID/notarized build. Final public candidate must repeat packaged gates after signing/notarization.

## Physical qualification sequence

1. Safe read-only current-device stage probes.
2. Dedicated account/device: fresh clean Apple Silicon Mac.
3. Fresh clean Intel Mac.
4. Reopen, Mac reboot and iPhone reboot.
5. Reinstall same build without cleanup.
6. Upgrade from prior Veya and IOSSim state.
7. Capacity occupied by unrelated cert: prove fail-safe.
8. Owned stale cert: prove one-serial recovery with before/after inventory.
9. Same Apple ID on second Mac: prove no cross-Mac revoke.
10. Interrupted certificate, signing, install, pairing and VPN operations.
11. Profile renewal and certificate-expiry simulation; later real-time soak before public confidence.
12. Only then authorize a numbered integration candidate and DMG.

