# Physical validation ledger

Tracks defects found by real physical validation of Installation V2.

Status vocabulary: `FOUND` → `INVESTIGATING` → `FIXED_SOFTWARE` →
`RETEST_REQUIRED` → `PHYSICALLY_VERIFIED`.

A defect reaches `PHYSICALLY_VERIFIED` only after the corrected artifact has
been run on real hardware and observed to pass. Software gates never confer it.

| # | Defect | Found on | Status | Fixed in | Retest artifact |
|---|---|---|---|---|---|
| 001 | `SIGNING_KEY_ACCESS_DENIED` on a clean Mac — the Personal Team signing key was created in the login Keychain, where `securityd` stamps it with a `cdhash:<creator>` partition that `/usr/bin/codesign` can never match | Intel x86_64, macOS 14.8.9 (23J631), no Xcode, `Veya-0.1.0-build1-1259da5-local-test.dmg` | **RETEST_REQUIRED** | `dd259bd` | `Veya-0.1.0-build2-dd259bd-local-test.dmg` (`a5cfa59e…`) |

## Defect 001 detail

* Report: [`PHYSICAL_DEFECT_001_SIGNING_KEY_ACCESS_DENIED.md`](PHYSICAL_DEFECT_001_SIGNING_KEY_ACCESS_DENIED.md)
* Reproduction evidence: [`repro/EVIDENCE_MATRIX.md`](repro/EVIDENCE_MATRIX.md)
* Test results: [`PHYSICAL_DEFECT_001_TEST_RESULTS.md`](PHYSICAL_DEFECT_001_TEST_RESULTS.md)
* Artifact: [`PHYSICAL_DEFECT_001_ARTIFACT.md`](PHYSICAL_DEFECT_001_ARTIFACT.md)
* Retest instructions: [`PHYSICAL_RETEST_001.md`](PHYSICAL_RETEST_001.md)
* Support bundle: `evidence/IOSSim-Support-1789592208.zip`

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
