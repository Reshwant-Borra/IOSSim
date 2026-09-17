# IOSSim iPhone Payload

## Consumer payload set

Only two top-level apps are distributed:

| Role | Source target/scheme | Source ID | Contents |
|---|---|---|---|
| Main | `IOSSimOnDevicePOC` / `IOSSimOnDevicePOC` | `com.iossim.on-device-dvt-poc` | UI, setup ingress, mapping consumer, pairing Keychain, and frozen location runtime |
| Runner | Xcode runner for `IOSSimLocationControlUITests` / `IOSSimPayloadRunner` | `com.iossim.location-control-uitests.xctrunner` | embedded `com.iossim.location-control-uitests` UI-test bundle and XCTest frameworks |

The Location Witness and non-UI unit-test bundle are not DeviceArtifacts. The runner is required by the retained TestManager/XCUILocation architecture; it is installed during setup but never started by this task.

## Build identity and Personal Team derivation

Build-time source IDs are stable compatibility boundaries. Consumer setup derives a deterministic namespace from the selected Team ID, rewrites main, runner, and embedded UI-test IDs consistently, creates matching App IDs/profiles, then signs. The last proven installed generation was:

- Main: `com.personalteam.iossim.t026e0910b111.on-device-dvt-poc`
- UI tests: `com.personalteam.iossim.t026e0910b111.location-control-uitests`
- Runner: `com.personalteam.iossim.t026e0910b111.location-control-uitests.xctrunner`

Current source target deployment is iOS 17.0. The fresh Xcode 27.0 device products and their prepared packaged copies are arm64; the main and runner Info.plists both report minimum iOS 17.0, and the runner embeds `PlugIns/IOSSimLocationControlUITests.xctest`. Prepared payloads contain no embedded provisioning profile and add no distribution-specific entitlement; consumer setup supplies the current Personal Team profiles/signature.

## Setup startup path

The `IOSSimOnDeviceDVTPOCApp` SwiftUI entry attaches setup-only tasks to `RootTabView`. `AutomaticPairingInboxController` retains the pairing flow. `LocalDevVPNSetupInboxController` reads `localdevvpn.request`, reuses `DeveloperRouteProbe`, and writes `localdevvpn.receipt`; it does not create a VPN configuration or start TestManager/XCTest/location. External LocalDevVPN is opened by the Mac through AppService. The exact graph is in `../IPHONE_SETUP_INGRESS_CALL_GRAPH.md`.

## Automatic pairing contract

Files are schema 1:

- `remote-pairing.request`: non-secret device/team/current-app binding, request ID, timestamp.
- `remote-pairing.bootstrap`: phone-generated nonce and 32-byte one-time AES import key, protected and transient.
- `remote-pairing.envelope`: AES-GCM sealed pairing plist bound to device/team/nonce.
- `remote-pairing.receipt`: device/team/nonce/status/pairing identifier/public-key fingerprint/timestamp only.

The runtime Keychain contract is unchanged:

- service `com.iossim.on-device-dvt-poc.rppairing`
- account `primary`
- `public_key`: exactly 32 bytes
- `private_key`: exactly 32 bytes
- `identifier`: non-empty
- `alt_irk`: absent or exactly 16 bytes
- accessibility: after first unlock, this device only

Successful import writes the receipt atomically, then deletes request/bootstrap/envelope. Failure writes no false receipt; startup stops retrying the persistent error during that activation, retains evidence for bounded Mac-side repair, and permits replacement/reactivation.

## Runtime mapping contract and compatibility

Canonical delivered path: `Library/Application Support/IOSSim/runtime-mapping.json`, schema 1. Fields are 64-hex safe device hash, optional non-empty team, exact main ID, and exact runner ID. The Mac writes only missing/stale content, reads it back, and compares complete semantics. The phone validates schema/hash/team shape/current main binding/runner identity, accepts the runner, and caches it in UserDefaults.

Precedence is:

1. explicit environment override;
2. valid delivered runtime mapping;
3. `IOSSimGate3RunnerBundleIdentifier` in Info.plist;
4. previously accepted UserDefaults mapping;
5. canonical source runner ID.

This retains the physically proven Info.plist/UserDefaults compatibility path. Invalid or mismatched delivered JSON falls through without deleting a known-good mapping. A valid delivered mapping migrates the accepted runner ID into UserDefaults.

## Stale payload incident and prevention

The old payload source is `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`. Its main executable lacks the current startup controller, bootstrap, receipt, and runtime-mapping markers. Mac setup advanced while DeviceArtifacts did not.

Current packaging prevents recurrence in three stages:

1. source membership/startup/contract checks;
2. required markers in the built main Mach-O;
3. manifest capability versions plus exact tree hashes and dirty-source provenance.

The fresh payload was built with Xcode 27.0/iPhoneOS SDK 27.0 and is embedded in `.build/iossim/final-setup-payload-retest/IOSSim.app`. The main Mach-O contains pairing and LocalDevVPN controller/request/receipt markers. The schema-2 manifest declares four capability versions, including `localDevVPNSetupGate: 1`. Both automatic pairing and the LocalDevVPN readiness receipt are **PRESENT / PHYSICAL_PASS**.

Current payload provenance is HEAD `1259da507ecded222022cc86bf82863c15640db9`, dirty `true`, source-tree SHA-256 `5668a29add1a3966c4514115523b1a21e69ff6585bdbc76c3e89dcb0aae64a5a`, build timestamp `2026-09-15T16:07:08.661384Z`, variant `DEVICE_PAYLOAD_RELEASE`. Main and runner tree hashes are `8c60fe20198307ba57550f7230c33b9361ab1ca57bcd1880db0ddb9f639b0081` and `c1e42038a763889b6dd23d175058a6c1d077b962caa61e50f456f8c4d7b5fb9c`.
