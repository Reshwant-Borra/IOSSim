# DMG Static Analysis

This file preserves package-level facts, static findings, and bounded interpretations from the supplied Vanish 3.2.1 DMG.

## DMG and Signing

| Field | Finding | Confidence | Evidence |
| --- | --- | --- | --- |
| Filename | `VanishSetup.dmg` | CONFIRMED | E01 |
| Size | 147,766,400 bytes | CONFIRMED | E01 |
| SHA-256 | `fef10cf9e2dcca54773f059fcbc865ad402f43637f9260c7f1391ac541c96ed0` | CONFIRMED | E01 |
| Format | ULFO read-only compressed image | CONFIRMED | E01 |
| Public release match | Matches v3.2.1 public GitHub release asset | CONFIRMED | E29 |
| Outer DMG signature | No usable code signature | DISPROVEN as signed code object | E02 |
| Enclosed app | Signed, hardened, stapled/notarized, Gatekeeper accepted | CONFIRMED | E02 |
| App bundle ID | `com.vanish.app` | CONFIRMED | E02 |
| App version | 3.2.1 | CONFIRMED | E02 |
| Developer ID | Bhavya Khunt, team `6343MY26K5` | CONFIRMED | E02 |

## Bundle Scale

`CONFIRMED`: `bundle-inventory.json` records 4,386 regular non-symlink files under `Vanish.app/Contents`, totaling 339,823,032 bytes. `asar-inventory.json` records 161 ASAR entries. Evidence: E03.

Large or important files:

| Path | Bytes | SHA-256 / role |
| --- | ---: | --- |
| `Frameworks/Electron Framework.framework/Versions/A/Electron Framework` | 149,716,544 | Electron runtime |
| `Resources/python/lib/libpython3.13.dylib` | 19,056,640 | Bundled Python runtime |
| `Resources/sideloader/VanishSideloader` | 11,998,848 | Rust sideloader |
| `Resources/vanish-ipa/Vanish.ipa` | 11,911,195 | Intended mobile payload; SHA-256 `7959eba32164c8de29cec2d723df7381f63b8b292fbb76f137c9b40d0e935dbc` |
| `Resources/vanish-ipa/StikDebug-2.3.7.ipa` | 12,048,589 | Legacy/additional IPA present; normal install not established |
| `Resources/app.asar` | 6,581,165 | Electron app archive; SHA-256 `557ba9cc7320a0d4c4c1eb2cc3815d5ae0ae2162a82f0fa1f5f448cb023f7dc7` |
| `Frameworks/Squirrel.framework/Versions/A/Squirrel` | 147,104 | Updater framework |

## Application Structure

Important confirmed components:

- `Contents/MacOS/Vanish`: Electron launcher, 69,600 bytes, arm64.
- `Contents/Frameworks/Electron Framework.framework`: Electron.
- `Contents/Frameworks/Squirrel.framework`: update framework.
- `Contents/Frameworks/Mantle.framework` and `ReactiveObjC.framework`: support libraries.
- Electron helper apps: Helper, GPU, Renderer, Plugin.
- `Contents/Resources/app.asar`: readable Electron app archive.
- `Contents/Resources/python`: bundled Python 3.13 and site-packages.
- `Contents/Resources/sideloader/VanishSideloader`: Rust native helper.
- `Contents/Resources/vanish-ipa`: packaged mobile payloads.

No dedicated Vanish launch agent, privileged helper bundle, system extension, XPC service, Packet Tunnel extension, or embedded Vanish Network Extension was identified in the app bundle. That is a static bundle finding only; runtime installation was not observed.

## Entitlements

`CONFIRMED`: The main app and sideloader entitlement dictionaries declare:

- `com.apple.security.cs.allow-jit`
- USB access related entitlement
- location, Bluetooth, camera, microphone/audio-input, and print related permissions

`CONFIRMED`: No App Sandbox or Network Extension entitlement key was identified in those inspected entitlement dictionaries. Evidence: E31.

Interpretation:

- Broad entitlements do not prove active use of camera, microphone, Bluetooth, or user location.
- Absence of a Vanish Network Extension fits the model where LocalDevVPN is a separate iPhone-side app/service.

## Mach-O Binaries and Frameworks

### Mac Side

`CONFIRMED`: `VanishSideloader` is an arm64 Rust executable, signed by the same Developer ID team, minimum macOS 11.0. It links:

- `Security`
- `SystemConfiguration`
- `CoreFoundation`
- `libiconv`
- `libSystem`

It imports Keychain generic-password APIs. Evidence: E07.

`CONFIRMED`: No direct linked Apple `CoreDevice.framework`, `DVTFoundation.framework`, `DTDeviceKit.framework`, `DVTDeviceFoundation.framework`, `DVTiPhoneSimulatorRemoteClient.framework`, or `MobileDevice.framework` replacement was identified in the bundle. Evidence: E06-E08, E31.

Interpretation:

- Vanish's no-Xcode path is not "ship Apple's CoreDevice framework" based on current evidence.
- It is "ship independent protocol clients and helpers."

### iPhone Payload

`CONFIRMED`: `Vanish.ipa` contains:

- `Payload/StikDebug.app/StikDebug`
- display name Vanish
- source bundle ID `com.vanish.stikdebug`
- version 3.2.0
- minimum iOS 17.4
- `VanishLiveActivityExtension.appex`
- source extension ID `com.vanish.stikdebug.liveactivity`

`CONFIRMED`: The inspected IPA inventory did not contain:

- embedded provisioning profile
- XCTest runner
- `.xctest` bundle
- bundled Apple framework directory
- VPN/PacketTunnel extension

Evidence: E12.

`CONFIRMED`: The main iPhone executable SHA-256 was:

```text
ec52e1028187175aee2ab53eab352bc47cb3a1973e1f9bc6c0530b5f2d370304
```

Evidence: E13.

## Python Components

`CONFIRMED`: Bundled Python 3.13 and `pymobiledevice3` 9.12.0 are packaged. `pymobiledevice3` METADATA declares GPL-3.0-or-later. Evidence: E04.

Important bundled Python helpers:

- `Resources/python/vanish_loc_stream.py`: imports RSD, DvtProvider, LocationSimulation; maintains context; handles point set, GPX playback, clear, and clear on EOF.
- `Resources/python/vanish_remotepair_setup.py`: RemotePairing setup helper.
- `Resources/python/vanish_wireless_discover.py`: wireless discovery helper.
- `Resources/python/vanish_wireless_tunnel.py`: wireless tunnel helper.

`STRONG_EVIDENCE`: These replace common Xcode/devicectl host-device operations for discovery, Developer Mode checks, developer image mounting, remote pairing, tunnel setup, and DVT location simulation. Evidence: E05-E06.

Other identified packages include:

- `developer_disk_image` 0.2.0, license not established in this research.
- `srptools` 1.0.1, BSD-3-Clause.
- `gpxpy` 1.6.2, Apache-2.0.
- `cryptography` 49.x, Apache-2.0 or BSD-3-Clause.

## Rust Components

`STRONG_EVIDENCE`: `VanishSideloader` contains or links functionality matching public `idevice` and `isideload` stacks:

- `idevice` build paths identify 0.1.65.
- `isideload` checkout `3c1a008` appears in build strings.
- Public matching `isideload` manifest identifies version 0.3.17 and MIT license.

Capabilities found in symbols/strings:

- GrandSlam/SRP Apple auth.
- trusted-device and SMS 2FA.
- Xcode auth token handling.
- Developer Services teams.
- CSR/certificate operations.
- device registration.
- App ID and provisioning profile operations.
- signing.
- `installation_proxy`.
- AFC and HouseArrest.
- RemotePairing/RPPairing.

Evidence: E07-E09.

Limitation:

- Public library features and compiled strings prove capability presence, not that every path runs for every user.
- Fork modifications are possible.

## Pairing Evidence

`CONFIRMED`: Static code paths include:

- RemotePairing creation/trust.
- Stored RPPairing check per device.
- Pairing selection.
- Pairing placement.
- Pairing repair.
- Export fallback involving `pairingFile.plist`.
- Native filename markers including `rppairing_file_`, `rp_pairing_file.plist`, and `pairingFile.plist`.

Evidence: E11.

Interpretation:

- Pairing is automated/hidden.
- Pairing is not eliminated.
- No real pairing material was read or copied.

## Provisioning Evidence

`STRONG_EVIDENCE`: `VanishSideloader` includes:

- GrandSlam/SRP authentication.
- Developer Services endpoints.
- team list/discovery.
- CSR generation/submission.
- development certificate creation/reuse/limit handling.
- device registration.
- App ID creation/listing.
- provisioning profile download.
- signing and install.

Evidence: E08-E09.

`CONFIRMED`: Optional saved-password path uses Electron safeStorage and `sideload_accounts.json`. Evidence: E10.

## Location and DVT Evidence

`CONFIRMED`: Desktop helper uses RSD, DvtProvider, and LocationSimulation. Evidence: E06.

`CONFIRMED`: Mobile executable contains:

- `_location_simulation_new`
- `_location_simulation_set`
- `_location_simulation_clear`
- `_ls_simulate_location`
- `_ls_retarget`
- `_ls_stop_simulated_location`
- `_ls_location_tunnel_is_up`

Evidence: E13.

`UNKNOWN`: Rich metadata injection. Targeted scans did not find `XCUILocation`, XCTest runner, or `testmanagerd` indicators in the bundled IPA. Evidence: E12-E13.

## LocalDevVPN and Cellular Evidence

`STRONG_EVIDENCE`: Mobile strings and metadata reference:

- LocalDevVPN URL scheme.
- LocalDevVPN App Store URL.
- RPPairing filename.
- VanishDevicePreparer.
- local-tunnel probe.
- cellular off/on guidance.
- local session retarget.

Evidence: E14.

`PLAUSIBLE`: Packaged handoff notes attribute cellular failures to carrier/private-address route collisions and wrong interface selection. Evidence: E15. These notes are vendor-authored and internally inconsistent in test-status wording, so they are not runtime proof.

## Network and Hostname Evidence

Static endpoint and provider categories:

| Category | Endpoint or provider | Confidence | Evidence |
| --- | --- | --- | --- |
| Apple auth | `gsa.apple.com`, GrandSlam `GsService2` | STRONG_EVIDENCE | E08 |
| Apple Developer Services | `developerservices2.apple.com` | STRONG_EVIDENCE | E08 |
| Anisette candidates | `ani.sidestore.io`, `ani.stikstore.app` | CONFIRMED candidates | E08 |
| Vanish backend | Supabase project `zsxakqcwikibmzytgusw` | CONFIRMED request construction | E20 |
| Update | GitHub releases, `bhavyakhunt/vanish-releases` | CONFIRMED | E21 |
| Desktop maps | CARTO, Esri | CONFIRMED | E18 |
| Search | Mapbox geocoding/search | CONFIRMED | E18 |
| Routing | OSRM, Valhalla | CONFIRMED | E18 |
| Mobile map/data | MapKit, Overpass candidates | STRONG_EVIDENCE | E19 |
| Legacy candidate | `locsim.info` | UNKNOWN active use | E20 |

Static endpoint presence does not prove live traffic, payload contents, port timing, or server-side storage.

## Negative Findings

Bounded negative findings from the supplied artifact:

- No embedded Apple CoreDevice.framework replacement found.
- No embedded DVT/XCTest runner found in `Vanish.ipa`.
- No Vanish PacketTunnel/NetworkExtension in the inspected IPA.
- No proof of Vanish coordinate relay through its backend.
- No proof that Developer Mode is bypassed.
- No proof that seven-day signing is bypassed.
- No proof that Apple passwords are sent to Vanish servers.

These are bounded to the supplied v3.2.1 package and static methods used.
