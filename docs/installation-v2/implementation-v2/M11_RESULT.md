# M11 Result — Packaging and Legacy Removal

Status: **PARTIAL: packaging gates hardened; safe removals done; ROUTE SWITCH + LEGACY DELETION BLOCKED_HUMAN**
(on M4 and on physical proof of the new route). Per spec 04/27 the old signer is removed only after the exact Veya payload installs and launches
through the new path. Removing it earlier would leave the product with no working signer.

## Done

| Gate | Change | Evidence |
|---|---|---|
| Universal bridge, no stale dylib | `build_app.sh` refuses a bridge whose `lipo -archs` differs from `config/release.json` or that lacks `veya_signing_abi_version` | universal passes; host-only and Build 11 bridges refused |
| Workspace artifact paths | `build_app.sh`/`iossim_cli.py` use `native/target/...` and `native/Cargo.lock`; path sanitizer is root-based | review + guard |
| MPL-2.0 compliance | `ThirdPartyNotices/MPL-2.0-Notices.txt` generated from the shipped dependency graph (9 crates; license text + exact source location); packaging fails if absent | generator run |
| Baseline coverage | `installation-baseline` now tests/lints the whole Rust workspace (it previously built only the bridge manifest, so signer tests never ran there) and runs the Swift signer facade against a real dylib (previously 2 skips) | baseline log |
| Static legacy guard | `scripts/checks/check_legacy_signing_routes.py`: `--scope v2` (new modules + signer crates) must stay at 0 findings and is in the baseline; `--scope all` is the M11 exit instrument | v2: 0; all: 18 findings in 9 files |
| Offline signing | the signer crate graph has no HTTP/timestamp path; Apple verification is `NO_NETWORK_ACCESS` | static |

## Legacy removal worklist (`check_legacy_signing_routes.py --scope all`, today)

`PersonalTeamProvisioningPOC.swift`, `ProvisioningProfileInspector.swift`, `ApplePersonalTeamDiscovery.swift`,
`ApplePersonalTeamLive.swift` (codesign ×5, ACL ×5), `ConsumerArtifactProvisioner.swift` (codesign ×7),
`NativeSigningIdentityResolver.swift` (codesign, SecIdentity, security CLI), `VeyaSigningKeychain.swift`
(codesign, search list, ACL, custom keychain), `VeyaSigningQualification.swift`, `IOSSimSigningKeyTestHelper`.
The 9 legacy Keychain/codesign integration tests that currently skip (`IOSSIM_RUN_KEYCHAIN_INTEGRATION`) are
deleted with them.

## Required before Build 12 (from the M4 resolution pass)

The Keychain-accessing helper must be the main executable of a bundle that carries an embedded provisioning
profile (for example `Contents/Helpers/VeyaProvisioner.app`), team-signed, hardened, with
`keychain-access-groups`. Not implemented blind: the layout is only verifiable with a real profile (AMFI).

## Not done

Consumer no-tool/no-network runtime proof on clean Apple Silicon and Intel hosts; mounted-DMG audit (no
Build 12 DMG exists, correctly).

## Continuation (2026-09-21)

### Done now (safe without M4 / physical proof)

| Change | Effect |
|---|---|
| Production composition builds only `InProcessPayloadSigning` (or `UnavailablePayloadSigning`, which fails closed) and `LiveApplePersonalTeamBackend.installationV2()`, whose legacy identity store is `RetiredLegacyIdentityKeychain` (refuses every call) | Legacy signing cannot become a fallback of the new route, even by accident |
| v2 static guard gained a spec-27 "subprocess execution" rule (`Process()`, `ProcessRunner`, `posix_spawn`, `std::process::Command`); only the client that launches the helper is allowlisted; verified to fire on a probe file | No `codesign`/`security` or any subprocess can enter engine/payload work |
| `/usr/bin/security cms -D` replaced by in-process CMS decoding in `ProvisioningProfileInspector`, `ConsumerArtifactProvisioner.decodedProfile`, `ApplePersonalTeamDiscovery.decodeProfile` | `--scope all` findings 18 → 16; fewer subprocesses on the shipping route |
| v2 pairing store on the M4 backend (`com.veya.remote-pairing.v2`) | No login-Keychain item for the new route |

### Remaining legacy code (`check_legacy_signing_routes.py --scope all`: 16 findings in 8 files)

| File / route | Legacy use | Why it cannot be deleted yet |
|---|---|---|
| `SetupStore.runProvisioningBody` → `BundledProvisioningEngine.consumerProvision` → helper `consumer-provision`, `consumer-resume-setup`, `consumer-reconcile`, `consumer-runtime-ready` | The shipping UI route | The UI must switch to `ProvisionerEngineClient` (`EngineRequest(reconcile, device, capabilities)`). On every build without a profile-granted key store (all current ad-hoc builds) the new route fails closed at `.signingKey` (`VEYA-KEY-001`), so switching now would leave no working install path. Spec 27: remove only after the new route installs and launches on the iPhone. |
| `ConsumerArtifactProvisioner.swift` (codesign ×7) | Payload signing via `/usr/bin/codesign` | Same route as above |
| `NativeSigningIdentityResolver.swift` (codesign ×2, SecIdentity ×2, `security` ×1) | Keychain identity resolution for codesign | Same route |
| `VeyaSigningKeychain.swift` (custom keychain, search list, `security` ×2) | Plaintext-equivalent signing keychain (open P1, retired by removal) | Same route; M8 never imports its key |
| `ApplePersonalTeamLive.swift` (codesign ×1, ACL ×4): `IOSSimIdentityMetadataStore`, `prepareIdentity`, `ensureCertificateCapacity`, `CertificateOwnership` | Legacy identity + machineId-based reclaim | Used by the shipping UI coordinator (`ExperimentalConsumerProvisioningCoordinator.prepareProvisioning`) |
| `ApplePersonalTeamDiscovery.swift` (`security find-certificate`), `PersonalTeamProvisioningPOC.swift` (`security find-identity`, `codesign -d` ×2) | Xcode-account discovery and doctor diagnostics | Legacy Xcode-managed backend and `doctor`; go with the route |
| `VeyaSigningQualification.swift`, `IOSSimSigningKeyTestHelper` | Qualification tooling for the legacy keychain | Tests of the still-shipping route (9 opt-in skips) |
| `KeychainRemotePairingStore` default (`com.iossim.remote-pairing.v1`, login Keychain, no UI-fail) | Legacy pairing store | Used by the legacy route's pairing coordinator |
| `ConsumerProvisioningStateStore` cached-READY | Legacy READY | Legacy UI state |

### Exact removal set for the route switch (after M4 + physical proof)

1. `SetupStore`: replace `engine.consumerProvision(…)` / `provisionDevice` with `ProvisionerEngineClient.send(EngineRequest(command: .reconcile, device:, connectionGeneration:, capabilities:))`; drive UI state from `QualificationResult`.
2. Delete `ConsumerArtifactProvisioner.swift`, `NativeSigningIdentityResolver.swift`, `VeyaSigningKeychain.swift`, `VeyaSigningQualification.swift`, `Sources/IOSSimSigningKeyTestHelper/` (+ `Package.swift` target), `ApplePersonalTeamDiscovery.swift`, the legacy helper commands above, and in `ApplePersonalTeamLive.swift` the `IOSSimIdentityMetadataStore` / `prepareIdentity` / reclaim ladder (then `RetiredLegacyIdentityKeychain` and `IOSSimManagedIdentityKeychain`).
3. Delete their tests: `NativeSigningIdentityIntegrationTests`, `VeyaSigningKeychainRegressionTests`, `CertificateCapacityRecoveryTests`, the `prepareIdentity` cases of `ApplePersonalTeamLiveTests`, legacy `ConsumerProvisioningTests`.
4. Make `KeychainRemotePairingStore` require a backend (drop the v1 default); M8 inventories the v1 items.
5. Gate: `check_legacy_signing_routes.py --scope all` must report 0 findings.

## M11-A (2026-09-22, `65cddeb`)

Deleted the `personal-team-poc` helper command, `AppleSigningIdentityInspector`, `SigningGraphInspector` and
`PersonalTeamPOCInspectionReport`. Nothing called them (no UI, engine, script, or test caller). The shared parsers
stay. `--scope all`: 16 → 14 entries in 7 files.

Everything else in the removal set still requires M4, the `SetupStore` route switch, and a physical run through the
production composition. None of it depends on the DDI decision.

Additional gaps found:
- M8 does not inventory `com.iossim.remote-pairing.v1`.
- `--scope v2` does not scan the `Services/` files that the v2 path uses.
