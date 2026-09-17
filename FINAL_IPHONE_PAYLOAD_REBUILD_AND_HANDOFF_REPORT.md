# Final iPhone Payload Rebuild and Handoff Report

Date: 2026-09-15 (America/New_York)

## 1. Executive verdict

`FIRST_TIME_NO_XCODE_SETUP_PHYSICAL_PASS`

The Xcode build-machine blocker is resolved. The current iPhone main payload and exact XCTest runner were built, statically verified, staged with honest dirty-source provenance, and embedded in the authoritative `.build/iossim/final-setup-payload-retest/IOSSim.app`. The stale-payload guard, manifest self-verification, and final deep signature pass. The physical chain passed installation, developer services, AppService, House Arrest, pairing, external LocalDevVPN AppService launch, functional TCP readiness, and schema-4 `SETUP_READY_FOR_RUNTIME`. No TestManager/XCTest location runtime, Spoof, or Drive operation was started.

## 2. Repository state

- Directory: `/Users/rishiborra/Desktop/IOSSim`
- Branch: `work/final-no-xcode-setup-v1`
- HEAD: `1259da507ecded222022cc86bf82863c15640db9`
- Worktree: dirty before and after; no reset, clean, merge, history rewrite, deletion, or unrelated revert occurred.
- Actual payload source: HEAD plus dirty `ios/` inputs, fingerprinted below.

## 3. Why rebuild was required

Mac setup source advanced to typed developer readiness, native AppService, House Arrest configuration, automatic RemotePairing, receipt verification, and schema 3 while DeviceArtifacts remained at `bc339b3...`. The stale main Mach-O did not contain the inbox controller/bootstrap/receipt/runtime-mapping implementation and could never acknowledge automatic pairing.

## 4. Old payload provenance

- Source: `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`
- Main tree SHA-256: `0d5a653d54b3b50136b629371fb5963b77dbb0b86e08227d496b8af522cee878`
- Runner tree SHA-256: `804c1fa26fd3c86db13a6d7423fc6be8966668e6ecf04cdfdd8c4fa33cde9c64`
- Old manifest file SHA-256: `c95f5fa573abbbebdc90d8a2976e7728d1cd3f51a60604e69b6b1a3a200f2d0d`
- Status: historical/stale; not selected by the authoritative app.

## 5. New iPhone-side features

The rebuilt main contains the startup inbox controller, non-secret request processing, one-time bootstrap generation, AES-GCM envelope decryption, device/team/nonce validation, frozen pairing semantic validation, Keychain import, bound receipt creation, successful transient cleanup, bounded failure handling, and schema-1 runtime-mapping validation/compatibility fallback.

## 6. Target membership proof

`AutomaticPairingInbox.swift` has PBX file/build references, group membership, and `IOSSimOnDevicePOC` Compile Sources membership. `IOSSimOnDeviceDVTPOCApp.swift` calls `AutomaticPairingInboxController().reconcile()` from the main SwiftUI startup task. The source guard passed before build.

## 7. Build environment

| Item | Result |
|---|---|
| Xcode path | `/Applications/Xcode.app/Contents/Developer` |
| Xcode | 27.0 (27A266a) |
| iPhoneOS SDK | 27.0 |
| Swift | 6.4 |
| Host | arm64, macOS 26.6.2 |
| License/first launch | initialized by administrator |

`BUILD_MACHINE_CONFIGURATION_BLOCKER=RESOLVED`; `XCODE_BUILD_MACHINE_REQUIREMENT=EXPECTED`; `XCODE_CONSUMER_REQUIREMENT=NONE`.

## 8. Exact Xcode targets

| Artifact | Target | Scheme | Canonical source ID |
|---|---|---|---|
| Main app | `IOSSimOnDevicePOC` | `IOSSimOnDevicePOC` | `com.iossim.on-device-dvt-poc` |
| UI-test bundle + generated runner | `IOSSimLocationControlUITests` | `IOSSimPayloadRunner` | `com.iossim.location-control-uitests` / `.xctrunner` |

The payload-only scheme excludes Location Witness. No ordinary unit-test bundle is distributed.

## 9. Exact build commands

The canonical successful command was `./iossim package-app`. Its `build_ios` implementation runs Release `IOSSimOnDevicePOC` `build` and Release `IOSSimPayloadRunner` `build-for-testing` for `generic/platform=iOS`, with signing disabled and reproducible packaged flags. Exact expanded commands are retained in `docs/IOSSim_BUILD_AND_PACKAGING.md` and build logs under `.build/iossim/logs`.

## 10. Main payload result

PASS. `IOSSim DVT POC.app` is arm64, minimum iOS 17.0, source ID `com.iossim.on-device-dvt-poc`, profile-free/prepared for Personal Team re-signing. Tree SHA-256: `9792dcbba98ee3d70d8f0ecbcd8b7b00bce2e8a59f3ee2d73dcc8361a832bb3e`.

## 11. Runner payload result

PASS. `IOSSimLocationControlUITests-Runner.app` is arm64, minimum iOS 17.0, source ID `com.iossim.location-control-uitests.xctrunner`. Tree SHA-256: `c1e42038a763889b6dd23d175058a6c1d077b962caa61e50f456f8c4d7b5fb9c`.

## 12. Nested artifact result

PASS. The runner contains `PlugIns/IOSSimLocationControlUITests.xctest` with canonical UI-test ID. Witness and ordinary unit tests are absent from DeviceArtifacts.

## 13. Binary/architecture verification

`file` and `lipo -archs` report physical iOS arm64 for both top-level executables. Info.plists report iOS 17.0 minimum. The fresh main executable contains all required byte markers: `AutomaticPairingInboxController`, `remote-pairing.bootstrap`, `remote-pairing.receipt`, `com.iossim.on-device-dvt-poc.rppairing`, and `runtime-mapping.json`.

## 14. Entitlement verification

Prepared main, runner, and embedded `.xctest` pass deep codesign verification, contain no embedded provisioning profile, and expose no added distribution-specific entitlement. They remain templates for IOSSim's later deterministic Personal Team re-signing.

## 15. Pairing contract verification

PASS at source/POC/static and physical receipt level. The phone Keychain contract remains service `com.iossim.on-device-dvt-poc.rppairing`, account `primary`, 32-byte public/private keys, non-empty identifier, optional 16-byte `alt_irk`, accessibility after-first-unlock-this-device-only. Generation 5 accepted the pairing and returned a bound receipt.

## 16. Runtime mapping verification

PASS at source/POC/static and physical semantic-readback level. Schema 1 binds safe device hash, optional team, exact main, and runner. Phone precedence remains environment override → delivered JSON → Info.plist → UserDefaults → canonical source ID. Invalid delivered mappings fall through without destroying a known-good compatibility mapping. Generation 5 reported `RUNTIME_CONFIGURATION_WRITTEN` (`ALREADY_CURRENT`, schema 1) and `RUNTIME_CONFIGURATION_VERIFIED` after native House Arrest readback.

## 17. Security verification

PASS at static/POC and physical delivery level. No inbox logging is present; private pairing material is not written to UserDefaults or receipts. Plaintext exists only in memory between AES-GCM open, validation, and Keychain import. Request/bootstrap/envelope are removed after success. Receipt serialization does not contain bootstrap-key bytes. Persistent startup errors stop the bounded watcher for that activation. Generation-5 journal/output exposed no pairing private material.

## 18. DeviceArtifacts replacement

PASS. Canonical staging generated fresh DeviceArtifacts inside `.build/iossim/self-contained/IOSSim.app`; the focused build copied only those verified artifacts into the authoritative app. The stale payload remains only in historical apps and is not selected.

## 19. Manifest changes

Schema 2 records exact component paths/IDs/versions/tree hashes, `personalTeamResign`, capability versions (`automaticPairingInbox=1`, `runtimeMappingSchema=1`, `pairingReceiptSchema=1`), HEAD, dirty flag, deterministic iOS source-tree hash, timestamp, and `DEVICE_PAYLOAD_RELEASE` variant. Manifest SHA-256: `1eec9fc91fbf02606cfcf7ecd09270352d06e4817d8d908cec909650b85768e3`.

## 20. Old versus new hashes

Old and new main/runner hashes differ, proving replacement. Final packaged copies equal the new manifest exactly. Values are in sections 4, 10, 11, and 19.

## 21. Payload provenance

- `PAYLOAD_SOURCE_HEAD=1259da507ecded222022cc86bf82863c15640db9`
- `PAYLOAD_SOURCE_DIRTY=true`
- `PAYLOAD_SOURCE_TREE_SHA256=87b6a6717f66003553ed4be67f2e511f4d2f9985f43535252590f812834265d0`
- `PAYLOAD_BUILD_TIMESTAMP=2026-09-15T15:08:44.374275Z`
- `PAYLOAD_BUILD_VARIANT=DEVICE_PAYLOAD_RELEASE`

No synthetic commit was invented.

## 22. Stale-payload guard

PASS. It checked actual target membership/startup wiring, compiled main markers, capability versions, full provenance, component hashes, bundle IDs, and required runner scheme contents. The final Mac build also refused any absent/incomplete DeviceArtifacts and performed helper self-verification.

## 23. Mac app packaging

PASS. Authoritative app: `.build/iossim/final-setup-payload-retest/IOSSim.app`. Final deterministic app-tree SHA-256 using IOSSim's `sha256_path` convention: `8200221baab34c019c857449aabb6ec317586d2b4508c9607372c63bc563c65c`. It embeds current GUI/helper, bridge `iossim-device-bridge/0.1.0+idevice-1838db1`, idevice revision `1838db107d38701b4044361163aac049006c2627`, setup schema 4, fresh payload, and complete provenance. Final helper self-verification and deep codesign pass. No DMG was produced.

## 24. No-Xcode consumer audit

PASS. The packaged composition uses `BundledProvisioningEngine` and native usbmux/Lockdown/AFC/Installation Proxy/CoreDevice/RSD/AppService/House Arrest. Consumer setup does not invoke Xcode, `xcodebuild`, `xcrun devicectl`, Xcode Accounts, manual certificate management, or payload builds. Retained legacy/developer implementations are not selected.

## 25. Test results

| Check | Result |
|---|---|
| Exact iOS main + runner Release builds | PASS |
| iOS `POCUnitChecks` | PASS |
| Compiled setup capability guard | PASS |
| Manifest/helper verification | PASS, both components |
| Bundle structure/IDs/arm64/minimum OS | PASS |
| macOS GUI/helper build | PASS; only known deprecated Security API warnings |
| Rust fmt/check/tests/release | PASS; 8/8 library tests |
| no-Xcode consumer routing | PASS |
| native install/container/AppService routing | PASS |
| discovery CLI tests | PASS, 5/5 |
| final deep signature | PASS after both physical-integration fixes |
| final packaged helper verification | PASS; embedded main/runner hashes match schema-2 manifest |
| `git diff --check` | PASS after final app verification; rerun after final documentation patch |
| Setup-focused macOS XCTest | PASS: ArtifactManifest 5/5, NativeApplicationManagement 7/7, NativeDeviceBridge 15/15, ReadinessRecovery 5/5, selected pairing lifecycle 3/3 |
| Full macOS XCTest | EXECUTED: 271 tests, 6 skipped, 37 failures; the former no-XCTest blocker is resolved |

The full-suite failures are not hidden. They consist primarily of legacy provisioning/backend/SetupStore expectations that predate current native setup composition, plus one stale RemotePairing repair fixture. Payload-specific POC/artifact/static checks pass. One explicit `return` was added to make `SetupStoreTests` compile under Swift 6.4; broad legacy test modernization is outside this payload rebuild and did not block the verified artifact.

## 26. Documentation created/updated

Updated `CURRENT_WORKTREE_SNAPSHOT.md`, `IPHONE_SETUP_INGRESS_CALL_GRAPH.md` (already current), all nine authoritative `docs/IOSSim_*` documents, `docs/README.md`, the dated handoff snapshot, and this report. Historical evidence was retained.

## 27. Physical tests performed

The authoritative native stack saw iPhone18,1 / iOS 26.6.2 through usbmux/Rust/C ABI/Swift/Lockdown. After reconnect and Developer Mode confirmation, `readiness-debug` returned every readiness boolean true. Refresh generation 5 installed/upgraded the freshly signed main and runner, inventoried both, launched the exact main through native AppService, vended its container through House Arrest, verified runtime mapping semantics, created and delivered RemotePairing, verified the phone receipt, and persisted `SETUP_READY_FOR_RUNTIME` at `2026-09-15T15:27:56Z`. No destructive operation or location runtime was started.

Two precise defects were corrected during the physical progression. AMFI's Developer Mode inspection was a false negative despite the phone UI being on and the complete live readiness probe succeeding, so the static AMFI value is now advisory while typed readiness failures remain authoritative. The first fresh-artifact refresh signed current bytes but skipped installation because the derived IDs already existed, producing `bootstrapMissing` from the stale installed app. Explicit refresh now force-upgrades both owned payloads; repair remains component-scoped. The next refresh passed end to end.

## 28. Physical tests still required

The setup chain has no remaining physical gate through `SETUP_READY_FOR_RUNTIME`. The user confirmed that IOSSim visibly foregrounded without a tap, matching the successful native launch receipt.

Saved Apple session reuse and authenticated Personal Team provisioning are PHYSICAL_PASS. Fresh Apple login from zero state after the SRP fix is separately `FINAL_CLEAN_INSTALL_RETEST_REQUIRED`. Runtime startup, Spoof, Rich Drive, renewal, and cellular qualification are later tasks.

## 29. Authoritative artifacts

- App: `.build/iossim/final-setup-payload-retest/IOSSim.app`
- App SHA-256: `18512833aadc266379e77cd78cae150a4c321f4df4947cdbbe6c1fa5a6d5fcb6` (`sha256_path`)
- DMG: not produced
- Historical `.build/iossim/final-setup-retest/IOSSim.app`: stale; diagnostics/history only

## 30. Exact setup-only recheck commands

```bash
cd "/Users/rishiborra/Desktop/IOSSim"
./iossim device-debug
./iossim readiness-debug
pkill -x IOSSim 2>/dev/null || true
pkill -x IOSSimProvisioner 2>/dev/null || true
open -n "/Users/rishiborra/Desktop/IOSSim/.build/iossim/final-setup-payload-retest/IOSSim.app"
```

## 31. Decision tree

```text
current generation 5 -> SETUP_READY_FOR_RUNTIME -> STOP
next task -> runtime startup + Spoof + Rich Drive regression

future setup regression only:
  DDI_REQUIRED -> STOP -> targeted approved DDI task
  CoreDeviceProxy/tunnel/RSD/RemoteXPC failure -> STOP at exact typed layer
  AppService failure -> STOP at exact typed AppService layer
  House Arrest failure -> STOP at container layer
  delivery/receipt failure -> STOP at automatic pairing layer
```

## 32. Remaining work

The next engineering task is runtime startup + Spoof + Rich Drive regression. Renewal, cellular qualification, and the separate fresh-account clean-state test remain later work.

## 33. Final LocalDevVPN setup integration (2026-09-15)

Setup schema 4 now places `LOCALDEVVPN_READY` after pairing receipt verification and before `SETUP_READY_FOR_RUNTIME`. The Mac writes a non-secret request through House Arrest, activates the iPhone's bounded watcher, and opens external `com.jkcoxson.LocalDevVPN` through the existing native AppService path when needed. The phone reuses the frozen `DeveloperRouteProbe`; only TCP reachability to `10.7.0.1:49152` is success. Missing installation and Apple/user confirmation are typed as `LOCALDEVVPN_MISSING` and `LOCALDEVVPN_USER_ACTION_REQUIRED`.

The rebuilt manifest declares `localDevVPNSetupGate: 1`; payload source-tree SHA-256 is `5668a29add1a3966c4514115523b1a21e69ff6585bdbc76c3e89dcb0aae64a5a`. New hashes: main `8c60fe20198307ba57550f7230c33b9361ab1ca57bcd1880db0ddb9f639b0081`, runner `c1e42038a763889b6dd23d175058a6c1d077b962caa61e50f456f8c4d7b5fb9c`, manifest `ecdf74fafe767b024fe9712b14512f9b572ba7f627ebf806b4c84867f0a9dd66`, authoritative app tree `8200221baab34c019c857449aabb6ec317586d2b4508c9607372c63bc563c65c`.

Physical refresh on iPhone18,1 / iOS 26.6.2 recorded `LOCALDEVVPN_READINESS_STARTED`, `LOCALDEVVPN_LAUNCH_STARTED`, `LOCALDEVVPN_LAUNCH_SUCCEEDED`, `LOCALDEVVPN_READY`, `SETUP_READY_FOR_RUNTIME`, and `COMPLETE` at `2026-09-15T16:07:58Z`. The readiness detail explicitly proves the endpoint connection. TestManager, XCTest, XCUILocation, Spoof, Drive, and Rich Drive were not started. No DMG was produced.
