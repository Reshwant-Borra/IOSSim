# M5 Result — In-Process Signer

Status: **SOFTWARE_GATE_PASS / PHYSICAL_BLOCKED_HUMAN**. Build remains `11`. The signer is
implemented, qualified locally on both Mac architectures, and still **dark** (not routed into the
production install path; routing is M7). The blueprint exit criterion "exact Veya payload physically
installs/launches on the qualification device under a controlled test certificate" is not met and is
not claimed.

## Architecture (unchanged from the in-progress M5 work)

`veya-signing-core` (Rust, MPL-2.0) using `isideload-apple-codesign =0.29.11` → versioned C ABI in
`iossim-device-bridge` (`VEYA_SIGNING_ABI_VERSION 1`) → Swift `InProcessSigner` facade that obtains the
PKCS#8 only through `VeyaSigningKeyStore.withUnlockedPKCS8`. Copy source → sign the disposable candidate
in place → Veya structural verification → Apple `SecStaticCodeCheckValidity` (all-arch, nested, strict,
no-network) → source-immutability check → `RENAME_EXCL` publication.

## Defects found and fixed this session

| ID | Class | Finding | Fix | Regression test |
|---|---|---|---|---|
| M5-D1 | UPSTREAM_DEFECT | Any symlink in a bundle produced an invalid seal (`-67054`). Root cause: `isideload-vfs 0.0.1` `DirEntry::file_type()` calls `metadata` (follows links), so `isideload-walkdir` classifies symlinks as regular files and `apple-codesign` seals them with their target's bytes. Our Apple verifier caught it; nothing was published. | Refuse bundles containing symlinks before any mutation (`InvalidRequest`). iOS bundles are flat; the exact Veya payload has none. | `internal_symlink_is_refused_before_mutation` |
| M5-D2 | BUILD_DEFECT | `build_app.sh` packages `native/target/release/libiossim_device_bridge.dylib`, which a plain host `cargo build --release` also writes (single-arch). A stale or pre-signer dylib could ship silently. | Packaging now refuses a bridge whose `lipo -archs` differs from `config/release.json` or lacks `veya_signing_abi_version`. Verified: universal passes, arm64-only and the Build 11 bridge are refused. | manual guard exercise (3 inputs) |
| M5-D3 | COMPLIANCE_GAP | Nine MPL-2.0 crates ship in the bridge, but packaging shipped only idevice/BigInt notices. | `write_mpl_notices` walks the normal-dependency graph from `cargo metadata --locked` and writes `ThirdPartyNotices/MPL-2.0-Notices.txt` (license text + exact crates.io source per crate); packaging fails if none are found. | generator run: 9 sections, 0 local paths |
| M5-D4 | LINT | `clippy -D warnings` failed (2 collapsible `if`, unused import). | Fixed. | clippy clean |
| M4-Z1 | HARDENING | `withUnlockedPKCS8` copied the decrypted `Data` into an array and zeroed only the copy. | The single decrypted buffer is cleared in place. | `SigningKeyStoreTests` 10/10 |

## Golden fixtures (spec 04 "Required fixtures")

| Fixture | Result | Level |
|---|---|---|
| Minimal app / appex / framework (existing nested test) | pass + Apple strict verify | INTEGRATION_PROVEN |
| **Exact Veya payload**: `IOSSim DVT POC.app` and `IOSSimLocationControlUITests-Runner.app` + `.xctest`, from the installed Build 11 `DeviceArtifacts`, starting from stale ad-hoc signatures | pass: Mach-O count exact, source unchanged, Veya + Apple strict verification, arm64 **and x86_64** | LOCAL_SYSTEM_PROVEN (synthetic identity) |
| Loose dylib, framework, appex, XCTest bundle, nested `.app`, plain resources; profiles only on `.app`/`.appex` | pass, 6 Mach-O, Apple strict verify | INTEGRATION_PROVEN |
| Stale signature (re-sign an already signed candidate) | pass + Apple strict verify | INTEGRATION_PROVEN |
| Malformed Mach-O | fails, no candidate, source unchanged, no temp residue | INTEGRATION_PROVEN |
| Code added after manifest approval | `InventoryMismatch` before mutation | INTEGRATION_PROVEN |
| Symlink / resource edge | escaping symlink rejected; internal symlink refused (M5-D1) | INTEGRATION_PROVEN |
| arm64-only payload | all fixtures and the Veya payload are arm64-only | INTEGRATION_PROVEN |
| Compare with a known-good Apple `codesign` fixture | substituted by Apple `SecStaticCode` strict validation of every output; a byte-level comparison with a keychain-identity `codesign` output is not performed | PARTIAL |

The exact-payload test is `#[ignore]` in plain `cargo test` because the payload is a build product; the
qualification command runs it with `VEYA_EXACT_PAYLOAD_DIR=<DeviceArtifacts> cargo test -- --ignored`.

## Test results (this session)

| Suite | Result |
|---|---|
| `cargo fmt --check`, `cargo clippy --workspace --all-targets -D warnings` | pass |
| `cargo test --workspace` (aarch64) | bridge 15/0, signer 12/0 (+1 ignored exact-payload) |
| `cargo test --workspace --target x86_64-apple-darwin` (Rosetta) | bridge 15/0, signer 12/0 |
| exact payload, `--ignored` | 1/0 on arm64 and x86_64 |
| release `iossim-device-bridge` for `aarch64`/`x86_64` | builds; 8 `veya_signing_*` exports each; no `/usr/bin/codesign` string |
| Swift `InProcessSignerTests` against the **universal release** dylib | 3/0 |
| Swift `SigningKeyStoreTests` (10 noninteractive) | 10/0 |
| `check_installation_v2_secrets.py` | 76 files, 0 findings |

## Network

The pinned signer has no HTTP or timestamp code path (no network dependency in its crate graph; no
`time_stamp_url` setting). Apple verification passes `kSecCSNoNetworkAccess`. Proven statically, and (continuation
2026-09-21) at runtime: the exact-payload sign + Apple strict verification test passes under
`sandbox-exec '(deny network*)'` (control: `curl` cannot resolve under the same profile). LOCAL_SYSTEM_PROVEN
for the signer binary; a packaged-app network-denied run is still NOT_RUN.

## Not proven / blocked

- **Physical install/launch of the signed exact payload** — BLOCKED_HUMAN: needs a real Apple Development
  certificate and profile from the user's Personal Team (M6 authorization) plus the connected iPhone. The
  positive FFI sign path cannot be exercised with a synthetic identity because production profile
  decoding requires Apple-signed CMS (by design).
- **Clean Intel Mac** — x86_64 proven only under Rosetta on Apple Silicon (SIMULATED for the Build 12 gate).
- **Packaged network-denied run** — NOT_RUN (the signer binary itself passes network-denied).
- **Production routing** — the old `/usr/bin/codesign` signer is still the shipping route (7 source files);
  replacement is M7, removal M11.
