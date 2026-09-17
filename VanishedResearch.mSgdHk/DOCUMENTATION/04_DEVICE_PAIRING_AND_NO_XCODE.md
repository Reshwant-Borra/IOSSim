# Device Pairing and No-Xcode Architecture

This document preserves two critical findings:

1. Vanish does not eliminate pairing. It automates and hides it.
2. Vanish avoids requiring full Xcode by bundling independent device-protocol clients and a prebuilt mobile payload.

## Pairing Verdict

`DISPROVEN`: Vanish does not remove pairing from the architecture.

`CONFIRMED`: Shipped code includes creation, storage checks, placement, repair, and manual export fallback for RemotePairing/RPPairing material.

Evidence: E11.

## Pairing Layers

Keep these distinct:

- USB lockdown trust: standard "Trust This Computer" host relationship used for local services, installation, and preparation.
- RemotePairing/RPPairing: modern developer-tunnel trust material used by LocalDevVPN/RSD paths.
- App delivery/import: moving the needed pairing state into the phone app so the user does not handle a plist in the normal path.

Vanish contains all three concepts. USB trust is not the same thing as RemotePairing, and RemotePairing is not eliminated simply because the user never sees the file.

## Pairing Evidence

| Evidence | What it means | Confidence |
| --- | --- | --- |
| Electron main references RemotePairing setup | Pairing creation is in flow | CONFIRMED |
| Per-device stored RPPairing checks | State is persisted and associated with a device | CONFIRMED |
| Pairing placement path | Pairing is delivered to installed app | CONFIRMED |
| Pairing repair command | Stale/missing pairing has targeted recovery | CONFIRMED |
| Export fallback using `pairingFile.plist` | Manual file workflow remains a fallback | CONFIRMED |
| Native filename markers `rppairing_file_`, `rp_pairing_file.plist`, `pairingFile.plist` | Helper/device stack contains expected artifacts | CONFIRMED |
| `~/.pymobiledevice3` references | Python/wireless pairing store is involved | CONFIRMED static destination |

Evidence: E11, E22.

## Pairing Interpretation

`STRONG_EVIDENCE`: In the normal path, Vanish likely performs:

1. User connects iPhone and approves normal Apple trust.
2. Mac establishes or reuses RemotePairing.
3. Vanish stores per-device pairing state.
4. Vanish signs/installs phone app.
5. Vanish places required pairing material into the app through an authorized device/app transfer channel.
6. Phone app imports/uses pairing with LocalDevVPN to reach developer services.
7. If placement or validation fails, pairing repair/export flow is offered.

`UNKNOWN`:

- Exact record transformation.
- Exact host storage path for all records.
- Whether Keychain is used for every layer.
- Exact app import channel.
- Stale-record validation policy.
- Survival across device reset, iOS update, or host migration.

No real pairing material was read, copied, or exposed.

## No-Xcode Verdict

`STRONG_EVIDENCE`: Vanish avoids full Xcode for users by packaging independent protocol clients and prebuilt payloads, not by shipping Apple's CoreDevice stack.

Core facts:

- Bundled Python 3.13 and `pymobiledevice3` 9.12.0 exist. Evidence: E04.
- Electron invokes the bundled Python stack for usbmux list, AMFI Developer Mode checks, developer-image auto-mount, and tunnel commands. Evidence: E05.
- `vanish_loc_stream.py` directly uses RSD, DvtProvider, and LocationSimulation. Evidence: E06.
- `VanishSideloader` contains Rust `idevice`/`isideload` related functionality for signing, install, AFC, HouseArrest, installation_proxy, and RemotePairing. Evidence: E07-E09.
- The phone app is prebuilt as `Vanish.ipa`. Evidence: E12.

`DISPROVEN for inspected package`: The no-Xcode replacement is not an embedded Apple `CoreDevice.framework`. No such bundled framework was identified. Evidence: E06-E08, E31.

`DISPROVEN`: Developer images are unnecessary. Vanish has developer-image mounting and image/trustcache references. Evidence: E05, E14.

## What Functions Vanish Replaces

Vanish appears to replace these Xcode/devicectl-like user-facing functions:

- Physical device discovery.
- Device identity resolution.
- Lock/Developer Mode readiness checks.
- Developer-image preparation/mounting.
- App installation.
- App-scoped transfer/staging.
- RemotePairing creation/reuse.
- RSD/RemoteXPC tunnel setup.
- DVT location simulation.
- Consumer signing and installation workflow.

It does not replace:

- Apple's user trust model.
- Developer Mode user confirmation.
- Apple Developer Services for signing/provisioning.
- Personalized developer-image/device-service requirements.
- Provisioning expiration.

## IOSSim No-Xcode Matrix

| IOSSim operation | Current Xcode/devicectl dependency | Vanish-equivalent mechanism | Evidence | Clean-room IOSSim replacement |
| --- | --- | --- | --- | --- |
| Device list | `xcrun devicectl list devices` default backend | usbmux/lockdown through bundled Python/idevice | E05, E25 | macOS-native usbmux/lockdown bridge with stable identity model |
| Device identity resolution | devicectl selected IDs/raw IDs | per-device pairing and helper identity checks | E09-E11, E25 | one normalized device registry separating UDID, pairing ID, signing ID |
| App inventory | devicectl app info/inventory | installation_proxy browse/lookup likely | E08-E09, E25-E26 | installation_proxy inventory with visibility/error classification |
| App install | devicectl install | Rust sideloader + installation_proxy/AFC | E08-E09 | AFC staging + installation_proxy install/upgrade |
| App uninstall | direct devicectl in IOSSim | not specifically proven for Vanish, but idevice supports install services | E08, E26 | installation_proxy uninstall scoped to IOSSim artifacts |
| Lock state | devicectl info lockState | lockdown/device service checks | E05, E25 | version-aware lockdown/readiness layer |
| Launch app | direct devicectl in IOSSim | Vanish installed app/manual/mobile flow; exact launch path unknown | E09, E26 | RemoteXPC/CoreDevice-equivalent launch service where supported |
| App container readback | direct devicectl in IOSSim | AFC/HouseArrest evidence | E08, E26 | app-scoped HouseArrest/AFC or IOSSim-owned transfer protocol |
| Developer Mode check | devicectl/system tooling | AMFI checks/reveal | E05 | AMFI/readiness check plus user-guided Settings flow |
| Developer image | devicectl/CoreDevice ecosystem | pymobiledevice3 mounter plus DDI references | E05, E14 | lawful personalized DDI acquisition/mounting flow |
| Pairing plist handling | explicit RPPairing material in IOSSim UX | automatic creation/storage/placement/repair | E11, E28 | internal pairing lifecycle plus advanced export fallback |
| Location session | IOSSim LocalDevVPN/RPPairing/RSD/TestManager/XCTest/XCUILocation | Vanish DVT coordinate simulation | E06, E13, E28 | keep IOSSim runtime; no replacement needed |
| Signing/provisioning | IOSSim native ApplePersonalTeamLive | Rust isideload flow | E08-E09, E27 | keep IOSSim native auth/signing; improve orchestration |
| Consumer build | possible signing-shell fallback | prebuilt IPA | E12, E26 | prebuilt release artifacts, no end-user compilation |

## Clean-Room Design Constraints

- Do not copy Vanish code or assets.
- Do not copy Apple device components without rights.
- Do not treat public developer-image repositories as redistribution permission.
- Do not suppress Apple trust or Developer Mode prompts.
- Do not expose pairing records in logs or support bundles.
- Do not hard-code private interfaces without version qualification.

## Practical IOSSim Takeaway

No-Xcode parity is a host-device bridge problem, not a reason to replace the phone runtime. The biggest gap in IOSSim is that its native `idevice` backend is currently incomplete and installation explicitly returns unavailable, while direct `devicectl` use remains outside the abstraction. Evidence: E25-E26.

The clean-room path is:

1. Finish a macOS-native device bridge.
2. Centralize all device operations behind it.
3. Add pairing lifecycle management.
4. Keep devicectl as an explicit development fallback during qualification.
5. Test on a genuinely clean no-Xcode host.
