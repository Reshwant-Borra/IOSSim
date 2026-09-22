# M12 Result — Automated Scenario Campaign

Status: **FAIL (required gate item open: M4)**. All other automated rows pass. Physical rows are not run.

## Campaign run (after all session changes)

| Suite | Result |
|---|---|
| Swift, full (`swift test`, signer dylib supplied) | 474 executed, 13 skipped, **1 failing test** (4 assertions): the M4 packaged gate, failing closed with `VEYA-KEY-001` |
| Rust workspace aarch64 | bridge 15/0, signer 12/0 (+1 ignored exact-payload) |
| Rust workspace x86_64 (Rosetta) | bridge 15/0, signer 12/0 |
| Exact Veya payload, in-process sign + Apple strict verify | 1/0 |
| `installation-baseline` (earlier run this session) | all steps PASS except macOS Swift (the same single M4 test) |
| Secret scan / legacy v2 guard / fmt / clippy | PASS |

Skips (13): 9 legacy SecIdentity/codesign Keychain integration tests (deleted in M11), 1 opt-in auth local-system
test (run separately: 5/0, no SecurityAgent), 1 opt-in local machine-identity probe, 1 opt-in development-DDI
network test, 1 packaged-artifact test needing `IOSSIM_V3_PACKAGED_APP`.

## Scenario coverage

| Scenario | Evidence | Level |
|---|---|---|
| Fresh install / relaunch / reinstall / reconnect / lease loss / crash-resume | M3 scenario fixtures (7) via VeyaQualify + journal fault suite | SIMULATED boundaries |
| Upgrade (key store across cdhash) | M4 packaged gate | **FAIL: BLOCKED_HUMAN (profile)** |
| IOSSim migration | `LegacyMigrationTests` | INTEGRATION_PROVEN |
| Key missing / corrupt / tampered / wrong installation | `SigningKeyStoreTests` | UNIT_PROVEN |
| Authorization-state corruption / tamper / v1 migration | `AppleAuthorizationKeychainRegressionTests` | LOCAL_SYSTEM_PROVEN |
| Certificate capacity / owned stale / unknown / second Mac / ambiguous issue | `CertificateReconciliationTests` | SIMULATED Apple |
| Profile expiry / mismatch / wrong cert / private entitlement | signer qualification tests | INTEGRATION_PROVEN |
| Signing interruption / cancellation / failed sign never publishes | signer + `PayloadTransactionTests` | INTEGRATION_PROVEN / SIMULATED |
| Install interruption / lost response / renewal false-success / device lost app | `PayloadTransactionTests` | SIMULATED device |
| Device disconnect / connection-generation change | M7/M9/M10 tests | SIMULATED |
| Pairing interruption / VPN pending, running-not-ready | `DeviceDomainsTests` | SIMULATED |
| Runtime failure, expiry, cleanup failure | `RuntimeReadinessTests` | SIMULATED |
| Journal corruption / candidate rollback-promotion / retention | journal + engine suites | UNIT_PROVEN |
| Intel build / Apple Silicon build | Rust both arches; universal packaging guard | LOCAL (Rosetta), clean Intel NOT_RUN |
| Packaging audit | guards, MPL, static legacy scan (18 legacy findings remain) | PARTIAL |
| Physical install/launch/DDI/pairing/VPN/runtime | — | BLOCKED_HUMAN |

## Continuation campaign (2026-09-21, after M6/M7/M9/M10 production integration)

| Suite | Result |
|---|---|
| `./iossim installation-baseline` | every step PASS except macOS Swift: bundle IDs, no-Xcode runtime/routing, artifact identity, device discovery, v2 secret scan (0), v2 legacy guard (0, now incl. subprocess rule), Rust fmt/check/clippy/tests, iOS shared checks, Rust release aarch64 + x86_64 |
| Swift, full (signer dylib supplied) | **497 executed, 13 skipped, 1 failing test** (4 assertions): the M4 packaged gate, still failing closed with `VEYA-KEY-001` (unchanged, expected) |
| Swift opt-in local-system auth (`IOSSIM_RUN_KEYCHAIN_INTEGRATION=1`) | 5/0; no SecurityAgent process |
| New/changed suites | `AppleDomainsTests` 10/0, `ShippedPayloadIntegrationTests` 1/0 (exact payload, real signer), `PayloadTransactionTests` 13/0, `ProductionWiringTests` 6/0, `CertificateReconciliationTests` 11/0, `LegacyMigrationTests` 3/0 |
| Rust workspace aarch64 / x86_64 (Rosetta) | bridge 15/0, signer 12/0 (+1 ignored) on both |
| Exact Veya payload sign + Apple strict verify (`--ignored`) | 1/0 arm64, 1/0 x86_64 |
| `check_legacy_signing_routes.py --scope all` | 16 findings in 8 files (was 18/9); all on the legacy route (see M11) |

Skips (13, unchanged categories): 9 legacy SecIdentity/codesign keychain integration (deleted with the legacy route),
1 opt-in auth local-system (run separately: 5/0), 1 opt-in local machine identity, 1 opt-in development-DDI network,
1 packaged-artifact (`IOSSIM_V3_PACKAGED_APP`).

### New scenario coverage (SIMULATED_APPLE unless noted)

| Scenario | Evidence |
|---|---|
| Fresh Apple account → certificate for the key-store key → both profiles; idempotent rerun with zero Apple mutations | `AppleDomainsTests` |
| No/expired session → sign-in action, zero Developer Services calls | `AppleDomainsTests` |
| Capacity full (unknown certs) → `VEYA-CERT-046`, no revoke; key rotation reclaims only own retired cert, only with `destructiveOwned` | `AppleDomainsTests` |
| Engine retries never exceed 1 revoke / 2 issues per transition | `CertificateReconciliationTests` |
| Lost CSR response, cert revoked elsewhere, renewal window, tampered DER, profile without our cert, device change | `AppleDomainsTests` |
| Exact payload: plan, per-team rewrite approval, non-Apple profile refused, nothing published, source intact | `ShippedPayloadIntegrationTests` (LOCAL_SYSTEM, real signer) |
| Two-bundle sign/install order, runner loss repair, rewrite refusal, staging GC | `PayloadTransactionTests` |
| DDI/pairing/VPN production coordinators behind read-only observations; app reinstall invalidates pairing/VPN | `ProductionWiringTests` |
| Full production composition: all 13 domains observed; fails closed at the key store on builds without M4 | `ProductionWiringTests` |

Status remains **FAIL (required gate item open: M4)**; physical rows remain BLOCKED_HUMAN.
