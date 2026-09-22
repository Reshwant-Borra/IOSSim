# Master Test Matrix

| Layer | What it proves | Does not prove | Environment / fixture | Required by |
|---|---|---|---|---|
| Swift unit | Pure domain behavior/error mapping | packaging/Apple/device | SwiftPM fakes | M1 onward |
| State machine/model | Every state/edge/invariant/idempotency | external APIs | generated snapshots + model oracle | M2 |
| Journal fault | atomicity, corruption/crash recovery | filesystem varieties | temp APFS, write fault adapter | M2 |
| Hermetic Apple | auth/team/cert/profile decisions and call order | current Apple service | recorded synthetic schemas | M6 |
| Real key store | create/reopen/no prompt/upgrade/corruption | clean consumer Mac | isolated service + packaged helper | M4 |
| Signer unit | bundle graph/entitlement policy | iOS acceptance | synthetic Mach-O fixtures | M5 |
| Signing integration | actual shipped Rust path creates independently valid payload | install/launch | exact Veya payload + golden nested bundles | M5 |
| Certificate campaign | 7460/owned/unknown/second Mac algorithms | Apple mutation success | hermetic inventory/transport | M6 |
| Profile | CMS/team/device/cert/expiry/capabilities | server availability | signed profile fixtures | M7 |
| Install fake | ambiguity/retry/rollback logic | USB/installd | scripted transport | M7 |
| Device ABI | Swift/Rust ABI and status mapping | every iOS version | actual packaged dylib, fake/none device | M3/M9 |
| Physical transport | discovery/Lockdown/inventory/services | clean state/reinstall | connected qualification iPhone, read-only | M9 |
| DDI provider | exact lookup/cache/integrity/quarantine | production catalog longevity | local signed catalog fixtures | M9 |
| DDI physical | mount/service readiness for exact build | other OS builds | permitted test iPhone | M14 |
| Pairing | active/candidate/replay/wrong-device/recovery | Apple pairing changes | protocol fakes + iOS unit checks | M9 |
| VPN | all states/restart/endpoint proof | approval UX across iOS | phone receipt fixtures; later physical | M9/M14 |
| AppService | exact runner and launch chain | XCTest/Rich | Rust service fakes + physical | M10/M14 |
| Rich | nonce target, observe, clear, freshness | long-duration product behavior | iOS POC + physical | M10/M14 |
| Reinstall scenarios | minimal repair across persistence combinations | second physical Mac | production engine + temp roots | M12 |
| Migration scenarios | one-way import/partial resume/no dual write | every historic machine | captured sanitized legacy fixtures | M8/M12 |
| Failure injection | active survives all named failures/crashes | unmodeled OS behavior | production engine + boundary fakes | M12 |
| Packaged | actual helper/resources/ABI/no repo deps | clean Mac quirks | mounted artifact bytes | M11 |
| Apple Silicon | native packaged execution/no UI prompt | Intel | clean AS Mac | Build 12 gate |
| Intel | x86_64 execution/signing/helper/bridge | AS | clean Intel Mac | Build 12 gate or declared blocker |
| Clean Mac | no stale state/toolchain dependency | all Mac policies | fresh user/VM/physical Mac | Build 12 gate |
| Physical iPhone | actual install/launch/runtime chain | other models/builds/accounts | qualification matrix | M14 |

Required results are exact pass/fail; expected user-action states are asserted as outcomes, not skipped tests. Any test using a fake labels the unproven external boundary in its report. Release qualification runs actual production composition and rejects test-only engines.

