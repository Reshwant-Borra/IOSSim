# IOSSim Handoff Snapshot — 2026-09-15

- **VERDICT:** `FIRST_TIME_NO_XCODE_SETUP_PHYSICAL_PASS`
- **BRANCH:** `work/final-no-xcode-setup-v1`
- **HEAD:** `1259da507ecded222022cc86bf82863c15640db9`
- **DIRTY:** yes; payload source is HEAD plus dirty `ios/` changes
- **BUILD-MACHINE BLOCKER:** resolved with Xcode 27.0 (27A266a), iPhoneOS SDK 27.0
- **AUTHORITATIVE MAC APP:** `.build/iossim/final-setup-payload-retest/IOSSim.app`
- **AUTHORITATIVE APP TREE SHA-256:** `8200221baab34c019c857449aabb6ec317586d2b4508c9607372c63bc563c65c` (`sha256_path`)
- **AUTHORITATIVE DMG:** not produced
- **OLD PAYLOAD SOURCE:** `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`
- **NEW PAYLOAD SOURCE:** HEAD above, dirty `true`, source-tree SHA-256 `5668a29add1a3966c4514115523b1a21e69ff6585bdbc76c3e89dcb0aae64a5a`, timestamp `2026-09-15T16:07:08.661384Z`
- **OLD HASHES:** main `0d5a653d54b3b50136b629371fb5963b77dbb0b86e08227d496b8af522cee878`; runner `804c1fa26fd3c86db13a6d7423fc6be8966668e6ecf04cdfdd8c4fa33cde9c64`
- **NEW HASHES:** main `8c60fe20198307ba57550f7230c33b9361ab1ca57bcd1880db0ddb9f639b0081`; runner `c1e42038a763889b6dd23d175058a6c1d077b962caa61e50f456f8c4d7b5fb9c`; manifest `ecdf74fafe767b024fe9712b14512f9b572ba7f627ebf806b4c84867f0a9dd66`
- **BRIDGE VERSION:** `iossim-device-bridge/0.1.0+idevice-1838db1`
- **IDEVICE REVISION:** `1838db107d38701b4044361163aac049006c2627`
- **SETUP SCHEMA:** 4; payload manifest schema 2; `localDevVPNSetupGate: 1`
- **PHYSICAL DEVICE:** iPhone18,1 / iOS 26.6.2 / stable selected UDID redacted as `000081...401C`
- **PHYSICAL PASS SUMMARY:** the schema-4 refresh passed fresh payload installation/inventory, existing setup gates, LocalDevVPN AppService launch, functional TCP verification at `10.7.0.1:49152`, and `SETUP_READY_FOR_RUNTIME` at `16:07:58Z`
- **DDI:** no acquisition was required; readiness reported an existing mounted image
- **APPLE AUTH:** saved-session reuse and authenticated Personal Team provisioning are PHYSICAL_PASS; fresh login from zero state is `FINAL_CLEAN_INSTALL_RETEST_REQUIRED`
- **RUNTIME/SPOOF/DRIVE:** deliberately not started

## Resolved integration defects

1. AMFI Developer Mode inspection was a false negative even though the iPhone UI was on and the live typed readiness chain passed. AMFI is advisory; typed readiness remains authoritative.
2. Refresh skipped installation when matching derived IDs existed, leaving stale phone bytes. Explicit refresh now force-upgrades both owned payloads; repair stays component-scoped.

## Evidence

The new gate's journal receipts are `LOCALDEVVPN_READINESS_STARTED`, `LOCALDEVVPN_LAUNCH_STARTED`, `LOCALDEVVPN_LAUNCH_SUCCEEDED`, `LOCALDEVVPN_READY`, `SETUP_READY_FOR_RUNTIME`, and `COMPLETE`. The functional receipt explicitly records TCP reachability to `10.7.0.1:49152`; final timestamp `2026-09-15T16:07:58Z`.

## Exact setup-only recheck commands

```bash
cd "/Users/rishiborra/Desktop/IOSSim"
./iossim device-debug
./iossim readiness-debug
pkill -x IOSSim 2>/dev/null || true
pkill -x IOSSimProvisioner 2>/dev/null || true
open -n "/Users/rishiborra/Desktop/IOSSim/.build/iossim/final-setup-payload-retest/IOSSim.app"
```

## Next decision tree

```text
current state -> SETUP_READY_FOR_RUNTIME -> STOP
next authorized task -> runtime startup + Spoof + Rich Drive regression

future setup regression only:
  DDI_REQUIRED -> STOP, targeted approved DDI task
  CoreDeviceProxy/tunnel/RSD/RemoteXPC error -> STOP at exact typed layer
  AppService error -> STOP at exact AppService layer
  House Arrest error -> STOP at container layer
  delivery/receipt error -> STOP at pairing layer
```

LocalDevVPN startup/readiness is now part of setup and physically passed. Do not start XCTest/TestManager/location, Spoof, Drive, or Rich Drive as part of setup validation.
