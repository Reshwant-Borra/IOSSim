# Durable Evidence Register

This register preserves each major claim with confidence, evidence, interpretation, alternatives, and limits. It complements the original `EVIDENCE.md` E01-E31 register and does not replace it.

## Evidence ID Map

| ID | Claim | Confidence | Evidence type | Artifact/path | Component | Interpretation | Alternatives / limitations |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E01 | DMG size, hash, and read-only image format were identified | CONFIRMED | local file metadata | `VanishSetup.dmg` | DMG | Target artifact is fixed by SHA-256 | Does not prove runtime behavior |
| E02 | Enclosed app is signed/notarized; outer DMG is not usable signed code | CONFIRMED / DISPROVEN outer claim | codesign/spctl/plist | `Vanish.app` | Mac app | App accepted by Gatekeeper; DMG signature separate | Not a security audit of every update |
| E03 | Bundle and ASAR inventories were generated | CONFIRMED | metadata inventory | `bundle-inventory.json`, `asar-inventory.json` | App bundle | 4,386 files, 161 ASAR entries | Inventory metadata only |
| E04 | Bundled Python and pymobiledevice3 exist | CONFIRMED | package metadata | `Resources/python` | Python stack | Device stack packaged | GPL implications require review |
| E05 | Electron invokes Python usbmux/AMFI/mounter/tunnel commands | CONFIRMED | readable JS call paths | `app.asar::electron/dist/main/main.js` | Mac UI | Actual call sites, not just strings | Does not prove every path used in a real session |
| E06 | Desktop location helper uses RSD/DVT LocationSimulation | CONFIRMED | Python helper imports/logic | `Resources/python/vanish_loc_stream.py` | Desktop runtime | Mac can stream point/GPX/clear | Not phone-local proof |
| E07 | Rust sideloader metadata and linked libraries | CONFIRMED | Mach-O/import metadata | `Resources/sideloader/VanishSideloader` | Native helper | Local helper with Security/SystemConfiguration | Not source provenance proof |
| E08 | Sideloader contains idevice/isideload, Apple auth, signing, pairing vocabulary | STRONG_EVIDENCE | symbols/strings/public-source comparison | `VanishSideloader` | Native helper | Apple auth/provisioning/signing/installation capability | Compiled capability does not prove each operation executed |
| E09 | Electron-to-Rust command bridge includes login/install/pairing events | CONFIRMED | readable JS call paths | `electron/dist/main/main.js` | Mac orchestration | Helper is used from UI | Exact live step ordering unknown |
| E10 | Optional Apple password saving uses safeStorage | CONFIRMED | readable JS path | `electron/dist/main/main.js` | Mac account UX | Password persistence option exists | Not proof of durable Apple session or server transmission |
| E11 | RemotePairing creation/storage/placement/repair/export exists | CONFIRMED | JS/native metadata | ASAR + sideloader | Pairing | Pairing automated, not eliminated | No actual pairing records inspected |
| E12 | Vanish IPA payload inventory | CONFIRMED | ZIP/plist inventory | `Resources/vanish-ipa/Vanish.ipa` | iPhone app | Main app and Live Activity packaged; no runner/profile found | Final installed ID/team unknown |
| E13 | iPhone executable contains location simulation/tunnel symbols | STRONG_EVIDENCE | Mach-O symbols/strings | `Payload/StikDebug.app/StikDebug` | Mobile runtime | Local DVT coordinate simulation likely | No runtime execution; rich metadata unknown |
| E14 | LocalDevVPN/cellular prep strings present | STRONG_EVIDENCE | plist/strings | Vanish IPA | Mobile runtime | Phone-local helper/VPN workflow | Exact setup screens unknown |
| E15 | Packaged handoff notes describe cellular retained-session flow | PLAUSIBLE to STRONG_EVIDENCE when combined | packaged markdown self-report | `HANDOFF-3.2.0.md` in ASAR | Internal notes | Supports cellular bootstrap model | Self-report, internally inconsistent test wording |
| E16 | On-phone self-refresh/re-sign machinery exists | STRONG_EVIDENCE | symbols/strings/copy | Vanish IPA | Renewal | Seven-day handled by refresh, not bypass | Rollover success unknown |
| E17 | Watchdog/retry/replay logic exists | CONFIRMED code paths | readable JS | `electron/dist/main/main.js` | Recovery | Scoped retry/replay mechanisms | Success rates and timings unmeasured |
| E18 | Desktop map/search/routing providers identified | CONFIRMED | readable JS | ASAR UI/main assets | Map UX | Mapbox/CARTO/Esri/OSRM/Valhalla requests | Live traffic and payload retention unknown |
| E19 | Mobile UX features evidenced | STRONG_EVIDENCE | symbols/public release notes | IPA + GitHub notes | Mobile UX | saved places, routes, speed options, Live Activity | UI rendering untested |
| E20 | Supabase backend endpoints and telemetry shapes exist | STRONG_EVIDENCE | readable JS/strings | ASAR + IPA strings | Cloud | backend beyond updates/licensing-only | Does not prove coordinate relay |
| E21 | Mac updater uses Squirrel/GitHub release service | CONFIRMED | JS/framework metadata | ASAR + Squirrel | Updates | Electron updater configured | Update migration untested |
| E22 | Static filesystem destinations identified | CONFIRMED static destinations | readable JS | ASAR | Persistence | expected userData/log/wireless paths | No measured filesystem deltas |
| E23 | No runtime Vanish process observed; host not clean | CONFIRMED baseline | process/path checks | local Mac | Runtime baseline | No live Vanish session; host already has Apple dev services | Cannot prove no-Xcode clean-host success |
| E24 | IOSSim git/source context | CONFIRMED | git/source read | IOSSim repo | Source context | Findings bound to HEAD/branch | No code modified |
| E25 | IOSSim devicectl default and incomplete idevice backend | CONFIRMED source | `RuntimeProvisioningSupport.swift` | IOSSim Mac | No-Xcode gap | Backend not enough for install |
| E26 | Additional IOSSim direct devicectl dependencies exist | CONFIRMED source | `ConsumerArtifactProvisioner.swift`, `InstallationInventory.swift` | IOSSim Mac | Device bridge needs centralization | Some paths may be fallback-only |
| E27 | IOSSim native Apple auth/provisioning exists | CONFIRMED source | `ApplePersonalTeamLive.swift` | IOSSim provisioning | Do not replace auth wholesale | No new physical auth test |
| E28 | IOSSim rich runtime exists | CONFIRMED source/historical docs | `LocationCoordinator.swift` and docs | IOSSim iPhone runtime | Rich runtime likely advantage | Latest RC not requalified here |
| E29 | Public release metadata matches local DMG | CONFIRMED | GitHub API/public metadata | `bhavyakhunt/vanish-releases` | Distribution | Artifact identity corroborated | Public metadata can change; recorded date matters |
| E30 | Public site/tutorial/privacy/changelog reviewed | CONFIRMED public research | getvanish.app public assets | Public claims | Marketing vs mechanism matrix | Public copy contradictory/stale in places |
| E31 | Entitlements and selected binary sizes recorded | CONFIRMED | codesign/file/otool | app bundle | Static metadata | No app sandbox/network extension entitlement in inspected dicts | Broad entitlements not active-use proof |

## Major Conclusions Preserved

| Claim | Confidence | Evidence IDs | Alternative explanations | Limitations |
| --- | --- | --- | --- | --- |
| Vanish is a two-mode product | STRONG_EVIDENCE | E05-E16 | A single shared library could serve both paths | Runtime mode selection untested |
| No-Xcode is achieved by bundled protocol clients and prebuilt payloads | STRONG_EVIDENCE | E04-E09, E12 | Host could still rely on cached Apple services | Clean no-Xcode host not tested |
| Bundled Apple CoreDevice.framework is not the replacement | DISPROVEN for inspected package | E06-E08, E31 | Apple system services may still run on host | Negative limited to supplied bundle |
| Pairing is automated, not eliminated | CONFIRMED / DISPROVEN no-pairing claim | E11 | Some flows may still require manual export | No real pairing records read |
| Apple auth/provisioning is local-helper orchestrated | STRONG_EVIDENCE | E08-E10 | Backend may still provide entitlement or anisette support | No live traffic |
| Apple password persistence exists as an option | CONFIRMED | E10 | Users may choose not to save | No account-store content read |
| Developer Mode is required in intended flow | STRONG_EVIDENCE | E05, E19, Apple docs | UI may not check every transport | Fresh disabled device untested |
| Mobile payload is Vanish/StikDebug with Live Activity | CONFIRMED packaged | E12 | Final signed bundle ID may change | Actual install delta unknown |
| Mobile uses LocalDevVPN/local developer services | STRONG_EVIDENCE | E13-E14 | Additional cloud gating can coexist | Runtime session untested |
| Cellular uses retained local session with off/on bootstrap | STRONG_EVIDENCE | E14-E15 | Vendor notes may oversimplify route issue | Transition matrix unrun |
| Vanish mobile DVT looks coordinate-only | STRONG_EVIDENCE for current evidence | E12-E13 | Later download or hidden path possible | Rich metadata not measured |
| Seven-day expiration is refreshed, not bypassed | STRONG_EVIDENCE / DISPROVEN bypass claim | E16, E30 | Paid account behavior might differ | Profile dates not collected |
| Recovery mechanisms exist | CONFIRMED mechanisms | E11, E17 | Some may be rarely successful | Success rates unknown |
| Backend has roles beyond license-only | STRONG_EVIDENCE | E20, E30 | Some endpoints may be inactive | No live payloads |
| Backend coordinate relay is unproven | UNKNOWN | E20 | `mobile-spoof-session` could be accounting or relay | Endpoint name insufficient |
| IOSSim need not replace rich runtime | STRONG_EVIDENCE | E25-E28 | Runtime tests could expose cellular limitation requiring changes | Missing physical experiments |

## Raw Evidence Files

Use these when validating this documentation:

- Original evidence register: `../EVIDENCE.md`
- Original full report: `../REPORT.md`
- Experiment matrix: `../EXPERIMENTS.tsv`
- Bundle inventory: `../bundle-inventory.json`
- ASAR inventory: `../asar-inventory.json`
- Read-only inspection script: `../inspect_archive.py`

## Evidence Count

Major evidence entries preserved here: 31 original EIDs plus 15 major-conclusion rows.
