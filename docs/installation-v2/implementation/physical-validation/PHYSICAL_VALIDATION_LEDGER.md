# Physical validation ledger

Tracks defects found by real physical validation of Installation V2.

Status vocabulary: `FOUND` → `INVESTIGATING` → `INVESTIGATED_PLAN_READY` →
`IMPLEMENTED_SOFTWARE` → `RETEST_REQUIRED` → `PHYSICALLY_VERIFIED`.

`INVESTIGATED_PLAN_READY` means the mechanism is understood and an implementation
plan exists. No production source has been changed and nothing has been retested.

A defect reaches `PHYSICALLY_VERIFIED` only after the corrected artifact has
been run on real hardware and observed to pass. Software gates never confer it.

| # | Defect | Found on | Status | Fixed in | Retest artifact |
|---|---|---|---|---|---|
| 001 | `SIGNING_KEY_ACCESS_DENIED` on a clean Mac — the Personal Team signing key was created in the login Keychain, where `securityd` stamps it with a `cdhash:<creator>` partition that `/usr/bin/codesign` can never match | Intel x86_64, macOS 14.8.9 (23J631), no Xcode, `Veya-0.1.0-build1-1259da5-local-test.dmg` | **RETEST_REQUIRED** | `dd259bd` | `Veya-0.1.0-build2-dd259bd-local-test.dmg` (`a5cfa59e…`) |
| 002 | `CERTIFICATE_LIMIT_REACHED` — Veya has no recovery path from its own obsolete signing certificate. Build 2 correctly rejects the Build-1 identity, tries to reissue, and finds the Personal Team's two certificate slots full — one of them holding Veya's own dead certificate | Intel x86_64, macOS 14.8.9 (23J631), no Xcode, `Veya-0.1.0-build2-dd259bd-local-test.dmg`, run against intact Build 1 state | **RETEST_REQUIRED** | `ea8269b` | `Veya-0.1.0-build3-ea8269b-local-test.dmg` (`d75908ed…`) |

## Defect 001 detail

* Report: [`PHYSICAL_DEFECT_001_SIGNING_KEY_ACCESS_DENIED.md`](PHYSICAL_DEFECT_001_SIGNING_KEY_ACCESS_DENIED.md)
* Reproduction evidence: [`repro/EVIDENCE_MATRIX.md`](repro/EVIDENCE_MATRIX.md)
* Test results: [`PHYSICAL_DEFECT_001_TEST_RESULTS.md`](PHYSICAL_DEFECT_001_TEST_RESULTS.md)
* Artifact: [`PHYSICAL_DEFECT_001_ARTIFACT.md`](PHYSICAL_DEFECT_001_ARTIFACT.md)
* Retest instructions: [`PHYSICAL_RETEST_001.md`](PHYSICAL_RETEST_001.md)
* Support bundle: `evidence/IOSSim-Support-1789592208.zip`

Defect 001's retest was **blocked by defect 002**: the build2 run stopped at the
certificate limit before signing was reached, so the Keychain fix is still
unproven on hardware. 001 stays `RETEST_REQUIRED`, and the Build-3 run tests both
defects in a single pass.

Known limitation: the defect-001 **negative control**
(`testLoginKeychainKeyCreatedByAPackagedHelperIsBlockedByItsPartitionList`) no
longer reproduces on the *development* Mac, whose login Keychain now grants
`/usr/bin/codesign` access. Evidence that this is host state rather than a code
regression — including a fresh-cdhash experiment — is in the defect-002
implementation record. The positive control still passes and no test was
weakened.

## Defect 002 detail

* Plan: [`PHYSICAL_DEFECT_002_CERTIFICATE_RECOVERY_PLAN.md`](PHYSICAL_DEFECT_002_CERTIFICATE_RECOVERY_PLAN.md)
* Lifecycle comparison: [`BUILD1_BUILD2_VANISH_SIGNING_COMPARISON.md`](BUILD1_BUILD2_VANISH_SIGNING_COMPARISON.md)
* Exact failure: `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift:1446`
* Classification: `MISSING_RECOVERY_CASE`, not a regression of Apple provisioning
* Support bundle: **`IOSSim-Support-1789611416.zip` is not archived.** The Build 2
  timeline in the plan is `INFERRED_FROM_SOURCE` until that bundle is added to
  `evidence/`.

Build 3 must satisfy defects 001 and 002 **together** — no Keychain-password
dialog *and* automatic, ownership-proven recovery from Veya's own obsolete
certificate.

* Implementation record: [`PHYSICAL_DEFECT_002_CERTIFICATE_RECOVERY_IMPLEMENTATION.md`](PHYSICAL_DEFECT_002_CERTIFICATE_RECOVERY_IMPLEMENTATION.md)
* Physical procedure: [`BUILD3_PHYSICAL_RETEST_HANDOFF.md`](BUILD3_PHYSICAL_RETEST_HANDOFF.md)
* Independent DMG audit: [`logs/defect002-independent-dmg-audit.log`](logs/defect002-independent-dmg-audit.log)

Build 3 artifact `Veya-0.1.0-build3-ea8269b-local-test.dmg`
(`d75908edc1989f4a5854a73c021077ce02266a9dfc698d113c9d060a7927d648`), built from
`ea8269b` with `dirty=false`. Full Swift suite 377 executed / 12 skipped / 0
failures. Acceptance gates are in section 21 of the defect 002 plan and the
success criteria of the handoff.

## Physical stage status

Observed on hardware during the build1 run:

| stage | status |
|---|---|
| Veya launch (Intel x86_64) | PASS |
| No-Xcode consumer path | PASS |
| Native iPhone discovery | PASS |
| Apple Account authentication and session | PASS |
| Personal Team discovery | PASS |
| Device registration / reuse | PASS |
| Derived App IDs | PASS |
| Main + Runner provisioning profiles, `PROVISIONING_READY` | PASS |
| Signing key access | **FAIL — defect 001** |
| DDI personalization | NOT REACHED |
| TSS / DDI mount | NOT REACHED |
| Native installation | NOT REACHED |
| RemotePairing | NOT REACHED |
| LocalDevVPN / software tunnel / RSD / RemoteXPC | NOT REACHED |
| AppService launch | NOT REACHED |
| Rich XCUILocation runtime | NOT REACHED |
| Reboot survival / renewal | NOT REACHED |
| Gatekeeper / notarization (public distribution) | OUT OF SCOPE — separate task |

Nothing below the signing row has been validated on hardware, and this fix
makes no claim about any of it.
