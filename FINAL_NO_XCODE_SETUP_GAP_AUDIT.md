# Final No-Xcode Setup Gap Audit

Audit date: 2026-09-15 (America/New_York)  
Branch: `work/final-no-xcode-setup-v1`  
Baseline HEAD: `1259da507ecded222022cc86bf82863c15640db9`  
Working tree: intentionally dirty; it contains the physically proven native discovery/install/reconciliation continuation and the first AppService bridge implementation.

## Governing decisions

- The final Astra research package in `/Users/rishiborra/Desktop/VanishedResearch.mSgdHk/FINAL_PREIMPLEMENTATION/` is the design specification.
- Persisted setup checkpoints are hints. Current physical inventory and current session readiness are authoritative.
- Discovery remains `NATIVE_IDEVICE_USBMUX`; installation remains `NATIVE_AFC_INSTALLATION_PROXY`; launch remains `NATIVE_APPSERVICE_RSD`.
- The pinned idevice revision remains `1838db107d38701b4044361163aac049006c2627`.
- USB Lockdown pairing, CoreDevice developer-service readiness, and runtime RemotePairing are separate relationships.
- No consumer Xcode, `xcodebuild`, `xcrun devicectl`, Python device stack, runtime start, XCTest start, location spoof, or drive operation is allowed in this work.

## Gap matrix

| Subsystem | Astra target | Current implementation | Current files / symbols | Current backend | Production composed? | Physical status | Missing pieces | Dependencies | Proposed action |
|---|---|---|---|---|---|---|---|---|---|
| AppService launch | Exact current bundle launched over shared CoreDeviceProxy -> software tunnel -> RSD -> RemoteXPC -> AppService | Rust launch export and Swift launcher exist | `iossim_bridge_launch_app`; `DynamicNativeDeviceTransport.launchApplication`; `NativeAppServiceLauncher`; `ConsumerArtifactProvisioner.launchMainForRuntimeConfiguration` | `NATIVE_APPSERVICE_RSD` | Yes | Failed as `deviceNotFound`; manual phone launch passes | Layer diagnostics; readiness gate; service/feature/application error separation | live selected identity, Developer Mode, optional DDI, RSD map | Add typed developer-service probe; route launch through it; preserve exact bundle ID |
| CoreDeviceProxy | One shared developer-services primitive | Constructed inline only inside Rust launch | `CoreDeviceProxy::connect` in `iossim_bridge_launch_app` | pinned idevice | Launch only | Unproven | Separate status and error; reusable preparation function | trusted selected device; service availability | Add native readiness receipt and stage-specific result |
| Software tunnel | Reusable session-scoped tunnel | Constructed inline per launch | `create_software_tunnel` | pinned idevice `tunnel_tcp_stack` | Launch only | Unproven | Explicit status/error; reconnect semantics | CoreDeviceProxy | Probe and report independently; do not persist live handles |
| DDI | Exact-build personalized image with explicit state | Coordinator scaffold and bridge mount/status exports | `DeveloperSupportCoordinator`; `iossim_bridge_developer_support_status`; `iossim_bridge_mount_developer_support` | pinned idevice MobileImageMounter/TSS | No | Unvalidated | Production composition; correct mounted query; requirement model; cache receipt; approved source | Developer Mode, device/build identity, approved asset provider | Correct probe and integrate; fail typed when approved source is absent |
| TSS personalization | Device/build-bound request and validated ticket | idevice `mount_personalized` performs device query, SHA-384 manifest lookup, reconnect, TSS request, upload and mount | `ImageMounter::mount_personalized`; `NativeDeveloperSupportDeviceService` | pinned idevice TSS | No | Unvalidated | Typed stage errors and receipt metadata; production call site | exact BuildManifest/image/trust cache | Keep ticket inside Rust; expose only safe stage/result |
| Developer image acquisition | Existing authorized cache or IOSSim-approved signed HTTPS manifest | Read-only Apple-cache metadata provider only | `ExistingAppleCacheProvider`; `DeveloperSupportArtifact` | local approved cache | No | No matching asset found on this Mac | No approved IOSSim provider endpoint/manifest/signing key exists in repository; redistribution/runtime-fetch rights unresolved | release operations/legal approval | Implement provider contract/cache selection; do not invent a source; report `NO_APPROVED_SOURCE` |
| Developer image mount | Upload/mount/re-query exact Personalized image | Rust mount exists; Swift service calls it | `iossim_bridge_mount_developer_support`; `DynamicNativeDeviceTransport.mountDeveloperSupport` | MobileImageMounter | No | Unvalidated | Correct pre/post query and stage mapping | approved exact asset and TSS | Integrate into readiness repair after requirement probe |
| RSD | Typed service-map readiness after tunnel | Inline handshake in launch; scaffold RSD probe always fails | `RsdHandshake::new`; `AwaitingPhysicalRSDProbe` | pinned idevice | Partly | Runtime RSD historically proven; Mac setup RSD unproven | Production readiness probe and service map receipt | CoreDeviceProxy/tunnel, DDI if required | Add native readiness probe shared by DDI/AppService/pairing policy |
| RemoteXPC | AppService connection/feature verification | Implicit in `AppServiceClient::connect_rsd` | pinned idevice `CoreDeviceServiceClient` | pinned idevice | Launch only | Unproven | Explicit handshake/AppService feature state | RSD map | Include in readiness receipt and typed errors |
| Developer-services readiness | Separate Developer Mode/DDI/proxy/tunnel/RSD/RemoteXPC/AppService facts | No live coordinator; setup jumps from install to launch | scaffolds plus inline launch | none coherent | No | Failed at ambiguous launch boundary | One production orchestration path and safe diagnostics | device inspection and DDI provider | Extend the existing provisioning/reconciliation path, not a second setup engine |
| House Arrest | One native container service shared by config and pairing | Native vend-container read/write implemented | `HouseArrestClient`; `NativeApplicationService.readContainer/writeContainer` | native House Arrest + AFC | Yes for calls | AFC staging passed; House Arrest container path unvalidated | Typed container errors; shared reconciliation service | installed current main app; unlocked/trusted device | Reuse this service for config and pairing; add semantic receipts |
| AFC container access | Allowlisted app-private paths and bounded bytes | Implemented, path validated in Swift/Rust | `iossim_bridge_container_write/read`; `NativeApplicationPathPolicy` | native House Arrest + AFC | Yes | Unvalidated through House Arrest | Operation-specific status and safe diagnostics | House Arrest VendContainer | Preserve path policy; add missing-directory-safe write behavior |
| Runtime mapping write | Deterministic schema/version/team-derived bundle mapping, idempotent | An unused JSON writer exists; production flow currently relies on app Info.plist -> UserDefaults | `NativeApplicationManager.writeAndVerifyRuntimeMapping`; `Gate3XCTestRunnerBundleIdentifierResolver` | native House Arrest + AFC target | No | Historical mapping succeeded; native write not proven | Choose one canonical delivered config and make phone consume it | installed main/runner IDs | Use existing `runtime-mapping.json` scaffold as canonical delivered setup receipt while retaining Info.plist/UserDefaults fallback for runtime compatibility |
| Runtime mapping readback | Native readback and semantic comparison | Production reads app preferences plist; JSON writer compares bytes only | `verifyPersistedRunnerMapping`; `writeAndVerifyRuntimeMapping` | native House Arrest + AFC | Partly | Historical readback pass; current native path unvalidated | Semantic JSON verification; migration/fallback readback | container access | Write only if stale/missing; read back and decode fields, not byte equality |
| Automatic RemotePairing | Create/reuse, validate, persist, deliver, receipt, setup-only verification | Mac coordinator and Rust create/validate exist but are test-only | `RemotePairingCoordinator`; `iossim_bridge_create_remote_pairing`; `iossim_bridge_validate_remote_pairing` | pinned idevice RemotePairing lockdown | No | Unvalidated | Production composition, bootstrap exchange, receipt polling, classified repair, journal metadata | trusted device, launched current app, House Arrest | Integrate after config using the same container service |
| Pairing persistence | Device/team scoped Keychain secret; safe metadata only elsewhere | Mac Keychain store exists; phone proven Keychain contract exists | `KeychainRemotePairingStore`; `KeychainRPPairingStore` | macOS/iOS Keychain | Mac store not composed | Phone manual import historically used | Strong semantic validation; metadata update; no generic regeneration | stable UDID + team + RP identifier/fingerprint | Preserve phone service/account; harden Mac validation and device association |
| Pairing delivery | Encrypted one-time envelope to app-private setup inbox | AES-GCM envelope and House Arrest writer exist | `RemotePairingEnvelope`; `NativeRemotePairingContainerDelivery`; `AutomaticPairingInboxProcessor` | House Arrest + AFC | No | Unvalidated | Bootstrap request/session exchange; phone startup processor; envelope deletion | launched current app/container | Add file-backed bootstrap/receipt protocol; keep secret only in encrypted envelope |
| Pairing receipt | Authenticated/bound acceptance receipt | Receipt structs and immediate read exist | `RemotePairingReceipt`; `AutomaticPairingReceipt` | app-private container | No | Unvalidated | Phone writes receipt; Mac bounded polling; app-build/binding evidence | phone startup inbox processor | Implement atomic receipt generation and polling; reject mismatched/old receipt |
| Pairing verification | Semantic record + explicit pair-verify + receipt without runtime start | Native record validation exists; operational proof is an always-failing stub | `NativeRemotePairingOperations.validate`; `AwaitingPhysicalRemotePairingProof` | RemotePairing lockdown | No | Unvalidated | Setup-scoped proof distinct from LocalDevVPN/TestManager runtime proof | selected device and receipt | Use explicit native pair-verify plus receipt as this task's setup gate; defer runtime proof |
| Setup state integration | Existing schema-2 physical reconciliation extended with independent domains and final gate | Manifest/checkpoint currently ends at runtime config/`COMPLETE`; separate readiness journal is unwired | `ConsumerProvisioningManifest`; `ConsumerSetupCheckpoint`; `ConsumerArtifactProvisioner`; `SetupStore` | bundled provisioning engine | Yes, but incomplete | Reconciliation/install repair passes | Developer-service/config/pairing facts and final state | all above domains | Extend schema and existing path; do not activate `ConsumerOnboardingCoordinator` |
| Recovery/retry | Try Again observes all domains and repairs first incomplete domain only | Inventory/config reconciliation only | `reconcileSetup`; `resumeSetup`; `SetupStore.retryCurrentStep` | bundled provisioning engine | Partly | Main-only repair passed | Session developer-service recheck, pairing reuse/delivery repair, typed budgets | independent domain receipts | Derive next repair from physical/session facts on every resume |
| Support diagnostics | Safe state for every setup domain and backend/provenance | Schema 6 covers install/provenance, not final domains | `SupportBundleExporter`; provisioning JSONL | allowlisted local export | Partly | Existing support bundles produced | Developer-service/config/pairing fields and events; secret tests | new typed snapshot | Add safe fields/events; never serialize pairing bytes/import key/nonce secret |

## Exact AppService failure graph and first proven defect

```text
ConsumerArtifactProvisioner.advanceRuntimeConfiguration
  -> launchMainForRuntimeConfiguration
  -> IdeviceProvisioningBackend.launch
  -> NativeApplicationService.launch
  -> NativeAppServiceLauncher.launch
  -> DynamicNativeDeviceTransport.launchApplication
  -> withHandle / iossim_bridge_open_device (stable Lockdown UDID)
  -> iossim_bridge_launch_app
  -> selected_device (UDID + connection-local usbmux id)
  -> IdeviceProvider
  -> CoreDeviceProxy::connect
  -> create_software_tunnel
  -> adapter.connect(server_rsd_port)
  -> RsdHandshake::new
  -> AppServiceClient::connect_rsd
  -> CoreDevice RemoteXPC handshake
  -> com.apple.coredevice.feature.launchapplication
  -> exact derived main bundle ID
```

The bridge's `error_result` currently maps any error message containing `not found` to `Status::DeviceNotFound`. The pinned idevice has distinct `NotFound`, `ServiceNotFound`, and `DeviceNotFound` variants. Therefore `ServiceNotFound` at CoreDeviceProxy/RSD/AppService is falsely surfaced as a missing physical device. This classifier defect is proven. The underlying first unavailable service is not recoverable from the existing physical artifact because the launch function does not annotate its stages. Developer trust, installation, checkpoint state, and Xcode absence are not supported root causes.

## Implementation plan

1. Add a versioned developer-services readiness receipt and stage-specific native errors; repair the false `deviceNotFound` mapping.
2. Make launch consume the same native readiness primitive and verify the exact bundle appears in AppService before launch.
3. Correct and compose DDI mounted/requirement/cache behavior. Support existing authorized cache and an explicit IOSSim-approved provider contract; fail closed when no approved source is configured.
4. Compose one House Arrest configuration reconciler using the existing runtime-mapping schema, idempotent semantic readback, and compatibility with the proven Info.plist/UserDefaults resolver.
5. Complete the file-backed phone bootstrap/envelope/receipt path, harden device-scoped Keychain persistence and classified RemotePairing reuse/repair, and use explicit pair-verify plus receipt for setup readiness.
6. Extend the schema-2 manifest/checkpoint and bundled helper IPC so Try Again, restart, and reconnect derive the first incomplete domain from live facts.
7. Add safe support fields/events, failure-injection/unit/static checks, build one authoritative retest app, and stop before runtime startup.

## Known pre-implementation blocker

No matching DDI asset exists in the repository or this consumer account's Apple cache, and no release-approved IOSSim DDI provider configuration exists. Apple documentation found in this audit describes Xcode/Xcode-component acquisition, not an official third-party no-Xcode runtime feed. Production code must therefore support an approved provider but cannot claim clean-Mac DDI acquisition or a physical DDI pass until release operations supplies a signed manifest/feed with reviewed rights.
