# Physical Validation

This document separates physical iPhone evidence from local integration,
automated tests, and planned work.

## Evidence Labels

| Label | Meaning |
| --- | --- |
| PHYSICALLY PROVEN | Observed on actual iPhone hardware |
| LOCAL INTEGRATION PROVEN | Exercised real local OS/tool integration, but not necessarily iPhone hardware |
| AUTOMATED TESTED | Covered by deterministic tests or build/audit commands |
| IMPLEMENTED, NOT PHYSICALLY PROVEN | Code exists but current physical evidence is missing |
| PLANNED | Not implemented or intentionally deferred |
| NOT APPLICABLE | The row does not apply to that column |

## Latest Physical Install State

Latest same-Mac/same-iPhone evidence established:

- Apple authorization worked.
- Personal Team provisioning worked.
- Native signing worked.
- Main artifact installed.
- Runner artifact installed.
- Installation inventory was capable of verifying both artifacts.
- iOS developer-profile trust was required before the installed development app
  could launch.
- After trust and retry, the setup flow could continue.
- Later support-report evidence reached `COMPLETE`.

This does not claim clean-Mac qualification, no-Xcode qualification, public
release readiness, current RC Rich Drive requalification, or true profile
expiration renewal.

## Physical Setup Bugs Fixed In Current Branch

| Bug | Physical observation | Root cause | Fix |
| --- | --- | --- | --- |
| False installation verification failure | App was already downloaded/installed, IOSSim showed "Cannot Verify Installation", Try Again continued | Old `ConsumerArtifactProvisioner.installAndVerify` captured `installedBefore=false` from pre-install inventory. Main and runner then installed and post-install checks succeeded, but stale `installedBefore` still triggered `MAIN_INSTALL_FAILURE`. | Removed the obsolete pre-install guard. Authoritative post-install inventory now determines success. |
| Developer-profile trust treated as failure | Installed app could not launch until Settings trust was completed | `ConsumerArtifactProvisioner.launchMain` classified the structured untrusted-developer launch failure as generic runtime failure. | Structured CoreDevice/FBS trust error maps to `DEVELOPER_PROFILE_TRUST_REQUIRED`; Continue retries only launch/trust verification. |
| Stale historical team re-entry | Historical `5337SALD55` state could produce `CROSS_TEAM_UPGRADE_BLOCKED` after current `T8SL4SG87F` install evidence | Runtime/trust failure occurred before the new manifest checkpoint was saved, leaving stale metadata in place. | Save install checkpoints before trust; authoritative current main+runner inventory for the selected team wins over stale local metadata where safe. |

Developer-profile trust signature observed:

```text
CoreDeviceError error 10002
FBSOpenApplicationServiceErrorDomain error 1
FBSOpenApplicationErrorDomain error 3
BSErrorCodeDescription = Security
profile has not been explicitly trusted
```

## Gate History

| Gate | Purpose | Current evidence |
| --- | --- | --- |
| Gate 3 | Runner launch through retained RSD/TestManager/XCTest path | PHYSICALLY PROVEN in earlier runtime and Personal Team cycles |
| Gate 4 | Rich XCUILocation point behavior | PHYSICALLY PROVEN for rich metadata experiments; current RC requalification pending |
| Gate 5 | Rich Drive | PHYSICALLY PROVEN in earlier Personal Team cycle; current RC requalification pending |

Important successful Gate 3 sequence recorded in runtime history:

```text
RSD_READY
TESTMANAGER_CONTROL_READY
TESTMANAGER_MAIN_READY
DVT_READY
RUNNER_LAUNCHED
PID_AUTHORIZED
XCTEST_HANDSHAKE_READY
TEST_PLAN_STARTED
FINISHED
```

## Evidence Matrix

| Capability | Implementation | Automated tests | Local integration | Physical iPhone | Clean Mac | Release qualified |
| --- | --- | --- | --- | --- | --- | --- |
| Apple login | `ApplePersonalTeamLive` GrandSlam/SRP | PROVEN for protocol pieces | PROVEN on current Mac | PROVEN on current Mac/iPhone | UNPROVEN | UNPROVEN |
| 2FA | Trusted-device/SMS verification flow | PROVEN for state handling | PARTIAL | PROVEN on current Mac/iPhone | UNPROVEN | UNPROVEN |
| Personal Team discovery | Developer Services team list | PROVEN | PROVEN | PROVEN | UNPROVEN | UNPROVEN |
| Signing certificate/key | IOSSim-managed Keychain identity | PROVEN | PROVEN, except current protected-data test issue | PROVEN | UNPROVEN | UNPROVEN |
| Device registration | Developer Services device operations | PROVEN | PROVEN | PROVEN or reuse observed | UNPROVEN | UNPROVEN |
| App IDs | Deterministic main/UI-test/runner IDs | PROVEN | PROVEN | PROVEN | UNPROVEN | UNPROVEN |
| Profiles | Main and runner development profiles | PROVEN | PROVEN | PROVEN | UNPROVEN | UNPROVEN |
| Native signing | Keychain/SecIdentity/codesign | PROVEN | PROVEN, with current environment caveat | PROVEN | UNPROVEN | UNPROVEN |
| Main install | `devicectl device install app` | PROVEN via tests/mocks | PROVEN by package/audit | PROVEN | UNPROVEN | UNPROVEN |
| Runner install | `devicectl device install app` | PROVEN via tests/mocks | PROVEN by package/audit | PROVEN | UNPROVEN | UNPROVEN |
| Inventory verification | `devicectl device info apps` bounded retry | PROVEN | PROVEN | PROVEN capable; current stabilized policy pending retest | UNPROVEN | UNPROVEN |
| Developer-profile trust handling | Explicit trust checkpoint and UI | PROVEN | PROVEN by synthetic classifier/resume tests | PHYSICAL CONDITION OBSERVED; new flow pending retest | UNPROVEN | UNPROVEN |
| Runtime configuration | Launch main, read back runner mapping | PROVEN | PROVEN | PROVEN reached `COMPLETE` after trust/retry | UNPROVEN | UNPROVEN |
| RPPairing persistence | Keychain/persisted pairing state on iPhone | PROVEN | PROVEN | PHYSICALLY PROVEN in runtime cycles | UNPROVEN | UNPROVEN |
| RSD | Local RSD discovery/connection | PROVEN | PROVEN | PHYSICALLY PROVEN | UNPROVEN | UNPROVEN |
| Gate 3 | Retained RSD/TestManager runner launch | PROVEN | PROVEN | PHYSICALLY PROVEN | UNPROVEN | UNPROVEN |
| Spoof | Normal location simulation | PROVEN | PROVEN | PHYSICALLY PROVEN in earlier cycles | UNPROVEN | UNPROVEN |
| Rich XCUILocation | Rich runner samples | PROVEN | PROVEN | PHYSICALLY PROVEN in earlier cycles | UNPROVEN | UNPROVEN |
| Rich Drive | Route playback through rich transport | PROVEN | PROVEN | PHYSICALLY PROVEN in earlier cycles | UNPROVEN | UNPROVEN |
| Profile refresh | Same-team refresh architecture | PROVEN | PROVEN | PARTIAL; immediate refresh/update proven, true expiration renewal unproven | UNPROVEN | UNPROVEN |
| Xcode installed, never opened/configured | Target product assumption | PARTIAL | UNPROVEN | UNPROVEN | UNPROVEN | UNPROVEN |
| Xcode prerequisite detector | `XcodePrerequisiteDetector` | AUTOMATED TESTED | PROVEN against local Xcode 26.6 | NOT APPLICABLE | UNPROVEN | UNPROVEN |
| Xcode automatic download/install | Streaming/bootstrap primitives; download auth adapter incomplete | PARTIAL | UNPROVEN | NOT APPLICABLE | UNPROVEN | UNPROVEN |
| Automatic RPPairing | Exact-device isolated helper at pinned revision | AUTOMATED TESTED / BUILDS | helper build proven | UNPROVEN | UNPROVEN | UNPROVEN |
| Automatic private pairing transfer | CoreDevice app-data-container + transactional iPhone inbox | AUTOMATED TESTED | generic iOS build proven | UNPROVEN | UNPROVEN | UNPROVEN |
| Public distribution | Developer ID + notarized DMG | AUTOMATED PATH IMPLEMENTED | LOCAL_TEST_ONLY package proven | UNPROVEN | UNPROVEN | UNPROVEN |

## Current Known Test Issue

The latest stabilization report recorded this unresolved environment issue:

- `swift test --package-path macos` executed 213 tests, skipped 6, and produced
  49 failure assertions, including 5 unexpected failures.
- The common cause was the current Mac session denying access to
  `.completeFileProtection` temporary writes and an existing protected native
  artifact file.
- Five opt-in real signing integration attempts were blocked by the same
  protected-data denial.
- Focused setup stabilization suites, package builds, release-local, audits,
  frontend tests, backend tests, Rust checks, bundle-ID guards, generic iOS
  no-sign builds, POC unit checks, and package scans passed in the stabilization
  run.

The Phase 1 preservation run on 2026-09-09 did not reproduce this issue: the
full current `./iossim test` path passed. Production iOS complete file
protection was not weakened; Mac-only package fixtures use owner-only
permissions because iOS data-protection classes do not apply on macOS.

## Milestone History

| Milestone | Commit |
| --- | --- |
| Physically validated on-device Drive POC | `7c2d609` |
| Preserve physically working rich XCUILocation Drive architecture | `728c745` |
| Prove rich XCUILocation runner without Xcode orchestration | `c13c0ad` |
| Make rich XCUILocation default Drive transport | `18d15cc` |
| Final Drive hardening/user-facing lifecycle | `db20856` |
| Native macOS setup app | `1ef1220` |
| Self-contained macOS app packaging | `829337c` |
| Consumer Personal Team provisioning backend | `0393b02` |
| Production macOS release pipeline | `b44e0bf` |
| Local release candidate packaging | `5239e96` |
| Zero-Xcode feasibility/licensing documentation | `1b36fcf` |
| Live Personal Team provisioning transport | `ed0f4cf` |
| Wire LOCAL_TEST_ONLY Personal Team flow | `f72061b` |
| Native Personal Team signing stabilization | `e43aa18` |
| Physical install state stabilization | `53ba222`, `06478ba` |

## Source References

- `docs/mac-host/PHYSICAL_INSTALL_STATE_STABILIZATION.md`
- `docs/mac-host/PERSONAL_TEAM_PROVISIONING_POC.md`
- `docs/iphone_on_device_dvt/DRIVE_MODE_IMPLEMENTATION.md`
- `docs/iphone_on_device_dvt/ARCHITECTURE.md`
- `macos/Tests/IOSSimMacCoreTests/ConsumerProvisioningTests.swift`
- `macos/Tests/IOSSimMacCoreTests/SetupStoreTests.swift`
- `ios/Sources/POCUnitChecks/main.swift`
