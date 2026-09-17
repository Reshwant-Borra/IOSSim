# Installation V2 implementation ledger

This ledger is append-only by milestone. Test classes are `UNIT`, `HERMETIC_INTEGRATION`, `ARTIFACT`, `LOCAL_SYSTEM`, and `PHYSICAL_DEVICE`. A physical pass is never inferred from a lower class.

## V0 — Freeze product decisions and implementation contract

- START TIME: `2026-09-16T02:32:51Z`
- END TIME: `2026-09-16T02:36:27Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Services/DeveloperSupportCoordinator.swift`; `macos/Sources/IOSSimMacCore/Services/NativeDeveloperServicesCoordinator.swift`; `macos/Tests/IOSSimMacCoreTests/DeveloperSupportCoordinatorTests.swift`; `docs/installation-v2/implementation/00_IMPLEMENTATION_BASELINE.md`; `V0_DECISIONS.md`; this ledger; pre-implementation status/patch captures.
- OBJECTIVE: Freeze installation ownership, developer-support provider policy, stable identities, release truth policy, runtime invariants, and production security controls before behavior changes.
- IMPLEMENTATION: Added explicit developer-support distribution and provider classifications, provider descriptors, validation policy, and a public-release fresh-acquisition gate. Both developer-support coordinator boundaries now select through the same explicit policy. Public production permits validated cache consumption but cannot select development mirrors/test fixtures and cannot claim clean-machine release readiness without an approved fresh-acquisition provider. Recorded ownership, LocalDevVPN, stable-identity, runtime, release-truth, and security decisions.
- TESTS RUN: `UNIT` — `swift test --filter DeveloperSupportCoordinatorTests`; safe source/synthetic checks — `check_no_xcode_consumer_runtime.py`, `check_no_xcode_install_routing.py`, `test_device_discovery_cli.py`; `git diff --check`.
- TEST RESULTS: 9 focused Swift tests passed with 0 failures; 5 synthetic discovery tests passed; both no-Xcode checks passed; diff check passed. Swift compiled all package/test sources while selecting only the hermetic developer-support test class. No live account, Keychain, device, or network mutation ran.
- KNOWN LIMITATIONS: Production DDI source is not approved; public fresh-machine zero-Xcode must remain closed.
- PHYSICAL VALIDATION DEFERRED: No device or account interaction belongs to V0.
- ACCEPTANCE GATE: Owner map unambiguous; provider contract compiled; public-production policy rejects development/test providers; relevant tests pass.
- VERDICT: `PASS`
- NEXT MILESTONE: V1 — canonical artifact truth.

## V1 — Canonical artifact truth

- START TIME: `2026-09-16T02:36:27Z`
- END TIME: `2026-09-16T02:50:25Z`
- FILES TOUCHED: `config/release.json`; `macos/Sources/IOSSimMacCore/Models/ArtifactManifest.swift`; `macos/Sources/IOSSimMacCore/Services/NativeDeviceBridge.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; `macos/scripts/build_app.sh`; `scripts/bootstrap/iossim_cli.py`; new `scripts/bootstrap/artifact_identity.py`; `macos/Tests/IOSSimMacCoreTests/ArtifactManifestTests.swift`; `macos/Tests/IOSSimMacCoreTests/ConsumerProvisioningTests.swift`; new `scripts/checks/test_artifact_identity.py`; `V1_ARTIFACT_TRUTH_REPORT.md`; mounted identity JSON.
- OBJECTIVE: Make final artifact bytes authoritative for architecture, schemas, plists, payloads, hashes, source state, signing class, and release metadata.
- IMPLEMENTATION: Added a shared app/DMG inspector, built-component protocol reporting, mounted-DMG-derived sidecar schema 2, internal schema/hash comparisons, direct-builder schema derivation, nested bridge signing correction, and public DDI release fail-closed policy.
- TESTS RUN: `UNIT` — 5 Python identity tests and 6 Swift manifest tests; `ARTIFACT` — fresh self-contained app build, app audit, synthetic stale-schema app, V1 DMG create/mount/inspect/expectation audit; safe no-Xcode/source/discovery checks; diff check.
- TEST RESULTS: All unit and safe checks passed. Artifact actual-value inspection passed. Deliberately wrong universal metadata and deliberately stale setup schema both failed with exact mismatch messages. The current host-only build was truthfully identified as arm64 and refused against universal release policy.
- KNOWN LIMITATIONS: Native bridge is currently arm64-only; V1 test DMG is not a release candidate; final signing/notarization/SBOM/publication remain V17.
- PHYSICAL VALIDATION DEFERRED: No device behavior belongs to V1. Final downloaded/canonical DMG validation remains V17/V19.
- ACCEPTANCE GATE: Desired values cannot disagree with built output; stale schema and wrong architecture fail; mounted audit reports actual values; local/public classification remains fail-closed.
- VERDICT: `PASS`
- NEXT MILESTONE: V2 — hermetic installer test harness.

## V2 — Hermetic installer test harness

- START TIME: `2026-09-16T02:50:25Z`
- END TIME: `2026-09-16T03:02:55Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/SetupStore.swift`; new `macos/Tests/IOSSimMacCoreTests/HermeticInstallationHarnessTests.swift`; `SetupStoreTests.swift`; `ApplePersonalTeamExperimentalTests.swift`; `ConsumerProvisioningTests.swift`; `ProvisioningBackendTests.swift`; `RemotePairingLifecycleTests.swift`; new `V2_HERMETIC_TEST_REPORT.md`; this ledger.
- OBJECTIVE: Exercise Setup Engine V2 repeatedly with isolated product-state roots and fake device/account/signing/developer-support/install/pairing/VPN/runtime services, without touching a real phone, Apple account, or production Keychain.
- IMPLEMENTATION: Added the 26-scenario hermetic harness, crash/restart and concurrent-root tests, in-memory secret store, injectable SetupStore preferences/temp root, and isolated all SetupStore tests. Repaired stale reconciliation/install/pairing fixtures and fail-closed runtime mapping/trust routing exposed by isolation.
- TESTS RUN: `HERMETIC_INTEGRATION` — 3 harness tests and 34 SetupStore tests; focused regression set of 22 tests; broad safe Swift package regression; `git diff --check`.
- TEST RESULTS: Harness 3/3 passed; SetupStore 34/34 passed; focused regressions 22/22 passed; broad safe suite 279 executed, 1 opt-in local-system test skipped, 0 failures, 0 unexpected. Six Keychain/codesign integration tests and one real-Keychain persistence test were explicitly excluded rather than mutating the user's Keychain.
- KNOWN LIMITATIONS: The production keyed durable state/lease is V4; service fakes prove orchestration behavior, not Apple/device physical behavior.
- PHYSICAL VALIDATION DEFERRED: All phone, account, signing identity, pairing, VPN approval, developer-services, and Rich runtime physical checks remain deferred.
- ACCEPTANCE GATE: Required scenario matrix is repeatable against isolated roots and fakes; no real external state is required; broad safe regression is clean.
- VERDICT: `PASS`
- NEXT MILESTONE: V3 — packaged engine/helper boundary hardening.

## V3 — Packaged engine/helper boundary hardening

- START TIME: `2026-09-16T03:02:55Z`
- END TIME: `2026-09-16T03:13:22Z`
- FILES TOUCHED: new `macos/Sources/IOSSimMacCore/Services/PackagedEngineIntegrity.swift`; `BundledProvisioningEngine.swift`; `SetupStore.swift`; `IOSSimMacApp.swift`; `macos/scripts/build_app.sh`; `scripts/bootstrap/iossim_cli.py`; `scripts/bootstrap/artifact_identity.py`; `BundledProvisioningEngineTests.swift`; `SetupStoreTests.swift`; `scripts/checks/test_artifact_identity.py`; new `V3_ENGINE_BOUNDARY_REPORT.md`; mounted identity JSON; this ledger.
- OBJECTIVE: Make the packaged helper path deterministic and fail precisely before any domain mutation when helper/resources/hash/schema/protocol integrity is wrong.
- IMPLEMENTATION: Added signed-order engine-integrity metadata, fixed-path static validation, per-operation hash recheck, versioned helper handshake, stable `VEYA-INTEGRITY-001…006` errors, precise SetupStore UX, and mounted-byte inspection of the integrity manifest.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 9 engine tests plus SetupStore UX; 5 Python identity tests; `ARTIFACT` — packaged app build and mounted V3 DMG/helper handshake; safe source/routing scans; broad safe Swift suite; syntax/diff checks.
- TEST RESULTS: Missing/non-executable/tampered/wrong-protocol/missing-manifest cases passed with precise codes; mounted helper handshake passed; safe scans passed; broad suite 285 executed, 1 opt-in local-system test skipped, 0 failures, 0 unexpected.
- KNOWN LIMITATIONS: V3 DMG is arm64/ad-hoc test evidence, not a release candidate. Additional process framing/size/time policy remains for later protocol/diagnostic hardening.
- PHYSICAL VALIDATION DEFERRED: Clean installed-app launch remains V19.
- ACCEPTANCE GATE: Fixed bundle helper only; helper/resources/manifest/hash/schema handshake proven; no repo/development CLI fallback; no doctor-executable confusion.
- VERDICT: `PASS`
- NEXT MILESTONE: V4 — durable keyed state and cross-process lease.

## V4 — Durable keyed state and cross-process lease

- START TIME: `2026-09-16T03:13:22Z`
- END TIME: `2026-09-16T03:28:36Z`
- FILES TOUCHED: new `macos/Sources/IOSSimMacCore/Services/KeyedSetupStateStore.swift`; `IOSSimSetupEngine.swift`; `BundledProvisioningEngine.swift`; `SetupStore.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; new `macos/Tests/IOSSimMacCoreTests/KeyedSetupStateStoreTests.swift`; `BundledProvisioningEngineTests.swift`; `scripts/checks/check_no_xcode_install_routing.py`; new `V4_STATE_AND_LEASE_REPORT.md`; this ledger.
- OBJECTIVE: Replace singleton mutation assumptions with release/team/device/artifact-keyed durable state, an OS cross-process lease, CAS generations, a secret-safe journal, schema migration, and crash recovery.
- IMPLEMENTATION: Added schema-5 keyed snapshots, hash-chained intent/observation/commit journal, `flock` lease, atomic fsync/rename persistence, stale-generation rejection, schema-4 digest import, interruption recovery, per-key compatibility domain stores, precise state errors, and exact device/team status routing. Packaged provision/resume/reconcile/runtime-ready mutations now run under the single helper-owned lease.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 12 keyed-state tests and 10 bundled-boundary tests; broad safe Swift suite; no-Xcode runtime/routing checks; five synthetic discovery tests; `git diff --check`.
- TEST RESULTS: Focused state tests 12/12 passed. Focused state/boundary set executed 22 with one opt-in artifact skip and zero failures. Broad safe suite executed 298 with two opt-in skips, zero failures, zero unexpected. Safe routing/discovery/diff checks passed. Seven real-Keychain/codesigning tests were explicitly excluded.
- KNOWN LIMITATIONS: Domain-specific recovery observers and candidate directories land with their owning later milestones; schema-4 compatibility remains for migration; physical crash/reboot behavior is not inferred from hermetic tests.
- PHYSICAL VALIDATION DEFERRED: Mac reboot/process-kill with a live device and exact external-effect reconciliation remain V19.
- ACCEPTANCE GATE: No lost update or stale overwrite; device/team/release/artifact isolation; concurrent helper rejection; atomic recovery before/after snapshot commit; corrupt journal/snapshot fail closed; safe schema-4 import; broad regression clean.
- VERDICT: `PASS`
- NEXT MILESTONE: V5 — first-time Trust/native Lockdown pairing.

## V5 — First-time Trust / native Lockdown pairing

- START TIME: `2026-09-16T03:28:36Z`
- END TIME: `2026-09-16T03:45:34Z`
- FILES TOUCHED: `native/iossim-device-bridge/include/iossim_device_bridge.h`; `native/iossim-device-bridge/src/lib.rs`; `macos/Sources/IOSSimMacCore/Services/NativeDeviceBridge.swift`; new `NativeLockdownPairing.swift`; `NativeApplicationManagement.swift`; `RuntimeProvisioningSupport.swift`; `IOSSimSetupEngine.swift`; `BundledProvisioningEngine.swift`; `SetupStore.swift`; `macos/Sources/IOSSimMac/SetupWizardView.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; `ApplePersonalTeamLive.swift`; `ConsumerArtifactProvisioner.swift`; `NativeProvisioningArtifactStore.swift`; `NativeDeviceBridgeTests.swift`; new `NativeLockdownPairingTests.swift`; `BundledProvisioningEngineTests.swift`; `SetupStoreTests.swift`; new `V5_FIRST_TRUST_REPORT.md`; this ledger.
- OBJECTIVE: Add legitimate first-time USB/Lockdown pairing without Xcode, preserve Apple's Trust prompt, bind selection to the exact connection, and return typed secret-free state.
- IMPLEMENTATION: Added native ABI 2 pairing and exact-open operations, deterministic duplicate selection, one-shot Trust orchestration, record validation/persistence/fresh-session proof, packaged `pair-device`, keyed mutation lease, typed SetupStore/UI states, and helper schema 2. A gate-discovered macOS persistence defect was corrected by replacing rejected iOS file-protection flags with atomic writes plus existing owner-only permissions.
- TESTS RUN: `UNIT` — 10 Rust tests, native symbol/ABI inspection, 16 device bridge tests, 4 pairing coordinator tests, SetupStore and packaged-helper Trust tests; `HERMETIC_INTEGRATION` — broad safe Swift suite; C header syntax, helper protocol-info, no-device command behavior, and `git diff --check`.
- TEST RESULTS: Rust 10/10 passed; focused Swift Trust/device tests 21/21 passed; packaged command test passed; broad suite executed 305 with two opt-in skips, zero failures, zero unexpected. No real phone, account, production Keychain, or pairing record was mutated.
- KNOWN LIMITATIONS: Physical never-paired-device proof is outstanding; V5 does not replace RemotePairing, which remains V10; public universal packaging remains V17.
- PHYSICAL VALIDATION DEFERRED: First USB Trust prompt, unlock/passcode state, denial, disconnect/reconnect, usbmux record persistence, and fresh Lockdown session validation on a supported iPhone.
- ACCEPTANCE GATE: Versioned native ABI; exact identity selection; no auto-approval; safe pending/denied/locked outcomes; existing enumeration compatibility; broad safe regression clean.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V6 — developer-support/DDI provider.

## V6 — Developer-support / DDI provider

- START TIME: `2026-09-16T03:45:34Z`
- END TIME: `2026-09-16T04:00:30Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Services/DeveloperSupportCoordinator.swift`; new `DeveloperSupportDevelopmentProvider.swift`; `NativeDeveloperServicesCoordinator.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; `DeveloperSupportCoordinatorTests.swift`; `scripts/bootstrap/artifact_identity.py`; `scripts/bootstrap/iossim_cli.py`; `scripts/checks/test_artifact_identity.py`; new `V6_DEVELOPER_SUPPORT_REPORT.md`; this ledger; workspace-local download/cache evidence under `.build/iossim`.
- OBJECTIVE: Provide exact-build, verified, provenance-bearing developer-support acquisition for development/local testing without Xcode while preventing any development mirror from becoming a production dependency.
- IMPLEMENTATION: Added artifact/provenance schema 2, Veya-owned build-keyed cache, immutable pinned three-file development provider, bounded HTTPS acquisition, size/hash/BuildManifest validation, candidate commit, quarantine/reacquisition, revocation controls, public provenance revalidation, compile-time local-test composition, and artifact-derived provider classification.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 15 developer-support tests, broad safe Swift suite; explicit real-network empty-cache provider test; local-test and production helper compilation/protocol inspection; no-Xcode routing/runtime scans; five synthetic discovery tests; six artifact-truth tests; Python syntax and diff checks.
- TEST RESULTS: Hermetic developer-support suite executed 15 with one opt-in skip and zero failures; the skipped real-network test passed separately and acquired all three pinned assets with matching hashes into a workspace cache. Broad suite executed 311 with three opt-in skips, zero failures, zero unexpected. All safe scans and artifact tests passed.
- KNOWN LIMITATIONS: Repository/Apple asset production rights are unresolved; no approved production source exists; supported-major policy is explicitly bounded; device/session readiness receipts complete in V12.
- PHYSICAL VALIDATION DEFERRED: Fresh-device Apple TSS personalization, Developer Mode transition, personalized mount, RSD/RemoteXPC/AppService, offline reuse on the actual phone, and TSS/mount outage behavior.
- ACCEPTANCE GATE: Empty local-test cache acquisition without Xcode passes; exact asset/provenance/cache policy passes; production rejects the development provider and its cached provenance; public release remains fail-closed.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V7 — exact native device/install parity.

## V7 — Exact native device / install parity

- START TIME: `2026-09-16T04:00:30Z`
- END TIME: `2026-09-16T04:13:03Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Models/ArtifactManifest.swift`; `NativeApplicationManagement.swift`; `RuntimeProvisioningSupport.swift`; `ConsumerArtifactProvisioner.swift`; `ConsumerProvisioning.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; `native/iossim-device-bridge/src/lib.rs`; `NativeApplicationManagementTests.swift`; `ProvisioningBackendTests.swift`; `ConsumerProvisioningTests.swift`; `scripts/checks/check_no_xcode_consumer_runtime.py`; `check_no_xcode_install_routing.py`; new `V7_NATIVE_DEVICE_REPORT.md`; this ledger.
- OBJECTIVE: Retain exact native connection identity through every consumer device operation; make install success inventory-backed; prevent deletion or replacement without deterministic ownership; preserve native-only packaged routing.
- IMPLEMENTATION: Added shared exact UDID/mux/connection/generation binding, a backend exact-identity boundary, schema-1 native install receipts, deterministic app-tree identity, exact post-install team/version proof, interruption reconciliation, ownership-conflict handling, expected-team propagation, verified ownership-scoped uninstall, and Rust inventory version fallback.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 30 focused Swift tests, 10 Rust bridge tests, broad safe Swift suite; five synthetic device discovery tests; six artifact identity tests; no-Xcode runtime/routing audits; `git diff --check`.
- TEST RESULTS: Focused Swift 30/30 and Rust 10/10 passed. Broad safe suite executed 324 with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected. Synthetic, artifact, routing, and diff checks passed. No process runner was invoked by native application operations.
- KNOWN LIMITATIONS: Real InstallationProxy team/version field behavior, transfer/install interruption, physical reconnect, and AppService prerequisite behavior require a supported iPhone. V9 owns transactional signing/profile lifecycle; V12 owns operational AppService receipts.
- PHYSICAL VALIDATION DEFERRED: Exact USB selection with duplicate network presence; lock/Trust/Developer Mode states; fresh install, upgrade, interruption, inventory, House Arrest, owned uninstall, and AppService on a real phone.
- ACCEPTANCE GATE: Deterministic exact selection; native enumeration/inventory/install/upgrade/owned-uninstall/House Arrest/AppService boundaries preserved; unknown ownership fails closed; no consumer devicectl/xcodebuild dependency; automated regression clean.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V8 — Apple Personal Team adapter hardening.

## V8 — Apple Personal Team adapter hardening

- START TIME: `2026-09-16T04:13:03Z`
- END TIME: `2026-09-16T05:13:54Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamExperimental.swift`; `ApplePersonalTeamLive.swift`; `macos/Sources/IOSSimMacCore/SetupStore.swift`; `ApplePersonalTeamExperimentalTests.swift`; `ApplePersonalTeamLiveTests.swift`; new `V8_APPLE_ADAPTER_REPORT.md`; this ledger.
- OBJECTIVE: Preserve the Swift Apple Personal Team implementation while isolating private protocol details behind a typed, versioned, independently disableable adapter.
- IMPLEMENTATION: Added `ApplePersonalTeamService`, `VersionedPrivateAppleProvisioningAdapter`, version allowlist and environment kill switch, stable disabled/incompatibility outcomes, SetupStore adapter composition, and non-destructive stored-session handling on response-shape drift.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 76 focused Apple adapter tests and broad safe Swift suite; no-Xcode routing/runtime audits; `git diff --check`.
- TEST RESULTS: Focused adapter suite executed 76 with one opt-in credentials-free local-system skip and zero failures. Broad safe suite executed 328 with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected. Kill-switch, version mismatch, response drift, session preservation, error matrix, and secret-redaction fixtures passed.
- KNOWN LIMITATIONS: Private Apple protocols are version-bound; live physical qualification remains false; V9 owns transactional certificate/profile lifecycle.
- PHYSICAL VALIDATION DEFERRED: Current Apple auth/2FA, token issuance, Personal Team discovery, device/App ID/certificate/profile operations, service limits, and session renewal against an approved test account.
- ACCEPTANCE GATE: Setup/UI does not depend on SRP details; adapter independently disables before credential operations; response incompatibility is explicit/non-destructive; offline success and failure matrix passes.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V9 — signing/certificate/profile lifecycle.

## V9 — Signing / certificate / profile lifecycle

- START TIME: `2026-09-16T05:13:54Z`
- END TIME: `2026-09-16T05:35:47Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamExperimental.swift`; `ApplePersonalTeamLive.swift`; `NativeProvisioningArtifactStore.swift`; `ConsumerArtifactProvisioner.swift`; `macos/Sources/IOSSimMacCore/SetupStore.swift`; `ApplePersonalTeamExperimentalTests.swift`; `ApplePersonalTeamLiveTests.swift`; `ConsumerProvisioningTests.swift`; new `V9_SIGNING_PROFILE_REPORT.md`; this ledger.
- OBJECTIVE: Replace destructive/premature signing and profile replacement with a candidate lifecycle whose promotion follows exact verified installation.
- IMPLEMENTATION: Added active/candidate Keychain metadata, active/candidate owner-only profile artifacts, explicit lifecycle propagation, active-only setup reuse, idempotent promotion after exact bundle/team/version inventory, and crash-safe preservation of the prior active resources. Retained explicit inside-out nested signing and existing Keychain/profile validation.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 89 focused Apple/provisioning tests; downstream fault/retry gate; broad safe Swift suite; `git diff --check`.
- TEST RESULTS: Focused suite executed 89 with one opt-in local-system skip and zero failures. Downstream fault/retry gate passed. Broad safe suite executed 328 with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected. Candidate isolation, active preservation, atomic promotion, identity recovery, profile expiry, limits, nested signing, entitlement verification, and non-deletion checks passed.
- KNOWN LIMITATIONS: Safe grace-period retirement is deferred rather than deleting superseded managed keys/certificates; live revocation and renewal need Apple/device proof.
- PHYSICAL VALIDATION DEFERRED: Current Apple certificate/profile issuance and expiry renewal; packaged cross-process Keychain ACL; native install/upgrade and post-inventory promotion; restart reuse on a supported iPhone.
- ACCEPTANCE GATE: Valid resources reused; invalid/expired resources renewed as candidates; failure preserves active install; nested signing explicit; exact inventory controls promotion; unrelated resources never deleted; secrets never exported.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V10 — staged RemotePairing replacement.

## V10 — Staged RemotePairing replacement

- START TIME: `2026-09-16T05:35:47Z`
- END TIME: `2026-09-16T05:48:45Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Services/RemotePairingLifecycle.swift`; `ConsumerArtifactProvisioner.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; `ios/Sources/IOSSimOnDeviceDVTPOC/AutomaticPairingInbox.swift`; `PairingStore.swift`; `LocalDevVPNSetupInbox.swift` (macOS test-host protected-write parity only); `macos/Tests/IOSSimMacCoreTests/RemotePairingLifecycleTests.swift`; `ios/Sources/POCUnitChecks/main.swift`; new `V10_PAIRING_REPORT.md`; this ledger.
- OBJECTIVE: Replace destructive pairing repair with a request-bound candidate transaction that preserves the last working record until phone possession and developer-services readiness are proven.
- IMPLEMENTATION: Added Mac/phone active-candidate stores, schema-2 request/generation/release binding, encrypted candidate transfer, candidate receipt, HMAC possession challenge, non-no-op native/developer-services proof, explicit phone promotion, final operational receipt, Mac promotion, and crash-resume reuse. Removed coordinator deletion of active pairing.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 9 focused Mac pairing tests; iPhone `POCUnitChecks`; broad safe Swift suite; `git diff --check`.
- TEST RESULTS: Pairing 9/9 passed; iPhone checks passed; broad macOS suite executed 333 with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected. Wrong device/request, replay, corrupt proof, developer-service failure, phone failure before promotion, and Mac crash/resume preserve active state.
- KNOWN LIMITATIONS: V12 strengthens the developer-services/AppService receipt; physical phone Keychain and scene scheduling remain unproven.
- PHYSICAL VALIDATION DEFERRED: Real House Arrest exchange, phone scene activation, RemotePairing possession, RemoteXPC/developer service operation, disconnect/crash boundaries, and restart recovery on a supported iPhone.
- ACCEPTANCE GATE: Failed repair leaves the previous working pairing intact; receipt is not readiness; request/device/generation/release/nonces bind the transaction; possession and developer-services proof precede promotion; no raw pairing material is logged.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V11 — LocalDevVPN consumer lifecycle.

## V11 — LocalDevVPN consumer lifecycle

- START TIME: `2026-09-16T05:48:45Z`
- END TIME: `2026-09-16T05:57:28Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Services/LocalDevVPNSetupCoordinator.swift`; `ConsumerArtifactProvisioner.swift`; `macos/Sources/IOSSimMacCore/Models/ArtifactManifest.swift`; `ios/Sources/IOSSimOnDeviceDVTPOC/LocalDevVPNSetupInbox.swift`; `ios/App/IOSSimOnDeviceDVTPOCApp.swift`; `ios/Sources/POCUnitChecks/main.swift`; `scripts/bootstrap/iossim_cli.py`; `macos/scripts/build_app.sh`; `LocalDevVPNSetupCoordinatorTests.swift`; `ArtifactManifestTests.swift`; new `V11_LOCALDEVVPN_REPORT.md`; this ledger.
- OBJECTIVE: Preserve LocalDevVPN as an explicit external dependency while making install, compatibility, Apple approval, configured/running, endpoint, foreground, and resume states independently diagnosable.
- IMPLEMENTATION: Added a seven-state lifecycle, exact version policy, bound schema-2 requests/receipts, typed `VEYA-VPN` outcomes, scene-active inbox reprocessing, retained pending requests, artifact dependency metadata, and distinct setup guidance without bypassing iOS VPN approval.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 11 focused LocalDevVPN/artifact tests, iPhone `POCUnitChecks`, broad safe Swift suite; `ARTIFACT` / compile — unsigned generic iOS-device app build; six artifact-identity tests; no-Xcode runtime/routing audits; `git diff --check`.
- TEST RESULTS: Focused tests 11/11 and phone checks passed. Generic iOS-device build succeeded. Broad macOS suite executed 335 with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected. Artifact and safe routing checks passed. A simulator link attempt was correctly inapplicable because the existing vendored native archive is built for iOS device; source compilation completed and the matching device build passed.
- KNOWN LIMITATIONS: Endpoint evidence is bounded TCP reachability; V12 supplies developer-services/AppService proof and V13 supplies Rich runtime proof. Observed App Store version 1.3.0 is not yet physically qualified.
- PHYSICAL VALIDATION DEFERRED: App Store install, version compatibility, VPN approval/denial, scene reactivation, tunnel lifecycle, and real endpoint behavior on supported iPhone/iOS combinations.
- ACCEPTANCE GATE: Missing/unsupported/permission/configured/running/endpoint-ready states are distinct; foreground/reopen resumes pending work; user approval is preserved; dependency contract is release-visible; automated regression is clean.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V12 — developer-services/AppService proof.

## V12 — Developer services / AppService proof

- START TIME: `2026-09-16T05:57:28Z`
- END TIME: `2026-09-16T06:03:42Z`
- FILES TOUCHED: `native/iossim-device-bridge/src/lib.rs`; `macos/Sources/IOSSimMacCore/Services/NativeDeviceBridge.swift`; `NativeDeveloperServicesCoordinator.swift`; `NativeApplicationManagement.swift`; `RemotePairingLifecycle.swift`; `ConsumerArtifactProvisioner.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; `NativeDeviceBridgeTests.swift`; `scripts/bootstrap/iossim_cli.py`; `macos/scripts/build_app.sh`; new `V12_APPSERVICE_REPORT.md`; this ledger.
- OBJECTIVE: Prevent mounted DDI, RSD reachability, or AppService discovery from being classified as developer-services readiness without a fresh exact-target launch receipt.
- IMPLEMENTATION: Added transport-vs-operational readiness, schema-2 identity/context/freshness binding, exact runner AppService launch evidence, enriched native launch payload, pairing-generation/release binding, and artifact provenance for the receipt schema.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 28 focused Swift device/pairing tests, 11 Rust bridge tests, broad safe Swift suite; optimized native bridge rebuild; no-Xcode runtime/routing audits; `git diff --check`.
- TEST RESULTS: Focused Swift 28/28 and Rust 11/11 passed. Broad suite executed 338 with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected. Release bridge build, routing audits, and diff check passed.
- KNOWN LIMITATIONS: Live native sockets remain operation-scoped; already-mounted support uses build/service-map identity; V13 owns TestManager/XCTest and bounded Rich location proof.
- PHYSICAL VALIDATION DEFERRED: Real DDI/tunnel/RSD/RemoteXPC/AppService/exact runner launch and stale-receipt invalidation across physical reconnect/update/rotation scenarios.
- ACCEPTANCE GATE: AppService launch is an independent, exact-target, fresh, context-bound receipt; transport-only evidence cannot satisfy readiness; automated regression is clean.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V13 — real Rich runtime proof.

## V13 — Real Rich runtime proof

- START TIME: `2026-09-16T06:03:42Z`
- END TIME: `2026-09-16T06:13:58Z`
- FILES TOUCHED: new `macos/Sources/IOSSimMacCore/Services/RichRuntimeReadiness.swift`; `ConsumerProvisioningStateStore.swift`; `ConsumerProvisioning.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; `ArtifactManifest.swift`; `SetupWizardView.swift`; new `ios/Sources/IOSSimOnDeviceDVTPOC/RichRuntimeProofInbox.swift`; `IOSSimOnDeviceDVTPOCApp.swift`; `AppleXCUILocationControlUITests.swift`; iOS project; `POCUnitChecks`; `scripts/bootstrap/iossim_cli.py`; `macos/scripts/build_app.sh`; `ConsumerProvisioningTests.swift`; new `RichRuntimeReadinessTests.swift`; new `V13_RUNTIME_PROOF_REPORT.md`; this ledger.
- OBJECTIVE: Make READY depend on a bounded, exact-context Rich XCUILocation operation with TestManager/XCTest control, acknowledgement, location clear, and cleanup rather than any stored checkpoint.
- IMPLEMENTATION: Added bound House Arrest request/receipt, live exact-runner Gate-1 XCTest invocation through the retained RSD path, required stage evidence, witness-backed harmless Rich write, unconditional test-level reset, authoritative coordinator clear, session cleanup, receipt persistence/invalidation, and payload capability enforcement.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 13 focused runtime/state/artifact tests, iPhone `POCUnitChecks`, broad safe Swift suite; `ARTIFACT` / compile — unsigned generic iOS-device app build and six artifact-identity tests; no-Xcode runtime/routing audits; `git diff --check`.
- TEST RESULTS: Focused 13/13 and iPhone checks passed; iOS-device build succeeded; broad macOS suite executed 342 with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected; artifact/routing/diff gates passed.
- KNOWN LIMITATIONS: The witness assertion plus successful XCTest completion is the strongest safe acknowledgement; raw location data is not exported. V14 owns broader restart/expiry/upgrade reconciliation.
- PHYSICAL VALIDATION DEFERRED: Real retained-RSD TestManager/XCTest runner launch, Rich witness callback, clear/no-residual-location proof, scene delivery, failures, and retry/restart on a supported iPhone.
- ACCEPTANCE GATE: Stored state alone cannot mark READY; every bound runtime dependency is represented; cleanup is mandatory; no Drive route starts; automated regression is clean.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V14 — repair/resume/renewal.

## V14 — Repair / resume / renewal

- START TIME: `2026-09-16T06:13:58Z`
- END TIME: `2026-09-16T06:22:56Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Services/ReadinessRecovery.swift`; `ConsumerArtifactProvisioner.swift`; `macos/Sources/IOSSimMacCore/Models/ConsumerProvisioning.swift`; `ReadinessRecoveryTests.swift`; `ConsumerProvisioningTests.swift`; new `V14_REPAIR_RENEWAL_REPORT.md`; retained `v14-swift-test.log`; this ledger.
- OBJECTIVE: Reconcile every restart against current prerequisites and perform only the smallest safe repair while preserving unrelated valid state.
- IMPLEMENTATION: Added ordered repair domains, actual-payload release checks, profile refresh-window checks, refresh-vs-repair routing, exact missing-component repair, live-boundary READY invalidation, runtime-proof rerun classification, and conservative pairing/VPN/developer-service revalidation. Also corrected early V13 pairing/VPN completion states so they cannot assert READY.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — 10 repair-planner tests, four focused resume/reconciliation cases, broad safe Swift suite; six artifact-identity tests; no-Xcode runtime/routing audits; `git diff --check`.
- TEST RESULTS: Focused policy 10/10 passed; focused resume/reconciliation 4/4 passed; broad suite executed 349 with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected. Artifact, routing, and diff gates passed.
- KNOWN LIMITATIONS: Live Apple expiry/revocation, DDI staleness, reboot, reconnect, install interruption, and release-upgrade side effects require physical qualification; production DDI remains unapproved.
- PHYSICAL VALIDATION DEFERRED: Personal Team renewal, reboot/reconnect, missing-app repair, stale pairing/DDI/VPN/runtime proof, interrupted install, and upgrade on a supported iPhone.
- ACCEPTANCE GATE: Earliest invalid prerequisite only; unrelated valid state preserved; actual artifact identity used; READY invalidated across live sessions; destructive Fresh Install remains explicit; automated regression clean.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V15 — diagnostics and support.

## V15 — Diagnostics / support

- START TIME: `2026-09-16T06:22:56Z`
- END TIME: `2026-09-16T11:42:21Z`
- FILES TOUCHED: new `macos/Sources/IOSSimMacCore/Services/VeyaDiagnostics.swift`; `SupportBundleExporter.swift`; `ConsumerProvisioning.swift`; `macos/Sources/IOSSimProvisioner/main.swift`; `ConsumerProvisioningTests.swift`; new `VeyaDiagnosticsTests.swift`; `docs/installation-v2/21_ERROR_TAXONOMY.md`; new `V15_DIAGNOSTICS_REPORT.md`; retained `v15-swift-test.log`; this ledger.
- OBJECTIVE: Provide stable, actionable, machine-readable errors and a strict support export that cannot include credentials, signing secrets, or pairing material.
- IMPLEMENTATION: Added exhaustive `VEYA-*` taxonomy descriptors, retry/repair/user-action metadata, packaged failure descriptors, stage-owned unknown codes, one-file support allowlist, schema-8 diagnostic export, final redaction, and fail-closed prohibited-secret scanning.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — four taxonomy/scanner tests, sentinel ZIP extraction test, 11 packaged-boundary tests, broad safe Swift suite; six artifact-identity tests; no-Xcode runtime/routing audits; `git diff --check`.
- TEST RESULTS: Taxonomy 4/4 and sentinel ZIP test passed; the ZIP contained only `support.json` and no injected password/2FA/token/cookie/private-key/pairing sentinels. Broad suite executed 353 with 9 explicit skips, zero failures, zero unexpected. Artifact, routing, and diff gates passed.
- KNOWN LIMITATIONS: Codes are now compatibility API; raw vendor responses remain intentionally unavailable in support reports.
- PHYSICAL VALIDATION DEFERRED: None for the diagnostic/support software gate; physical scenario failures should later be checked for correct live mappings.
- ACCEPTANCE GATE: Every modeled error has stable fields; support export is allowlisted; injected secrets are absent from logs/ZIP; broad regression clean.
- VERDICT: `PASS`
- NEXT MILESTONE: V16 — legacy removal after parity.

## V16 — Legacy removal after parity

- START TIME: `2026-09-16T11:42:21Z`
- END TIME: `2026-09-16T12:13:18Z`
- FILES TOUCHED: `macos/Sources/IOSSimMacCore/Services/ConsumerProvisioningBackend.swift`; `RuntimeProvisioningSupport.swift`; `ProvisioningBackendTests.swift`; `DevelopmentCLIEngineTests.swift`; `scripts/checks/check_no_xcode_consumer_runtime.py`; new `V16_LEGACY_REMOVAL_REPORT.md`; retained `v16-swift-test.log`; this ledger.
- OBJECTIVE: Retire ambiguous consumer fallback selection only after native parity gates, while retaining explicitly scoped development and migration paths that still have a documented purpose.
- IMPLEMENTATION: Compile-time locked packaged provisioning to native Personal Team and packaged device operations to idevice, added a hostile-environment packaged test, and extended the source audit. Classified retained development CLI, devicectl/Xcode comparison, build-machine, and schema-migration paths.
- TESTS RUN: `UNIT` — dedicated packaged-flag selector test; `HERMETIC_INTEGRATION` — broad safe Swift suite; no-Xcode consumer and native install-routing audits; `git diff --check`.
- TEST RESULTS: Packaged hostile-selector test passed; broad suite executed 353 with 9 explicit skips, zero failures, zero unexpected; both routing audits and diff check passed.
- KNOWN LIMITATIONS: Physical parity and rollback-release evidence are still required before deleting developer comparison implementations; schema migration readers remain within the supported upgrade window.
- PHYSICAL VALIDATION DEFERRED: Native-vs-development comparison for trust, renewal, install, DDI, pairing, AppService, and Rich runtime on supported devices.
- ACCEPTANCE GATE: Packaged consumer has one compile-time authoritative path; no environment fallback; every retained legacy path is explicitly developer/build/migration scoped.
- VERDICT: `PASS`
- NEXT MILESTONE: V17 — canonical distribution.

## V17 — Canonical distribution

- START TIME: `2026-09-16T12:13:18Z`
- END TIME: `2026-09-16T15:40:41Z`
- FILES TOUCHED: `scripts/bootstrap/iossim_cli.py`; `scripts/bootstrap/artifact_identity.py`; `scripts/checks/test_artifact_identity.py`; `macos/Sources/IOSSimProvisioner/main.swift`; `PackagedEngineIntegrity.swift`; `SupportBundleExporter.swift`; `BundledProvisioningEngineTests.swift`; new `V17_RELEASE_REPORT.md`; new `V17_MOUNTED_ARTIFACT_IDENTITY.json`; retained V17 build/audit/test logs; canonical DMG, checksum, release JSON, and assembled artifacts under `.build/iossim`; this ledger.
- OBJECTIVE: Produce one mounted-artifact-derived release pipeline and a truthful local test DMG while keeping public production closed without an approved DDI provider and Apple distribution qualification.
- IMPLEMENTATION: Added canonical names, configured multi-architecture Rust bridge builds, SPDX/lock/license provenance, mounted dependency identity, strengthened pairing/Rich payload gates, separate setup-state/provisioning schema truth, and DDI-first public fail-closed policy.
- TESTS RUN: `ARTIFACT` — full canonical local release build and two independent read-only mounted audits; public release fail-closed check; `UNIT` / `HERMETIC_INTEGRATION` — 353-test Swift suite, POCUnitChecks, 11 Rust tests, six artifact tests; no-Xcode audits; Python compile; `git diff --check`.
- TEST RESULTS: Local build/audits passed; universal GUI/helper/bridge and all actual schema/hash/signature/provenance checks passed; public command failed at unresolved production DDI as required; Swift 353/9 skipped/0 failed, Rust 11/11, phone checks, artifact tests, scans, and diff passed.
- KNOWN LIMITATIONS: Artifact is dirty-source, ad hoc signed, not notarized/stapled/Gatekeeper-qualified, and LOCAL_TEST_ONLY. Production DDI rights/source remain unresolved. V18 display branding may require a final local rebuild.
- PHYSICAL VALIDATION DEFERRED: Clean Mac/iPhone, Developer ID, notarization, stapling, Gatekeeper, full setup/runtime, and release upgrade.
- ACCEPTANCE GATE: Canonical local artifact is unambiguous and mounted-byte audited; actual architecture/schema truth passes; public production fails closed; no publication occurred.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V18 — IOSSim to Veya migration.

## V18 — IOSSim to Veya migration

- START TIME: `2026-09-16T15:40:41Z`
- END TIME: `2026-09-16T16:23:02Z`
- FILES TOUCHED: `config/release.json`; new `macos/Sources/IOSSimMacCore/Models/ProductBrand.swift`; `SetupState.swift`; `ConsumerProvisioning.swift`; Mac `RootView.swift`, `SetupWizardView.swift`, `DashboardView.swift`, and `SharedViews.swift`; `scripts/bootstrap/iossim_cli.py`; `scripts/checks/test_artifact_identity.py`; `scripts/checks/check_no_xcode_consumer_runtime.py`; `ApplePersonalTeamExperimentalTests.swift`; `SetupStoreTests.swift`; new `ProductBrandMigrationTests.swift`; new `V18_VEYA_MIGRATION_REPORT.md`; new `V18_MOUNTED_ARTIFACT_IDENTITY.json`; retained V18 test/build/audit logs; final Veya local-test artifact and sidecars under `.build/iossim`; this ledger.
- OBJECTIVE: Change product/display branding to Veya after installer reliability while preserving all low-level identities and avoiding destructive reprovisioning.
- IMPLEMENTATION: Added an explicit product-brand migration contract, Veya migration-window UI and release naming, user-facing error translation, dynamic Veya DMG/SBOM auditing, and invariant tests for the unchanged Mac bundle/state/preferences/phone/runner/Keychain identities.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — three focused migration tests and broad Swift suite; six artifact tests; native-only consumer audit; `ARTIFACT` — full canonical Veya local release, separate read-only audit, independent mounted identity inspection; `git diff --check`.
- TEST RESULTS: Migration 3/3; broad suite 356 executed, 9 explicit skips, zero failures/unexpected; artifact tests 6/6; consumer audit and diff check passed. Final mounted Veya DMG audits passed with universal binaries, truthful schemas, stable compatibility IDs, and AD_HOC/LOCAL_TEST_ONLY classification.
- KNOWN LIMITATIONS: The migration has not been exercised as an in-place upgrade on a previously qualified physical IOSSim installation. The Mac icon and low-level executable/project names remain IOSSim compatibility details by design.
- PHYSICAL VALIDATION DEFERRED: Prior IOSSim V2 to Veya upgrade, state/signing/pairing/runtime reuse, Finder/LaunchServices presentation, and post-upgrade repair/renewal.
- ACCEPTANCE GATE: Display/artifact branding is Veya; stable identifiers are unchanged; no brand-only setup rekey or reprovisioning; final mounted local artifact passes.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: V19 — qualification.

## V19 — Qualification

- START TIME: `2026-09-16T16:23:02Z`
- END TIME: `2026-09-16T16:40:20Z`
- FILES TOUCHED: final Veya user-facing action translation in `DoctorStatus.swift`; new `V19_QUALIFICATION_REPORT.md`; new `PHYSICAL_VALIDATION_HANDOFF.md`; new `FINAL_IMPLEMENTATION_HANDOFF.md`; new `V19_MOUNTED_ARTIFACT_IDENTITY.json`; V19 qualification/rebuild/audit logs and checksum evidence; final status/file inventories; this ledger.
- OBJECTIVE: Complete every safe automated and mounted-artifact gate, classify all remaining skips/failures, audit architecture invariants A–L, and hand off physical/public qualification without overstating evidence.
- IMPLEMENTATION: Re-ran the complete safe software matrix, separately exercised the packaged artifact handshake, closed the last legacy-name presentation boundary, rebuilt and independently remounted the final Veya DMG, verified the public DDI fail-closed gate, classified all opt-in skips, completed the A–L audit, and wrote the ordered physical qualification runbook.
- TESTS RUN: `UNIT` / `HERMETIC_INTEGRATION` — full 356-test Swift suite, iPhone POC checks, 11 Rust bridge tests, six artifact tests, five discovery tests, packaged artifact handshake; `ARTIFACT` — final checksum and prior canonical/separate/independent mounted audits; source/routing/Python/diff gates; production release fail-closed check. No unauthorized `LOCAL_SYSTEM` or `PHYSICAL_DEVICE` mutation was run.
- TEST RESULTS: Swift 356 executed, 9 explicit skips, zero failures/unexpected; separately supplied packaged artifact test 1/1; POC passed; Rust 11/11; artifact 6/6; discovery 5/5; routing, compile, diff, DMG audit, and public fail-closed gates passed. No remaining automated failures.
- KNOWN LIMITATIONS: Clean Mac/iPhone, live Apple account/2FA/Personal Team, real Keychain signing, first Trust, TSS/mount, install, pairing, VPN, AppService, Rich proof, reboot/renewal/upgrade, and public Apple distribution gates were not executed.
- PHYSICAL VALIDATION DEFERRED: All scenarios in `PHYSICAL_VALIDATION_HANDOFF.md`; no physical pass is claimed.
- ACCEPTANCE GATE: Safe automated qualification clean; local artifact independently auditable; public release closed; failures/skips classified; exact physical handoff complete.
- VERDICT: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`
- NEXT MILESTONE: Controlled physical qualification, followed by approved production DDI and Apple distribution qualification.
