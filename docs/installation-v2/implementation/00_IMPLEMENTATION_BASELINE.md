# Installation V2 implementation baseline

Captured at `2026-09-16T02:32:51Z` before any Installation V2 production edit.

## Source identity

- Workspace: `/Users/rishiborra/Desktop/IOSSim`
- Branch: `work/final-no-xcode-setup-v1`
- HEAD: `1259da507ecded222022cc86bf82863c15640db9`
- Origin: `https://github.com/Reshwant-Borra/IOSSim.git`
- Research inventory: `sameBranch=true`, `sameHead=true`, `changedOrMissing=[]`, 412 baseline files
- Initial `git diff --check`: PASS
- Root `AGENTS.md`: none present (the reference-only tree is excluded from project instructions)

The current dirty worktree is the authoritative implementation input. GitHub main is historical evidence only. No reset, clean, restore, stash, merge, rebase, checkout, commit, or push was performed.

## Safety captures

- Exact pre-implementation porcelain status: `pre-implementation-status.txt`
- Exact tracked binary-capable patch: `pre-implementation-tracked.patch`
- Tracked patch size: 382,107 bytes
- Status capture size: 4,580 bytes
- Secret boundary: these captures contain tracked source diffs and path/status metadata only. No Keychain data, Apple credentials, pair records, pairing PSKs, private keys, or session material was queried or added.

## Pre-existing worktree

There were 44 tracked modified paths and 44 untracked status entries. The complete authoritative path list is preserved verbatim in `pre-implementation-status.txt`. The tracked modifications span the existing iPhone lifecycle/runtime work, Mac setup/provisioning services and models, tests, packaging scripts, the native Rust bridge, and safe check scripts. The untracked work includes engineering reports, pre-existing app/artifact snapshots, the full `docs/installation-v2/` research set, new phone/Mac services and tests, and check scripts.

Because `docs/installation-v2/` was already one untracked directory entry, this implementation directory does not change the recorded pre-existing untracked entry count.

## Authoritative architecture material

Read completely before production changes:

- Installation V2 `README.md`, documents 00 and 17–27, 29–40
- Vanish reference `README.md`, documents 00–04 and 10–20
- `evidence/RESEARCH_LEDGER.md`

Primary authority is `vanish-reference/20_VANISH_INFORMED_MASTER_IMPLEMENTATION_PLAN.md`. Newer current-code evidence wins over stale older claims without creating a third architecture.

## Current architecture state

- Preserve `SetupWizardView -> SetupStore -> IOSSimSetupEngine -> BundledProvisioningEngine -> Contents/MacOS/IOSSimProvisioner -> ConsumerArtifactProvisioner`.
- Packaged setup already uses the embedded helper and has no repository fallback.
- Native discovery, inspect, install, House Arrest, personalized-image mount, RSD/AppService, Personal Team provisioning, automatic pairing delivery, LocalDevVPN integration, and Rich runtime foundations exist.
- Known gaps include artifact-derived release truth, hermetic tests, process-safe keyed state, first Lockdown pairing ABI, approved DDI acquisition, exact connection selection, staged RemotePairing proof/promotion, full VPN lifecycle, real Rich readiness proof, renewal, allowlisted support export, and canonical distribution.
- Public fresh-machine zero-Xcode remains blocked by the unapproved production DDI provider policy. Development/local-test work may use an explicitly classified provider and public release must fail closed.

## Test baseline

- Latest saved Swift log: `.build/iossim/logs/20260915T182122Z-mac-swift-test.log`
- Size: 91,925 bytes
- Saved result: 279 tests, 7 skipped, 36 assertion failures, 1 unexpected failure
- Research classification: stale expectations, broken fixtures/mocks, and test-isolation defects; not all failures are presumed stale
- Research-safe checks previously passed: no-Xcode consumer source check, install-routing source check, five synthetic discovery tests, and `git diff --check`
- No real device, Apple account, Personal Team, signing identity, production Keychain, pairing, phone installation, or VPN mutation is authorized by this baseline.

## Baseline verdict

`PASS` — source identity and all 412 researched paths match the frozen baseline. Implementation may proceed milestone-by-milestone.
