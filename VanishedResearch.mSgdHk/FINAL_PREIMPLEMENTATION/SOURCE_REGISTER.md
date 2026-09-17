# Source Register and Evidence Rules

Research date: 2026-09-14. IOSSim was inspected read-only. No Apple login, SRP probe, pairing, device connection, image mount, installation, signing, or physical transition was executed. Public repositories were downloaded only for source inspection into references/. They are research snapshots, not dependencies installed into IOSSim.

## Evidence Labels

- CONFIRMED: directly observable in the pinned source or supplied durable evidence.
- STRONG_EVIDENCE: corroborated public reports/source, without an IOSSim reproduction in this pass.
- LIKELY: selected engineering inference, still subject to the stated implementation gate.
- UNKNOWN: no sufficient evidence; do not silently convert to supported behavior.
- REQUIRES_PHYSICAL_VALIDATION: deferred hardware qualification.
- REJECTED: not appropriate for this build.

READY_TO_BUILD means architecture and implementation boundaries are actionable. It does not mean authentication is fixed, no-Xcode has been physically proven, or the product is approved for public distribution.

## IOSSim and Prior Evidence

IOSSim baseline: branch work/fix-apple-srp-503; HEAD 0a18e986f40fd877a1aab1e91e4c6a87217c7c81; local origin/main ed233af070f5b751c22f6d8b9f86f4fc01885ce7. No fetch changed these refs. Tracked tree clean; untracked VanishSetup.dmg and tools/ left untouched. One worktree, /Users/rishiborra/Desktop/IOSSim.

All eleven files in ../DOCUMENTATION/00_RESEARCH_INDEX.md through 10_UNKNOWNS_AND_FUTURE_RESEARCH.md were read. They remain authoritative for Vanish facts; E01-E31 remain their original evidence identifiers. Particularly E25-E28 establish the incomplete host abstraction and richer IOSSim runtime. See ../DOCUMENTATION/09_EVIDENCE_REGISTER.md and ../DOCUMENTATION/10_UNKNOWNS_AND_FUTURE_RESEARCH.md. No new Vanish disassembly was needed.

IOSSim docs/CURRENT_STATE.md and docs/PHYSICAL_VALIDATION.md preserve historical physical evidence but their branch/HEAD descriptions are older than this audit. Their earlier runtime successes must not be represented as a clean-host or current-RC qualification.

## Pinned Public Sources

| Key | Source | Audited revision / version | Why it matters |
| --- | --- | --- | --- |
| RUST | [jkcoxson/idevice](https://github.com/jkcoxson/idevice/tree/1838db107d38701b4044361163aac049006c2627) | 1838db107d38701b4044361163aac049006c2627; 0.1.67; Sep 12 | Host service APIs, pairing, userspace tunnel, MIT |
| PMD | [pymobiledevice3](https://github.com/doronz88/pymobiledevice3/tree/fc0d053411fa1d3c9e80efc17962dc6b4e50526d) | fc0d053411fa1d3c9e80efc17962dc6b4e50526d; Sep 14 | Current implementation, not Vanish's older 9.12.0 |
| PYPI | [pymobiledevice3 package](https://pypi.org/project/pymobiledevice3/11.12.5/) | 11.12.5, uploaded Sep 13; Python >=3.9 | Current published version; wheel 1,256,320 bytes, NOT whole runtime |
| ISI-MAIN | [isideload main](https://github.com/nab138/isideload/tree/b6d111376657a59207ac26c8ef8be5cca8793cba) | b6d111376657a59207ac26c8ef8be5cca8793cba; 0.3.17 | Default branch still has stale Xcode client token |
| ISI-RELEASE | [isideload release branch](https://github.com/nab138/isideload/tree/f6a4d5dba717d72fc2af63eaba26b27ba44116be) | f6a4d5dba717d72fc2af63eaba26b27ba44116be; apple-codesign-quick; Sep 10 | Correct AKD token and pooling correction used by iloader |
| ILOADER | [iloader](https://github.com/nab138/iloader/tree/348eefd7de78e9bc612c9d619b8b1e7a80ba3ba0) | 348eefd7de78e9bc612c9d619b8b1e7a80ba3ba0; 2.3.3 | Cargo.lock confirms release isideload pin, operational reference |
| XTOOL | [xtool](https://github.com/xtool-org/xtool/tree/4208c77c8128568f8b938d0c67d2f4bdcf04e100) | 4208c77c8128568f8b938d0c67d2f4bdcf04e100; Sep 10 | Maintained independent Swift XKit GrandSlam implementation |
| XCODES | [XcodesLoginKit](https://github.com/XcodesOrg/XcodesLoginKit/tree/929f9aac3140caf7b64cbb5385f4f645c5f9913d) | 929f9aac3140caf7b64cbb5385f4f645c5f9913d; Sep 11 | IDMSA web auth, not a GSA Developer Services replacement |
| LIMD | [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice/tree/fa0f79190142bc309307967c058f89c1b36eb6b8) | fa0f79190142bc309307967c058f89c1b36eb6b8; Jun 10 | Mature classic services; current personalized image support |
| DDI | [DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage/tree/5423e4e955fbb3a9eef3e1212acfbfc6e7a26236) | 5423e4e955fbb3a9eef3e1212acfbfc6e7a26236; package 0.3.0 | Actual PMD image acquisition; third-party Apple-asset mirror |
| OLD-ADI | [apple-private-apis](https://github.com/SideStore/apple-private-apis/tree/03beb1aa42991ccdad6214dee77e72282bef461f) | 03beb1aa42991ccdad6214dee77e72282bef461f; Nov 2024 | Historical local AOSKit reference, not claimed current working |

## Auth Incident Evidence

- [isideload PR 11](https://github.com/nab138/isideload/pull/11): September 2026 client-info correction, merged into release branch, reports successful auth after correction.
- [AltStore PR 1790](https://github.com/altstoreio/AltStore/pull/1790): independent isolation of Xcode token rejection; changing OS/version/UA alone did not resolve reported failures.
- [iloader releases](https://github.com/nab138/iloader/releases): 2.3.2 addresses 503, 2.3.3 addresses subsequent connection-pooling/429 issue.
- [SideStore issue 1446](https://github.com/SideStore/SideStore/issues/1446): app-token-stage 503 with successful prior stages; explicitly a different failure location.

Reported observations are not an Apple contractual explanation or a newly executed IOSSim test.

## Official References

- [Apple: Enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple: Trust This Computer](https://support.apple.com/en-us/109054)
- [Apple: Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
- [Apple: Additional Xcode Components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
- [Apple: Packaging Mac Software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Apple developer agreements](https://developer.apple.com/support/terms/)

License conclusions are engineering diligence, not legal advice. Code licenses do not establish rights in Apple's developer images, frameworks, or service usage.

## Reproduction of This Audit

Read DEPENDENCY_SEARCH_APPENDIX.txt for all 736 output lines of the broad source/documentation/test search. Generated caches, binary DMGs and Rust target output were excluded from text matching. tools/ contains no source outside target in this checkout. Its untracked compiled artifacts are not an auditable build input. Follow source paths/functions in 01 and 02 rather than treating documentation mentions as commands.

No installed package, reference project's test harness, or Apple-facing command was executed. Missing physical results are implementation acceptance gates, not invented research tasks.

