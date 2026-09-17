# Setup Legacy-Interference Investigation

## 1. Executive summary

Stage A proves **multiple root causes**, with one direct behavioral cause for the manual-deletion reproduction:

1. `ConsumerArtifactProvisioner.resumeSetup` trusts `INSTALLATION_VERIFIED`, `RUNTIME_CONFIGURATION_WRITTEN`, `RUNTIME_CONFIGURATION_VERIFIED`, and `COMPLETE` without refreshing native inventory. A deleted main app therefore leads directly toward AppService launch/config work. This is `STALE_CHECKPOINT_INTERFERENCE`.
2. `SetupStore.routeAfterDoctor` treats persisted manifest state as installation authority. It does not reconcile app restart, device reconnect, or physical deletion. This is `ASTRA_ARCHITECTURE_DRIFT`.
3. The actual packaged engine is native and the exact `IOSSim Build`/`[FAIL] Generic iOS Debug app build` text comes from Python `command_build`, not `Try Again`. In the packaged product this is `DEVELOPER_BUILD_ONLY_NOT_PRODUCT_BUG`. An unbundled developer GUI can call that CLI through `DevelopmentCLIEngine`, but compile-time flags exclude that engine from packaged builds.
4. Release packaging does require two prebuilt payloads, but `build_app.sh` can emit a runnable `IOSSim.app` with no DeviceArtifacts when no source is supplied. Existing retest apps combine GUI/helper HEAD `1259da5` with payload commit `bc339b3`; `/Applications/IOSSim.app` has only the old manifest and no component BuildProvenance. This is `ASTRA_ARCHITECTURE_DRIFT` and stale provenance, not proof that consumer runtime built iOS source.
5. Astra coordinators for readiness/journal, automatic pairing, DDI/developer support, and renewal exist but have no production callers. The codebase contains multiple conceptual composition roots even though only one is live in the packaged app.
6. Current Keychain auth/signing records exist and are in active use. No Mac automatic-pairing record exists. There is no evidence that Keychain metadata caused launch failure, so credentials must be preserved.
7. The AppService `deviceNotFound` could be partially explained by the deleted app plus stale checkpoint. It is not evidence of a stable-device-ID mismatch: the same persisted canonical UDID successfully drove discovery, install, and inventory. The Rust bridge also maps any error containing “not found” to `deviceNotFound`, so a missing RSD service/application can be mislabeled as a missing physical device.

No state was deleted, no app was uninstalled, and no repository reset was performed.

## 2. Repository state

- Branch: `work/investigate-native-app-launch-v1`
- HEAD: `1259da507ecded222022cc86bf82863c15640db9` (`Document no-Xcode discovery fix`)
- Upstream `main`: `ed233af`
- The worktree was already materially dirty. All pre-existing modifications/untracked support and investigation artifacts were preserved.
- Modified areas include provisioning models/backends, native application/bridge code, `SetupStore`, helper, support exporter, tests, Mac build script, Rust bridge, and Python CLI.
- Untracked evidence includes two support ZIPs and prior no-Xcode discovery/install/launch investigations.

Recent relevant history, newest first: `1259da5` discovery documentation, `bc339b3` native discovery fix, `d7d1795` signed bridge, `529b573` bundled bridge, `178bdd3` renewal scaffold, `1fcd885` readiness scaffold, `c8cd305` automatic pairing scaffold, `e374b5f` native app management, `3c8b289` DDI scaffold, `e48f4c2` native bridge, `0c6fd78` SRP identity.

## 3. Astra target architecture

```text
SwiftUI -> one setup state machine -> physical readiness/recovery journal
       -> native Apple Personal Team auth/provisioning
       -> mandatory prebuilt payload manifest -> native signing
       -> one native device abstraction -> pinned Rust idevice
       -> usbmux/Lockdown/AMFI/MIM/AFC/Installation Proxy/House Arrest
       -> shared CoreDeviceProxy/RSD/RemoteXPC -> AppService + DVT/TestManager
       -> iPhone

iPhone -> LocalDevVPN -> automatic RemotePairing -> retained RSD
       -> TestManager -> XCTest runner/XCUILocation -> frozen Rich Drive
```

The authority rule is `physical state > persisted checkpoint`. Build machines may use Xcode; consumer setup may not.

## 4. Current implementation architecture

The live packaged route is:

```text
IOSSimMacApp (#if IOSSIM_BUNDLED_ENGINE)
 -> SetupStore
 -> BundledProvisioningEngine
 -> bundled IOSSimProvisioner helper
 -> ConsumerArtifactProvisioner
 -> shared NativeApplicationService
 -> DynamicNativeDeviceTransport
 -> C ABI -> pinned Rust idevice -> phone
```

It is native for discovery, install, inventory, launch, and container calls. Its live state authority, however, is a mixture of UserDefaults and a global schema-1 `provisioning-state.json` manifest. Astra’s `ReadinessCoordinator`, `SetupJournalStore`, `ConsumerOnboardingCoordinator`, automatic pairing coordinator, DDI coordinator, and renewal coordinator are parallel scaffolds, not the production route.

## 5. Differences from Astra

- Persisted checkpoint is treated as authority during resume and routing.
- There is no single live domain-readiness snapshot.
- `setup-journal.json` and `provisioning-state.json` are independent state roots.
- Automatic pairing, DDI/TSS readiness, and renewal are not composed into setup.
- AppService creates its own per-call CoreDeviceProxy/tunnel/RSD handshake rather than consuming a visibly shared developer-services lifecycle.
- Payload/GUI/helper provenance is incomplete and sometimes mismatched.
- Legacy backends remain selectable by direct helper/developer configuration; packaged GUI currently requests native, but there is no sufficiently strong fail-closed assertion.

## 6. Complete setup engine inventory

See `SETUP_ENGINE_INVENTORY.md`. Live consumer engine: `SetupStore` + `BundledProvisioningEngine` + `IOSSimProvisioner.nativeConsumerProvisioner`. Developer engine: `DevelopmentCLIEngine`. Other coordinators are test-only/unwired.

## 7. Try Again call graph

```text
DashboardView.FailureView Button("Try Again")
 -> SetupStore.retryCurrentStep()
 -> if consumer manifest + resumable last error:
      phase = .verifying
      IOSSimSetupEngine.resumeConsumerSetup(request)
      -> BundledProvisioningEngine.resumeConsumerSetup
      -> helper `consumer-resume-setup`
      -> IOSSimProvisioner.consumerProvision(resume: true)
      -> ConsumerArtifactProvisioner.resumeSetup
      -> checkpoint switch
      -> inventory ONLY for INSTALL_COMMANDS_SUCCEEDED
      -> launch/config for INSTALLATION_VERIFIED
 -> otherwise:
      SetupStore.refresh()
      -> doctor -> load persisted manifest -> routeAfterDoctor
```

`NATIVE_LAUNCH_UNAVAILABLE` is not currently in the resumable error set. Therefore the exact launch failure’s Try Again performs `refresh`, after which persisted `INSTALLATION_VERIFIED` routes the UI back to verification; a subsequent Continue/resume again jumps to launch. It does not invoke a build.

## 8. Fresh setup call graph

```text
app bootstrap -> doctor/discovery -> selected device -> native auth/team
 -> SetupStore.runProvisioningBody(.install)
 -> bundled helper consumer-provision --backend NATIVE_PERSONAL_TEAM
 -> native Personal Team assets/profile/signing identity
 -> copy mandatory prebuilt main+runner payloads
 -> rewrite deterministic IDs/embed profiles/codesign
 -> native install main -> native install runner
 -> native Installation Proxy inventory
 -> checkpoint INSTALLATION_VERIFIED
 -> native AppService launch
 -> native House Arrest/AFC config write/readback
 -> COMPLETE
```

The new route is real, but its readiness/pairing/DDI tail is not yet Astra-complete.

## 9. Resume/retry call graph

```text
app restart -> SetupStore.bootstrap -> refresh -> doctor -> load persisted manifest
 -> routeAfterDoctor (no live app inventory)

profile/retry continuation -> resumeConsumerSetup
 -> validate schema/team/device/bundle mapping
 -> INSTALL_COMMANDS_SUCCEEDED: live inventory
 -> INSTALLATION_VERIFIED: launch/config without live inventory
 -> RUNTIME_CONFIGURATION_WRITTEN: readback without live inventory
 -> VERIFIED/COMPLETE: report completion without live inventory
```

Disconnect/reconnect is re-evaluated by doctor, but deletion, replacement, or bundle drift is not reconciled at most checkpoints. Profile expiration and pairing/DDI readiness are not part of this authoritative state machine.

## 10. Consumer composition roots

- Packaged GUI root: `IOSSimMacApp` under `IOSSIM_BUNDLED_ENGINE`.
- Helper root: `IOSSimProvisioner.nativeConsumerProvisioner(context:)`, which explicitly shares one `NativeApplicationService` between inventory and provisioning backend.
- Developer GUI root: `DevelopmentCLIEngine`, compiled only when bundled flag is absent.
- Parallel/unwired roots: onboarding/readiness/journal/pairing/DDI/renewal coordinators.

Result: one currently live packaged root, but multiple competing architectural state models.

## 11. Legacy backend inventory

| Symbol/path | Classification | Consumer reachability before correction |
|---|---|---|
| `DevicectlProvisioningBackend` | DEVELOPER_ONLY/COMPATIBILITY legacy | Not injected by native helper root; direct legacy selection remains possible |
| `DevicectlApplicationInventoryReader` | DEVELOPER_ONLY/legacy | Historical production default; dirty tree default is now native |
| `DevelopmentCLIEngine` | DEVELOPER_ONLY | Compile-time excluded from bundled app |
| `ConsumerProvisioningXcodeRunner` / SigningShell | COMPATIBILITY_FALLBACK | Selected if request/backend has no native artifacts; packaged GUI requests native but helper lacks strict production rejection |
| Python `command_build`/`command_setup` | BUILD_MACHINE_ONLY | Not packaged helper route |
| Python `device --backend devicectl` | DEVELOPER_ONLY comparison | Not packaged helper route |
| `XcodeBootstrap/verified-developer-directory` | DEAD LEGACY STATE on this Mac | Not read by native consumer path |

No item remains UNKNOWN.

## 12. Xcode/devicectl reachability

- Packaged `Try Again`: no call to `build`, `xcodebuild`, or Python CLI.
- Packaged native provisioning: no xcodebuild/devicectl in the selected graph.
- Helper doctor calls `xcodebuild`/`xcrun` only if backend selection says an Xcode backend.
- Support export probes `xcodebuild` only for an Xcode-selected backend.
- Direct helper legacy backend and unbundled developer GUI can reach Xcode/devicectl.
- The native consumer path needs stronger fail-closed composition and a truthful static audit.

## 13. IOSSim Build output source

The exact banner and failures are emitted by `scripts/bootstrap/iossim_cli.py:command_build`:

```text
IOSSim Build
[FAIL] Generic iOS Debug app build
[FAIL] Internal app/Witness/XCUILocation runner build
```

That path is invoked by `./iossim build` (and build/package developer workflows). It uses `xcodebuild` to create iPhone payloads. `BundledProvisioningEngine.build()` instead invokes helper `verify-artifacts --json`. `Try Again` never calls `engine.build()`.

Classification for the reported output: **DEVELOPER_ONLY**, unless the executable was an intentionally unbundled developer GUI and the user selected its separate Update Components action. It is not emitted by packaged Try Again.

## 14. Payload source

Consumer provisioner reads `Contents/Resources/DeviceArtifacts/manifest.json` and exactly two prebuilt apps: `IOSSim DVT POC.app` and `IOSSimLocationControlUITests-Runner.app`. It copies them into a workspace, rewrites IDs, embeds profiles, and signs locally. It does not read `.build` or compile iOS source on the native request.

## 15. Prebuilt payload behavior

- Python release assembly requires both apps and validates bundle metadata/hashes.
- Raw `macos/scripts/build_app.sh` accepts an optional `IOSSIM_DEVICE_ARTIFACTS_SOURCE`; without it, it currently succeeds with no DeviceArtifacts.
- `.build/iossim/mac/IOSSim.app` has no payload manifest.
- Existing self-contained/retest apps use payload manifest commit `bc339b3` while GUI/helper provenance reports `1259da5` dirty.
- `/Applications/IOSSim.app` contains the older schema-1 manifest with commit `bc339b3`, but no `BuildProvenance.plist`.

This is a packaging/provenance blocker, not evidence of runtime compilation.

## 16. UserDefaults inventory

| Key | Purpose | Writer/reader | Authority | Current safe value | Legacy/interference |
|---|---|---|---|---|---|
| `IOSSimMac.onboardingCompleted` | UI completion hint | `SetupStore` | Hint only | `true` | Can combine with persisted runtime READY to show complete; must not prove physical readiness |
| `IOSSimMac.selectedDeviceIdentifier` | Canonical selected UDID | `SetupStore` | Selection hint | `00008150-00022D581E12401C` | Same identity used by successful native install; no stale mismatch proven |
| `IOSSimMac.selectedDeviceName` | Display | `SetupStore` | Non-authoritative | Present | No |
| `IOSSimMac.selectedPersonalTeam` | Selected Team ID | `SetupStore` | Selection hint | `T8SL4SG87F` | Matches manifest/current profiles |
| `IOSSimMac.automaticRefreshEnabled` | UI refresh preference | `SetupStore` | Preference | `true` | No architecture assumption |

No defaults were cleared. `AppStorage` did not introduce another setup authority.

## 17. Application Support inventory

| Source | Schema/purpose | Writer/reader | Authority | Finding |
|---|---|---|---|---|
| `provisioning-state.json` | schema 1, team/device/bundle/profile/inventory/checkpoint/runtime | live state store/provisioner/SetupStore | Currently treated as authoritative; should be hint | Current file says runtime `READY` and checkpoint `INSTALLATION_VERIFIED`; stale/contradictory after later launch failure/deletion |
| `provisioning-events.jsonl` | append-only sanitized events | state store/support | Evidence | Proves old devicectl failure, native installs/inventory, then launch failures |
| `native-provisioning-artifacts.json` | schema 1 profiles/cert metadata and protected profile payload | native artifact store | Reusable input, validate before use | Same team/device/bundle IDs; preserve; no mismatch proven |
| `setup-journal.json` | schema 1 Astra scaffold journal | onboarding coordinator | Not read live | Contains fixture-like `ONBOARD-DEVICE-001`, stage `checkingIPhone`; second stale state root but not current interference |
| `ProvisioningWork/*` | signing workspaces/DerivedData/prepared apps | legacy/current provisioner | Cache only | 266 MB tree with old SigningShell/DerivedData; stale but not selected as payload source |
| `XcodeBootstrap/verified-developer-directory` | old Xcode path verification | Python/legacy setup | Dead for native route | Safe to retain during evidence audit; production must ignore |

There is no migration beyond exact schema equality. Compatible auth/signing values should be preserved; derived checkpoints and inventory require recomputation.

## 18. Keychain metadata inventory

No secret bytes were read.

| Service | Account category | Exists | Created/modified (UTC) | Purpose | Migration finding |
|---|---|---|---|---|---|
| `com.iossim.mac.apple-authorization` | `personal-team-session` (redacted in command output) | Yes | 2026-09-08 / 2026-09-15 | Native Apple session envelope | Active and valid per support metadata; preserve |
| `com.iossim.mac.personal-team-signing` | per-team metadata (redacted) | Yes | 2026-09-08 / 2026-09-08 | IOSSim-owned key/cert metadata | Used for successful physical signing; preserve and validate |
| `com.iossim.remote-pairing.v1` | device+team | No Mac record | N/A | Planned automatic pairing | Not causing current mismatch; live integration absent |
| `com.iossim.on-device-dvt-poc.rppairing` | `primary` | Not present in Mac login Keychain (phone-side service) | N/A | iPhone runtime pairing | Must be inspected on phone only through safe product diagnostics; no Mac conclusion |

## 19. Device-installed artifact inventory

Last physically proven native inventory before the user’s manual deletion reported selected-device match and exact current main+runner present, with no stale IOSSim artifacts. Current expected IDs are:

- Main: `com.personalteam.iossim.t026e0910b111.on-device-dvt-poc`
- Runner: `com.personalteam.iossim.t026e0910b111.location-control-uitests.xctrunner`
- UI test bundle: `com.personalteam.iossim.t026e0910b111.location-control-uitests`

The phone was disconnected during this audit, so a new physical inventory was not fabricated. The user’s observation establishes that main was manually deleted at least once; whether it was subsequently reinstalled must be re-read natively during retest. No uninstall was performed.

## 20. Bundle ID model

Source IDs are protected compatibility boundaries:

- Main `com.iossim.on-device-dvt-poc`
- UI tests `com.iossim.location-control-uitests`
- Runner `com.iossim.location-control-uitests.xctrunner`
- Witness `com.iossim.location-witness` remains a developer/test source target but is rejected from the two-component consumer manifest.

Installed IDs use deterministic lowercased Team-ID hashing through `PersonalTeamBundleIdentifierSet`. The persisted values match the selected team and the last successful native inventory. No bundle-ID mismatch is currently proven. Reconciliation must still enumerate stale generations instead of trusting that history.

## 21. Checkpoint model

| Checkpoint | Intended entry evidence | Current physical evidence check | Safe retry | Rollback condition |
|---|---|---|---|---|
| `INSTALL_COMMANDS_SUCCEEDED` | native install commands returned success | Live inventory is performed | Poll inventory | Missing app remains install repair |
| `INSTALLATION_VERIFIED` | exact main+runner found on selected live device | **Not rechecked on resume** | Currently launches directly | Either app missing -> install repair |
| `DEVELOPER_PROFILE_TRUST_REQUIRED` | launch/config produced trust-specific error | **Inventory not rechecked** | Verify trust and retry launch | App/profile/device changed -> earlier stage |
| `RUNTIME_CONFIGURATION_WRITTEN` | container write succeeded | Only readback | Readback | App missing/replaced -> install/launch/write |
| `RUNTIME_CONFIGURATION_VERIFIED` | container readback matches | Resume may complete | Complete | Physical app/config mismatch -> repair |
| `COMPLETE` | all readiness/runtime evidence current | Returned from history | No-op | Any domain stale/missing -> derived recovery |

Also, a schema-1 manifest missing `setupCheckpoint` is inferred as `COMPLETE` when runtime status is READY, an unsafe historical upgrade.

## 22. Reconciliation model

Current live code has no one authoritative pass. Provision performs inventory, but resume and app restart do not. Required derivation order:

```text
resolve selected canonical UDID against live discovery
 -> inspect lock/trust/developer-mode
 -> derive expected Team bundle IDs
 -> native inventory exact main/runner + stale variants
 -> validate profile/signing metadata and expiry
 -> verify config only if current main is present
 -> evaluate developer support / pairing as independent domains
 -> derive next checkpoint and repair set
```

## 23. Device identity model

| Identifier type | Safe value/source | Used by | Persisted | Expected relationship |
|---|---|---|---|---|
| Lockdown/canonical UDID | `00008150-00022D581E12401C` from native discovery/UserDefaults | selection, signing registration, inventory/install/launch request | UserDefaults + hashed/safe manifest form | Authoritative stable identity |
| usbmux connection ID | Ephemeral integer from Rust discovery; not logged here | open current connection | Not persisted | Re-resolved for canonical UDID; changes on reconnect |
| Signing registration ID | Defaults to canonical UDID | Apple portal | artifact metadata hash | Same canonical device for current implementation |
| RemotePairing identity | Not currently integrated/persisted on Mac | planned pairing/RSD | No current Mac record | Mapped explicitly to canonical UDID later |
| Developer-services/CoreDevice identity | Not separately surfaced | CoreDeviceProxy/RSD/AppService | Not persisted | Must be diagnostic, not assumed equal without evidence |
| Connection generation | Model field exists | stale connection protection | Lost when operations reconstruct `IOSSimDeviceIdentity(udid:)` | Must change on reconnect |

## 24. Current launch identifier path

```text
UserDefaults selected canonical UDID
 -> ConsumerProvisioningRequest.deviceIdentifier
 -> IOSSimDeviceIdentity(udid: request.deviceIdentifier)
 -> NativeApplicationService.launch
 -> DynamicNativeDeviceTransport.withHandle
 -> Rust enumerate + match device.udid (+ captured usbmux ID)
 -> CoreDeviceProxy -> software tunnel -> RSD handshake
 -> AppService launch bundle ID
```

The launch call loses the original discovery descriptor’s usbmux/generation metadata but re-resolves the device. That deserves diagnostics; it does not yet prove the wrong namespace was used.

## 25. AppService deviceNotFound relevance

**Partial.** A stale `INSTALLATION_VERIFIED` checkpoint can attempt AppService launch after the main app is absent. In addition, Rust error mapping classifies any text containing “not found” as `deviceNotFound`, including a missing RSD service or application. Therefore the displayed error does not prove physical-device selection failed. Because discovery, install, and inventory all succeeded with the same canonical UDID, stale selected-device identity is currently unlikely. After routing is corrected, retest and retain the exact underlying failure stage.

## 26. DDI/RSD architecture alignment

`DeveloperSupportCoordinator` models DDI/TSS/mount preparation, but production does not call it. The iPhone runtime retains its RSD session; the Mac AppService launch creates a separate per-operation CoreDeviceProxy/tunnel/RSD handshake. These are shared pinned-library primitives but not one composed lifecycle. This is partial Astra alignment. Do not redesign the proven runtime during this task.

## 27. Pairing architecture alignment

Mac automatic pairing coordinator, secure envelope, native container delivery, and phone inbox exist. They are test-only/unwired; no Mac pairing Keychain record exists. The phone UI/runtime still relies on its `KeychainRPPairingStore` and historically manual import. This is a known later-phase gap, not the cause of installation retry behavior.

## 28. House Arrest alignment

Native House Arrest/AFC container write/readback is wired through `NativeApplicationService` and used after launch. It has not been independently physically validated in the current AppService path because launch fails first. Container readback must remain a separate readiness result.

## 29. Renewal compatibility

The renewal planner matches Astra concepts (reauth, refresh profiles, install in place, repair pairing), but is not production-wired. A physically derived checkpoint and preservation of valid auth/signing assets are prerequisites. Blind `COMPLETE` state is not renewal-safe.

## 30. Provenance model

Current BuildProvenance reports GUI/helper commit, dirty state, bridge version, idevice revision, build variant, setup engine, discovery/install/launch backends, and timestamp. Missing or conflated fields include payload source/commit/manifest version, setup-state schema, persisted-vs-derived checkpoint, reconciliation, pairing/DDI backends, legacy fallback flag, and consumer build-attempt flag. Existing installed/retest artifacts demonstrate GUI/payload commit mismatch.

## 31. Root-cause matrix

| Finding | Classification | Evidence | Impact | Confidence |
|---|---|---|---|---|
| Resume skips inventory after `INSTALLATION_VERIFIED` | `STALE_CHECKPOINT_INTERFERENCE` | Direct checkpoint switch + current manifest | Deleted main can jump to launch | Proven |
| App refresh routes from persisted manifest | `STALE_CHECKPOINT_INTERFERENCE`, `ASTRA_ARCHITECTURE_DRIFT` | `routeAfterDoctor`, UserDefaults+manifest | Restart/retry not physically authoritative | Proven |
| `IOSSim Build` output is Python build command | `DEVELOPER_BUILD_ONLY_NOT_PRODUCT_BUG` | Exact strings/caller | No packaged Try Again Xcode dependency | Proven |
| Native helper root uses shared native backends | `LEGACY_SETUP_PATH_UNREACHABLE` for current route | Explicit construction | Protects physical discovery/install passes | Proven |
| Direct legacy backend paths remain | `LEGACY_SETUP_PATH_REACHABLE` only by developer/direct helper surfaces | selectors/factories | Needs fail-closed production assertion | Proven |
| Build script may emit app without payload | `ASTRA_ARCHITECTURE_DRIFT` | `build_app.sh` and actual app | Ambiguous/unusable consumer artifact | Proven |
| GUI/helper/payload provenance mismatch | `MULTIPLE_ROOT_CAUSES` | manifests/plists | Debug ambiguity, stale payload risk | Proven |
| UserDefaults selected device stale | `STALE_USERDEFAULTS_INTERFERENCE` | Value matches successful install route | None proven | Not supported |
| App Support auth/profile artifacts stale | `STALE_APPLICATION_SUPPORT_INTERFERENCE` | Current IDs/team match physical pass | Derived checkpoint stale; credentials valid | Partial only |
| Keychain causes mismatch | `STALE_KEYCHAIN_METADATA_INTERFERENCE` | Valid auth/signing used successfully | None proven | Not supported |
| Bundle mismatch | `BUNDLE_ID_MISMATCH` | Deterministic values match last inventory | None proven | Not supported |
| Launch identity namespace mismatch | `DEVICE_IDENTITY_NAMESPACE_MISMATCH` | Lossy context/broad error exists, but same UDID passes install | Possible diagnostic issue | Unproven |
| Parallel dormant coordinators | `MULTIPLE_COMPOSITION_ROOTS` | No production callers | Astra features not authoritative | Proven architecture drift |

## 32. Legacy paths that must be disconnected

- Consumer helper must reject Xcode provisioning backends unless explicitly built/invoked as developer tooling.
- Consumer deterministic environment must not inherit `DEVELOPER_DIR`.
- Packaged production build must never use `DevelopmentCLIEngine`.
- Static audit must inspect reachable composition rather than label active files “LEGACY”.
- Missing bundled payloads must fail at packaging, not trigger a compile fallback.

## 33. State that requires migration

- Derived setup checkpoint and runtime READY status: revalidate physically.
- Schema-1 manifests with no checkpoint: do not infer COMPLETE solely from READY.
- Stored installation inventory: timestamp/history only, never current truth.
- Setup journal: either integrate/version under one authority or quarantine it as non-production.
- Payload provenance: add component/source distinction.

## 34. State that may safely remain

- Valid Apple authorization session.
- Valid IOSSim-owned signing key/certificate metadata.
- Native provisioning artifacts that pass team/device/bundle/profile-expiry validation.
- User display preferences and selected device/team as hints.
- Sanitized event history and old workspaces until an explicit cleanup policy is approved.
- iPhone runtime data and pairing records; no wipe is justified.

## 35. Minimum corrective architecture

1. Make one read-only physical reconciliation mandatory before resume/checkpoint routing.
2. If main/runner is missing, route to native repair and install only missing owned components.
3. Make Try Again invoke reconciliation for all consumer failures, including native launch failure.
4. Fail closed to native backends in packaged consumer composition.
5. Require and verify prebuilt payloads for any consumer app artifact.
6. Extend provenance/support output with setup schema, payload provenance, reconciliation, and false legacy/build flags.
7. Keep automatic pairing/DDI/shared-RSD/renewal as named remaining Astra phases rather than inventing parallel temporary flows.

## 36. Regression plan

- Unit-test resume with both installed, main missing, runner missing, both missing, stale COMPLETE, partial config, and launch failure.
- Unit-test Try Again graph and ensure `build()` is never called.
- Static-check production composition for `xcodebuild`, `xcrun`, and `devicectl` reachability.
- Verify payload manifest hashes/bundle relationships at build and runtime.
- Run Swift core tests, CLI checks, helper build, and no-Xcode Mac app build.
- Preserve existing native discovery/install tests.

## 37. Physical validation plan

1. Connect/unlock/trust the iPhone and run `./iossim device-debug`.
2. Open only `.build/iossim/setup-architecture-retest/IOSSim.app`.
3. Existing state: observe reconciliation event and no unnecessary install.
4. Main missing/runner present: press Try Again; expect main-only native repair, inventory, then launch. No build output.
5. Both installed: expect no install and native launch.
6. Restart after failure: expect current native inventory-derived stage, not saved checkpoint.
7. If AppService still returns `deviceNotFound`, collect stage-specific identity/RSD/AppService diagnostics and investigate separately.

## Stage A stop-point answers

- **A. Does Try Again use the intended new setup engine?** Yes in the packaged app, but it resumes with unsafe stale-checkpoint semantics.
- **B. Does Try Again invoke any Xcode-dependent build path?** No.
- **C. Does consumer setup ever invoke xcodebuild?** Not on the selected packaged native route; legacy/direct-helper selection needs a hard guard.
- **D. Are prebuilt payloads correctly bundled?** Release artifacts yes; generic `build_app.sh` output not guaranteed. Current commits are mismatched.
- **E. If main is manually deleted, does reconciliation detect it?** No, because authoritative reconciliation is missing on resume.
- **F. Is INSTALLATION_VERIFIED trusted incorrectly?** Yes, proven.
- **G. Are stale bundle IDs present?** No stale installed generation was present in the last physical inventory; current phone must be re-enumerated.
- **H. Are stale device IDs present?** The separate setup journal is stale but unreachable. Live selected UDID matches the successful native path.
- **I. Are multiple setup engines consumer reachable?** Only one in a bundled app; an unbundled developer app uses the CLI engine. Multiple conceptual roots remain.
- **J. Does current architecture match Astra?** Partially.
- **K. Exact nonmatching areas?** Physical reconciliation, unified readiness/journal, packaging/provenance, hard legacy isolation, automatic pairing, DDI/TSS production wiring, shared developer-services lifecycle, renewal wiring.
- **L. Could these explain AppService deviceNotFound?** Partially: stale install state can launch a missing app and broad error mapping hides the true not-found subject. A device identity namespace mismatch remains unproven.

## Stage B implementation and verification

Verdict: **MULTIPLE_ROOT_CAUSES_FIXED_READY_FOR_RETEST**.

Implemented:

- Added schema-2, non-destructive migration. Schema 1 is decoded, useful auth/signing/profile state is preserved, and a missing historical checkpoint is conservatively migrated to `INSTALLATION_VERIFIED`.
- Added `consumer-reconcile` to the bundled helper and structured `ConsumerSetupReconciliationResult` output.
- Reconciliation logs `TRY_AGAIN_REQUESTED`, persisted checkpoint, native backend choices, physical main/runner truth, derived checkpoint, and false fallback/build flags.
- `SetupStore.refresh` and Try Again reconcile before routing. A missing component routes to `.repair`; current components are not reinstalled.
- Resume rechecks inventory at every checkpoint. It also checks current native House Arrest/AFC mapping before accepting a persisted runtime-verified/complete checkpoint.
- Fixed refresh-success bookkeeping so success is written only after runtime configuration advancement succeeds.
- Made packaged consumer provisioning native-only. Explicit Xcode backend requests return `LEGACY_CONSUMER_BACKEND_FORBIDDEN`; AUTO cannot select Xcode; `DEVELOPER_DIR` is not propagated.
- Made prebuilt DeviceArtifacts mandatory in `build_app.sh`, verified by the bundled helper before signing the Mac app.
- Added provenance fields and support schema 6.
- Added a regression test modeling `main absent / runner present`, expecting only main installation. The source compiles, but XCTest cannot execute on this intentionally Xcode-free Mac because the XCTest module is unavailable.

Verification performed:

| Check | Result |
|---|---|
| Bundled Swift products build with Command Line Tools | PASS |
| Consumer no-Xcode reachability audit | PASS |
| Native install/launch routing audit | PASS |
| Discovery CLI regression tests (5) | PASS |
| Python syntax + shell syntax | PASS |
| Missing payload negative test | PASS; exact `PAYLOAD_MISSING_FROM_DISTRIBUTION` |
| Explicit `XCODE_FALLBACK` helper request | PASS; rejected with `LEGACY_CONSUMER_BACKEND_FORBIDDEN` |
| Isolated schema-1 -> schema-2 migration | PASS; checkpoint retained conservatively as `INSTALLATION_VERIFIED` |
| Embedded payload hash verification | PASS, both components |
| Mac app deep code-sign verification | PASS |
| Isolated support export | PASS, schema 6 and separated provenance fields |
| Full `swift test` | BLOCKED by absent XCTest module, expected on this no-Xcode Mac |
| Rust bridge rebuild | BLOCKED because `cargo` is not installed/on PATH; unchanged embedded bridge reports `iossim-device-bridge/0.1.0+idevice-1838db1` and contains the physically exercised launch ABI |
| Current phone inventory/launch | PENDING; phone was disconnected during final audit |

Authoritative artifact:

- App: `.build/iossim/setup-architecture-retest/IOSSim.app`
- Archive: `.build/iossim/setup-architecture-retest/IOSSim-0.1.0-setup-architecture-retest.zip`
- Archive SHA-256: `6dcd356213d2c5d1e7ff82394fe2ac4e6e5a635f7dd6fc06af055d23a0b9d574`
- GUI/helper source: `1259da507ecded222022cc86bf82863c15640db9`, dirty by design
- Payload source: `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`, manifest schema 1, both hashes verified
- Native bridge: idevice revision `1838db107d38701b4044361163aac049006c2627`

No DMG was produced; the app above is the sole authoritative retest build.
