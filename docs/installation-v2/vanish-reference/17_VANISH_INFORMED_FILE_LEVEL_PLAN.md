# Vanish-informed file-level implementation plan

Each entry contains the requested implementation fields. “Physical” names a required future device test; none is run in this research task.

## Mac application and engine boundary

### `macos/Sources/IOSSimMac/Views/SetupWizardView.swift`
- **Current role / status:** renders broad setup phases and actions; **REFACTOR**.
- **Vanish analog / target:** polished step-specific guidance; render the schema-5 phase, preserved-state summary, exact Apple/user action, retry/cancel/resume, stable code, and release identity without protocol jargon.
- **Dependencies/change:** SetupStore presentation model and error catalog; keep view free of service calls.
- **Tests/physical:** view-model/snapshot coverage for every action-required and recovery state; clean-flow usability and accessibility.
- **Migration/security/rollback:** no secrets/raw identifiers in text or telemetry; old presentation can remain behind a development preview only.

### `macos/Sources/IOSSimMac/IOSSimMacApp.swift`
- **Current role / status:** application composition and compile-time engine selection; **HARDEN**.
- **Vanish analog / target:** packaged mode always resolves bundled resources; production distribution constructs only the verified `BundledProvisioningEngine`, while development composition lives in a separate build configuration/target.
- **Tests/physical:** factory/source checks and mounted-DMG launch; helper absence/tamper UX.
- **Migration/security/rollback:** no runtime backend environment selector; rollback is a prior signed app.

### `macos/Package.swift`
- **Current role / status:** targets, defines, resources, native linkage; **REFACTOR NARROWLY**.
- **Target/change:** isolate development-only engines/tools from distribution dependency graph; declare new state/provider/runtime modules and test fakes; preserve pinned native bridge linkage.
- **Tests/physical:** `swift package describe`, clean two-architecture builds, packaged dependency scan; no direct device test.
- **Migration/security/rollback:** incremental target moves; avoid exposing test/development resources in Veya.app.

### `macos/Sources/IOSSimMacCore/SetupStore.swift`
- **Current role / status:** UI orchestration, generation checks, friendly errors; live defaults can leak into tests and persisted checkpoints overstate readiness.
- **Vanish analog / target / action:** one guided installer controller; presentation adapter over one V2 reconcile API; **REFACTOR**.
- **Exact change / dependencies:** remove domain decisions and protocol details; render typed phase, user action, last verified domains, cancel/resume; depends on schema 5 and engine envelope.
- **Tests / physical:** hermetic route/action/cancel/resume tests; full setup UX on clean account/device.
- **Migration / security / rollback:** decode schema 4 through helper migration; never hold passwords/2FA; feature flag can retain old view model for one rollback release.

### `macos/Sources/IOSSimMacCore/Services/IOSSimSetupEngine.swift`
- **Current role / status:** engine protocol with evolving defaults; **REFACTOR** to `protocolInfo`, `reconcile`, `performAction`, `status`, `cancel` typed DTOs.
- **Vanish analog:** stable Electron-to-helper command surface.
- **Dependencies/change:** schema 5 models and error envelope; remove behavior-bearing protocol defaults after mocks conform.
- **Tests/physical:** compatibility/unknown-field/framing tests; none direct.
- **Migration/security/rollback:** support one prior helper protocol; bounded payloads; keep adapter for one release.

### `macos/Sources/IOSSimMacCore/Services/BundledProvisioningEngine.swift`
- **Current role / status:** launches embedded helper; **HARDEN**.
- **Target/change:** fixed bundle-relative path; validate nested signature/team/hash against release manifest; negotiate protocol/schema before command; bound output/time/cancellation; reject environment path override in distribution builds.
- **Tests/physical:** fake-process, tamper, timeout, mounted-DMG launch; no secrets in argv/logs.
- **Migration/rollback:** accept previous protocol only when manifest declares it; rollback by app release, never repo helper.

### `macos/Sources/IOSSimProvisioner/main.swift`
- **Current role / status:** command parser/composition root; independent invocations can race; **REFACTOR**.
- **Target/change:** expose protocol-info and one domain reconcile/action/status/cancel surface; acquire keyed cross-process lease; compose only production services; keep legacy commands hidden until callers migrate.
- **Tests/physical:** CLI contract, concurrent processes, kill/recovery, malformed JSON; packaged end-to-end.
- **Migration/security/rollback:** migrate under lock; environment allowlist; legacy dispatcher retained one release.

## Provisioning, models, and persistence

### `macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift`
- **Current role / status:** substantial linear sign/install/developer-services/pairing/VPN flow; **REFACTOR**.
- **Vanish analog/target:** automated installer plus repair commands; domain reconciler invoking `check/repair/verify`, invalidation graph, smallest repair.
- **Change/dependencies:** schema 5 store/lease first; separate install from readiness; add staged renewal and real runtime proof; retain current native services.
- **Tests/physical:** injected fault after every mutation, idempotence, reconnect, wrong team; complete physical matrix.
- **Migration/security/rollback:** import old manifest as hints; redact receipts; rollback each candidate independently.

### `macos/Sources/IOSSimMacCore/Services/ConsumerProvisioningBackend.swift`
- **Current role:** native/legacy routing policy; **REFACTOR** to compile-time native production policy.
- **Change:** move Xcode/devicectl/environment selectors to development target; no automatic consumer fallback.
- **Tests/physical:** source/routing checks and native parity lab; rollback requires a signed prior release, not runtime selector.

### `macos/Sources/IOSSimMacCore/Services/ConsumerProvisioningStateStore.swift`
- **Current role:** singleton JSON with actor serialization only; **REPLACE**.
- **Target/change:** directory per hashed setup key, snapshot + append journal + generation CAS + `flock`/equivalent lease; atomic/fsynced replacement; corruption quarantine; schema-4 importer.
- **Tests/physical:** multi-process writers, SIGKILL at every boundary, disk-full/corrupt file, multi-team/device; reboot resume.
- **Security/migration/rollback:** 0700 directories, safe aliases, no raw secrets; copy-on-read migration and preserved backup; reader can revert for one release.

### `macos/Sources/IOSSimMacCore/Models/ConsumerProvisioning.swift`
- **Current role:** schema-4 checkpoint/state DTOs; **REFACTOR** schema 5.
- **Change:** add `SetupKey`, domain states/receipts, candidate IDs, invalidation causes, operations, typed actions/errors, runtime proof; checkpoints become derived compatibility values.
- **Tests:** roundtrip, forward fields, migration, expiry/invalidation property tests; no physical direct.
- **Risk/rollback:** avoid secrets/raw UDIDs; dual decode, write schema 5 only after migration commit.

### `macos/Sources/IOSSimMacCore/Models/ArtifactManifest.swift`
- **Current role:** payload metadata without full release authority; **REFACTOR**.
- **Change:** manifest V2 includes observed architectures, nested hashes/signatures, helper/bridge protocols, state/wire schemas, payload IDs/hashes, source commit/dirty/channel; validator consumes mounted artifact facts.
- **Tests/physical:** mutate every field/component and require failure; final notarized DMG audit.
- **Migration/security/rollback:** versioned decoder; signature/hash trust rooted in release policy.

### `macos/Sources/IOSSimMacCore/Models/DoctorStatus.swift`
- **Current role:** doctor/helper/domain health conflated; **REFACTOR**.
- **Change:** separate engine integrity, dependency, device, Apple, signing, install, developer-service, pairing, VPN, runtime health; stable Veya errors and actions.
- **Tests:** decoding and user-message snapshots; ensure no “could not find doctor.”

## Apple provisioning and signing

### `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamExperimental.swift`
- **Current role:** public service concepts mixed with experimental naming; **REFACTOR/RENAME** to stable `ApplePersonalTeamService` protocols and domain results.
- **Vanish analog:** sideloader command surface.
- **Change:** no GrandSlam constants/types above adapter boundary; define idempotency and error taxonomy.
- **Tests/physical:** pure contract fakes; Personal Team account matrix later.
- **Migration/security/rollback:** typealiases/adapters for callers; ephemeral secret inputs.

### `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift`
- **Current role:** working private/version-bound auth/developer services; **REFACTOR**, retain behavior.
- **Change:** extract `AKD2026Adapter`, machine metadata provider, auth client, developer client; protocol fingerprint/compatibility failure, kill switch, read-before-create, bounded retries.
- **Tests/physical:** captured redacted response fixtures for all errors; opt-in account tests only.
- **Security/migration/rollback:** Keychain session references, never password/2FA logs; keep previous adapter disabled but selectable by signed compatibility policy.

### `macos/Sources/IOSSimMacCore/Services/NativeSigningIdentityResolver.swift`
- **Current role:** exact certificate/private-key resolver and access handling; **HARDEN**.
- **Change:** active/candidate identity inventory, `/usr/bin/codesign` disposable access probe, renewal promotion, managed orphan-reference cleanup; never broad-delete Keychain items.
- **Tests/physical:** mocked Security API and opt-in isolated Keychain; GUI/helper/codesign ACL validation.
- **Migration/rollback:** tag Veya-managed keys; keep active until candidate signed artifact verifies.

## Native device, installation, and developer support

### `macos/Sources/IOSSimMacCore/Services/NativeDeviceBridge.swift`
- **Current role:** dynamic C ABI wrapper; no initial pair; **REFACTOR ABI v2**.
- **Change:** protocol negotiation; pair state/request/poll/validate receipts; exact mux ID/type in handle; typed DDI/AppService errors; production library path fixed.
- **Tests/physical:** fake ABI ownership/errors/duplicate device records; never-trusted phone and USB/Wi-Fi duplicate.
- **Migration/security/rollback:** retain ABI v1 read-only operations for one release; pair records never logged/exported.

### `native/iossim-device-bridge/include/iossim_device_bridge.h`
- **Current role:** C ABI declarations; **REFACTOR**.
- **Change:** versioned `iossim_bridge_pair_once`, pair validation/state structs, selected connection receipt, bounded buffers/free functions; document thread/ownership rules.
- **Tests:** C/Swift layout and compatibility compilation; security-sensitive output review.

### `native/iossim-device-bridge/src/lib.rs`
- **Current role:** idevice implementation for discovery/install/DDI/AppService; **REFACTOR**.
- **Change:** select by `(stable UDID, expected mux ID/type)` before opening; wrap `LockdownClient::pair_once` while preserving Trust; persist through provider facilities; validate session; retain current mount/readiness/launch.
- **Tests/physical:** Rust selector/pair state/error tests with fake usbmux; initial Trust, disconnect, denial, multiple records, AppService launch.
- **Security/rollback:** no trust bypass/pair record output; ABI v1 symbols remain during transition.

### `native/iossim-device-bridge/Cargo.toml` and lockfile
- **Current role:** pinned idevice dependency; **KEEP PIN/HARDEN**.
- **Change:** enable only required pairing features; record revision; generate SBOM/notices; offline reproducible build; separate upgrade PRs.
- **Tests:** license policy, lock consistency, universal slice build; rollback pin available.

### `macos/Sources/IOSSimMacCore/Services/NativeApplicationManagement.swift`
- **Current role:** AFC/PublicStaging, InstallationProxy inventory/install/upgrade/uninstall; **KEEP/HARDEN**.
- **Change:** operation ID and exact handle/artifact receipt, staged upgrade classification, post-install profile/team/version inventory, cancellation reconciliation.
- **Tests/physical:** fake faults and real install/upgrade/interruption; never uninstall unknown ownership.

### `macos/Sources/IOSSimMacCore/Services/NativeDeveloperServicesCoordinator.swift`
- **Current role:** readiness-first, cache-provider, native mount, RSD/AppService verification; **KEEP/REFACTOR**.
- **Change:** explicit acquisition/personalization/mount/tunnel/RSD/AppService receipts with TTL/build/device binding; call approved provider only after `DdiRequired`.
- **Tests/physical:** no-DDI, wrong build/hash, TSS outage, already mounted, missing AppService; fresh cache/device.

### `macos/Sources/IOSSimMacCore/Services/DeveloperSupportCoordinator.swift`
- **Current role:** integrity/cache abstractions and native mounter, but no fresh approved source; **REFACTOR, BLOCKED PROVIDER**.
- **Change:** provider provenance/signature/revocation/cache contract; exact build selection; no developer-Mac cache as release success criterion; implement selected source only after ADR approval.
- **Tests/physical:** provider fixtures/cache corruption/rollback; cleared cache and new supported iOS build.
- **Security/migration/rollback:** quarantine untrusted assets; cache may be deleted without affecting active installation; no third-party fallback.

## Pairing, VPN, and runtime

### `macos/Sources/IOSSimMacCore/Services/RemotePairingLifecycle.swift`
- **Current role:** generation, AES-GCM transfer/import receipt, destructive forced repair/no-op proof; **REFACTOR**.
- **Change:** active/candidate slots, unique request key/nonce/request ID, transcript binding, phone possession challenge, operational developer-service proof, atomic promotion, grace cleanup.
- **Tests/physical:** replay/mismatch/crash at each edge/crypto vectors; first import, forced repair, rollback, reboot.
- **Migration/security/rollback:** migrate old active as slot 0; never delete it until proof; redact all secrets.

### `ios/Sources/IOSSimOnDeviceDVTPOC/AutomaticPairingInbox.swift`
- **Current role:** request/bootstrap/import/receipt and Keychain storage; **REFACTOR**.
- **Change:** request-specific bootstrap expiry; candidate Keychain label; challenge sign/MAC response; promote/abort commands; current-device binding and idempotent receipt.
- **Tests/physical:** relaunch, stale/replay/wrong request, Keychain access; real repair/reboot.

### `macos/Sources/IOSSimMacCore/Services/LocalDevVPNSetupCoordinator.swift`
- **Current role:** launches external bundle and checks endpoint; **REFACTOR**.
- **Change:** inventory/version, App Store-required action, native launch, request-bound phone coordination, VPN permission state, authenticated endpoint plus developer-service proof, timeouts.
- **Tests/physical:** missing/old app, denied/pending approval, relaunch, endpoint impostor; real Apple VPN prompt.

### `ios/Sources/IOSSimOnDeviceDVTPOC/LocalDevVPNSetupInbox.swift`
- **Current role:** one-shot phone setup inbox; **REFACTOR**.
- **Change:** durable request state/expiry, scene-active observer, idempotent acknowledgements, URL/App Store handoff as approved, authenticated readiness receipt.
- **Tests/physical:** foreground cycles, restart, stale/replay; phone approval.

### `ios/App/IOSSimOnDeviceDVTPOCApp.swift`
- **Current role:** root lifecycle and `.task`; **REFACTOR narrowly**.
- **Change:** observe `scenePhase`; resume pairing/VPN reconciliation on active; keep UI/runtime ownership unchanged.
- **Tests/physical:** lifecycle simulation and background/foreground during setup.

### `ios/Sources/IOSSimOnDeviceDVTPOC/DvtLocationClient.swift`
- **Current role:** retained RSD, TestManager/XCTest, location and cadence runtime; **KEEP/HARDEN proof hook**.
- **Change:** expose bounded proof receipt for runner stage, write acknowledgement/effect signal, clear, session/device IDs; do not alter scheduler/writer semantics.
- **Tests/physical:** existing checks plus proof success/failure/cleanup; 2 Hz/1 Hz/hold/resume/clear regression drive.

### `macos/Sources/IOSSimMacCore/Services/RuntimeProvisioningSupport.swift`
- **Current role:** runtime orchestration plus legacy paths; **REFACTOR**.
- **Change:** `RuntimeVerificationService`; start exact runner via native path, require Rich proof, expire receipt; isolate then remove devicectl/Xcode consumer routes.
- **Tests/physical:** fake runner stages/timeouts/clear; actual AppService/TestManager/Rich proof.

### `macos/Sources/IOSSimMacCore/Services/SupportBundleExporter.swift`
- **Current role:** broad persistence export; **REPLACE** schema 8.
- **Change:** construct allowlist DTO with rotating device/account aliases, codes/stages/timing/release facts; post-export scanner rejects passwords/tokens/cookies/private keys/pair records/PSKs/raw UDIDs/profile blobs.
- **Tests/physical:** golden output and adversarial secret corpus; support review only.

## Phone project and checks

### `ios/IOSSimOnDevicePOC.xcodeproj/project.pbxproj`
- **Current role:** phone target membership; **REFACTOR NARROWLY** to include new lifecycle/protocol files and tests; no project-wide rewrite.
- **Tests:** archive membership, no duplicate resources; migration risk controlled by minimal diff.

### `ios/Sources/POCUnitChecks/main.swift`
- **Current role:** compiled phone unit checks; **KEEP/EXTEND** with pairing/VPN wire versions, expiry/replay, scene reactivation, runtime-proof cleanup.
- **Physical:** run as part of signed payload qualification; no secrets.

## Build, release, and regression tooling

### `macos/scripts/build_app.sh`
- **Current role:** divergent app assembler with stale schema literal/host architecture; **REPLACE then DELETE_LATER**.
- **Change:** thin call into canonical release library; may build dev app but cannot author provenance.
- **Tests/physical:** byte/manifest equivalence; actual universal or architecture-specific output as declared.

### `scripts/bootstrap/iossim_cli.py`
- **Current role:** strongest build/release orchestration but monolithic and copies desired metadata; **REFACTOR**.
- **Change:** shared assembler/auditor; inspect built Mach-O/plists/hashes/signatures/schemas; mount final DMG and derive signed manifest; notarize/staple/publish one canonical name.
- **Tests/physical:** hermetic artifact mutations, local DMG, final notarized clean-Mac launch.

### release tooling and release manifest
- **Current role:** local/release commands and sidecars can disagree with artifacts; **REPLACE authority model**.
- **Change:** one build graph and manifest V2 generated from mounted bytes; publish draft, download, hash/audit, then promote; immutable release identity.
- **Tests:** architecture/schema/helper/payload/commit/sign/notarization mismatch must fail; rollback retains prior immutable release.

### `scripts/checks/check_no_xcode_consumer_runtime.py`
- **Action:** **KEEP/EXTEND** to reject consumer `DevelopmentCLIEngine`, repo lookup, environment selectors, Xcode/devicectl/xcodebuild, and unmanifested dependencies.

### `scripts/checks/check_no_xcode_install_routing.py`
- **Action:** **KEEP/EXTEND** to assert native discovery/pair/install/DDI/AppService/pairing/VPN/runtime graph and production composition.

### `scripts/checks/test_device_discovery_cli.py`
- **Action:** **KEEP/EXTEND** with duplicate UDID/mux ordering, pair states, disconnect/reconnect, and safe fake records.

### relevant `macos/Tests/IOSSimMacCoreTests/*`
- **Current problem/action:** several mocks rely on defaults/real stores; **REFACTOR tests** to explicit temp roots, clocks, Security/Apple/device fakes, and complete protocols.
- **Gates:** classify/fix all saved failures by owning milestone; tests must never touch real user Keychain, Apple session, device, defaults, or Application Support.
