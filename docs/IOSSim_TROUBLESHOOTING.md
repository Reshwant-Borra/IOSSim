# IOSSim Troubleshooting

These instructions are for the packaged no-Xcode consumer unless explicitly labeled build-machine-only.

| Symptom/code | Meaning | Safe action |
|---|---|---|
| No phone detected / zero usbmux devices | selected phone is not currently visible | Unlock, reconnect USB, retry `./iossim device-debug`; allow a brief retry for transient disappearance |
| `LOCKDOWN_FAILED` / `TRUST_REQUIRED` | computer trust session unavailable | Unlock phone and accept Trust This Computer; enter passcode on phone |
| device locked | protected device services unavailable | Unlock phone; retry without clearing state |
| Developer Mode disabled | Apple user action required | Settings → Privacy & Security → Developer Mode → enable → restart → unlock → confirm Turn On |
| AMFI says Developer Mode disabled but iPhone UI is on and typed readiness passes | AMFI status false-negative on this device/OS | Treat AMFI value as advisory; use the live CoreDevice readiness result. Still stop on an actual typed `developerModeRequired` rejection |
| Apple auth/2FA | scoped Developer Services session unavailable | Use IOSSim sign-in and complete Apple 2FA; do not open Xcode Accounts |
| Personal Team/cert/profile error | one native signing domain failed | Preserve existing key/cert; retry classified team/profile step; do not manually manage certificates unless doing explicit engineering recovery |
| native signing failure | artifact/profile/identity mismatch or expiry | inspect exact component/profile receipt; never substitute an unrelated team |
| install failure | AFC staging or Installation Proxy rejected exact component | preserve typed backend error; recheck trust/unlock/signature; do not use devicectl fallback |
| inventory mismatch | phone does not contain exact derived IDs | physical reconciliation installs only missing/stale owned component and re-reads inventory |
| stale checkpoint | persisted stage disagrees with phone | Try Again triggers native reconciliation; physical state wins |
| `DEVICE_RESOLUTION_FAILED` | selected stable identity did not resolve | retry discovery for same device; do not silently select another phone |
| `COREDEVICE_PROXY_FAILED` | modern proxy service failed | record exact diagnostic; retry after Developer Mode/trust/unlock checks |
| `SOFTWARE_TUNNEL_FAILED` | proxy opened but tunnel creation failed | retry boundedly; investigate tunnel layer only |
| `RSD_UNAVAILABLE` | RSD connect/handshake/service map failed | preserve exact stage; do not regenerate profiles/pairing |
| `REMOTEXPC_FAILED` | selected RSD service could not complete RemoteXPC | investigate that layer only |
| `APPSERVICE_UNAVAILABLE` | AppService absent/unavailable in RSD map | ensure Developer Mode is enabled; rerun readiness; preserve service-map evidence |
| `FEATURE_UNAVAILABLE` | AppService exists but launch feature is absent | capture OS/build/bridge receipt; targeted compatibility investigation |
| `APPLICATION_NOT_FOUND` | exact derived main ID absent from AppService inventory | re-run native inventory/reconciliation; do not label phone missing |
| `LAUNCH_REJECTED` | AppService policy/profile trust rejected launch | trust developer profile on phone if prompted, then retry exact app |
| `DDI_REQUIRED` | device explicitly requires matching developer support | stop; report device model, iOS version/build, typed error, requested identity; start a separate approved DDI task |
| `DDI_NO_APPROVED_SOURCE` | no authorized exact asset is configured | stop; do not use an unofficial mirror or arbitrary image |
| House Arrest/container unavailable | exact app container cannot be vended | ensure exact main app is installed/launched/unlocked; preserve `VendContainer` error |
| runtime mapping mismatch | container JSON differs from device/team/main/runner expectation | rewrite schema-1 file through native House Arrest and semantic readback; retain fallback until verified |
| pairing delivery failure | request/bootstrap/envelope transfer failed | reuse valid Mac Keychain record; repair delivery only |
| bootstrap missing/invalid | phone startup ingress did not create valid one-time session | confirm fresh payload is installed and app activated; inspect capability manifest/binary markers |
| refresh signs fresh apps but bootstrap remains missing | same derived bundle IDs may have caused old installed bytes to survive | use current refresh implementation, which force-upgrades both owned payloads and then re-inventories; do not uninstall generically |
| receipt missing/invalid | phone did not acknowledge or binding mismatched | preserve valid pairing; redeliver/reactivate; do not regenerate unless native validation rejects |
| `LOCALDEVVPN_MISSING` | external prerequisite `com.jkcoxson.LocalDevVPN` is not installed | install LocalDevVPN on the iPhone, then choose Try Again; do not add a consumer Xcode/build fallback |
| `LOCALDEVVPN_USER_ACTION_REQUIRED` | external app opened but its established route is not yet functional | on iPhone, approve Apple's VPN prompt if shown or tap Connect in LocalDevVPN, then choose Try Again |
| `LOCALDEVVPN_READINESS_FAILED` | bounded phone probe could not reach `10.7.0.1:49152` | keep LocalDevVPN visible, verify it says connected, and retry; interface visibility alone is not success |
| profile trust required | installed app is signed but not user trusted | Settings → General → VPN & Device Management → select developer identity → Trust |

## Stale payload diagnosis

Run the current helper's `verify-artifacts`. A current package requires `automaticPairingInbox>=1`, `runtimeMappingSchema>=1`, `pairingReceiptSchema>=1`, and `localDevVPNSetupGate>=1`, plus complete payload provenance. The old `bc339b3` payload must fail. Do not work around `PAYLOAD_PROVENANCE_INCOMPLETE`, `PAYLOAD_CAPABILITY_MISMATCH`, or `PAYLOAD_CAPABILITY_BINARY_MISMATCH` by copying old DerivedData.

## Build-machine-only issues

If `xcodebuild -version` says the selected directory is Command Line Tools or no `iPhoneOS.sdk` is listed, install full Xcode and use its `Contents/Developer` for payload build commands. This is not a consumer recommendation. Normal consumer setup never installs or invokes Xcode.

Current build machine status is resolved: `/Applications/Xcode.app/Contents/Developer`, Xcode 27.0 (27A266a), iPhoneOS SDK 27.0. If Apple presents the license gate on a new build machine, an administrator must run `sudo xcodebuild -license accept` and `sudo xcodebuild -runFirstLaunch`; this remains build-machine-only.

## Resolved physical incidents (2026-09-15)

The earlier `APPSERVICE_UNAVAILABLE` result did not reproduce once the phone was connected with Developer Mode enabled: generation 5 passed CoreDeviceProxy, tunnel, RSD, RemoteXPC, AppService, and native launch. The next failure was `bootstrapMissing`, which proved refresh had signed new artifacts but skipped same-ID installation. The force-upgrade correction installed both fresh payloads; the next refresh passed House Arrest, mapping, pairing delivery, phone receipt, and readiness. These are historical diagnostics, not current blockers.

## Evidence collection

Use `./iossim device-debug`, then `./iossim readiness-debug`, and retain the first typed failure. Support exports are redacted and must never include passwords, 2FA, signing private keys, pairing plist bytes, bootstrap keys, or route coordinates. Do not collapse service-not-found into device-not-found.
