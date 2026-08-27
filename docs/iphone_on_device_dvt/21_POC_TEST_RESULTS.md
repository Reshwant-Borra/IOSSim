# POC Test Results

Date: 2026-08-27

IOSSim commit under test: working tree on `poc/on-device-dvt` after `82c8b06`.

## Automated Software Checks

STATUS: CONFIRMED

Command:

```bash
cd ios
swift build
```

Result:

```text
PASS
Build complete.
```

Command:

```bash
cd ios
swift run POCUnitChecks
```

Result:

```text
PASS
POCUnitChecks passed
```

Coverage:

- valid semantic RPPairing plist accepted;
- missing `private_key` rejected;
- invalid `alt_irk` rejected;
- top-level non-dictionary plist rejected;
- in-memory store validates before saving;
- LocalDevVPN `10.7.0.0/24` detection;
- route probe reports TCP result;
- diagnostic state records stage status/timing;
- no-FFI build reports `IDEVICE_BRIDGE_UNAVAILABLE`.

These are software checks only. They do not prove the physical on-device DVT architecture.

Update on 2026-08-27 after Xcode license acceptance:

```bash
cd ios
swift build
swift run POCUnitChecks
```

Result:

```text
PASS
Build complete.
POCUnitChecks passed
```

## iOS App Build Attempt

STATUS: SIGNED BUILD PASS

Command:

```bash
xcodebuild -project ios/IOSSimOnDevicePOC.xcodeproj \
  -scheme IOSSimOnDevicePOC \
  -configuration Debug \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  build
```

Result:

```text
PASS
BUILD SUCCEEDED
```

Signing observed:

```text
Signing Identity: Apple Development
Provisioning Profile: iOS Team Provisioning Profile: com.iossim.on-device-dvt-poc
```

Unsigned compile/link verification also passed earlier and confirmed the Swift app target compiles for `arm64-apple-ios17.0`, imports `IOSSimIdeviceFFI`, links `libidevice_ffi.a`, and has no unresolved symbols.

## Physical Install Attempt

STATUS: CONFIRMED

Device:

```text
Rishi Borra
iPhone 17 Pro (iPhone18,1)
Identifier: 812EB0E1-DB40-5E49-9347-08079A74CBAF
```

Command:

```bash
xcrun devicectl device install app \
  --device 812EB0E1-DB40-5E49-9347-08079A74CBAF \
  "$HOME/Library/Developer/Xcode/DerivedData/IOSSimOnDevicePOC-bbdpihytljrdxqbyampzaelomrko/Build/Products/Debug-iphoneos/IOSSim DVT POC.app"
```

Result:

```text
PASS
bundleID: com.iossim.on-device-dvt-poc
```

## Diagnostic UI Update

STATUS: CONFIRMED

After physical launch showed `RUN DIAGNOSTICS` could appear to do nothing while Network.framework printed repeated `nw_connection` warnings, the POC now:

- checks pairing presence/validity during `RUN DIAGNOSTICS`;
- exposes top-of-screen action status;
- visibly reports `PAIRING_MISSING` if no RPPairing is stored;
- visibly reports `LOCALDEVVPN_ROUTE_MISSING` if no `10.7.0.*` interface is visible;
- visibly reports `ENDPOINT_UNREACHABLE` if the route exists but TCP to `10.7.0.1:49152` fails.

The Network.framework warnings are consistent with failed/cancelled TCP probes and are not by themselves an E1 protocol result.

## idevice iOS Build Attempt

STATUS: CONFIRMED

Command:

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
ios/scripts/build_idevice_ios.sh
```

Result:

```text
PASS
Built ios/Vendor/idevice/lib/libidevice_ffi.a
```

Artifact:

```text
Target: aarch64-apple-ios
Size: 90 MB
Committed: no
```

Symbol verification:

```bash
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
ios/scripts/verify_idevice_symbols.sh
```

Result:

```text
PASS
FOUND rp_pairing_file_read
FOUND tunnel_create_rppairing
FOUND remote_server_connect_rsd
FOUND device_info_directory_listing
FOUND location_simulation_new
FOUND location_simulation_set
FOUND location_simulation_clear
```

Tooling correction: the verifier now prefers Rust's `llvm-nm` from the active Rust sysroot. Apple `llvm-nm` from Xcode 26.6 could not parse Rust 1.98 object attributes.

## Existing Backend Regression Attempt

STATUS: BLOCKED

Command attempted:

```bash
python3 -m pytest backend/test_wireless_location.py backend/test_userspace_location_diagnostic.py backend/test_userspace_location_compatibility_probe.py
```

Observed:

```text
No module named pytest
```

The repo's `backend/.venv/bin/python` also lacks `pytest`. No backend files were changed.

## Physical Test Template

For every physical test, record:

```text
Test ID:
Date:
iPhone model:
iOS version:
IOSSim commit:
idevice commit/version:
LocalDevVPN version:
Network state:
Wi-Fi:
Cellular:
Mac power state:
Pairing source:
Developer Mode:
Steps:
Expected:
Observed:
Timing:
Core Location flags:
Logs:
Verdict:
```

## Physical E1 Update - Mac-Free LocationSimulation Works Briefly

STATUS: PARTIAL PHYSICAL SUCCESS / NOT STABLE

Observed on 2026-08-27:

- iPhone unplugged from Mac.
- LocalDevVPN active.
- valid RPPairing already imported.
- IOSSim POC launched directly on iPhone.
- no USB runtime connection.

POC reported PASS for:

- Pairing
- LocalDevVPN
- Endpoint
- Developer Tunnel
- RSD
- DeviceInfo
- DVT
- LocationSimulation

`SET TEST LOCATION` successfully changed the iPhone's reported location. One run lasted only a few seconds. A later unplugged run lasted approximately 15 seconds before reverting.

Verdict: E1 is no longer "not physically validated"; the Mac-free on-device DVT path is physically proven to reach `LocationSimulation` and issue a working set command. It is not stable enough to call E1 complete because static coordinate persistence is not established.

Current blocker: determine why the DVT/LocationSimulation session or the simulated Core Location state disappears after approximately 15 seconds.

## Session Persistence Diagnostic Build

STATUS: READY TO RUN

Implemented after the partial E1 result:

- persistent JSONL diagnostic sessions beginning at `CONNECT`;
- continuously refreshed text summaries;
- in-app session status, coordinate state, timeline, marker, and export controls;
- route/interface sampling for `10.7.0.x`;
- low-rate endpoint sampling for `10.7.0.1:49152`;
- bridge/object lifetime recording for tunnel, RSD, DVT, DeviceInfo, and LocationSimulation;
- continuous Core Location recording with distance from requested coordinate and source flags;
- app lifecycle, memory warning, background task, and monitor task events;
- background task plus background-capable Core Location observer after one successful `SET`.

No periodic coordinate resend was added.

Security: diagnostic output records only redacted messages and non-secret metadata. It does not record raw RPPairing plists, private keys, PSKs, authentication blobs, or memory addresses.

New persistence ladder:

| Test | Status | Notes |
| -- | -- | -- |
| P1 30-second static coordinate | READY TO RUN | One `SET`, no resend. |
| P2 2-minute static coordinate | READY TO RUN | Run only if P1 succeeds. |
| P3 10-minute static coordinate | READY TO RUN | Immediate objective. |
| P4 30-minute static coordinate | READY TO RUN | Run only after P3. |

## E1-E10 Current Status

| Test | Status | Notes |
| -- | -- | -- |
| E1 Mac-off Wi-Fi cold-start | PARTIAL | Physical test proved Mac-free LocalDevVPN/RPPairing/RSD/DVT/LocationSimulation can set a coordinate, but the simulated location reverted after a few seconds to approximately 15 seconds. Stability still unproven. |
| E2 repeated coordinates | SOFTWARE SCAFFOLD ONLY | `runRepeatedCoordinateChanges(count: 50)` implemented; not run on hardware. |
| E3 Wi-Fi to cellular continuation | NOT RUN | Network path recorder added; hardware test pending. |
| E4 cellular cold-start | NOT RUN | Route/TCP diagnostics implemented; hardware test pending. |
| E5 no external network | NOT RUN | Endpoint probe can run; hardware test pending. |
| E6 reboot persistence | NOT RUN | Pairing Keychain persistence expected but unverified. |
| E7 app force quit | NOT RUN | Relaunch/reconnect path pending hardware test. |
| E8 LocalDevVPN restart | NOT RUN | Reconnect and route probe available; hardware test pending. |
| E9 source classification | SOFTWARE SCAFFOLD ONLY | Core Location flags recorded; no hardware observation. |
| E10 update-rate diagnostics | PARTIAL SOFTWARE SCAFFOLD | Repeated updates implemented at fixed delay; explicit 0.5/1/2/5 Hz runner variants still pending. |

## Verdicts

Wi-Fi cold-start verdict: PARTIAL / LOCATION SET PHYSICALLY OBSERVED / PERSISTENCE NOT VALIDATED.

Wi-Fi to cellular verdict: UNKNOWN / NOT PHYSICALLY VALIDATED.

Cellular cold-start verdict: UNKNOWN / NOT PHYSICALLY VALIDATED.

No stable-duration physical PASS is claimed.
