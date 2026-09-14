# Verdict

`ROOT_CAUSE_FIXED_READY_FOR_RETEST`

`DEVICE_PHYSICAL = AWAITING_RETEST`

The software and packaging faults that prevented the production no-Xcode helper from reaching Apple's live usbmux service are fixed. The replacement DMG has passed a mounted-artifact bridge probe, but the iPhone was no longer present in the USB registry during the post-fix run. This report does not claim that the physical gate passed.

# Repository State

Before edits:

```text
git status --short
?? IOSSim-Support-1789416447.zip

git branch --show-current
work/no-xcode-productization-v1

git rev-parse HEAD
c98b7b576f6bf364fd7258163fb65869b626e68f

git log --oneline --decorate -10
c98b7b5 (HEAD -> work/no-xcode-productization-v1) Polish implementation report
46f4fb5 Add final no-Xcode implementation report
d7d1795 Sign bundled native bridge
de449e1 Sanitize bundled bridge paths
529b573 Bundle native Mac device bridge in releases
e27a8c5 Document no-Xcode productization and audit
178bdd3 Add Mac-assisted signing renewal
2f71e76 Simplify consumer onboarding
1fcd885 Add unified readiness and recovery
c8cd305 Automate RemotePairing lifecycle
```

Fix branch: `work/fix-no-xcode-device-discovery`

Fix/source commit: `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`

The original untracked `IOSSim-Support-1789416447.zip` was not deleted, reset, committed, or modified. Tracked source was clean when the DMG was assembled. `git status` remains dirty only because that preserved support ZIP is untracked; release metadata records the clean tracked source commit.

# Physical Evidence

- Xcode was absent.
- Finder saw the connected, unlocked phone as `Rishi Borra`, `iPhone 17 Pro`, including battery and storage.
- IOSSim from the previous local DMG simultaneously rendered `No iPhone Connected`.
- The previous support bundle retained historical device/app data but reported `computerTrust`, `developerMode`, and `deviceLock` as `UNKNOWN`.
- During the post-fix command-line and mounted-DMG probes, the phone was no longer present in `system_profiler`, `ioreg`, or usbmux enumeration. The fixed bridge therefore correctly reported `ZERO_DEVICES_RETURNED`; physical success still requires the specified retest.

# Exact Root Cause

The production failure was a serial chain of three concrete defects:

1. `IOSSimProvisioner` is a standalone nested executable. `DynamicNativeDeviceTransport` searched paths derived from `Bundle.main`, but the packaged bridge lives at `IOSSim.app/Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib`. In the helper process, `Bundle.main` did not resolve the outer app resource directory. The existing helper therefore did not find the library.
2. Even when the old helper was given the dylib explicitly, the LOCAL_TEST_ONLY hardened-runtime signature rejected the separately ad-hoc-signed dylib: `mapping process and mapped file (non-platform) have different Team IDs`. The old Swift abstraction discarded this load error with `try?` and returned `[]`, making a bridge failure indistinguishable from a successful zero-device enumeration.
3. Direct invocation of the shipped Rust C ABI reproduced a second immediate failure at `iossim_bridge_list_devices`: it constructed `tokio::time::timeout(...)` before `Runtime::block_on` entered the Tokio runtime. The release dylib aborted with `there is no reactor running`. Every timed bridge operation used the same pattern, so enumeration and subsequent Lockdown inspection could not work after loading.

Finder visibility was not contradictory: macOS `com.apple.usbmuxd` was running, its socket was `/var/run/usbmuxd` with mode `0777`, and the pinned Rust dependency also defaults to `/var/run/usbmuxd`. The failure occurred before the production helper could perform a valid usbmux list request.

# Failure Layer

`packaging`

The first production blocker was helper-to-dylib location/loading under LOCAL_TEST_ONLY signing. A directly adjacent Rust bridge-initialization defect and Swift error-collapse defect were also fixed because either would still prevent this same discovery/readiness path from functioning.

# Actual Production Discovery Path

1. `DashboardView.deviceHeader` renders `No iPhone Connected` when `store.status?.device.devices.isEmpty == true`. `DeviceConnectView` uses the same live status.
2. `Check Setup` calls `SetupStore.refresh()`.
3. `SetupStore.refresh()` always calls `engine.doctor()`; it does not reuse a cached empty device list.
4. The production app wires `BundledProvisioningEngine`, whose `doctor()` launches `Contents/MacOS/IOSSimProvisioner doctor --json`.
5. `ProvisionerTool.doctor(context:)` calls `AppleDeviceTool.discoverDeviceSnapshot(context:)` (previously the array-only `discoverDevices`).
6. The shipping backend defaults to `IdeviceProvisioningBackend`; `devicectl` is only an explicit development-comparison selection.
7. `IdeviceProvisioningBackend.discoverDeviceSnapshot` calls `IOSSimDeviceBridge.listDevices()` and then `IOSSimDeviceBridge.inspect(...)` for each descriptor.
8. `IOSSimDeviceBridge.listDevices()` calls `DynamicNativeDeviceTransport.listDevices(timeout:)`.
9. The dynamic transport resolves and calls C ABI symbol `iossim_bridge_list_devices` and copies the result payload before calling `iossim_bridge_result_free`.
10. Rust `iossim_bridge_list_devices` calls `devices()`, which creates `UsbmuxdAddr::default()`, connects to `/var/run/usbmuxd`, and issues `get_devices()`.
11. Rust maps `Connection::Usb` to `usb`, `Connection::Network` to `wireless`, and unknown variants to `unknown`.
12. Swift decodes the JSON list, validates identifiers, deduplicates only identical UDIDs, and prefers the USB descriptor over a wireless duplicate. There is no product-type allowlist, iOS-version gate, model-name table filter, trusted-only filter, lock filter, or Developer Mode filter.
13. Inspection opens the exact UDID/usbmux ID, connects Lockdown, reads name/product/version/build, attempts the existing pairing record/session, and then queries AMFI Developer Mode. Pairing is not required merely to enumerate.

Answers to the requested trace questions:

1. Swift request: `IOSSimDeviceBridge.listDevices()` through `IdeviceProvisioningBackend.discoverDeviceSnapshot(context:)`.
2. C ABI symbol: `iossim_bridge_list_devices`.
3. Rust enumeration: exported `iossim_bridge_list_devices`, backed by async `devices()`.
4. Backend: pinned Rust `idevice` usbmuxd client over `/var/run/usbmuxd`; Lockdown is used only after enumeration for inspection/readiness.
5. Filters: only UDID deduplication, with USB preferred over wireless. No hardware/iOS/readiness filtering.
6. Connection differentiation: Rust `Connection::Usb`, `Connection::Network`, or `Connection::Unknown` serialized to `usb`, `wireless`, or `unknown`.
7. Error conversion: Rust status plus sanitized diagnostic in `BridgeResult`; Swift copies payload/diagnostic, frees the Rust result, maps status to `NativeDeviceBridgeError`, then maps discovery/inspection errors to stable `DeviceDiscoveryDiagnosticCode` values.
8. Zero devices: only a successful usbmux list with an empty returned array now produces `ZERO_DEVICES_RETURNED`. Bridge/load/init/usbmux/decode errors no longer become an empty success.
9. `UNKNOWN` readiness: no descriptor means inspection never runs. For a discovered descriptor, failed Lockdown inspection preserves the device and reports typed diagnostics while trust/lock/Developer Mode remain unknown.
10. Cache behavior: the UI uses the latest doctor result. Stored selection and provisioning manifests explain the historical app/runner data, but they are not used as live enumeration. `Check Setup` performs a fresh helper/bridge call.

# Direct Bridge Evidence

Before the fix, direct C ABI invocation against both the build dylib and the DMG-bundled dylib initialized ABI version 1 and then aborted at Rust `src/lib.rs` in `iossim_bridge_list_devices`:

```text
there is no reactor running, must be called from the context of a Tokio 1.x runtime
```

After the timer fix, direct C ABI invocation returned status `0`, diagnostic `ok`, and a valid JSON array. The array count was zero because no phone was attached at that later time.

An isolated signed-helper probe then proved the production signing boundary:

```text
without local helper exception: BRIDGE_UNAVAILABLE
detail: native bridge rejected by hardened runtime library validation

with exact local helper exception: ZERO_DEVICES_RETURNED
detail: usbmux returned no connected devices
```

The same `ZERO_DEVICES_RETURNED` result was obtained by running `device-diagnostics` from the read-only mounted replacement DMG. This proves bridge presence, executable-relative lookup, ABI initialization, dynamic loading, Tokio initialization, socket access, request/response transfer, and Swift decoding in the packaged context.

# Bundled Artifact Audit

- Bundle path: `Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib`
- Lookup: absolute executable-relative `Contents/Resources/NativeDeviceBridge` candidate, with existing environment and main-bundle candidates retained
- Mode: executable (`0755`)
- Dylib architecture: `arm64`, matching the physical test Mac
- GUI/helper architectures: `arm64 x86_64`
- Dylib dependencies: CoreFoundation, libiconv, libSystem only
- Install name: sanitized fixed-length source placeholder; the app uses explicit `dlopen`, not rpath lookup
- Signatures: ad hoc, hardened runtime; deep/strict verification passed
- App entitlements: empty
- Production/Developer-ID helper entitlements: empty and unchanged
- LOCAL_TEST_ONLY helper entitlement: only `com.apple.security.cs.disable-library-validation = true`, required because ad-hoc code has no shared Developer ID Team ID
- App Sandbox: absent
- Public release signing policy still forbids the local-only entitlement
- The existing x86_64 bridge limitation was not changed; it did not affect this arm64 physical test

# Fix

- Added executable-relative dylib discovery for the nested helper.
- Added safe `dlerror` classification for missing library, hardened-runtime rejection, architecture mismatch, and missing dependency.
- Added the one LOCAL_TEST_ONLY helper entitlement required to load the ad-hoc dylib; no entitlement was added to the GUI app or public-release helper.
- Created Tokio timeout futures only after entering the runtime, through a shared `block_on_timeout` helper.
- Preserved enumerated devices when Lockdown/readiness inspection fails.
- Replaced discovery `try? -> []` collapse with typed, sanitized discovery diagnostics.
- Added `device-diagnostics`, doctor checks, support-bundle schema 4 `deviceDiscovery`, and concise `Device Discovery Unavailable` UI text.
- Kept `Check Setup` as a forced live doctor/enumeration refresh.

# Files Changed

- `native/iossim-device-bridge/src/lib.rs`
- `macos/Sources/IOSSimMacCore/Services/NativeDeviceBridge.swift`
- `macos/Sources/IOSSimMacCore/Services/RuntimeProvisioningSupport.swift`
- `macos/Sources/IOSSimMacCore/Services/SupportBundleExporter.swift`
- `macos/Sources/IOSSimProvisioner/main.swift`
- `macos/Sources/IOSSimMac/Views/DashboardView.swift`
- `macos/Sources/IOSSimMac/Views/SetupWizardView.swift`
- `macos/Release/IOSSimProvisionerLocal.entitlements`
- `scripts/bootstrap/iossim_cli.py`
- `macos/Tests/IOSSimMacCoreTests/NativeDeviceBridgeTests.swift`
- `macos/Tests/IOSSimMacCoreTests/SetupStoreTests.swift`

# Tests Added

- Tokio timer creation occurs inside an entered runtime.
- Live list C ABI returns a result without a reactor panic.
- Rust `BridgeResult` layout, JSON payload, and free ownership are stable.
- Rust device-list JSON decodes into the Swift identity/connection model.
- Nested helper resolves the bridge relative to the outer app executable.
- Dynamic loader diagnostics do not expose filesystem paths.
- Future iPhone model and iOS 26 data are not filtered.
- Lockdown inspection failure does not turn a discovered phone into no device.
- Bridge failure is distinguishable from successful zero-device enumeration.
- `Check Setup`/`SetupStore.refresh()` performs another live doctor call.

# Test Results

- Rust `cargo fmt -- --check`: PASS
- Rust `cargo check`: PASS
- Rust `cargo test`: PASS, 6/6
- Swift debug package build: PASS
- Swift release package/helper/app builds: PASS
- Swift test source parse: PASS
- Direct Rust C ABI pre-fix reproduction: PASS (reproduced reactor abort)
- Direct Rust C ABI post-fix probe: PASS (status 0, valid zero-length device array)
- Unsigned helper missing/present bridge diagnostic probe: PASS
- Hardened signed helper before/after local entitlement probe: PASS
- Mounted-DMG `device-diagnostics`: PASS (`ZERO_DEVICES_RETURNED`, not a bridge error)
- Mounted-DMG support export: PASS; schema 4 contains sanitized `deviceDiscovery`
- Local app content/signature audit: PASS
- Local DMG integrity/content/provenance/signature audit: PASS
- No-Xcode static diff audit: PASS; no Xcode/xcrun/devicectl invocation was added
- `./iossim test`: overall FAIL in the Xcode-deleted environment because Apple's standalone Command Line Tools installation has no `XCTest` Swift module and the unrelated pinned iOS FFI rebuild requests Xcode license tooling. All runnable bridge/Rust, app-build, frontend, backend, symbol, and bundle-ID checks passed.
- `./iossim build`: overall FAIL only in the existing iOS rebuild steps that require Xcode/xcodebuild. Native Mac bridge build, symbol verification, Swift package build, and Mac app build passed.

Xcode/XCTest was not installed or restored to turn those environment-dependent failures into passes. The retest DMG reused the unchanged, previously verified Release iPhone artifacts and rebuilt only the Mac GUI/helper arm64 slices and native Rust bridge without Xcode or xcrun.

# Frozen Systems Audit

- Apple auth: untouched
- Provisioning/signing: iPhone provisioning and signing untouched; LOCAL_TEST_ONLY macOS helper signing changed only to add the directly required bridge-loading entitlement
- DDI: untouched
- App install path: untouched
- Pairing: untouched
- Readiness architecture: unchanged; only discovery error/readiness diagnostics and preservation of discovered-but-not-inspected devices changed
- Renewal: untouched
- LocalDevVPN: untouched
- RSD/TestManager runtime: untouched
- XCTest runner: untouched
- XCUILocation: untouched
- Rich Drive: untouched

# Xcode Audit

The fix does not call or require Xcode, `xcrun`, or `devicectl`. The shipping default remains the native `idevice` backend. Existing explicit development-comparison code for `devicectl` was not reactivated or selected. The new DMG was assembled with Xcode absent and without invoking `xcrun` or `devicectl`.

# New DMG

- Classification: `LOCAL_TEST_ONLY`
- Filename: `IOSSim-0.1.0-local-device-discovery-bc339b3.dmg`
- Full path: `/Users/rishiborra/Desktop/IOSSim/.build/iossim/local-release/IOSSim-0.1.0-local-device-discovery-bc339b3.dmg`
- Size: `17,967,602 bytes`
- SHA-256: `ca5e58c50cd2ed014b142bacf338ed99b081cf94bbc89e48f2d0a0bc29c8b50c`
- Source commit: `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`
- Branch: `work/fix-no-xcode-device-discovery`
- Tracked source state at assembly: clean
- Overall `git status`: dirty only because preserved pre-existing `IOSSim-Support-1789416447.zip` is untracked
- Previous `.build/iossim/local-release/IOSSim-0.1.0-local.dmg`: not overwritten

# Exact Retest Steps

1. Keep Xcode absent and connect the unlocked iPhone by USB.
2. Confirm Finder displays the iPhone and its battery/storage.
3. Open the new DMG and copy its `IOSSim.app` to Applications, replacing the prior local test app.
4. Launch IOSSim and click `Check Setup`.
5. Confirm IOSSim displays `Rishi Borra` (or the current device name) rather than `No iPhone Connected`.
6. Confirm live trust, lock, and Developer Mode readiness appears; an incomplete prerequisite must appear as user action required, not as no device.
7. If it does not, export a new support bundle and preserve its schema 4 `deviceDiscovery` section.

Only after step 5 and the live readiness check succeed may `DEVICE_PHYSICAL` be marked passed.
