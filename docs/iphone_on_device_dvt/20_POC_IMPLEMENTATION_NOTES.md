# POC Implementation Notes

Date: 2026-08-27

Starting commit: `82c8b06 Add on-device DVT research package`

Branch: `poc/on-device-dvt`

## Implementation Status

STATUS: PLAUSIBLE / SOFTWARE SCAFFOLD IMPLEMENTED

Created `ios/` as an isolated experimental iPhone-side POC package. The current stable IOSSim backend was not modified.

Implemented call chain when linked with the pinned `idevice` FFI:

```text
KeychainRPPairingStore
  -> RPPairingValidator
  -> DeveloperRouteProbe 10.7.0.1:49152
  -> IdeviceOnDeviceTunnelClient
  -> rp_pairing_file_read
  -> tunnel_create_rppairing
  -> remote_server_connect_rsd
  -> device_info_directory_listing("/")
  -> location_simulation_new
  -> location_simulation_set / location_simulation_clear
  -> CoreLocationVerifier
```

The default local build intentionally reports `IDEVICE_BRIDGE_UNAVAILABLE` because the pinned `idevice` static library/XCFramework is not committed.

## IOSSim Baseline Confirmed

STATUS: CONFIRMED

The current stable host-side path remains:

```text
UserspaceRsdTunnel(serial=UDID)
  -> RSD
  -> DvtProvider
  -> DeviceInfo.ls("/")
  -> LocationSimulation
  -> set(lat, lon) / clear()
```

Source: `backend/wireless_location/session.py`.

Set method: `LocationSimulation.set(lat, lon)`.

Clear method: `LocationSimulation.clear()`.

DVT service name: `com.apple.instruments.server.services.LocationSimulation`.

Selectors from idevice/pymobiledevice3:

- `simulateLocationWithLatitude:longitude:`
- `stopLocationSimulation`

Warmup behavior: host-side backend runs `DeviceInfo(dvt).ls("/")` before opening `LocationSimulation`. The POC bridge mirrors this with `device_info_directory_listing("/")`.

Reconnect semantics: host-side controller reconnects only if the Mac sees the same UDID over network discovery. The POC uses direct endpoint probing instead and implements only one reconnect attempt in the E2 harness.

Error taxonomy: the POC adds structured `POCErrorCode` values including `LOCALDEVVPN_ROUTE_MISSING`, `ENDPOINT_UNREACHABLE`, `TLS_PSK_FAILED`, `RSD_FAILED`, `DVT_FAILED`, `DEVICE_INFO_WARMUP_FAILED`, `LOCATION_SERVICE_FAILED`, `SET_COMMAND_FAILED`, and `CORELOCATION_VERIFICATION_FAILED`.

Logging: POC logs redacted stage events and never prints plist contents or private key material.

## Locus Verification

STATUS: CONFIRMED WITH CORRECTION

Independently inspected Locus commit `83c8fb324983728e8f44759cfd834dc637ee38b5`.

Confirmed:

- imports/stores `rp_pairing_file.plist`;
- dials `10.7.0.1:49152`;
- calls `tunnel_create_rppairing`;
- opens RSD with `remote_server_connect_rsd`;
- opens `location_simulation_new`;
- calls `location_simulation_set` and `location_simulation_clear`;
- reuses an active static `locationSimulation` handle for repeated coordinate changes.

Correction/clarification:

The audited Locus `LocationEngine` does not perform the `DeviceInfo.ls("/")` warmup that IOSSim's current host-side implementation requires. The IOSSim POC bridge includes a DeviceInfo root directory listing before `LocationSimulation` to preserve the known-good IOSSim behavior.

Additional discrepancy:

The pinned `idevice` source comment for `tunnel_create_rppairing` says the pairing file may be updated after pair-setup, while the Locus vendored header says the path only supports pair-verify. The POC treats imported RPPairing as mandatory and does not add on-device pair-setup scope.

## Pairing Handling

STATUS: IMPLEMENTED

- Validates semantic keys, not file extension.
- Stores pairing data in Keychain by default.
- Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Exposes only redacted identifier and boolean key presence.
- Adds repo ignore rules for POC pairing/secrets/artifact paths.

Tradeoff:

The bridge writes Keychain-loaded pairing bytes to a temporary protected file only when calling `rp_pairing_file_read`, because the audited Locus FFI path reads from disk. The file is removed after connection setup. This should be revisited if IOSSim adopts an FFI call that reads RPPairing directly from bytes.

## Build Environment Notes

STATUS: CONFIRMED FOR COMPILE/LINK, BLOCKED FOR INSTALL BY LOCAL SIGNING

Update on 2026-08-27 after Xcode license acceptance: full Xcode is installed, selected, and usable:

```text
/Applications/Xcode.app/Contents/Developer
Xcode 26.6
Build version 17F113
Apple Swift 6.3.3
Rust 1.98.0
cargo 1.98.0
rustup 1.29.0
```

Executed:

```bash
xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
```

Reason: initial device build failed because Xcode had not installed first-launch content, then because the iOS 26.5 platform content was missing from destination resolution.

The pinned `idevice` FFI now builds for physical iPhone arm64:

```text
Artifact: ios/Vendor/idevice/lib/libidevice_ffi.a
Architecture target: aarch64-apple-ios
Size: 90 MB
Committed: no; ignored by .gitignore
```

Normal signed device build reaches provisioning and fails at the local signing layer:

```text
Signing for "IOSSimOnDevicePOC" requires a development team.
0 valid code signing identities found.
```

An unsigned compile/link verification build succeeds with the real `idevice` archive:

```bash
xcodebuild -project ios/IOSSimOnDevicePOC.xcodeproj \
  -scheme IOSSimOnDevicePOC \
  -configuration Debug \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Result:

```text
BUILD SUCCEEDED
```

This proves Swift compilation, module import, arm64 linkage, and no unresolved FFI symbols. It does not prove installability until an Apple Development team/certificate is selected.

The app target compiles with `IOS_SIM_IDEVICE_FFI`, links `Vendor/idevice/lib/libidevice_ffi.a`, and uses automatic development signing with an intentionally blank `DEVELOPMENT_TEAM` for user/local selection.

## Installability Phase Notes

STATUS: PREPARED / BLOCKED BY LOCAL SIGNING AND NO VISIBLE DEVICE

Real iOS app project:

```text
ios/IOSSimOnDevicePOC.xcodeproj
target: IOSSimOnDevicePOC
bundle id: com.iossim.on-device-dvt-poc
deployment target: iOS 17.0
```

Permissions:

- `NSLocationWhenInUseUsageDescription`
- `NSLocalNetworkUsageDescription`

No NetworkExtension entitlement was added because LocalDevVPN remains external.

Native bridge:

- default SwiftPM path keeps fallback;
- physical Xcode app target defines `IOS_SIM_IDEVICE_FFI`;
- minimal C module name is `IOSSimIdeviceFFI`;
- static library path is ignored at `ios/Vendor/idevice/lib/libidevice_ffi.a`.

## ABI / Header Verification

STATUS: CONFIRMED

Compared `ios/Vendor/idevice/include/idevice_minimal.h` against the generated pinned upstream header at `ios/.build/idevice-src/ffi/idevice.h`.

Confirmed matching signatures for:

- `IdeviceFfiError`
- `rp_pairing_file_read`
- `tunnel_create_rppairing`
- `remote_server_connect_rsd`
- `device_info_new`
- `device_info_directory_listing`
- `location_simulation_new`
- `location_simulation_set`
- `location_simulation_clear`
- owned-handle free functions used by the POC

Correction made during implementation:

`verify_idevice_symbols.sh` now prefers Rust's matching `llvm-nm` via the active Rust sysroot before Apple `llvm-nm`. Apple `llvm-nm` from Xcode 26.6 failed to read Rust 1.98 archives with `Unknown attribute kind (105)`.
