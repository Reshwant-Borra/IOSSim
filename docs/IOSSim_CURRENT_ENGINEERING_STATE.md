# IOSSim Current Engineering State

Authoritative as of 2026-09-15. This document supersedes `docs/CURRENT_STATE.md` for present setup/productization status. Historical reports remain evidence, not current truth.

## Purpose and boundary

IOSSim provisions precompiled iPhone components from a Mac without requiring Xcode on the consumer Mac, then uses an iPhone-owned LocalDevVPN/RSD/TestManager/XCTest runtime to control simulated location. Setup now opens the externally installed LocalDevVPN app and requires functional reachability to `10.7.0.1:49152` before `SETUP_READY_FOR_RUNTIME`. TestManager, XCTest, location, Spoof, Drive, and Rich Drive remain frozen and are not started by setup.

## Repository state

- Branch: `work/final-no-xcode-setup-v1`
- HEAD: `1259da507ecded222022cc86bf82863c15640db9`
- Worktree: **DIRTY**; the source used for any future payload is HEAD plus uncommitted changes.
- Pre-task state: recorded in `CURRENT_WORKTREE_SNAPSHOT.md`.
- Built iPhone payload source fingerprint: `5668a29add1a3966c4514115523b1a21e69ff6585bdbc76c3e89dcb0aae64a5a`.

## Architecture

```text
BUILD MACHINE (full Xcode + iPhoneOS SDK allowed)
  iPhone source/Xcode targets
    -> arm64 main app + UI-test runner/test bundle
    -> capability/binary verification
    -> profile-free re-signable DeviceArtifacts + schema-2 manifest

CONSUMER MAC (no Xcode/devicectl/Python/Rust runtime dependency)
  IOSSim.app
    -> bundled IOSSimProvisioner
    -> native Apple auth + Personal Team provisioning/signing
    -> native usbmux/Lockdown/AFC/Installation Proxy
    -> conditional developer support/TSS
    -> CoreDeviceProxy/software tunnel/RSD/RemoteXPC/AppService
    -> House Arrest/AFC runtime mapping + encrypted pairing delivery
    -> receipt verification -> launch/verify external LocalDevVPN
    -> SETUP_READY_FOR_RUNTIME -> STOP

iPhone main app
  startup-only setup inbox -> Keychain pairing record + receipt
  runtime-mapping consumer -> existing frozen runtime
```

The pinned native bridge revision is `1838db107d38701b4044361163aac049006c2627`; bridge ABI is 1 and runtime version is `iossim-device-bridge/0.1.0+idevice-1838db1`. Setup state schema is 4. Support-export schema is 7.

`BUILD_MACHINE_CONFIGURATION_BLOCKER=RESOLVED`: this development Mac uses Xcode 27.0 (27A266a) and iPhoneOS SDK 27.0 to compile payloads. `XCODE_BUILD_MACHINE_REQUIREMENT=EXPECTED`; `XCODE_CONSUMER_REQUIREMENT=NONE`.

## Bundle identities

| Component | Source ID | Current Personal Team-derived ID |
|---|---|---|
| Main iPhone app | `com.iossim.on-device-dvt-poc` | `com.personalteam.iossim.t026e0910b111.on-device-dvt-poc` |
| UI test bundle | `com.iossim.location-control-uitests` | `com.personalteam.iossim.t026e0910b111.location-control-uitests` |
| XCTest runner | `com.iossim.location-control-uitests.xctrunner` | `com.personalteam.iossim.t026e0910b111.location-control-uitests.xctrunner` |

The Team-derived values are the last physically proven selected-team generation and must still be re-derived from the current team during setup. The Location Witness is a developer/test target and is not a consumer DeviceArtifact.

## Proven and current status

- `NO_XCODE_DEVICE_DISCOVERY`, usbmux, Rust bridge, C ABI, Swift discovery, Lockdown, Personal Team provisioning, native signing, AFC/Installation Proxy install, exact inventory, and reconciliation: **PHYSICAL_PASS** on iPhone18,1 / iOS 26.6.2.
- Developer Mode: **PHYSICAL_PASS** in the iPhone UI. The bridge AMFI inspection returned a false disabled advisory, but the live CoreDevice readiness chain was fully green; setup now treats that AMFI value as advisory and still stops on a typed readiness `developerModeRequired` error.
- CoreDeviceProxy, software tunnel, RSD, RemoteXPC, AppService readiness, native launch receipt, and visible automatic foreground launch without a tap: **PHYSICAL_PASS** in refresh generation 5. No `DDI_REQUIRED` was emitted; the readiness receipt reported an already-mounted DDI.
- House Arrest, runtime-mapping write/readback/semantic verification, automatic RemotePairing creation, encrypted delivery, phone receipt, and receipt verification: **PHYSICAL_PASS** in generation 5.
- LocalDevVPN native AppService launch and functional endpoint verification: **PHYSICAL_PASS** at `2026-09-15T16:07:58Z`. The iPhone receipt proved TCP reachability to `10.7.0.1:49152`; interface visibility alone was not accepted.
- Schema-4 `SETUP_READY_FOR_RUNTIME`: **PHYSICAL_PASS**, persisted at `2026-09-15T16:07:58Z`; setup stopped before TestManager/XCTest/location runtime.
- Saved Apple session reuse and authenticated Personal Team provisioning remain **PHYSICAL_PASS**. Completely fresh Apple login from zero state remains `FINAL_CLEAN_INSTALL_RETEST_REQUIRED`.
- `device-debug` currently reports two raw usbmux endpoints and one deduplicated Swift device for the same phone. Lockdown and the setup-selected stable UDID succeed; this is a non-blocking diagnostic-count discrepancy, not two phones.

## Current blockers

There is no remaining first-time setup blocker through `SETUP_READY_FOR_RUNTIME`; the verdict is `FIRST_TIME_NO_XCODE_SETUP_PHYSICAL_PASS`. Two physical integration defects were found and corrected without redesigning the architecture:

1. AMFI's Developer Mode flag was incorrectly used as a hard gate even while the typed live readiness probe could establish all CoreDevice stages. It is now advisory; an actual typed Developer Mode rejection still stops setup.
2. `refresh` re-signed fresh artifacts but skipped installation when the same derived bundle IDs already existed, leaving the stale phone app installed. Refresh now force-upgrades both owned payloads; repair remains component-scoped.

No DDI asset search/hack was needed or authorized. Only a future explicit `DDI_REQUIRED` result opens a targeted DDI task.

## Payload incident and authoritative artifacts

The historical payload in `.build/iossim/final-setup-retest/IOSSim.app` is from `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`, with main hash `0d5a653d54b3b50136b629371fb5963b77dbb0b86e08227d496b8af522cee878` and runner hash `804c1fa26fd3c86db13a6d7423fc6be8966668e6ecf04cdfdd8c4fa33cde9c64`. It lacks the startup controller/runtime-mapping markers and remains **STALE/HISTORICAL**.

The authoritative app is `.build/iossim/final-setup-payload-retest/IOSSim.app`. Its app-tree SHA-256 is `8200221baab34c019c857449aabb6ec317586d2b4508c9607372c63bc563c65c`; embedded main and runner hashes are `8c60fe20198307ba57550f7230c33b9361ab1ca57bcd1880db0ddb9f639b0081` and `c1e42038a763889b6dd23d175058a6c1d077b962caa61e50f456f8c4d7b5fb9c`. Manifest SHA-256 is `ecdf74fafe767b024fe9712b14512f9b572ba7f627ebf806b4c84867f0a9dd66`; it declares `localDevVPNSetupGate: 1`. No DMG was produced. This app generated the physical schema-4 setup pass and is the only authoritative build.

## Tooling boundary

Xcode is required on IOSSim development/build machines to compile fresh iPhone binaries. Xcode, `xcodebuild`, `xcrun devicectl`, Xcode Accounts, and manual certificate management are not required or reachable in the intended packaged consumer setup. Consumers receive prebuilt artifacts; IOSSim natively provisions, signs, installs, inventories, launches, configures, and pairs them.

## Next actions

1. Preserve the generation-5 setup receipts and authoritative app; do not retest by opening a historical build.
2. The next task is runtime startup + Spoof + Rich Drive regression using the already-ready setup state; LocalDevVPN is already functionally ready.
3. Separately, later validate a completely fresh Apple Account login from zero state, seven-day renewal, and cellular/Mac-off behavior.
