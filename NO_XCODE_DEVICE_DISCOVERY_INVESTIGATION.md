# No-Xcode Device Discovery Investigation V2

Investigation date: 2026-09-14 (America/New_York)  
Investigation branch: `work/investigate-no-xcode-device-discovery-v2`  
Investigation baseline: `1259da507ecded222022cc86bf82863c15640db9`

## 1. Executive summary

This investigation found two different failures that must not be conflated:

1. **The app rebuilt by the ordinary `./iossim build` Mac step was not the bundled consumer app.** It was compiled without `IOSSIM_BUNDLED_ENGINE`, contained neither `IOSSimProvisioner` nor the native bridge, and deliberately used `DevelopmentCLIEngine`. Its **Check Setup** path invoked repository `./iossim doctor --json`; that Python doctor still attempted `xcrun devicectl`. With Xcode absent, the failed command was converted to `[]`. This is the exact source of the reported stale Xcode/RPPairing instructions and the user-visible `device.connected=false`, `devices=[]`, `ready=false` result.
2. **The GUI process under observation was older than the rebuild.** PID 48481 started at 2026-09-14 16:43:38 local time and remained running across the later build. Replacing an app bundle on disk cannot change code already loaded in that process. Its log continued to prove `DevelopmentCLIEngine` execution. A quit/relaunch is a mandatory retest step.
3. **The actual native no-Xcode stack is operational through every software boundary, but Apple currently reports no attached usbmux device.** macOS 26.6.2 has a running `com.apple.usbmuxd`, with its active launchd socket at `/var/run/usbmuxd`. A protocol-level plist request made independently of IOSSim returned a successful `DeviceList=[]`. The exact pinned Rust client, IOSSim C ABI, Swift wrapper, unsigned helper, signed helper, and app-bundled helper all returned the same zero count. At the same instant, `system_profiler` and the IOUSB registry contained no iPhone USB host device.

The exact visibility-loss statement is therefore:

> In the currently rebuilt app, the native discovery path is never entered; the result is lost in the development Python doctor when missing `xcrun devicectl` is collapsed to an empty list. In the independently tested native path, visibility is not lost inside IOSSim: Apple's live usbmux service itself returns an empty list, consistent with the iPhone being absent from the IOUSB host registry at the time of this investigation.

Finder visibility does not disprove the second result. Finder can show and sync a previously configured iPhone over Wi-Fi, so it is not proof that a live USB data interface is registered at the same moment. This investigation does not claim a cable, port, phone, or trust root cause without a new physical check.

No production source was changed before this report was completed. Xcode was not installed, restored, or used as a discovery source, and no Xcode/devicectl fallback is recommended.

## 2. Current physical facts

Reported facts at task start:

- Full Xcode intentionally absent; Apple Command Line Tools remain.
- iPhone reported connected by USB, unlocked, and visible in Finder with normal device information.
- IOSSim displayed `state=ACTION`, `detail=not detected`, with `device.connected=false`, `device.devices=[]`, and `device.ready=false`.
- Native bridge, Swift package, and Mac app builds passed; iOS payload builds failed as expected without Xcode.

Observed facts during this investigation:

- Host: macOS 26.6.2, build 25G83, Apple Silicon (`arm64`).
- `system_profiler SPUSBDataType -json`: zero device-tree entries.
- `ioreg -p IOUSB`: two host controllers and no child iPhone/Apple USB host device.
- No live IOUSB registry object with Apple USB vendor ID `0x05ac`/1452 representing the phone.
- Apple `usbmuxd` was running and its independent `ListDevices` response was an empty array.
- Finder can retain network visibility independently of USB. Apple documents Finder Wi-Fi display/sync at <https://support.apple.com/en-gb/guide/mac-help/mchlada1d602/mac>.

Sanitized conclusion at the observation instant:

```text
APPLE_USB_LAYER_DEVICE_PRESENT = NO
APPLE_USBMUX_DEVICE_PRESENT = NO
RUST_USBMUX_DEVICE_PRESENT = NO
```

The broader registry contained internal Apple networking/device-mode classes such as `AppleUSBDeviceNCM`, but no corresponding active external IOUSB host-device node. Those class names are not evidence that the connected iPhone was on the USB bus.

## 3. Git and build provenance

Phase 0 was performed before tests or edits:

```text
original branch: work/fix-no-xcode-device-discovery
current branch:  work/investigate-no-xcode-device-discovery-v2
HEAD:            1259da507ecded222022cc86bf82863c15640db9

git status --short:
?? IOSSim-Support-1789416447.zip

git log -10 --oneline:
1259da5 Document no-Xcode discovery fix
bc339b3 Fix no-Xcode native device discovery
c98b7b5 Polish implementation report
46f4fb5 Add final no-Xcode implementation report
d7d1795 Sign bundled native bridge
de449e1 Sanitize bundled bridge paths
529b573 Bundle native Mac device bridge in releases
e27a8c5 Document no-Xcode productization and audit
178bdd3 Add Mac-assisted signing renewal
2f71e76 Simplify consumer onboarding
```

The untracked support ZIP was preserved and not modified. No reset, clean, merge, branch rollback, or speculative commit occurred.

There are three materially different app artifacts:

| Artifact | Engine | Helper/bridge embedded | Provenance |
|---|---|---:|---|
| `.build/iossim/mac/IOSSim.app` | `DevelopmentCLIEngine` | No | Fresh debug output from `macos/scripts/build_app.sh`; currently running artifact |
| `.build/iossim/self-contained/IOSSim.app` | `BundledProvisioningEngine` | Yes | Manifest source commit `bc339b3...`, production classification |
| `/Applications/IOSSim.app` | `BundledProvisioningEngine` | Yes | Byte-identical executable/helper/bridge to self-contained artifact; source commit `bc339b3...` |

The normal Mac build script compiles only `IOSSimMac` without `IOSSIM_BUNDLED_ENGINE`, writes `DevelopmentRepositoryRoot.txt`, and embeds no helper or dylib. The native bridge built earlier by `./iossim build` is therefore not used by this app.

The observed GUI PID 48481 started at 16:43:38, before the recorded 20:42–20:43 rebuild and Check Setup runs. It remained alive after the on-disk bundle was replaced. The process log, not the current bytes later written at the same pathname, is authoritative for the engine that served those UI requests.

The installed/self-contained bundle has:

```text
GUI SHA-256:    f3525... (same in both bundles)
helper SHA-256: 904d6... (same in both bundles)
dylib SHA-256: 62dc...  (same in both bundles)
manifest sourceCommit: bc339b3e13a62b7ac1eafb3d2598a2d65174b107
manifest builtAt:      2026-09-14T20:36:16Z
manifest sourceDirty:  false
bridge version:        iossim-device-bridge/0.1.0+idevice-1838db1
```

The locally rebuilt release bridge used by direct C ABI tests was:

```text
path: native/iossim-device-bridge/target/release/libiossim_device_bridge.dylib
SHA-256: af83701eddfd8a3765af5598c282f6e1aeab2ba3fb9c56e065081d1fee5345dd
architecture: arm64
version: iossim-device-bridge/0.1.0+idevice-1838db1
```

The diagnostic value `c442bd235bd1` shown by the development doctor describes the separately pinned iPhone-side FFI checkout. It is not the revision of the Mac discovery bridge. Treating it as proof about the running Mac bridge was a provenance error.

## 4. Discovery architecture map

### Production bundled path

```text
Check Setup button
  -> SetupStore.refresh()
  -> IOSSimSetupEngine.doctor()
  -> BundledProvisioningEngine.doctor()
  -> IOSSim.app/Contents/MacOS/IOSSimProvisioner doctor --json
  -> ProvisionerTool.doctor(context:)
  -> AppleDeviceTool.discoverDeviceSnapshot(context:)
  -> IdeviceProvisioningBackend.discoverDeviceSnapshot(context:)
  -> IOSSimDeviceBridge.listDevices(timeout:)
  -> DynamicNativeDeviceTransport.listDevices(timeout:)
  -> dlopen bundled libiossim_device_bridge.dylib
  -> iossim_bridge_list_devices (C ABI)
  -> Rust devices()
  -> idevice::usbmuxd::UsbmuxdConnection::default()
  -> Unix socket /var/run/usbmuxd
  -> ListDevices plist request/response
  -> Rust descriptors
  -> C JSON result + count/status
  -> Swift decode/deduplication
  -> optional per-device Lockdown inspection
  -> DetectedDevice (descriptor retained on inspection failure)
  -> DoctorStatus / selection policy
  -> SetupStore.status
  -> Dashboard/SetupWizard rendering
```

### Rebuilt app path actually exercised

```text
Check Setup
  -> SetupStore.refresh()
  -> DevelopmentCLIEngine.doctor()
  -> /bin/bash <repo>/iossim doctor --json
  -> scripts/bootstrap/iossim_cli.py: check_devices()
  -> discover_devices()
  -> xcrun devicectl list devices ...
  -> command failure because devicectl is absent
  -> []
  -> "not detected" + stale Xcode/RPPairing actions
  -> DoctorStatus
  -> UI "No iPhone Connected"
```

### Boundary inventory

| Layer / symbol | Process | Input | Output / error | Empty/error behavior |
|---|---|---|---|---|
| `DashboardView` / `SetupWizardView` Check Setup | GUI | Button action | `store.refresh()` | No cache decision in view |
| `SetupStore.refresh()` | GUI | Current engine | Async fresh `DoctorStatus` | Calls `doctor()` every time; prior status does not short-circuit |
| `BundledProvisioningEngine.doctor()` | GUI | `doctor --json` | Decoded status or process/decode error | Does not synthesize device `[]` |
| `DevelopmentCLIEngine.doctor()` | GUI | repo CLI | Decoded Python doctor status | Uses legacy Python implementation |
| `ProvisionerTool.doctor` | helper | runtime context | `DoctorStatus` | Calls fresh snapshot even if other readiness checks fail |
| `AppleDeviceTool.discoverDeviceSnapshot` | helper | selected backend | Devices + diagnostics | Native default; devicectl only explicit comparison backend |
| `IdeviceProvisioningBackend.discoverDeviceSnapshot` | helper | bridge | `DeviceDiscoverySnapshot` | Transport error becomes empty devices **plus typed diagnostic**; true empty gets `ZERO_DEVICES_RETURNED` |
| `IOSSimDeviceBridge.listDevices` | helper | timeout | Validated/deduplicated descriptors | Throws transport error; does not return `[]` for error |
| `DynamicNativeDeviceTransport.listDevices` | helper | dylib candidates + timeout | Decoded C payload | Library/symbol/status/JSON errors throw typed errors |
| `iossim_bridge_list_devices` | dylib/Rust in helper | timeout | owned C result | Panic guarded; status and sanitized diagnostic returned |
| Rust `devices()` | dylib/Rust | default usbmux address | `Vec<UsbmuxdDevice>` | Successful empty response is empty vector; connection/protocol error is `Err` |
| pinned `idevice` `get_devices()` | dylib/Rust | plist `ListDevices` | parsed descriptors | Uses `flat_map`; malformed individual records are silently omitted (latent defect) |
| Lockdown `inspect_device` | dylib/Rust | enumerated UDID + DeviceID | optional metadata/readiness | Happens after enumeration; Swift preserves the descriptor if it fails |
| Device selection policy | GUI | returned devices + saved selection | selected device or nil | No product/iOS allowlist; cannot create a device that upstream omitted |
| UI | GUI | status + discovery diagnostics | Connected / unavailable / no device | Bundled path distinguishes unavailable; development path has no bridge diagnostic and displays no-device |

No production native enumeration step invokes Xcode, CoreDevice, `xcrun`, or `devicectl` by default.

## 5. macOS USB evidence

Sanitized commands and outcomes:

```text
sw_vers
ProductVersion: 26.6.2
BuildVersion: 25G83

uname -m
arm64

system_profiler SPUSBDataType -json
SPUSBDataType entries: 0

ioreg -p IOUSB -l -w0
two AppleT8142USBXHCI controllers
no external child iPhone / Apple USB host device
```

Result:

```text
A. iPhone visible on current USB bus: NO
B. iPhone USB identity present:       NO
```

This is a point-in-time fact, not a claim that Finder never saw the phone or that the cable was never connected.

## 6. Apple usbmux evidence

`launchctl print system/com.apple.usbmuxd` showed:

```text
path = /Library/Apple/System/Library/LaunchDaemons/com.apple.usbmuxd.plist
state = running
program = /System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/Resources/usbmuxd
pid = 439
Listeners path = /var/run/usbmuxd
Listeners state = active
```

Filesystem and process evidence:

```text
/var/run/usbmuxd: Unix-domain socket, root:daemon, mode 0666
usbmuxd: running
remoted: running
MobileDeviceUpdater: running
MDRemoteServiceSupport: running
AMPDevicesAgent: launchd-registered, not required to keep usbmux socket available
```

Modern macOS 26.6.2 on this host therefore still exposes the usbmux plist protocol through `/var/run/usbmuxd`. No alternate socket or XPC endpoint is required for the operation under test. The world-readable/writable socket and successful signed-helper request also rule out root/user and app-sandbox access as current blockers.

A stale `pymobiledevice3` RSD-related process was present from an earlier date, with no matching current route. It is not the process used by the IOSSim bridge and does not explain the empty Apple `DeviceList`.

## 7. Rust usbmux evidence

The exact Mac bridge dependency is `idevice` revision `1838db107d...`, crate version 0.1.67. The old diagnostic revision `c442bd235...` is crate version 0.1.66 used by the iPhone-side FFI build.

Both exact revisions were built/run directly with `idevice_id` against the current host. Both connected successfully and returned `[]`.

The pinned implementation:

- defaults to Unix `/var/run/usbmuxd` on macOS;
- writes a plist `ListDevices` request;
- parses `DeviceList` entries into DeviceID, serial/UDID, and connection type;
- maps `USB`, network, and unknown connection values;
- does not inspect product type or iOS version during enumeration;
- performs Lockdown only after a usbmux descriptor exists;
- supports the current Apple Silicon build target in CI, but contains no explicit physical certification statement for macOS 26, iOS 26, or iPhone 17 Pro.

The upstream repository was inspected at <https://github.com/jkcoxson/idevice>. On 2026-09-14 its `master` HEAD was exactly `1838db107d...` (dated 2026-09-12). There are no commits after IOSSim's Mac pin, and therefore no concrete post-pin usbmux/macOS/iOS 26/Lockdown fix to adopt. The usbmux and Lockdown sources did not differ between `c442bd2` and `1838db1` for the enumeration path at issue.

One latent concern remains: `get_devices()` uses `flat_map` when converting response entries. A malformed entry can be silently dropped rather than returned as a parse error. That could convert a future incompatible record into a false zero, but it is not active here because the independent raw response contained an actually empty `DeviceList`.

## 8. Raw enumeration results

### Minimal Rust-only probe

```text
USBMUX_INITIALIZE = PASS
USBMUX_ENDPOINT = launchd-managed Unix socket /var/run/usbmuxd
USBMUX_CONNECT = PASS
USBMUX_LIST_REQUEST = PASS
RAW_USBMUX_DEVICE_COUNT = 0
RAW_ERROR_CATEGORY = NONE
RAW_ERROR_CODE = 0
```

No Lockdown call was made by this probe.

### Independent protocol probe

A separate Python-standard-library implementation opened `/var/run/usbmuxd`, sent a binary usbmux header and plist `ListDevices` request, read the framed plist reply, and counted the raw array without using Rust, IOSSim, Swift, or devicectl.

```text
APPLE_USBMUX_CONNECT = PASS
APPLE_USBMUX_LIST_REQUEST = PASS
APPLE_USBMUX_PROTOCOL_VERSION = 1
APPLE_USBMUX_MESSAGE_TYPE = 8
APPLE_USBMUX_DEVICE_COUNT = 0
```

This is the decisive parser boundary test: Apple returned an empty array, rather than returning entries that Rust discarded.

## 9. C ABI results

The exact exported functions in the release dylib were invoked directly through `ctypes`, including version/ABI discovery, `iossim_bridge_list_devices`, result copying, and `iossim_bridge_result_free`.

```text
bridge version = iossim-device-bridge/0.1.0+idevice-1838db1
ABI version = 1
C status = 0
C diagnostic = ok
C JSON payload = []
C_ABI_COUNT = 0
```

The successful, valid two-byte JSON payload and clean free rule out an active count width, array layout, pointer lifetime, premature free, UTF-8, struct-packing, or panic-handling failure for the current result.

## 10. Swift results

The exact production Swift wrapper was exercised through `IOSSimProvisioner device-diagnostics` with the release bridge and through the installed app's bundled helper/bridge:

```json
{
  "ok": true,
  "schemaVersion": 1,
  "data": {
    "diagnostics": [
      {
        "code": "ZERO_DEVICES_RETURNED",
        "detail": "usbmux returned no connected devices"
      }
    ],
    "rawDeviceCount": 0,
    "returnedDeviceCount": 0
  }
}
```

`DynamicNativeDeviceTransport` copies the result bytes before freeing the Rust allocation, validates status, and throws on bridge/load/symbol/decode errors. `IOSSimDeviceBridge` then validates identifiers, deduplicates exact UDIDs, and prefers USB over a duplicate network record. It does not convert transport failures to `[]`.

The higher-level snapshot API does structurally contain `devices=[]` on a transport error, but accompanies it with a typed diagnostic. The old array-only convenience method discards that diagnostic; this remains a contributing API defect.

## 11. Filter-stage counts

For the current run:

| Stage | Count |
|---|---:|
| `RAW_USBMUX_COUNT` (independent Apple reply) | 0 |
| `RUST_PARSED_COUNT` | 0 |
| `C_ABI_COUNT` | 0 |
| `SWIFT_PRE_FILTER_COUNT` | 0 |
| `POST_CONNECTION_TYPE_COUNT` | 0 |
| `POST_METADATA_COUNT` | 0 |
| `POST_IPHONE_FILTER_COUNT` | 0 |
| `POST_OS_FILTER_COUNT` | 0 |
| `POST_SELECTION_COUNT` | 0 |
| `UI_VISIBLE_COUNT` | 0 |

There is no connection-type, product-type, iPhone-model, iOS-version, paired-only, trusted-only, unlocked-only, or Developer-Mode-only filter in the native enumeration path. Unknown connection types are retained as `unknown`. Unknown/new product identifiers and OS versions are not eliminated. Missing optional Lockdown metadata does not remove a successfully enumerated descriptor.

## 12. Lockdown results

```text
USBMUX_DEVICE_VISIBLE = NO
LOCKDOWN_CONNECT = NOT_ATTEMPTED (correctly gated)
PAIR_RECORD_FOUND = UNKNOWN
TRUST_STATUS = UNKNOWN
LOCKDOWN_METADATA = NOT_ATTEMPTED
```

It is impossible to test Lockdown for a device that Apple's usbmux list did not enumerate. Pair records, trust, lock state, Developer Mode, DDI, and RPPairing are downstream of this gate and cannot explain the current raw count of zero.

Code and unit-test inspection confirms that when enumeration succeeds but Lockdown inspection fails, `IdeviceProvisioningBackend` now retains the descriptor and returns unknown/partial readiness plus a typed inspection diagnostic.

## 13. Process-context matrix

| Context | Library load | usbmux connect/list | Raw devices | Lockdown | Final devices |
|---|---|---|---:|---|---:|
| Independent plist protocol CLI | N/A | PASS | 0 | Not attempted | 0 |
| Direct Rust `idevice_id` 1838db1 | Static Rust | PASS | 0 | Not attempted | 0 |
| Direct Rust `idevice_id` c442bd2 | Static Rust | PASS | 0 | Not attempted | 0 |
| Direct C ABI via `ctypes` | PASS | PASS | 0 | Not attempted | 0 |
| Swift package helper, explicit bridge | PASS | PASS | 0 | Not attempted | 0 |
| `/Applications` signed helper | PASS | PASS | 0 | Not attempted | 0 |
| App-bundled/sanitized-environment helper | PASS | PASS | 0 | Not attempted | 0 |
| `.build/iossim/mac/IOSSim.app` Check Setup | **Not attempted** | **Not attempted** | N/A | N/A | 0 from legacy devicectl collapse |

The uniform native result rules out working directory, `DYLD_*`, rpath, app launch, sandbox, entitlement, and hardened-runtime differences as the reason for the current native zero. The development app is categorically different: it never launches the native helper.

## 14. Signing and entitlement audit

Audited objects:

- `/Applications/IOSSim.app`
- `Contents/MacOS/IOSSim`
- `Contents/MacOS/IOSSimProvisioner`
- `Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib`
- the equivalent self-contained bundle

Findings:

- App and helper are ad-hoc signed with hardened runtime in the LOCAL_TEST_ONLY artifact.
- Dylib is ad-hoc signed.
- Deep/strict verification passes.
- App entitlements are empty.
- Production helper entitlements are empty.
- LOCAL_TEST_ONLY helper has only `com.apple.security.cs.disable-library-validation=true`, the previous narrow fix for loading separately ad-hoc-signed code.
- App Sandbox is absent.
- No network-client, USB, Bluetooth, or Xcode entitlement is present or required for the working Unix-socket request.
- Signed helper and unsigned/direct probes produce the same result.

No signing weakening is justified by current evidence.

The GUI/helper are universal `arm64+x86_64`, while the bundled bridge is currently arm64-only. That is a real packaging compatibility defect on Intel, but cannot cause this Apple Silicon failure.

## 15. Runtime library path and bundle audit

Installed bundle resolved exactly:

```text
/Applications/IOSSim.app/Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib
```

The self-contained bundle contains one bridge at the equivalent path. The current `.build/iossim/mac/IOSSim.app` contains no bridge and no helper by design.

Checks performed:

- bridge file exists and is executable;
- expected ABI/version symbols exist;
- bridge version identifies `idevice-1838db1`;
- architecture is arm64 in the native artifact;
- explicit helper lookup resolves the outer-app resource path;
- helper runs correctly with a minimal/sanitized environment;
- no linked fallback bridge exists (`dlopen` is explicit);
- installed and self-contained helper/bridge hashes match;
- current build bridge hash recorded above;
- no stale alternate candidate was selected in the successful probe.

The runtime Swift executables contain standard Swift runtime search paths, including `/usr/lib/swift`; they run under Command Line Tools alone. Historical Xcode-looking rpaths in Mach-O load commands did not prevent execution and are not discovery dependencies.

## 16. Check Setup execution trace

Source trace:

- Dashboard/SetupWizard button calls `SetupStore.refresh()`.
- `refresh()` always creates a fresh task and calls `engine.doctor()`.
- It assigns the returned status and recalculates selection/UI state.
- It does not reuse an empty device list, prior completion state, selected metadata, expired provisioning, or stale UserDefaults as a substitute for enumeration.

Observed current development-app trace from `~/Library/Logs/IOSSimMac/development-engine.log`:

```text
2026-09-14T20:43:39Z launch doctor
Helper: Development CLI
Executable: /bin/bash
Launcher: /Users/rishiborra/Desktop/IOSSim/iossim
2026-09-14T20:43:45Z complete doctor

2026-09-14T20:43:47Z launch doctor
2026-09-14T20:43:52Z complete doctor
```

The repository doctor reproduced the displayed diagnostics. Its `xcrun devicectl` call failed with:

```text
xcrun: error: unable to find utility "devicectl", not a developer tool or in PATH
```

The installed production helper trace at `2026-09-14T21:14:55Z` showed request and result in the same second and reported `ZERO_DEVICES_RETURNED`, proving a fresh native call.

Conclusion: Check Setup is live, but the freshly selected engine differs by artifact. The bug is routing/provenance, not status caching.

The process itself must also be relaunched after rebuilding. The observed PID predates the rebuild, so it cannot load the new bundled-engine executable merely because files at its bundle path changed.

## 17. Error-collapse audit

| Source error | Current conversion | User-visible result | Correct result |
|---|---|---|---|
| Python `xcrun devicectl` missing/fails | `discover_devices()` returns `[]` | `not detected`; stale Xcode/RPPairing instructions | Native bridge call, or explicit `DEVICE_DISCOVERY_UNAVAILABLE` if bridge cannot run |
| Python devicectl output file missing | `[]` | No device | Explicit command/protocol error |
| Python devicectl JSON decode error | `[]` | No device | Explicit decode error |
| Swift native dylib unavailable | Typed throw, then snapshot `devices=[]` plus typed diagnostic | Bundled UI: Device Discovery Unavailable | Correct for doctor; avoid array-only callers that discard diagnostic |
| C ABI status nonzero | Typed Swift error | Device Discovery Unavailable | Correct |
| Rust panic | C ABI panic status/diagnostic | Device Discovery Unavailable | Correct |
| usbmux connection/protocol failure | Rust/C status error, typed Swift diagnostic | Device Discovery Unavailable | Correct |
| successful usbmux empty list | valid `[]`, `ZERO_DEVICES_RETURNED` | No iPhone Connected | Correct |
| malformed raw usbmux entry | upstream `flat_map` silently omits it | Potential false no-device | Preserve parse error/diagnostic; not current failure |
| Lockdown connect/metadata failure after enumeration | descriptor retained; typed inspection diagnostic | Device visible, readiness partial/unknown | Correct |
| `discoverDevices()` convenience API | returns only `snapshot.devices` | Diagnostic can be lost by non-doctor callers | Prefer snapshot/result API |
| legacy Swift `DevicectlProvisioningBackend` failures | several `[]` returns | No device if explicitly selected | Explicit dev comparison error; never consumer default |
| development UI receives Python zero | no `Device Bridge` diagnostic | No iPhone Connected | Eliminate devicectl discovery or carry typed unavailability |

## 18. Xcode dependency classification

| Reference | Classification | Reason |
|---|---|---|
| Rust `idevice`/usbmux discovery | Consumer runtime | No Xcode reference; correct native default |
| `RuntimeProvisioningSupport` devicectl backend | `DEVELOPER_ONLY` / `LEGACY_UNUSED` | Explicit comparison backend only |
| Python `discover_devices()` via devicectl | **`CONSUMER_RUNTIME_BUG` for rebuilt Mac app** | Development app is the artifact produced by normal Mac build and sends Check Setup here |
| Python doctor Xcode/SDK/license checks | `BUILD_ONLY`, incorrectly presented by rebuilt app | Relevant to source payload builds, not consumer discovery/readiness |
| Python `Import RPPairing` action | `DEVELOPER_ONLY` stale consumer guidance | Not required for raw enumeration; native pairing lifecycle is separate |
| iOS `xcodebuild` project/payload scripts | `BUILD_ONLY` | Expected failure without Xcode; not a consumer runtime gate |
| release `xcrun --sdk macosx`, notary/stapler tools | `BUILD_ONLY` packaging | Do not participate after app is built |
| `IOSSimProvisioner` xcrun/devicectl checks | `LEGACY_UNUSED` for native default | Evaluated only for explicitly selected Xcode backend or informational checks |
| CoreDevice/Xcode framework references | No native discovery dependency found | Not linked or loaded by native bridge |
| `DEVELOPER_DIR` / iPhoneOS SDK | `BUILD_ONLY` | No effect on usbmux enumeration |

Consumer runtime must not instruct the user to install/open/select Xcode or manually import RPPairing for raw device visibility.

## 19. Pinned idevice compatibility assessment

| Capability | Assessment | Evidence |
|---|---|---|
| macOS 26.x socket selection | Supported on this host | Pin uses `/var/run/usbmuxd`; launchd exposes that exact active socket; connect/list succeeds |
| Apple Silicon | Supported for current build | arm64 dylib builds, loads, and completes request |
| iOS 26 / iPhone 17 enumeration | No model/version dependency at raw stage | usbmux enumeration does not parse product type or OS version |
| USB connection type | Supported | Known USB/network values parsed; unknown preserved by IOSSim model |
| Lockdown on iOS 26 | Not physically evaluated in this run | No raw descriptor; downstream check correctly not attempted |
| Tokio timeout/runtime | Previously fixed and currently operational | C call returns normally; Rust tests pass |
| FFI ownership/count | Operational for current empty result | valid status/payload/free across direct C and Swift paths |
| Malformed new usbmux fields | Latent risk | upstream per-record `flat_map` may drop malformed record silently |
| Explicit upstream macOS 26/iPhone 17 qualification | Not found | CI/build support is not equivalent to physical qualification |

There is no evidence-based dependency upgrade available: the Mac bridge already pins the current upstream HEAD.

## 20. Upstream comparison

- IOSSim Mac bridge pin: `1838db107d...` / idevice 0.1.67.
- Upstream `master` at investigation time: same commit.
- Old iPhone FFI pin: `c442bd235...` / idevice 0.1.66.
- No relevant diff in the usbmux/Lockdown enumeration path between those two local revisions.
- No upstream commits exist after the active pin, so no later socket, launchd, parser, iOS 26, or Tokio fix can currently be cited.
- The implementation source continues to use `/var/run/usbmuxd`, matching macOS launchd evidence: <https://github.com/jkcoxson/idevice/blob/master/idevice/src/usbmuxd/mod.rs>.

## 21. Root-cause matrix

| Rank | Hypothesis | Evidence for | Evidence against / result | Confidence | Impact |
|---:|---|---|---|---|---|
| 1 | Rebuilt app routes Check Setup to legacy Python/devicectl | Running bundle lacks helper/bridge; compile flag absent; logs show Development CLI; exact stale diagnostics reproduced | None | Proven | Primary user-visible software cause |
| 2 | Running GUI process predates rebuilt bytes | PID start 16:43; rebuild/checks occurred after 20:42; log remains Development CLI | None; loaded process cannot update in place | Proven | Relaunch required to test any rebuilt app |
| 3 | Current phone absent from host USB data path / Apple usbmux | IOUSB and system profiler absent; independent Apple `DeviceList=[]`; all native layers agree | User reports cable and Finder visibility, but Finder may be Wi-Fi | Proven point-in-time condition; physical cause unknown | Blocks physical native retest |
| 4 | Legacy Python collapses transport/tool failure to `[]` | Source and reproduction | None | Proven | Turns unavailable into false no-device |
| 5 | Wrong modern macOS usbmux endpoint | Old/new library assume `/var/run/usbmuxd` | launchd shows exact active endpoint; independent connect/list passes | Ruled out | None currently |
| 6 | usbmux service inaccessible | Could produce zero/error | socket active/mode 0666; signed and unsigned contexts request successfully | Ruled out | None currently |
| 7 | Pinned idevice incompatibility | No explicit iOS/macOS 26 physical certification; latent `flat_map` | Independent raw Apple response itself is empty; active pin is upstream HEAD | Not active; low residual risk | Future compatibility risk |
| 8 | iOS 26 parsing incompatibility | New OS can change metadata | OS is not parsed before enumeration | Ruled out at raw stage | None for zero raw count |
| 9 | iPhone 17 Pro product parsing | New product identifier | Product type not parsed/filtered during enumeration | Ruled out | None |
| 10 | Connection-type filtering | A new value might be unknown | No filter; unknown retained; raw array empty | Ruled out | None |
| 11 | Lockdown failure drops device | Historical class of bug | Current code preserves descriptor; Lockdown never reached with raw zero | Ruled out current | Regression-sensitive |
| 12 | C ABI pointer/count/packing bug | Boundary can lose arrays | status/payload/free valid; independent and C counts agree | Ruled out current | None |
| 13 | Swift decoding/async issue | Boundary can collapse error | exact wrapper returns typed successful zero; no filters | Ruled out current | None |
| 14 | Helper entitlement/library validation | Previously failed | signed helper now loads and lists; same result standalone | Ruled out current | None on arm64 local artifact |
| 15 | Hardened runtime/socket restriction | Could deny socket | signed helper succeeds with native request | Ruled out | None |
| 16 | Stale library loaded | Multiple artifacts existed | exact resolved path/version/hash recorded; helper has one candidate | Ruled out for native probes | Provenance remains usability issue |
| 17 | Stale app/DMG provenance | Multiple apps differ | Installed consumer app is known bc339; current rebuilt/running app is development artifact | Contributing/proven | Leads user to test wrong stack |
| 18 | Check Setup cache/short-circuit | Repeated stale result | source and timestamped logs prove new doctor calls | Ruled out | None |
| 19 | Tokio timeout/reactor bug | Previously found | direct C returns normally; Rust tests pass | Ruled out current | None |
| 20 | Hidden Xcode dependency in native discovery | Stale guidance and dev path use Xcode | bundled native path uses only bridge/usbmux; succeeds to empty reply | Ruled out in native; proven in rebuilt dev artifact | Major routing defect |
| 21 | Trust/pairing mismatch | Finder may have trust state | usbmux enumeration precedes Lockdown/trust | Ruled out for raw zero | Downstream unknown |
| 22 | macOS 26 service/API change | Plausible on new OS | conventional socket is actively registered and answers protocol | Ruled out for endpoint/protocol; physical behavior still gate | Low residual |
| 23 | Unknown usbmux record silently discarded | upstream `flat_map` | independent raw array has zero entries | Latent, not active | Could cause future false empty |
| 24 | Universal GUI with arm64-only bridge | Packaging mismatch exists | current Mac is arm64 and bridge loads | Ruled out current | Intel defect |

## 22. Primary root cause

The primary software root cause of the reported IOSSim UI diagnostics is **artifact/engine misrouting**: the app produced and launched by the normal Mac rebuild is a development shell app, not the no-Xcode consumer app. Its Check Setup command enters the legacy Python doctor, calls unavailable `xcrun devicectl`, and collapses that error into `[]`.

The primary current physical gate for the true native stack is outside IOSSim: Apple's usbmux service returns no devices and IOUSB shows no phone. The investigation cannot distinguish cable/port/accessory mode, transient reconnect, Finder Wi-Fi visibility, or another physical-state cause without a fresh on-device retest.

## 23. Secondary contributing defects

1. The Python discovery function collapses command, file, and decode failures into a successful empty list.
2. The running GUI was not relaunched after its bundle pathname was rebuilt, leaving old code resident.
3. Build output naming/documentation does not make the development-engine nature of `.build/iossim/mac/IOSSim.app` obvious.
4. The development doctor exposes build-only Xcode checks as consumer readiness guidance.
5. The development doctor reports the iPhone-side c442 revision where users reasonably infer the Mac bridge revision.
6. Array-only Swift discovery APIs can discard typed snapshot diagnostics.
7. Upstream usbmux parsing silently omits malformed individual entries with `flat_map`.
8. Current diagnostic output does not show the resolved bridge path/version at every process boundary.
9. The bridge artifact is arm64-only while shipping GUI/helper binaries are universal.
10. No single no-Xcode command currently prints system USB, raw Apple usbmux, C ABI, Swift, and Lockdown stages separately.

Items 5–8 are not proven causes of this arm64 failure and must not be used to justify speculative broad changes.

## 24. Exact recommended fix

The narrow evidence-supported change is:

1. Add a no-Xcode `./iossim device-debug` command that probes system USB, Apple's raw usbmux protocol, the exact C ABI bridge, and the exact Swift helper independently, with typed/sanitized errors.
2. Stop using Python `xcrun devicectl` for `doctor` device discovery. Route the development doctor to the already-built native helper/bridge; if those are absent or fail, return `DEVICE_DISCOVERY_UNAVAILABLE`, never an empty success.
3. Make the ordinary local Mac-app build/test artifact use the bundled consumer engine and embed the freshly built helper/bridge, or make the development artifact unmistakably separate. For this task, the consumer test path should be the default output used after `./iossim build`.
4. Mark remaining Python Xcode checks as `BUILD_ONLY` and remove Xcode/open-Xcode/manual-RPPairing guidance from consumer device readiness.
5. Preserve existing native enumeration/Lockdown separation and do not alter entitlements, socket selection, dependency pin, or parsing without contrary physical evidence.

## 25. Regression tests required

Required coverage:

- raw Apple usbmux count equals Rust parsed/C ABI count equals Swift pre-filter count for a controlled response;
- a bridge/transport failure produces `DEVICE_DISCOVERY_UNAVAILABLE`, not `[]`/no-device;
- Lockdown failure retains an enumerated physical descriptor;
- unknown/new iPhone product identifiers remain visible;
- unknown/new iOS versions remain visible unless an explicit supported-operation check later rejects an operation;
- unknown connection type remains visible;
- C ABI result allocation/count/payload/free ownership remains correct;
- Check Setup performs a new enumeration call every time;
- the local consumer test app contains and invokes the helper/bridge;
- development doctor cannot invoke `xcrun devicectl` for discovery;
- device-debug reports divergence at the exact boundary.

Several native tests already cover C ABI ownership, future product/version retention, Lockdown preservation, bridge-error distinction, and repeated `SetupStore.refresh`. New tests should target the proven development routing/error-collapse and diagnostic command.

## 26. Remaining unknowns

- Why the phone was absent from IOUSB during this investigation despite the user's earlier cable/Finder observation.
- Whether Finder was using Wi-Fi sync at the observation instant.
- Whether reconnecting with a confirmed data-capable cable/port makes Apple's raw `DeviceList` non-empty.
- Lockdown trust, pair-record, metadata, and Developer Mode results for this physical phone; these cannot be measured until enumeration succeeds.
- Whether upstream `idevice` correctly parses a real iOS 26/iPhone 17 usbmux record on this host. The current raw empty reply did not exercise that parser with a record.
- Physical behavior of the corrected app after the routing fixes. It must remain `DEVICE_PHYSICAL = AWAITING_RETEST` until the user performs the real-phone test.

## Investigation-stage verdict

```text
VERDICT = MULTIPLE_ROOT_CAUSES_FOUND

USER_VISIBLE_FAILURE_LAYER = development app -> Python doctor -> devicectl error collapse
NATIVE_CURRENT_ZERO_LAYER = Apple USB/usbmux input (before Rust)

SYSTEM_USB = 0
APPLE_USBMUX = 0
RUST = 0
C_ABI = 0
SWIFT = 0

DEVICE_PHYSICAL = AWAITING_RETEST
```

## Post-investigation implementation and verification

This section was added only after Sections 1–26 were completed and the evidence was reviewed.

### Implemented narrow fixes

- Extended `IOSSimProvisioner device-diagnostics` to return the exact Swift-visible device array alongside raw/returned counts and typed diagnostics.
- Replaced Python doctor's `xcrun devicectl` enumeration with the exact native helper/bridge diagnostic path. Missing helper, bridge, process failure, usbmux failure, and decode failure now remain distinct from a successful empty list.
- Added `./iossim device-debug`, which independently checks IOUSB, raw Apple usbmux plist protocol, direct Rust C ABI, the exact Swift helper, Lockdown diagnostics, and cross-layer count equality.
- Changed `macos/scripts/build_app.sh` to compile the bundled engine, build/embed `IOSSimProvisioner`, embed the freshly built native bridge, apply only the existing LOCAL_TEST_ONLY helper entitlement for ad-hoc signing, and deep/strict verify the app.
- Added a local discovery-build provenance plist containing classification, source HEAD, dirty state, build timestamp, and pre-sign bridge hash.
- Marked Python Xcode checks `BUILD_ONLY` and removed them from consumer Mac readiness. Removed legacy manual RPPairing instructions from the Mac CLI path and corrected consumer-facing Apple-tooling recovery text.
- Added regression coverage for error-versus-empty parsing, future product/iOS retention, count-boundary reporting, no-devicectl doctor routing, bundled local app contents, and unknown connection-type retention.

No change was made to the usbmux endpoint, Rust dependency pin, Rust parser, Lockdown behavior, native entitlements, iPhone runtime, DDI, provisioning, or Xcode fallback behavior.

### Post-fix live result

```text
IOSSim Device Discovery Debug

[PASS] System USB: devices: 0
[PASS] Apple usbmux: devices: 0
  endpoint: launchd Unix socket /var/run/usbmuxd
[PASS] Rust bridge: devices: 0
  version: iossim-device-bridge/0.1.0+idevice-1838db1
[PASS] C ABI: devices: 0
[PASS] Swift: devices: 0
[SKIP] Lockdown: no enumerated device
[ACTION] Discovery: NO_DEVICE_AT_APPLE_USBMUX
```

The result is an actionable physical gate, not a software transport failure. Exit code 2 represents a successful discovery pipeline with no device at Apple usbmux; transport/ABI/decode failures use exit code 1.

### Verification results

| Check | Result |
|---|---|
| Python compile | PASS |
| No-Xcode discovery CLI tests | PASS, 5/5 |
| Swift test-source parse | PASS |
| Swift package debug build | PASS |
| Swift helper release build | PASS |
| Swift GUI release build | PASS |
| Rust bridge tests | PASS, 6/6 |
| No-Xcode static consumer audit | PASS |
| Local bundled Mac app build | PASS |
| Deep/strict app signature verification | PASS |
| App-bundled helper bridge load/list | PASS, typed zero |
| Mounted-DMG helper bridge load/list | PASS, typed zero |
| `swift test --package-path macos` | EXPECTED ENVIRONMENT FAILURE: Command Line Tools installation has no `XCTest` Swift module |
| Full iPhone payload builds | NOT USED AS GATE: full Xcode intentionally absent |

The XCTest test bodies were syntax-parsed successfully, but this report does not mislabel them as executed under an environment that lacks XCTest.

### New test artifacts

Local bundled discovery app (bridge/UI-only build output):

```text
/Users/rishiborra/Desktop/IOSSim/.build/iossim/mac/IOSSim.app
distributionClass: LOCAL_DEVICE_DISCOVERY_TEST
sourceCommit: 1259da507ecded222022cc86bf82863c15640db9
sourceDirty: true
buildTimestamp: 2026-09-14T23:55:49Z
bridge SHA-256 before bundle signing: af83701eddfd8a3765af5598c282f6e1aeab2ba3fb9c56e065081d1fee5345dd
```

Full local physical-retest app, assembled with the unchanged prebuilt iPhone artifacts from the previously verified local bundle:

```text
/Users/rishiborra/Desktop/IOSSim/.build/iossim/device-discovery-retest/IOSSim.app
Mac discovery sourceCommit: 1259da507ecded222022cc86bf82863c15640db9 (dirty working tree)
prebuilt iPhone payload sourceCommit: bc339b3e13a62b7ac1eafb3d2598a2d65174b107 (clean at its build time)
Mac/helper/bridge: replaced with V2 outputs
iPhone payloads: unchanged
deep/strict signature verification: PASS
installed-copy mac readiness: PASS
```

Recommended full local retest DMG:

```text
/Users/rishiborra/Desktop/IOSSim/.build/iossim/local-release/IOSSim-0.1.0-local-device-discovery-v2-full.dmg
size: 17,989,661 bytes
SHA-256: 57c63c377d9fded08467e6a706ae2a32aa46c2f4aa1fbb659d34dacec54d786e
```

Lower-layer discovery-only DMG (does not include iPhone payload artifacts):

```text
/Users/rishiborra/Desktop/IOSSim/.build/iossim/local-release/IOSSim-0.1.0-local-device-discovery-v2.dmg
size: 6,807,051 bytes
SHA-256: 81408bc34e6e37cffe5ddd6f810503781ad337c548df6f9996184caf0fc62a23
```

Both DMGs are intentionally local device-discovery retest vehicles; neither is notarized, Gatekeeper-qualified, or suitable for public distribution. The recommended `v2-full` DMG reuses the explicitly recorded, unchanged prebuilt iPhone payloads instead of trying to rebuild them without Xcode. A copy installed from that DMG passed artifact verification and reported `mac.ready=true`. The existing general full-release command still requires Xcode to rebuild/universalize all release inputs, so it was not falsely reported as supported in the no-Xcode environment.

### Post-fix physical status

```text
SOFTWARE_ROUTING_FIX = PASS
NATIVE_BRIDGE_TO_APPLE_USBMUX = PASS
CROSS_LAYER_ZERO_COUNT_CONSISTENCY = PASS
DEVICE_PHYSICAL = AWAITING_RETEST
```
