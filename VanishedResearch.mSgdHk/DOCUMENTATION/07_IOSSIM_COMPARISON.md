# IOSSim vs Vanished Comparison

This document is the durable comparison between IOSSim as inspected and Vanish 3.2.1 as analyzed.

## Key Preservation Finding

`STRONG_EVIDENCE`: IOSSim likely does not need to replace its proven rich-location runtime to achieve most of Vanish's UX advantages.

Reason:

- Vanish's advantages are mostly host-device packaging, setup automation, pairing management, recovery, renewal, and UX.
- IOSSim already has the richer phone runtime path: LocalDevVPN, RPPairing, RSD, TestManager, XCTest runner, XCUILocation, rich metadata, retained sessions, generation/single-writer protection, pause/resume, Stop & Hold, and clear.

Evidence: E25-E28.

## IOSSim Source Findings to Preserve

`CONFIRMED`: IOSSim current source has:

- Native Apple Account/provisioning machinery in `ApplePersonalTeamLive.swift`.
- Keychain/session/key architecture, CSR, legitimate verification, teams and profiles.
- Existing iPhone runtime with LocalDevVPN/RPPairing/RSD/TestManager/XCTest/XCUILocation.
- Rich Drive logic and writer-generation protections.
- MapKit search and saved places/recents.

Evidence: E27-E28.

`CONFIRMED`: IOSSim's macOS native device backend is incomplete:

- `ProvisioningBackendKind` defaults to devicectl.
- `IdeviceProvisioningBackend` has discovery scaffolding but installation explicitly returns unavailable.
- Additional devicectl dependencies exist outside the backend abstraction for uninstall, inventory, launch, readback, and fallback build/signing flows.

Evidence: E25-E26.

## Comparison Matrix

| Capability | IOSSim Today | Vanish Evidence | Likely Vanish Mechanism | IOSSim Clean-Room Direction |
| --- | --- | --- | --- | --- |
| Full Xcode requirement | devicectl default and incomplete native bridge | STRONG_EVIDENCE no full-Xcode user requirement | bundled Python/pymobiledevice3, Rust idevice/isideload, prebuilt IPA | Complete Mac native device bridge |
| Device discovery | devicectl default; partial idevice scaffold | Python usbmux list and wireless discovery | usbmux/lockdown/RemotePairing | native usbmux/lockdown registry |
| Apple Account login | Native GrandSlam/SRP | Rust helper GrandSlam/SRP | isideload-like local helper | keep IOSSim native auth |
| 2FA | Native legitimate verification | helper event paths | trusted-device/SMS verification | polish UX/retry |
| Team setup | Native team/profile support | helper team discovery | Developer Services | keep, guide, cache safely |
| Certificates | Native CSR/key/signing | helper CSR/cert/limit paths | Developer Services + local keying | health checks and repair |
| Device registration | Native support | helper add/list device paths | Developer Services | idempotent device registration |
| App IDs | Native support | helper App ID paths | Developer Services | conflict-aware creation/reuse |
| Provisioning | Native profile operations | helper download/profile paths | Developer Services | expiry-aware refresh |
| Signing | Native system signing | Rust signing helper | isideload signing library | keep own signing |
| Installation | devicectl | native sideloader install | AFC + installation_proxy | native install bridge |
| Developer Mode | required by runtime | checks/reveal/guidance | AMFI + Settings | improve guidance |
| Trust This Computer | required by Apple | setup docs/guidance and lockdown path | standard USB trust | preserve Apple prompt |
| Pairing | explicit RPPairing material exposed | creation/storage/placement/repair/export | automated RemotePairing lifecycle | hide plist in normal path |
| LocalDevVPN | core runtime component | referenced/required by mobile | separate iPhone VPN helper | retain |
| RSD | runtime component | Python and mobile DVT/RSD evidence | RSD/RemoteXPC developer services | retain |
| DVT/TestManager | rich runtime through TestManager/XCTest | DVT location simulation evidence, no runner found | coordinate LocationSimulation | retain IOSSim richer runtime |
| XCTest | IOSSim runner | no bundled Vanish runner identified | not established | preserve IOSSim advantage |
| XCUILocation | IOSSim rich metadata | no targeted hits in Vanish IPA | not established | preserve IOSSim advantage |
| Teleport | present | point setter | DVT coordinate set | already covered |
| Drive | Rich Drive | route/GPX/route UI evidence | coordinate sequence | keep and polish |
| Rich metadata | speed/course/heading path | unknown; evidence favors coordinate-only | DVT coordinate setter | IOSSim likely stronger |
| Cellular | limitations reported | retained-session flow evidence | phone-local session bootstrap | test and harden existing runtime |
| Mac independence | phone runtime exists but UX/qualification unclear | mobile mode designed for phone-local use | LocalDevVPN + pairing + DVT | expose and qualify |
| Seven-day renewal | Mac/provisioning machinery, no proven phone self-refresh | on-phone refresh subsystem | SelfRefreshInstaller + signing | Mac-assisted first, phone refresh later |
| Recovery | existing reconnect/state logic | watchdog, pairing repair, cellular flow | scoped retries and guidance | unified health model |
| Diagnostics | engineering-oriented | copy logs/guidance evidence | consumer recovery screens | safer diagnostics UX |
| Updates | not established here | Squirrel/GitHub updater | electron autoUpdater | independent updater plan |
| Privacy | no need for saved password by default | saved password option, backend/map traffic | safeStorage + Supabase + providers | keep privacy-preserving defaults |
| Multiple devices | identity plumbing | per-device state, picker likely | device-bound pairing | test and protect identity |
| Onboarding | several exposed technical steps | consumer-guided flow | automation around same Apple mechanisms | one readiness pipeline |

## IOSSim Already Does Better

`STRONG_EVIDENCE`: richer location metadata and session model.

IOSSim's runtime has evidence for:

- retained long-lived RSD/TestManager session.
- XCUILocation runner path.
- 2 Hz rich updates and 1 Hz fallback.
- speed/course/heading.
- pause/resume.
- Stop & Hold.
- destination hold.
- clear simulation.
- single-writer/generation protection.

Evidence: E28.

`CONFIRMED`: IOSSim has native Apple auth and provisioning. Evidence: E27.

`PLAUSIBLE`: IOSSim can match most Vanish UX improvements by completing host/device and pairing layers around its current runtime.

## Vanish Clearly Does Better

`CONFIRMED/STRONG_EVIDENCE`:

- Ships a complete consumer-facing Mac device stack.
- Hides pairing material in normal flow.
- Automates pairing repair.
- Prebuilds payloads.
- Guides Developer Mode/trust/setup more clearly.
- Provides mobile/self-refresh architecture.
- Provides consumer update delivery.
- Packages mobile UX features such as Live Activity and cellular readiness.

## Marketing Difference vs Architecture

| Claim style | Reality |
| --- | --- |
| No pairing file | Pairing exists; file handling is automated and fallback remains |
| No Xcode | No full Xcode for user likely; Apple device services and developer images still matter |
| Works on cellular | Phone-local retained-session flow with bootstrap constraints; transitions untested |
| Computer only for setup | Credible for mobile mode; power-off fresh retarget untested |
| Seven-day solved | Refresh/re-sign/reinstall, not bypass |

## Comparison Bottom Line

IOSSim's main gap is not the phone-side location engine. It is the productization layer around it:

- no-Xcode Mac device bridge.
- automatic pairing lifecycle.
- readiness and recovery model.
- consumer onboarding.
- expiration/renewal UX.
- cellular bootstrap qualification.

Replacing IOSSim's rich runtime with Vanish-like coordinate-only DVT would likely lose capability.
