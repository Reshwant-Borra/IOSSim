# Phase 0 freeze snapshot

Captured 2026-09-18 in `America/New_York`. This is an evidence snapshot, not a claim that the working tree is reproducible. No state was deleted, revoked, reset, uninstalled, committed, pushed, rebased, cleaned, stashed, published, notarized, or packaged during this audit.

## Repository

| Field | Value |
| --- | --- |
| Branch | `work/final-no-xcode-setup-v1` |
| HEAD | `fd4fbfe364383f83b053ae13e6c96ec3af4fbfd6` |
| Configured product/version/build | `Veya` / `0.1.0` / `11` |
| Bundle identifier | `com.iossim.mac-provisioner` |
| Configured architectures | `arm64`, `x86_64` |
| Distribution class | production configuration, but production DDI source remains unresolved and local artifacts are `LOCAL_TEST_ONLY` |

The pre-audit worktree was dirty. Modified paths included `config/release.json`, `macos/Package.swift`, Apple authorization/signing source and tests, and Veya signing-Keychain source and tests. Untracked paths included this qualification corpus, `tools/`, Graphify output, and an authorization-Keychain regression test. This audit preserves those changes and does not attribute them to this phase.

## Installed application

`/Applications/Veya.app` was present as `0.1.0 (11)`, bundle ID `com.iossim.mac-provisioner`, universal `x86_64 arm64`, ad-hoc signed with hardened runtime, and without a Developer ID TeamIdentifier. This is a local qualification installation, not a consumer distribution proof.

## Build artifacts

All eleven local DMGs were present in `.build/iossim/local-release/`:

| Build | SHA-256 |
| ---: | --- |
| 1 | `0bbc112d7ef191190da2afce0067012392e6ec31719330d9e85a8aa7633d4a72` |
| 2 | `a5cfa59e7355b9a89482280b1c9546ebf5a892c8c19071c0b8895333c19ab2e7` |
| 3 | `d75908edc1989f4a5854a73c021077ce02266a9dfc698d113c9d060a7927d648` |
| 4 | `a9b74cf6a1440dbc3f092b2ac91d7245317a715193fb22514f7c5bb70c8815bf` |
| 5 | `72d36df1b5ec28609b22795a99b577659dc14aa66387bef86da702a920e0916c` |
| 6 | `2d88792652641088383732c8486abbb00cc41d7520eef5fa2775c01d71c5faa4` |
| 7 | `29e7cfd28f0a80846bce84cc16858fbb0864d607b95a6b441f6277e7906e09d3` |
| 8 | `81880997245f394fb8f3a1f33fe00e95f3ac34e0d2568f503d011b3aba578557` |
| 9 | `c75b8f40eb2dc349f2afdf159fcfdb6444d334b2413446219da0356cb430a189` |
| 10 | `cb58d36922b980a9ee4e01dd7d06231cde31a5c3d427bd1206aea2d855113462` |
| 11 | `3f8967b9969925651b784eb3c08e5a0c5012c4e14b9815a4db2bfb8b0e977399` |

Build 11's DMG, checksum sidecar, release JSON, explicit-attach output, screenshots, live state, timeline, matrix, report, and artifact history remain in their original repository locations. The DMG is 16,501,564 bytes. This table and the original files are the preservation manifest; no evidence was rewritten.

## Physical device

At the live-harness capture time, one physical iPhone 17 Pro was reported `available (paired)`. At the later audit snapshot, CoreDevice reported the physical devices unavailable. Raw device identifiers are intentionally omitted. No pairing, Trust, phone, or account state was changed.

## Persisted Veya/IOSSim state

Observed namespaces include:

- `~/Library/Application Support/IOSSim/`: provisioning manifest/events, native artifacts, setup journal, runtime proof, signing metadata, and signing-Keychain secret.
- `~/Library/Application Support/IOSSimMac/`: Apple Personal Team diagnostics and authorization material.
- `~/Library/Preferences/com.iossim.mac-provisioner.plist`.
- `~/Library/Keychains/Veya-Signing.keychain-db` plus login-Keychain entries created by older builds.
- Existing phone pairing, installed-app, profile, Apple certificate, and developer-service state.

The user Keychain search list included the Veya signing Keychain and duplicated login-Keychain entries. No secret values or raw identifiers were read into this report.

## Last authoritative failure

Build 10/11-era diagnostics show:

```text
PERSONAL_TEAM_FOUND
SIGNING_IDENTITY_LOOKUP_STARTED
MANAGED_IDENTITY_METADATA_MISSING
UNEXPECTED_ERROR
```

One preceding run scanned several locally managed key tags, spending tens of seconds on individual lookups, without recording a per-operation outcome. Another run reached `MANAGED_IDENTITY_RECOVERY_STARTED` and then `UNEXPECTED_ERROR`. No `KEYPAIR_CREATED` followed. This bounds the failure to metadata recovery/key lookup or fresh-key creation/ACL construction, but the current telemetry cannot prove the exact first failing API.

## Evidence quality warning

`LIVE_ARTIFACT_HISTORY.md` records only Builds 8-11 and labels Builds 9-11 pending even though later screenshots and diagnostics exist. `LIVE_QUALIFICATION_MATRIX.md` reports Build 3 for every row. Several files named as Build 6, 10, or 11 failure screenshots show unrelated browser content. These artifacts are retained, but filenames alone are not treated as physical proof.

