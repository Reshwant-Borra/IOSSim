# IOSSim no-Xcode installation root-cause investigation

Investigation date: 2026-09-14 (America/New_York)

Investigation branch: `work/investigate-no-xcode-installation-v1`

Repository HEAD: `1259da507ecded222022cc86bf82863c15640db9`

Stage A status: complete. No production installation routing was changed before this report was written.

## 1. Executive summary

The physical GUI reached `xcrun devicectl` because its bundled helper handled the GUI's `consumer-provision --backend NATIVE_PERSONAL_TEAM` request by constructing `ConsumerArtifactProvisioner(context:)` with the initializer defaults. Those defaults are `DevicectlProvisioningBackend()` for device selection/install and `DevicectlApplicationInventoryReader()` for inventory. The request's `NATIVE_PERSONAL_TEAM` value selects the Apple authentication/profile/signing branch only; it does not select the device-operation backend.

The exact failing route is therefore:

```text
SetupWizard Install
  -> SetupStore.runProvisioningBody
  -> BundledProvisioningEngine.consumerProvision
  -> IOSSimProvisioner consumer-provision
  -> ConsumerArtifactProvisioner(context:) defaults
       deviceBackend = DevicectlProvisioningBackend
       inventoryReader = DevicectlApplicationInventoryReader
  -> ConsumerArtifactProvisioner.installArtifacts
  -> ConsumerArtifactProvisioner.install
  -> DevicectlProvisioningBackend.install
  -> /usr/bin/xcrun devicectl device install app
```

This is not a DevelopmentCLIEngine incident and rebuilding current HEAD alone cannot fix it. Commit `e374b5f` added a real native AFC/Installation Proxy implementation but deliberately left the consumer provisioner's defaults on devicectl. It also added a misleading comment claiming the no-Xcode coordinator does not construct that type; the helper does exactly that. Existing integration tests explicitly expect two devicectl install commands for a `NATIVE_PERSONAL_TEAM` request, and the static no-Xcode audit suppresses the active consumer files by labeling them `LEGACY`.

The tested artifact had mixed provenance. Its GUI, helper, and bridge came from a dirty local build based on HEAD `1259da5`; its bundled iPhone payload and `DeviceArtifacts/manifest.json` came from clean commit `bc339b3`. The support bundle's sole `sourceCommit=bc339b3...` is copied from that payload manifest. It does not identify the GUI executable, helper, bridge, or complete app. The stale/misleading metadata did not cause the devicectl call: the routing defect remains in current HEAD and the tested helper contains it.

Native inventory, install/upgrade entry points, uninstall, and container read/write exist from Rust through C ABI and Swift. They were not wired into `ConsumerArtifactProvisioner`. Native launch is only an interface plus an `AwaitingPhysicalAppServiceLauncher` stub, so direct devicectl launch is a known next blocker. Container readback has a native implementation but the consumer flow still calls devicectl. Fresh uninstall is also direct devicectl. Renewal/refresh reuses the same affected provisioning path.

## 2. Physical facts

Facts supplied by the user and treated as authoritative:

- Full Xcode is absent; Apple Command Line Tools remain.
- A physical, unlocked iPhone was connected for the failing GUI attempt.
- Finder/macOS connectivity worked.
- `./iossim device-debug` physically returned one Apple-usbmux device, one Rust device, one C ABI device, one Swift device, and successful Lockdown metadata.
- The device reported product type `iPhone18,1` and iOS `26.6.2`.
- No-Xcode discovery is therefore physically passed and is outside the fix scope unless directly regressed.
- The next GUI attempt reused the existing Apple session, prepared Personal Team profiles, signed both payloads, verified signatures, then failed at `INSTALLING_MAIN`.

At the later time of this investigation, `./iossim device-debug` returned zero at Apple usbmux. The phone was no longer enumerable in the current process context. That changed state does not invalidate the earlier physical support-bundle evidence, but it prevented new non-mutating AFC and Installation Proxy physical probes during Stage A.

## 3. What has already physically passed

| Gate | Result | Evidence |
|---|---|---|
| Apple usbmux discovery | PHYSICAL_PASS | User's `device-debug`: devices 1 |
| Rust discovery | PHYSICAL_PASS | bridge version `iossim-device-bridge/0.1.0+idevice-1838db1`, devices 1 |
| C ABI discovery | PHYSICAL_PASS | devices 1 |
| Swift discovery | PHYSICAL_PASS | devices 1 |
| Lockdown metadata | PHYSICAL_PASS | product and OS returned |
| Native Apple session reuse | PHYSICAL_PASS for this attempt | support events show reused native context without reauthentication |
| Profile/key/signing preparation | PHYSICAL_PASS for this attempt | all identity, signing, and signature-verification events passed |
| No-Xcode installation | AWAITING_PHYSICAL_VALIDATION | execution never entered native install |

## 4. Current failure

The support bundle generated at `2026-09-15T00:25:45Z` records:

- `provisioningBackend=NATIVE_PERSONAL_TEAM`
- `xcodePresent=false`
- `zeroXcodeMode=true`
- latest stage `INSTALLING_MAIN`
- error `MAIN_INSTALL_FAILURE`
- sanitized detail: `xcrun: error: unable to find utility "devicectl", not a developer tool or in PATH`

Immediately preceding events show main/runner artifact preparation, nested signing, main signing, runner signing, signature verification, artifact validation, and install-command preparation all passed. The failure is therefore the first device install subprocess, not authentication, discovery, profile preparation, signing, or signature validation.

## 5. Repository state

Starting branch: `work/investigate-no-xcode-device-discovery-v2`

Investigation branch: `work/investigate-no-xcode-installation-v1`

HEAD: `1259da507ecded222022cc86bf82863c15640db9`

Pre-existing modified files preserved:

- `macos/Sources/IOSSimMacCore/Models/DoctorStatus.swift`
- `macos/Sources/IOSSimMacCore/Services/MockIOSSimSetupEngine.swift`
- `macos/Sources/IOSSimMacCore/SetupStore.swift`
- `macos/Sources/IOSSimProvisioner/main.swift`
- `macos/Tests/IOSSimMacCoreTests/NativeDeviceBridgeTests.swift`
- `macos/scripts/build_app.sh`
- `scripts/bootstrap/iossim_cli.py`

Pre-existing untracked artifacts preserved:

- two support ZIPs
- the prior discovery investigation report
- the prior discovery CLI test

No reset, clean, merge, force push, Xcode installation, or artifact deletion was performed.

## 6. Git history

Relevant focused history:

| Commit | Meaning for this investigation |
|---|---|
| `e48f4c2` | Added the native Mac device bridge |
| `e374b5f` | Added native application management, Rust app-management ABI, and the erroneous injectable devicectl defaults |
| `178bdd3` | Added renewal; renewal reuses consumer provisioning |
| `529b573` | Bundled the native bridge in releases |
| `d7d1795` | Signed the bundled bridge |
| `bc339b3` | Fixed native device discovery and is the bundled payload-manifest commit |
| `1259da5` | Documentation only; current HEAD |

`git diff bc339b3..HEAD` changes only `DEBUG_REPORT_NO_XCODE_DEVICE_DISCOVERY.md`. No installation, helper, GUI, routing, AFC, Installation Proxy, or packaging implementation changed after `bc339b3` in committed history. Dirty discovery work changes discovery/build diagnostics but does not change `ConsumerArtifactProvisioner`, `InstallationInventory`, or native app management.

## 7. Artifact inventory

All listed Mac apps are version `0.1.0` build `1` where an Info.plist is present. All modern relevant apps use the bundled engine unless noted. Hashes are SHA-256 prefixes; full tested-artifact hashes are in section 8.

| Path/category | Payload commit | GUI hash | Helper hash | Bridge hash/version | Arch | Signature/team/entitlements | Engine / install default | Purpose |
|---|---|---:|---:|---:|---|---|---|---|
| `.build/iossim/device-discovery-retest/IOSSim.app` | `bc339b3` | `d851da2c33a33ac6` | `e4ac3e0817d2bd18` | `809e20048abdb0ed`, `0.1.0+idevice-1838db1` | arm64 | ad hoc hardened; no Team ID; helper-only library-validation exception; unsandboxed | Bundled / devicectl defaults | Exact physical GUI path captured at investigation start |
| `.build/iossim/dmg-install-check/IOSSim.app` | `bc339b3` | same | same | same | arm64 | same | Bundled / devicectl defaults | Extracted-copy check |
| `.build/iossim/mac/IOSSim.app` | no payload manifest | `70671539e74d67a4` | same | same | arm64 | same | Bundled / devicectl defaults | current dirty local Mac build |
| `.build/iossim/self-contained/IOSSim.app` | `bc339b3` | `f3525a9a84d92d7d` | `904d6cfa5dc13136` | `62dcbdbe3a8c9e2b`, same version | universal GUI/helper | ad hoc hardened; no Team ID; unsandboxed | Bundled / devicectl defaults | clean bc339 local release app |
| `/Applications/IOSSim.app` | `bc339b3` | same as self-contained | same | same | universal GUI/helper | same | Bundled / devicectl defaults | installed clean bc339 app |
| `.build/iossim/bridge-probe/IOSSim.app` | none | none | `06ba75639d019d02` | current `809e...` | helper probe | local ad hoc | helper only | discovery bridge probe |
| release signing-order fixture | `b938c88` | `29c4a511750ba108` | `d603e9a7b2e795a2` | absent | arm64 | Apple Development test fixture | bundled historical | release-engineering fixture |
| mounted `/Volumes/IOSSim` through `IOSSim 12` | commits `4b8feea` through `06478ba` | distinct historical hashes | distinct historical hashes | absent | universal | mostly ad hoc | bundled historical | stale mounts of repeatedly overwritten local DMG path |
| mounted `/Volumes/IOSSim 13` | `d7d1795` | `f7235a8ed50cdd1a` | `5ab614a0cbe5c9fc` | `8a6568eaa816765d` | universal | ad hoc | bundled | pre-discovery local release |
| mounted `/Volumes/IOSSim 14` | `bc339b3` | clean bc339 hashes | clean bc339 hashes | clean bc339 bridge | universal | ad hoc | bundled / devicectl defaults | mounted bc339 discovery DMG |

Relevant DMGs:

| DMG | SHA-256 | Meaning |
|---|---|---|
| `IOSSim-0.1.0-local-device-discovery-v2-full.dmg` | `57c63c377d9fded08467e6a706ae2a32aa46c2f4aa1fbb659d34dacec54d786e` | contains byte-identical tested GUI/helper/bridge and bc339 payload |
| `IOSSim-0.1.0-local-device-discovery-v2.dmg` | `81408bc34e6e37cffe5ddd6f810503781ad337c548df6f9996184caf0fc62a23` | smaller discovery test DMG; not authoritative for the failed attempt |
| `IOSSim-0.1.0-local-device-discovery-bc339b3.dmg` | `ca5e58c50cd2ed014b142bacf338ed99b081cf94bbc89e48f2d0a0bc29c8b50c` | clean bc339 local candidate |
| `IOSSim-0.1.0-local.dmg` | `2ee25ebde5bb177b2f6190e2fb9515dbbe395a25bee8ed46dea51eddcb4effad` | clean d7d1795 local candidate currently mounted many times from an overwritten path |

Mounted historical volume names are not trustworthy provenance because the same `local.dmg` pathname was overwritten between mounts. Hashes and embedded manifests, not volume suffixes, distinguish them.

## 8. Tested artifact provenance

At investigation start the running process was captured as:

```text
PID 56946
/Users/rishiborra/Desktop/IOSSim/.build/iossim/device-discovery-retest/IOSSim.app/Contents/MacOS/IOSSim
started 2026-09-14 20:25:13 -0400
```

That start time matches the 20:25 local support-bundle attempt. The process exited later during investigation.

Exact component hashes:

- GUI: `d851da2c33a33ac6090516e7924755e2040a3ce842d8209328866188688b239e`
- helper: `e4ac3e0817d2bd1897eb2e0c294813a933a2e04d4ad8cf8866542261a817a324`
- bridge: `809e20048abdb0ed41ba0c1346c1add5344dc5ae36d53eba040a335a311f3198`

`DeviceDiscoveryBuild.plist` reports:

- base HEAD `1259da507ecded222022cc86bf82863c15640db9`
- `sourceDirty=true`
- build timestamp `2026-09-14T23:55:49Z`
- distribution class `LOCAL_DEVICE_DISCOVERY_TEST`

There is no single commit that exactly describes the GUI/helper because they were built from a dirty tree. No Swift or Rust production source was newer than the tested binaries at inspection time. The tested app's GUI/helper/bridge unsigned content matches the current `.build/iossim/mac` products modulo code-signature data. Its full helper and bridge hashes exactly match that current app.

The v2-full DMG was mounted read-only. It contains exactly the hashes above, validates with `codesign --verify --deep --strict`, and is arm64. Thus the repository app and v2-full DMG are not ambiguous internally, although their component provenance is mixed.

## 9. Support-bundle provenance analysis

The support bundle's `sourceCommit` path is:

```text
BundledProvisioningEngine.exportSupportBundle
  -> IOSSimProvisioner support-bundle
  -> context.loadManifest().release
  -> SupportBundleExporter.export(release:)
  -> SupportEnvironment.sourceCommit = release?.sourceCommit
```

`context.loadManifest()` loads `Contents/Resources/DeviceArtifacts/manifest.json`. In the tested hybrid app that manifest came from the clean `bc339b3` self-contained payload. Therefore `sourceCommit=bc339b3...` means “commit recorded by the bundled iPhone artifact manifest.” It does not prove the GUI, helper, bridge, enclosing app, or DMG commit.

The same support document reports `releaseVariant=PRODUCTION` because that field also comes from the payload manifest. It does not override the app's separate `LOCAL_DEVICE_DISCOVERY_TEST`, dirty-build metadata.

Conclusion: support metadata provenance is misleading and incomplete, but its `bc339b3` value is internally consistent with the payload it actually describes.

## 10. Running-process provenance

The live-process executable path was captured before it exited. The GUI binary contains `BundledProvisioningEngine` symbols and the strings “Helper: Bundled IOSSimProvisioner” and “Repository fallback: disabled.” It has no `DevelopmentRepositoryRoot.txt`. Its helper and bridge paths are therefore deterministically beneath the same app bundle:

- `Contents/MacOS/IOSSimProvisioner`
- `Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib`

The helper is not persistent, so there was no child process left for `lsof` after the failed operation. The helper that wrote the support ZIP nevertheless necessarily used the tested app's Resources path because `BundledProvisioningEngine` supplies its own helper URL and Resources directory to every helper invocation.

## 11. Build-variant matrix

| Variant | Setup engine | Discovery | Signing/provisioning | Install/inventory | Launch/readback |
|---|---|---|---|---|---|
| plain Swift debug | DevelopmentCLIEngine | development CLI | development CLI | CLI devicectl path | legacy/tooling |
| committed `build_app.sh` at HEAD | DevelopmentCLIEngine; no helper bundled | CLI path | CLI path | CLI devicectl | legacy/tooling |
| dirty discovery `build_app.sh` used for tested app | BundledProvisioningEngine + `IOSSIM_LOCAL_TEST_ONLY` | native bridge | native Personal Team | **devicectl initializer defaults** | **devicectl** |
| `package-app` self-contained | BundledProvisioningEngine, not local-test flag | native bridge present | native live experiment disabled | devicectl defaults if reached | devicectl |
| `release-local` | BundledProvisioningEngine + local-test flag | native bridge | native Personal Team | **devicectl defaults** | **devicectl** |
| production `release` | BundledProvisioningEngine, no local-test flag | bridge bundled | native live experiment disabled | Xcode-oriented request if reached | devicectl |
| device-discovery-retest / v2-full | BundledProvisioningEngine + local-test flag | physically passed native | native Personal Team | **devicectl defaults; physically failed** | would be devicectl |

The physical failure was not caused by DevelopmentCLIEngine or wrong engine selection. It was caused one layer below the correctly selected bundled engine. Separately, committed `build_app.sh` and true production-release flags are not yet aligned with the intended no-Xcode consumer architecture.

## 12. INSTALLING_MAIN call graph

| Layer | File / symbol | Input | Output / error | Backend choice |
|---|---|---|---|---|
| SwiftUI | `SetupWizardView.WizardControls.primaryAction` | Install button | calls store | none |
| state | `SetupStore.continueFromCurrentStatus` -> `runProvisioning` -> `runProvisioningBody` | selected live device/team | `ConsumerProvisioningResult` or typed failure | request backend is native because local-test flag is on |
| GUI engine | `BundledProvisioningEngine.consumerProvision` | native request | helper JSON envelope | fixed bundled helper |
| helper command | `ProvisionerTool.consumerProvision` | `--backend NATIVE_PERSONAL_TEAM` | constructs request and provisioner | **does not construct selected device backend** |
| provisioner | `ConsumerArtifactProvisioner.init` | context only | stores defaults | **DevicectlProvisioningBackend + DevicectlApplicationInventoryReader** |
| signing branch | `ConsumerArtifactProvisioner.provision` | request backend | native artifacts/profiles/signing | request backend is used here |
| install sequence | `installArtifacts` | prepared main then runner | two install results | calls stored device backend |
| install adapter | `ConsumerArtifactProvisioner.install` | `.app`, selected raw ID | ProcessResult -> typed consumer failure | stored device backend |
| concrete backend | `DevicectlProvisioningBackend.install` | component/path/device | subprocess result | `/usr/bin/xcrun` |
| primitive | `xcrun devicectl device install app` | selected ID and `.app` | exit 1/127-like failure | Xcode/CoreDevice |

Errors are not silently swallowed at this boundary: the subprocess output is classified and surfaced as `MAIN_INSTALL_FAILURE`. The architectural error is backend construction, not error collapse.

## 13. Exact devicectl invocation

`DevicectlProvisioningBackend.install` builds:

```text
/usr/bin/xcrun devicectl device install app
  --device <selected-device>
  <prepared-app-path>
  --timeout 60
  --quiet
```

The exact active call site is `macos/Sources/IOSSimMacCore/Services/RuntimeProvisioningSupport.swift`, `DevicectlProvisioningBackend.install` (current lines 614-638). `ConsumerArtifactProvisioner.install` reaches it through its stored `deviceBackend` (current lines 1057-1107).

## 14. Why that invocation was selected

1. The app was correctly compiled for `BundledProvisioningEngine` and local native Personal Team provisioning.
2. SetupStore sent `backend=NATIVE_PERSONAL_TEAM` to the helper.
3. The helper parsed that value and placed it in `ConsumerProvisioningRequest`.
4. The helper constructed `ConsumerArtifactProvisioner(context: context)` without passing `deviceBackend` or `inventoryReader`.
5. The initializer defaulted those independently to devicectl implementations.
6. `NATIVE_PERSONAL_TEAM` selected native profile/signing logic only; it never altered the stored device backend.
7. When devicectl discovery failed earlier in the method, the native signing branch intentionally fell back to the request's selected identifier and continued local signing.
8. `installArtifacts` then invoked the stored devicectl backend and failed immediately at main install because full Xcode was absent.

There is no “native failed, then fall back” branch here. Devicectl was the primary backend selected by initializer default.

## 15. All installation implementations

| Implementation | Status | Reachability |
|---|---|---|
| `DevicectlProvisioningBackend.install` | complete legacy/dev comparison | actively selected by consumer default (bug) |
| `IdeviceProvisioningBackend.install` | implemented adapter | used by generic helper `install`, not consumer-provision default |
| `NativeApplicationService.install` | implemented Swift-to-FFI call | reachable through Idevice backend |
| `DynamicNativeDeviceTransport.installApplication` | implemented C ABI call | not reached by physical consumer attempt |
| `iossim_bridge_install_app` | implemented Rust export | not reached by physical consumer attempt |
| idevice `installation::install_package/upgrade_package` | AFC staging + Installation Proxy | source present; physical install not yet validated |
| `NativeApplicationManager.installOrUpgrade` | implemented orchestration with pre/post inventory | not used by production consumer flow |

## 16. Native Installation Proxy implementation audit

| Question | Finding |
|---|---|
| client | pinned idevice `InstallationProxyClient` using `com.apple.mobile.installation_proxy` |
| browse/inventory | implemented via `get_apps(Some("User"), None)` |
| install | exported through Rust/C/Swift and stages via idevice utility |
| upgrade | exported through same ABI with boolean mode |
| uninstall | direct Installation Proxy `uninstall` exported through Rust/C/Swift |
| `.app` | accepted as a directory and recursively staged |
| `.ipa` | accepted as a file and uploaded as `PublicStaging/idevice.ipa` |
| path given to proxy | relative `PublicStaging/<bundle-directory-name>` for `.app`; fixed staged filename for IPA |
| progress | idevice supports callbacks, but IOSSim passes no callback and exposes only completion/failure |
| error propagation | Rust status + sanitized diagnostic -> Swift bridge error; Idevice adapter collapses all native install errors to exit 70 text |
| development-signed app | structurally supported; IOSSim pre-validates signing/profile, but physical native install not yet exercised |
| main/runner | generic implementation supports both paths |
| GUI wiring | disconnected by devicectl defaults |

Important implementation limitation: at pinned revision `1838db1` (also current upstream master during investigation), `install_package_with_callback` calls Installation Proxy `Upgrade` for directory packages. `upgrade_package_with_callback` does the same. Thus fresh and upgrade are not distinct at the protocol command level for `.app` directories. It may be accepted by iOS for both states, but that has not been physically proven and should be treated as a concrete qualification risk.

## 17. AFC implementation audit

The pinned idevice installation utility:

1. connects to AFC through the selected usbmux provider;
2. stats or creates `PublicStaging`;
3. recursively mirrors a directory to `PublicStaging/<local-directory-name>`;
4. sets `PackageType=Developer`;
5. passes that relative staged path to Installation Proxy.

IOSSim calls this utility from `iossim_bridge_install_app`. AFC staging therefore exists and is not a stub. Limitations:

- no IOSSim progress callback is surfaced;
- no explicit cleanup is performed after install;
- the remote directory is not cleared before recursive upload, so removed files from a later local bundle could remain in a reused staging directory;
- physical AFC service opening and staging were not re-probed because the phone ceased to enumerate during this investigation.

## 18. Native inventory audit

Rust, C ABI, Swift transport, `NativeApplicationService`, `NativeApplicationInventoryReader`, and `IdeviceProvisioningBackend.isAppInstalled` all contain real inventory logic. The tested dylib exports `iossim_bridge_app_inventory`.

The active consumer provisioner nevertheless defaults to `DevicectlApplicationInventoryReader`. It uses that reader for pre-install identity validation and bounded post-install verification. Native inventory is therefore **implemented but not wired** in the physical consumer path.

## 19. Native service physical probes

| Probe | Stage A result |
|---|---|
| usbmux | earlier PHYSICAL_PASS; later current count 0 |
| Lockdown | earlier PHYSICAL_PASS; not repeatable after disconnect |
| AFC | NOT RUN: no currently enumerated device |
| Installation Proxy browse | NOT RUN: no currently enumerated device |

The C ABI inventory probe was attempted against the exact tested bridge. It successfully initialized and listed zero current devices, then stopped without trying a device service. No install, uninstall, staging, container mutation, or fallback was attempted.

The support bundle's older stored `installationMainPresent=true` and `installationRunnerPresent=true` describe a prior completed installation checkpoint; they are not evidence that the new native inventory implementation was physically invoked.

## 20. Main/runner artifact audit

Packaged source inputs in the tested app:

| Role | Source bundle | Architecture | Embedded profile | Signature | Notes |
|---|---|---|---|---|---|
| main | `IOSSim DVT POC.app` | arm64 | intentionally absent before personalization | valid packaged ad hoc signature | source ID matches manifest |
| runner | `IOSSimLocationControlUITests-Runner.app` | arm64 | intentionally absent before personalization | valid packaged ad hoc signature | nine nested signable components |

The exact freshly personalized artifacts are created in a protected temporary provisioning workspace and normally removed by `defer`, including on failure. They were no longer available for direct re-audit. The physical event stream directly records that both profiles were found, all nested code was signed, main and runner were signed, signature display/entitlement/team checks passed, and relationship validation passed before install.

An older retained prepared workspace was found, but its timestamp predates this attempt and it was not misrepresented as the current payload.

## 21. bc339b3 -> HEAD comparison

Only the discovery documentation report changed in committed source. Therefore:

**Would simply rebuilding the GUI from current HEAD remove the devicectl installation path? NO.**

Moreover, committed `build_app.sh` at HEAD still builds DevelopmentCLIEngine and does not bundle the helper or bridge. The dirty discovery build script fixes that local build shape, but not consumer installation routing. Self-contained/release build functions do compile the bundled engine; their helper still contains the same devicectl consumer defaults.

## 22. All consumer devicectl references

| Operation/reference | Classification | Active in physical consumer path? |
|---|---|---|
| Consumer provisioner default device backend | ACTIVE_CONSUMER_RUNTIME | yes |
| Consumer provisioner default inventory reader | ACTIVE_CONSUMER_RUNTIME | yes after install / before migration checks |
| fresh-install uninstall subprocess | ACTIVE_CONSUMER_RUNTIME | yes when confirmed fresh install selected |
| main/runner install in Devicectl backend | ACTIVE_CONSUMER_RUNTIME | yes; observed failure |
| post-install app inventory | ACTIVE_CONSUMER_RUNTIME | yes if install succeeds |
| main app process launch | ACTIVE_CONSUMER_RUNTIME | yes after inventory succeeds |
| preferences container copy-from | ACTIVE_CONSUMER_RUNTIME | yes after launch succeeds |
| RuntimeProvisioning devicectl backend selector | DEVELOPER_COMPARISON plus accidentally active through defaults | yes through explicit default construction |
| generic helper `install` | backend-selected developer/helper command | native by default; not GUI consumer-provision |
| Python CLI install comparison | DEVELOPER_TOOLING | not used by bundled physical app |
| xcodebuild signing shell | LEGACY XCODE_FALLBACK | not used by observed native Personal Team attempt |
| release/notary xcrun calls | BUILD_ONLY | no |
| iOS source build xcrun/xcodebuild | BUILD_ONLY | no |
| tests containing devicectl | TEST_ONLY, but several encode the wrong architecture | no at runtime |

## 23. All later-stage Xcode dependencies

| Device operation | Current consumer implementation | Native exists | Wired | Expected next status |
|---|---|---|---|---|
| discovery | native bridge | yes | yes | physically passed |
| lock/trust metadata | Lockdown through native bridge | yes | yes | physically passed |
| developer mode readiness | native inspection | yes | yes | earlier passed sufficiently to proceed |
| main install | devicectl default | yes | no | current blocker |
| runner install | devicectl default | yes | no | next install blocker |
| inventory | devicectl reader | yes | no | next blocker |
| uninstall/fresh install | direct devicectl | yes | no | conditional blocker |
| launch | direct devicectl | interface only; production launcher stub | no | next unconditional blocker after install/inventory |
| container write | current app launch writes preferences | native House Arrest write exists | not used | architecture mismatch |
| container readback | direct devicectl copy-from | native House Arrest read exists | no | next blocker after launch |
| repair | same provisioning path | same components | no | affected |
| refresh/renewal | same provisioning path | same components | no | affected |

## 24. Packaging audit

Official `assemble_self_contained_app` removes the prior app directory before assembly and copies GUI/helper from the just-selected Swift product directory, bridge from the just-built host bridge, and iPhone artifacts from build outputs. Official DMG creation uses a new temporary staging directory. This design does not intentionally copy an old helper after a new GUI.

However:

- the physical discovery retest app was manually composed from clean bc339 payload resources plus dirty current GUI/helper/bridge;
- v2 DMGs have no standard checksum/release sidecars;
- support metadata reports only the payload manifest;
- committed `build_app.sh` is a development-engine build, while the dirty version silently changed purpose to bundled local consumer build;
- release-local currently insists on rebuilding iOS payloads and a clean tree, which conflicts with the present no-Xcode retest workflow;
- true production builds omit the compile flag that enables the live native Personal Team path.

These are provenance/productization defects, but none explains the observed devicectl call as strongly as the source-level default backend does.

## 25. Root-cause matrix

| Hypothesis | Evidence for | Evidence against / test | Result | Confidence | Impact |
|---|---|---|---|---|---|
| stale GUI | support commit looked old | live path/hash and build metadata identify dirty 1259-based GUI; current source retains bug | partial provenance only | high | medium |
| stale helper | possible mixed bundle | tested helper equals current local helper hash; no newer Swift source | rejected as cause | high | low |
| stale bridge | support omitted revision | exact bridge is 1838db1 and discovery physically passed | rejected as cause | high | low |
| stale DMG | many DMGs/mounts exist | live path was repository app; v2-full contains exact same components | not cause | high | low |
| stale running process | prior app instances plausible | captured executable start/path matches attempt and current test app | rejected | high | low |
| incorrect sourceCommit metadata | support says bc339 while GUI is dirty 1259-based | traced directly to payload manifest | proven | high | medium diagnostic impact |
| wrong build variant | ordinary debug could use DevelopmentCLIEngine | binary proves BundledProvisioningEngine/local-test build | rejected for physical attempt | high | high generally |
| DevelopmentCLIEngine selected | previous known problem | binary symbols/strings and direct helper event path disprove | rejected | high | high generally |
| devicectl fallback selected | devicectl executed | no fallback condition exists; it is primary default | wrong label; primary selection proven | high | high |
| native install implemented but not wired | Rust/C/Swift symbols exist; default is devicectl | none | proven | high | critical |
| native install partial | no progress; directory fresh/upgrade both issue Upgrade; no cleanup | core staging/proxy logic exists | proven limitations | high | high qualification risk |
| Installation Proxy absent | physical service not re-probed | source and symbols exist; discovery/Lockdown pass does not prove service | unproven physical | low | high if encountered |
| AFC staging absent | claimed implementation might be stub | pinned source performs real PublicStaging recursion | rejected in source; physical unknown | high source / unknown physical | high |
| native inventory exists but install does not | inventory symbols real | install symbols and source also real | rejected | high | low |
| main native, runner legacy | both share same `install` method | both currently devicectl | rejected current shape | high | high |
| install native, launch legacy | launch is direct devicectl and native launcher is stub | install currently also devicectl | proven downstream defect | high | critical next gate |
| container readback legacy | direct devicectl copy-from | native House Arrest read exists unused | proven | high | critical next gate |
| renewal legacy | refresh reuses consumer provisioner | native renewal signing exists but device ops same | proven | high | high |
| packaging copied old helper | hybrid packaging copied components manually | tested helper current and contains bug | not cause; provenance weakness | high | medium |
| current HEAD still uses devicectl | direct source/blame/diff evidence | none | proven | high | critical |
| request backend controls device backend | names imply it might | source proves independent values | rejected assumption | high | critical conceptual defect |
| no-Xcode audit would catch regression | audit exists | it allowlists active files as LEGACY | rejected; test gap proven | high | high |
| tests protect native routing | native tests exist | integration test explicitly expects devicectl under native request | rejected; test defect proven | high | high |
| Xcode absence inverted backend selection | support says native yet devicectl ran | no conditional selection: hard-coded default | not the mechanism | high | medium |

## 26. Primary root cause

`IOSSimProvisioner.consumerProvision` constructs `ConsumerArtifactProvisioner(context:)`, whose defaults are the legacy devicectl device backend and inventory reader. The native Personal Team request field controls only signing/profile preparation and is independent of those defaults. As a result, successful native signing deterministically transitions to devicectl installation.

The physical GUI reached devicectl because **the bundled helper's consumer provisioning composition root never injected the already-implemented native device backend and native inventory reader, and the provisioner itself defaulted both dependencies to devicectl**.

## 27. Secondary contributing defects

1. The comment added with the backend injection incorrectly says the no-Xcode coordinator does not construct `ConsumerArtifactProvisioner`; the helper does.
2. Native app-management orchestration was added but has no production callers.
3. Fresh uninstall remains direct devicectl rather than going through a backend/service abstraction.
4. Launch remains direct devicectl; the native launch implementation is a deliberate service-unavailable stub.
5. Container readback remains direct devicectl even though House Arrest read/write exists.
6. Post-install inventory defaults to devicectl even though a native reader exists.
7. Renewal/refresh/repair inherit the same device-operation routing.
8. The no-Xcode static audit marks active consumer files `LEGACY`, preventing failure.
9. Existing “native Personal Team” integration tests explicitly assert devicectl commands, encoding the architectural contradiction.
10. Support `sourceCommit` and `releaseVariant` identify only the payload manifest and omit GUI/helper/bridge/build-engine provenance.
11. The tested retest package was a mixed dirty/current host plus clean older payload build with no standard v2 sidecars.
12. Native install does not expose progress, has coarse error mapping, and does not distinguish fresh/upgrade for directory packages at the final idevice command.
13. True production builds do not enable the currently local-test-gated native Personal Team path.
14. Committed ordinary `build_app.sh` still creates a DevelopmentCLIEngine app, while the dirty copy changes it to a bundled consumer build.

## 28. Whether rebuild alone fixes it

**REBUILD_ONLY_SUFFICIENT = NO.**

Current committed HEAD contains the devicectl defaults and direct later-stage devicectl operations. Dirty discovery changes do not alter them. A rebuild would reproduce the installation failure once it reaches main install.

## 29. Whether code changes are necessary

**CODE_CHANGE_REQUIRED = YES.**

At minimum, the consumer composition root must construct native device operations and native inventory. Fresh uninstall and native container readback must be wired as well. Launch needs a real native implementation or must be reported as the next blocker; it cannot silently remain a consumer devicectl path.

## 30. Exact recommended fix

Narrow implementation plan supported by evidence:

1. Change the consumer provisioner's production defaults/composition to `IdeviceProvisioningBackend` and `NativeApplicationInventoryReader`.
2. Extend the device application abstraction only as needed so confirmed fresh uninstall uses `NativeApplicationService.uninstall` rather than a subprocess.
3. Route post-install inventory through the native reader.
4. Route container readback through existing native House Arrest read support.
5. Do not claim full setup ready until launch is native. Implement the smallest launch bridge using the already-pinned idevice AppService/RSD architecture if the source is complete enough; otherwise stop after native install/inventory and surface a typed next-gate failure.
6. Preserve explicit devicectl backend code solely for opt-in developer comparison, never as a consumer default or fallback.
7. Add component-specific build provenance and a consumer-artifact audit that fails on reachable devicectl device operations.

No discovery, usbmux, Lockdown, Apple authentication, profile issuance, signing, DDI/RSD runtime, or iPhone runtime redesign is indicated.

## 31. Regression tests required

- native Personal Team consumer construction selects Idevice, not devicectl;
- main install and runner install invoke the native service in order;
- post-install inventory uses the native reader;
- transport/native failures surface and never reroute to Xcode;
- confirmed fresh install uses scoped native uninstall;
- refresh/renewal/repair use the same native install/upgrade backend;
- consumer setup source and packaged binaries have no reachable devicectl install/inventory/launch/copy path;
- native container readback is used;
- if native launch is implemented, consumer launch uses it and propagates failure;
- no-Xcode build selects BundledProvisioningEngine and native device operations;
- support metadata distinguishes GUI, helper, bridge, payload, build variant, setup engine, and installation backend;
- existing device-debug discovery equality and error/empty distinctions remain green.

## 32. Remaining unknowns

- Physical AFC service opening on the currently targeted phone, because it stopped enumerating during Stage A.
- Physical Installation Proxy browse against the 1838db1 bridge.
- Physical `.app` PublicStaging transfer, fresh install, in-place upgrade, and cleanup behavior.
- Whether Installation Proxy `Upgrade` reliably installs a missing developer directory package on iOS 26.6.2.
- Physical native inventory contents/team metadata for the existing main and runner.
- A physically proven native app-launch primitive for this iOS/macOS pair.
- Physical native House Arrest read/write for the personalized main container.
- Automatic pairing, DDI/RSD, new-architecture runtime regression, and renewal gates explicitly remain unvalidated.

## Stage A completion-gate answers

| Question | Answer |
|---|---|
| A. Which exact app generated the attempt? | `.build/iossim/device-discovery-retest/IOSSim.app`, captured as the live executable at the matching time |
| B. Which commit produced it? | no single commit: dirty host build based on `1259da5`; payload manifest from clean `bc339b3` |
| C. Which helper? | same-bundle helper SHA-256 `e4ac3e...` |
| D. Which bridge? | same-bundle bridge SHA-256 `809e20...`, `iossim-device-bridge/0.1.0+idevice-1838db1` |
| E. Which setup engine? | BundledProvisioningEngine |
| F. Which installation backend? | DevicectlProvisioningBackend initializer default |
| G. Which function invoked devicectl? | `DevicectlProvisioningBackend.install` |
| H. Why selected? | helper omitted dependency injection; provisioner default is devicectl; request backend affects signing only |
| I. Complete native install in HEAD? | core AFC/Installation Proxy path exists, but progress/error/cleanup/fresh-vs-upgrade qualification is partial |
| J. Wired GUI -> helper -> bridge? | discovery yes; consumer install/inventory/uninstall/container no; launch not implemented natively |
| K. Clean rebuild alone? | no |
| L. Later active consumer devicectl paths? | yes: runner install, inventory, uninstall, launch, container readback, repair/refresh/renewal |

## Stage A verdict

`NATIVE_INSTALL_IMPLEMENTED_BUT_NOT_WIRED`

`NATIVE_INSTALL_PARTIAL`

`SUPPORT_METADATA_PROVENANCE_FAILURE`

`PACKAGING_PROVENANCE_FAILURE`

`MULTIPLE_ROOT_CAUSES`

`REBUILD_ONLY_SUFFICIENT = NO`

`CODE_CHANGE_REQUIRED = YES`

## Stage B implementation record

Stage B began only after the report above and the completion-gate answers were written.

The proven routing defect was corrected without changing usbmux, Lockdown, discovery parsing, the Rust discovery FFI, Apple authentication, signing, DDI/RSD, or the iPhone runtime:

- `ConsumerArtifactProvisioner` now defaults to `NativeApplicationInventoryReader` and `IdeviceProvisioningBackend`.
- `IOSSimProvisioner` explicitly composes the consumer provisioner from one `NativeApplicationService`, a native inventory reader, and an idevice backend. The signing-backend request no longer implicitly chooses a device-operation backend.
- main and runner install/upgrade use the existing Rust AFC/Installation Proxy bridge.
- post-install inventory uses Installation Proxy browse.
- confirmed fresh uninstall uses the selected device backend; the native consumer composition therefore uses Installation Proxy uninstall.
- preference readback uses the existing native House Arrest container read for `Library/Preferences/<main-bundle-id>.plist`.
- app launch no longer invokes devicectl from the consumer provisioner. The existing `AwaitingPhysicalAppServiceLauncher` still reports `NATIVE_LAUNCH_UNAVAILABLE`; this is deliberately retained as a typed next blocker because a native AppService launch bridge was not present or physically proven. No Xcode fallback is used.
- the production capability policy now checks the actual bundled native dylib and enables the selected native Personal Team architecture without the local-test compile flag.

The support-bundle provenance defect was corrected by adding `BuildProvenance.plist`. Schema 5 reports separate GUI commit, helper commit, payload commit, dirty state, bridge version, full idevice revision, build variant, setup engine, discovery backend, installation backend, build timestamp, and executable-path category. The ambiguous `sourceCommit` field now identifies the GUI when new metadata is present and states its component explicitly.

### Stage B verification

- Swift production package build: PASS with Apple Command Line Tools.
- Rust bridge tests: PASS, 6/6.
- no-Xcode install routing audit: PASS.
- discovery CLI tests: PASS, 5/5.
- Swift test sources parse: PASS.
- Full `swift test`: environment-gated because the installed Command Line Tools SDK has no XCTest module; this is not an iOS payload build gate.
- App code signature: PASS (`codesign --verify --deep --strict`).
- App/helper/bridge architectures: arm64.
- Mounted-DMG verification: PASS; embedded hashes equal the authoritative app.
- Support-bundle provenance round trip: PASS; `sourceCommitComponent=GUI`, GUI/helper commit `1259da5...`, payload commit `bc339b3...`, native backends, `xcodePresent=false`, `zeroXcodeMode=true`.

Current `./iossim device-debug` reached the authoritative helper and bridge but Apple usbmux reported zero devices. It therefore returned `NO_DEVICE_AT_APPLE_USBMUX`; no AFC, Installation Proxy, install, inventory, launch, or container physical claim is made from this run. The user's earlier discovery result remains the authoritative physical PASS.

### Authoritative retest artifact

- App: `.build/iossim/physical-retest/IOSSim.app`
- DMG: `.build/iossim/local-release/IOSSim-0.1.0-no-xcode-install-retest.dmg`
- DMG SHA-256: `7b640829b85e50fec9e4b480f241a2bbd8350f0b749f87a1178f35dee23874c5`
- GUI SHA-256: `77ce81adb1c8c4f1b4ce35d39d19e339090986efcbe3b2415df1ac57f05bf603`
- helper SHA-256: `cfcc04ef60081017c6f0e0b5149fbf484f6ea3ece9fa3fe1dca403079b524674`
- bridge SHA-256: `809e20048abdb0ed41ba0c1346c1add5344dc5ae36d53eba040a335a311f3198`
- host source: `1259da507ecded222022cc86bf82863c15640db9` plus explicitly recorded dirty changes
- payload source: unchanged prebuilt payload from `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`
- bridge: `iossim-device-bridge/0.1.0+idevice-1838db1`
- setup engine: `BUNDLED_PROVISIONING_ENGINE`
- installation backend: `NATIVE_AFC_INSTALLATION_PROXY`

### Stage B verdict boundary

The exact `INSTALLING_MAIN -> xcrun devicectl` root cause is proven and fixed in the authoritative artifact. Static and build validation are complete. Native installation is still `AWAITING_PHYSICAL_VALIDATION`; native launch remains the known next unimplemented/physical blocker and prevents any claim of full setup completion.
