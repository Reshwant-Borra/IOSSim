# idevice iOS Build Notes

Date: 2026-08-27

## Pin

```text
Repository: https://github.com/jkcoxson/idevice
Commit: c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5
License: MIT
```

## Local Toolchain

```text
Selected developer directory: /Applications/Xcode.app/Contents/Developer
Xcode: 26.6
Build version: 17F113
Swift: Apple Swift 6.3.3
Rust: rustc 1.98.0
cargo: cargo 1.98.0
rustup: rustup 1.29.0
xcodegen: not installed
```

Xcode first-launch/platform setup performed:

```bash
xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
```

`xcodebuild -downloadPlatform iOS` installed iOS 26.5 platform content required by destination resolution.

## Build Script

Prepared script:

```bash
cd ios
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
./scripts/build_idevice_ios.sh
```

The script:

- clones `https://github.com/jkcoxson/idevice` into ignored `ios/.build/idevice-src`;
- checks out `c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5`;
- adds Rust target `aarch64-apple-ios`;
- adds Rust `llvm-tools-preview` when available for symbol verification;
- builds `ffi` for physical iPhone arm64;
- copies output to ignored `ios/Vendor/idevice/lib/libidevice_ffi.a`.

Feature set:

```text
rustcrypto remote_pairing rsd dvt device_info location_simulation tunnel_tcp_stack core_device_proxy obfuscate
```

Rationale: this is narrower than upstream `full` while retaining raw RPPairing, TLS-PSK tunnel, RSD, DVT remote server, DeviceInfo warmup, and LocationSimulation.

## Expected Artifact

```text
Type: static library
Path: ios/Vendor/idevice/lib/libidevice_ffi.a
Architecture: arm64 iPhone (aarch64-apple-ios)
Committed: no
Actual size: 90 MB
```

Build status: CONFIRMED.

## Symbol Verification

Prepared script:

```bash
cd ios
./scripts/verify_idevice_symbols.sh
```

Required symbols:

```text
rp_pairing_file_read
tunnel_create_rppairing
remote_server_connect_rsd
device_info_directory_listing
location_simulation_new
location_simulation_set
location_simulation_clear
```

Actual symbol verification status: CONFIRMED.

Observed:

```text
FOUND rp_pairing_file_read
FOUND tunnel_create_rppairing
FOUND remote_server_connect_rsd
FOUND device_info_directory_listing
FOUND location_simulation_new
FOUND location_simulation_set
FOUND location_simulation_clear
```

Tooling note:

Apple `llvm-nm` from Xcode 26.6 failed on the Rust 1.98 archive with:

```text
Unknown attribute kind (105)
Producer: 'LLVM22.1.8-rust-1.98.0-stable'
Reader: 'LLVM APPLE_1_2100.1.1.101_0'
```

Correction: `verify_idevice_symbols.sh` now prefers Rust's matching `llvm-nm` from the active Rust sysroot before falling back to Apple tooling.

## Header Strategy

The POC commits a minimal IOSSim-owned C module:

```text
ios/Vendor/idevice/include/idevice_minimal.h
ios/Vendor/idevice/include/module.modulemap
```

Module name:

```text
IOSSimIdeviceFFI
```

The header declares only the symbols used by `DvtLocationClient.swift`. It avoids committing the full generated upstream header while preserving the MIT license notice.

## Current Blocker

STATUS: SIGNING / PHYSICAL INSTALL BLOCKED

The idevice archive builds and links into the POC. The signed iOS app build now reaches provisioning and fails because this machine has no valid Apple Development signing identity/team configured:

```text
Signing for "IOSSimOnDevicePOC" requires a development team.
security find-identity -v -p codesigning
0 valid identities found
```

Unsigned compile/link verification succeeds:

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

No physical iPhone was visible to `xcrun devicectl list devices` during this run, so install was not attempted.
