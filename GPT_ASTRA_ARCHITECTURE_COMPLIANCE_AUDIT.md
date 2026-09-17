# GPT Astra Architecture Compliance Audit

Baseline: `work/investigate-native-app-launch-v1` at `1259da507ecded222022cc86bf82863c15640db9`, before production changes from this audit. The final research package in `/Users/rishiborra/Desktop/VanishedResearch.mSgdHk/FINAL_PREIMPLEMENTATION/` is the architecture specification.

## Target architecture

```text
IOSSim SwiftUI Mac app
  -> one consumer setup state machine
  -> IOSSim-owned readiness/recovery + versioned setup journal
  -> native Apple Personal Team auth/provisioning
  -> versioned prebuilt iPhone payload manifest
  -> native profile embedding + signing
  -> one IOSSim native device abstraction
  -> pinned Rust idevice bridge
  -> usbmux / Lockdown / AMFI / MobileImageMounter / AFC /
     Installation Proxy / House Arrest / CoreDeviceProxy /
     one RSD + RemoteXPC primitive / AppService / DVT/TestManager
  -> physical iPhone

iPhone IOSSim app
  -> LocalDevVPN
  -> automatic RemotePairing
  -> retained RSD
  -> DVT/TestManager
  -> XCTest runner / XCUILocation
  -> Spoof / Rich Drive (frozen runtime)
```

Core rule: persisted checkpoints are hints. Current physical evidence determines the next safe stage.

## Compliance matrix

| Area | Astra target | Current implementation | Current files/symbols | Physical validation | Legacy path present? | Legacy reachable? | Migration required? | Gap | Recommended action |
|---|---|---|---|---|---|---|---|---|---|
| Device discovery | Pinned native usbmux/Lockdown | Native Rust bridge, normalized Swift descriptors | `NativeDeviceBridge.swift`, Rust `list_devices` | **PHYSICAL_PASS** | Python/devicectl comparison code | Not packaged consumer route | No | Protected pass | Keep native-only assertion/tests |
| Stable device identity | Typed identity with namespace conversions and reconnect generation | Typed model exists; many operations reconstruct from UDID and discard mux/generation/services IDs | `IOSSimDeviceIdentity`, `rawDeviceIdentifier`, `withHandle` | Discovery/install pass; AppService unresolved | Yes, string IDs | Partly | Yes, derived state | Identity context is lossy and error classification is broad | Persist canonical UDID only; re-resolve complete live identity; report namespace |
| Lockdown | Native pairing/trust/value reads | Native bridge | bridge/Rust lockdown | **PHYSICAL_PASS** | Old CLI | No consumer fallback | No | None for setup | Protect regression |
| Developer Mode detection | Separate readiness domain | Exposed through native inspection/doctor, but live UI collapses readiness | `DoctorStatus`, `SetupStore` | Previously observed | Yes | Live old aggregate model | Yes | Astra domain coordinator unwired | Integrate domain snapshot without changing runtime |
| Device trust | Separate computer-trust domain | Doctor checks/events; support often says UNKNOWN | same | Lockdown pass | No meaningful fallback | N/A | Yes | Not authoritative in journal | Record current probe evidence |
| Apple auth | IOSSim-owned GrandSlam SRP, Keychain session | Live native implementation and session reuse | `ApplePersonalTeamLive.swift` | Auth has succeeded | Historical Xcode Accounts | Native request uses native | Preserve valid record | Diagnostics/schema incomplete | Keep secret; version metadata |
| Personal Team discovery | Native portal API | Implemented | `ApplePersonalTeamLive`, `SetupStore.applyExperimentalTeams` | Passed in current state | Xcode discovery remains | Explicit legacy only | No wipe | Routing guard needed | Fail closed in consumer helper |
| Certificate management | IOSSim-owned key + cert lifecycle | Implemented with Keychain metadata | `IOSSimIdentityMetadataStore` | Used for physical installs | Xcode branch remains | Only legacy backend | Preserve/migrate metadata | Renewal integration unwired | Keep valid assets; validate team/profile |
| App ID management | Deterministic App IDs | Implemented for main/UI test/runner | `PersonalTeamBundleIdentifierSet` | Physical install pass | Witness/source IDs remain in dev project | Consumer manifest rejects witness | Maybe provenance | No stale installed inventory now available | Reconcile current native inventory |
| Profile creation | Native portal profiles, reusable artifact store | Implemented, schema 1 JSON | `NativeProvisioningArtifactStore` | Physical install pass | Xcode profile creation branch | Request-dependent | Yes | Strict schema rejection, no migration | Versioned compatible migration |
| Device registration | Idempotent native portal registration | Implemented | Apple Personal Team services | Physical provisioning pass | Xcode auto-register branch | Legacy only | No | None proven | Protect tests |
| Payload preparation | Prebuilt unsigned/re-signable payloads | Consumer copies two manifest payloads; old SigningShell branch can compile | `prepareArtifacts`, `prepareNativeArtifacts` | Packaged payload used physically | Yes | Source branch reachable through explicit legacy backend/helper | Yes | Consumer fail-closed guarantee incomplete | Reject nonnative backend in production helper |
| Payload signing | Native profile embedding/codesign | Implemented | `ConsumerArtifactProvisioner` | **PHYSICAL_PASS** as part install | Xcode SigningShell | Legacy branch | Preserve identity | Source separation incomplete | Keep native path; report provenance |
| Main install | Native AFC staging + Installation Proxy | Implemented shared native service | `IdeviceProvisioningBackend` | **PHYSICAL_PASS** | devicectl backend | Not current composition; explicit helper/env surfaces remain | No | Retry always/incorrectly resumes | Reconcile and install only missing |
| Runner install | Same native route | Implemented | same | **PHYSICAL_PASS** | devicectl | Same | No | Same | Same |
| Inventory | Native Installation Proxy | Implemented during provision | `NativeApplicationInventoryReader` | **PHYSICAL_PASS** | devicectl reader | Historical default fixed; code remains | State correction needed | Not called for most resume checkpoints | Always reconcile before trusting checkpoint |
| Uninstall | Native and ownership-scoped | Implemented backend | native app management | Unvalidated in this audit | devicectl implementation | Explicit developer only | No | No destructive validation | Keep guarded; do not uninstall now |
| Launch | AppService over CoreDeviceProxy/RSD/RemoteXPC | Newly implemented | `NativeAppServiceLauncher`, Rust `launch_app` | **UNVALIDATED/FAILED `deviceNotFound`** | devicectl launcher | Not current native composition | Maybe identity diagnostics | Broad not-found mapping; stale install checkpoint can launch missing app | Clean state routing first, then retest |
| Container access | Native House Arrest/AFC | Wired for config write/readback | `NativeApplicationService.writeContainer/readContainer` | Installation AFC pass; container readback not isolated after native launch | devicectl copy | Not current composition | Yes for readiness evidence | Coupled to launch stage | Report separate domain; validate later |
| House Arrest | Shared native primitive | Implemented/wired | bridge + native management | **UNVALIDATED** separately | Legacy copy route | No current | No | Evidence gap | Physical test after launch |
| Runtime mapping | Transfer deterministic installed IDs | Prepared and written after launch | `advanceRuntimeConfiguration` | Historical COMPLETE from older payload; current native launch blocked | Old mappings persist | Yes through manifest | Yes | Persisted READY can coexist with INSTALLATION_VERIFIED | Derive, do not blindly trust |
| RemotePairing | Automatic Mac lifecycle + secure container delivery | Coordinator and phone inbox exist | `RemotePairingLifecycle.swift`, `AutomaticPairingInbox.swift` | **UNVALIDATED/UNWIRED** | Manual plist UI remains phone-side | Manual flow is still actual runtime path | Yes | Major Astra gap | Integrate after Stage A/B routing cleanup |
| Pairing persistence | Mac and phone Keychain, versioned/enveloped | Implemented scaffolding; no Mac record exists | Keychain services | No current record | Manual iPhone Keychain | Yes on phone UI | Yes when integrated | Two unrelated stores | Converge lifecycle later, preserve valid records |
| DDI | Asset/TSS/mount coordinator | Source scaffold | `DeveloperSupportCoordinator.swift` | **UNVALIDATED/UNWIRED** | Old Xcode preparation assumptions | Not current live setup | Yes | No production caller | Integrate common developer-service readiness later |
| TSS personalization | Native and cached by identity/build | Source scaffold | developer support models/providers | **UNVALIDATED** | Xcode mounting assumptions | No current consumer route | Yes | Provider/live wiring gap | Follow Astra phase gates |
| RSD | One common developer-services primitive | Runtime has retained RSD; launch creates a separate per-launch tunnel/RSD handshake; coordinator unwired | Rust bridge, iPhone DVT runtime | Runtime previously proven; launch failed | Multiple constructions | Yes, parallel stacks | Yes | Shared primitive not yet explicit | Do not merge blindly; normalize lifecycle after evidence |
| RemoteXPC | Common RSD client primitive | Rust AppService and runtime vendor patch | Rust idevice | AppService unvalidated | None intended | N/A | No | Diagnostics gap | Preserve pinned revision |
| AppService | Native launch | Implemented, newly wired | `NativeAppServiceLauncher` | Failed `deviceNotFound` | devicectl launch | No current fallback | Maybe | Failure source ambiguous | Retest only after reconciliation |
| TestManager | Frozen runtime over retained RSD | Existing phone implementation | `DvtLocationClient`, idevice patch | Prior runtime baseline preserved | Xcode developer workflows | Consumer runtime uses phone stack | No | Setup readiness not integrated | Preserve |
| XCTest runner | Prebuilt/re-signed runner | Bundled consumer component | DeviceArtifacts manifest/provisioner | **PHYSICAL_PASS install** | On-demand build exists build-time | Not consumer native route | Payload provenance | Current payload commit can lag GUI | Separate provenance fields |
| XCUILocation | Frozen implementation | Existing | iOS test target/runtime | Prior evidence | No consumer alternative | N/A | No | None in Stage A | Preserve |
| Rich Drive | Frozen proven runtime | Existing | iOS sources | Prior evidence | No | N/A | No | None | Preserve |
| Renewal | Mac-assisted 7-day in-place renewal | Planner/scaffold tests only | `MacAssistedRenewal.swift` | **NOT_IMPLEMENTED live** | Xcode renewal history | No current coordinator route | Yes | Live scheduling/state absent | Ensure checkpoint model is renewal-compatible |
| Readiness/recovery | Domain-specific authority | Models exist but SetupStore uses aggregate DoctorStatus and manifest history | `ReadinessRecovery.swift`, `SetupStore` | Partial | Old aggregate flow | Active | Yes | Major integration gap | Make physical reconciliation authoritative first |
| Support diagnostics | Component provenance + derived/persisted checkpoint and reconciliation | Partial GUI/helper/bridge fields; payload commit conflated/missing; no retry reconciliation fields | `SupportBundleExporter`, BuildProvenance | Support zips captured | Legacy sourceCommit | Yes | Schema bump | Cannot distinguish payload/GUI in several artifacts | Add fields and explicit false fallback/build flags |
| Consumer packaging | Payloads mandatory, hashed, manifest-versioned | Release assembly requires payloads; raw `build_app.sh` can produce an app without them | Python packaging, `build_app.sh` | Installed app has payloads; local app lacks them | Repository build products | Build script ambiguity | Yes | Missing distribution can reach GUI doctor as an error instead of build failing | Fail build with `PAYLOAD_MISSING_FROM_DISTRIBUTION` |
| Xcode independence | No xcodebuild/xcrun/devicectl at consumer runtime | Current native GUI path does not call `./iossim build`; legacy implementations and permissive selectors remain | multiple | Discovery/install physical passes without Xcode | Yes | Not through current native graph; guard insufficient | No state wipe | Static audit misclassifies active files as legacy | Repair audit and fail-closed composition |

## Summary

- **Aligned/physical pass:** discovery, Lockdown, native auth/provisioning/signing, native main and runner install, native inventory.
- **Partially aligned:** identity, readiness, container access, runtime configuration, diagnostics, packaging, Xcode isolation.
- **Not aligned/unwired:** automatic pairing, live DDI/TSS readiness, renewal, one shared developer-services/RSD lifecycle.
- **Proven interference:** stale checkpoint/resume semantics and provenance/payload generation ambiguity.
- **Not proven:** stale UserDefaults, Keychain metadata, or selected-device value causing the AppService failure. The selected canonical UDID matches the physically successful install path.

## Post-correction status

The evidence-supported Stage B changes close the setup-routing blockers identified above:

- `SetupStore` now requests physical reconciliation on app/setup refresh and Try Again.
- `ConsumerArtifactProvisioner.resumeSetup` always reconciles native inventory before interpreting a checkpoint.
- Missing main, runner, or both routes through the same native repair path; exact current components are skipped, so repair is component-idempotent.
- A previously verified runtime mapping is read back through native container access during reconciliation. Failure derives `INSTALLATION_VERIFIED` instead of trusting `COMPLETE`.
- Schema 1 setup state migrates to schema 2 without deleting auth/signing data; absent legacy checkpoints conservatively become `INSTALLATION_VERIFIED`.
- Packaged helper requests reject Xcode provisioning backends, AUTO has no Xcode fallback, and the deterministic helper environment no longer inherits `DEVELOPER_DIR`.
- Mac app packaging now requires a verified prebuilt payload manifest and emits `PAYLOAD_MISSING_FROM_DISTRIBUTION` if absent.
- Support schema 6 and BuildProvenance distinguish GUI, helper, payload, bridge, setup schema, backends, persisted/derived state, and explicit false legacy/build flags.

The remaining PARTIAL/NOT_IMPLEMENTED rows—automatic pairing, live DDI/TSS readiness, shared developer-service lifecycle, and renewal scheduling—remain deliberate follow-on Astra gates. They were not papered over with a second temporary runtime.
