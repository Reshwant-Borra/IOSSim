# Vanish-informed acceptance gates

No gate can be waived by a saved checkpoint, source assertion, or passing mock. Evidence attaches release, commit, setup key aliases, device OS build, and test kind.

| Gate | Required evidence | Failure condition |
| --- | --- | --- |
| G0 product decisions | approved DDI source/rights/license/update policy; LocalDevVPN/release authority/architecture ADRs | unresolved owner or undeclared dependency |
| G1 artifact integrity | mounted-DMG audit of real Mach-O slices, nested hashes/signatures, schemas, payload IDs, version/build/commit/channel, notarization/staple | any config/sidecar claim differs from bytes |
| G2 hermetic tests | deterministic test inventory with no user Keychain/Apple/device/user defaults/Application Support access | external access or unexplained failure |
| G3 packaged engine | signed helper found only at bundle path; protocol/integrity handshake; source/binary scan excludes consumer repo/Xcode routes | fallback/override or generic doctor error |
| G4 durable state | multi-process and kill-point tests; schema migration; quarantine/recovery | lost update, cross-key access, active resource destroyed |
| G5 initial Trust | never-trusted supported phone completes via native bridge after legitimate Trust prompt; denial/timeout/reconnect work | Xcode/devicectl needed or prompt bypassed |
| G6 DDI | empty approved cache obtains exact supported build, verifies provenance, personalizes/mounts, produces RSD/AppService; cache/offline/revocation tested | mirror fallback, wrong build, or existing developer-Mac state required |
| G7 install | exact selected connection; signed main/runner install and post-inventory; interrupted install reconciles | ambiguous device, unverifiable bundle, unrelated app removal |
| G8 Apple/signing | Personal Team auth/2FA/session and all typed failures; candidate identity/profile lifecycle; access probe | secret leakage, private drift interpreted as credentials, destructive renewal |
| G9 pairing | request-bound import, phone possession challenge, developer-service proof, atomic promotion; crash/replay suite | import receipt alone marks operational or active state lost |
| G10 VPN | missing/install/version/permission/config/run/authenticated endpoint states and scene resume | bare TCP reachability or bypassed Apple approval |
| G11 developer services | live device/build-bound CoreDeviceProxy/tunnel/RSD/RemoteXPC/AppService receipt and exact app launch | manual phone launch counted as proof |
| G12 Rich runtime | exact runner reaches TestManager, bounded Rich location write is observed/acknowledged, then clear/stop; cadence invariants pass | stored checkpoint or runner launch alone marks READY |
| G13 recovery/renewal | every doc-15 scenario preserves valid domains and chooses smallest repair; real expiry/renewal/reboot/update | broad reinstall/reset as normal repair |
| G14 diagnostics | stable error/action coverage; support bundle negative secret corpus and release identity | forbidden value or raw identifier/profile appears |
| G15 legacy removal | packaged dependency/source/binary scan plus full physical parity | any consumer Xcode/devicectl/repo/env route or premature deletion |
| G16 distribution | canonical DMG signed/notarized/stapled, copied/downloaded hash matches, clean minimum-OS launch/update/rollback | mutable/ambiguous release or audit mismatch |
| G17 migration | IOSSim-to-Veya upgrade preserves supported state/Keychain/device installs and rollback | data loss, bundle/signing identity ambiguity |

## Physical qualification matrix

At minimum test a clean supported Mac, new macOS user, never-trusted iPhone, previously trusted iPhone, second iPhone, USB/Wi-Fi duplicate record, latest supported iOS with cleared DDI cache, locked/disconnected phone, Developer Mode off/on reboot, developer-profile trust, Apple session expiry, profile expiry/renewal, certificate/device/App-ID limits where safely reproducible, pairing repair, LocalDevVPN install/approve/deny, AppService runner launch, Rich proof, app/phone/Mac reboot, upgrade/reinstall, and the final downloaded DMG. Static or synthetic evidence remains labeled separately.
