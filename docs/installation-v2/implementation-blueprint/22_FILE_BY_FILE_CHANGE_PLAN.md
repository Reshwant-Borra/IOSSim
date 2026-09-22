# File-by-File Change Plan

## Swift production

| File | Current responsibility | Target responsibility | Action |
|---|---|---|---|
| `SetupStore.swift` | UI state and overlapping orchestration | Presentation adapter over provisioner status/commands | MODIFY |
| `IOSSimSetupEngine.swift` | linear setup protocol | Compatibility client protocol only, then remove | MIGRATION_ONLY |
| `ConsumerOnboardingCoordinator.swift` | separate setup coordinator | none after canonical engine | REPLACE |
| `BundledProvisioningEngine.swift` | helper invocation/protocol | typed `ProvisionerClient` | MODIFY |
| `ConsumerProvisioningStateStore.swift` | manifest/events/rich state | artifact staging helper; journal is authority | SPLIT |
| `KeyedSetupStateStore.swift` | independent setup journal | superseded by `InstallationJournalRepository` | REPLACE |
| `ConsumerProvisioningFaultInjection.swift` | provisioning-local faults | shared boundary failure schedule in tests | REPLACE |
| `ApplePersonalTeamExperimental.swift` | Apple auth/API/provisioning mix | parsers/SRP/transports split by domain | SPLIT |
| `ApplePersonalTeamLive.swift` | auth, team, cert, key, metadata | Apple auth/team/cert/profile services; no keychain signer | SPLIT |
| `VeyaSigningKeychain.swift` | dedicated Keychain/search list/ACL | none | DELETE after migration |
| `NativeSigningIdentityResolver.swift` | SecIdentity and codesign identity | none | DELETE |
| `ConsumerArtifactProvisioner.swift` | payload prep/profile/codesign/install | builder + transaction service; Rust signer | SPLIT |
| `ProvisioningProfileInspector.swift` | profile parsing | independent validator | KEEP/MODIFY |
| `NativeDeviceBridge.swift` | Swift/Rust dynamic ABI facade | sole `DeviceTransport` implementation; signer ABI facade split | SPLIT |
| `NativeApplicationManagement.swift` | inventory/install/launch | domain application installer | KEEP/MODIFY |
| `DeveloperSupportCoordinator.swift` | DDI orchestration | bounded DDI service | MODIFY |
| `DeveloperSupportDevelopmentProvider.swift` | development provider | debug/qualification only | KEEP |
| `NativeDeveloperServicesCoordinator.swift` | runtime service checks | transport primitive, no READY | MODIFY |
| `NativeLockdownPairing.swift` | Lockdown pairing | device transport operation | KEEP/MODIFY |
| `RemotePairingLifecycle.swift` | candidate pairing lifecycle | journal-integrated transaction | MODIFY |
| `LocalDevVPNSetupCoordinator.swift` | VPN setup | exact state/evidence coordinator | MODIFY |
| `RichRuntimeReadiness.swift` | Rich proof | generation-bound final proof | MODIFY |
| `ReadinessRecovery.swift` | recovery helper | planner rules | SPLIT |
| `VeyaDiagnostics.swift` | current error taxonomy | stable event/error registry | REPLACE/MIGRATE cases |
| `SupportBundleExporter.swift` | diagnostic export | schema/redaction-aware exporter | MODIFY |
| `ProductBrand.swift` | IOSSim compatibility constants | legacy reader + Veya v2 paths | SPLIT |
| `IOSSimProvisioner/main.swift` | many direct commands/composition | sole mutation host + versioned engine API | MODIFY |
| `IOSSimAuthDiagnostic/main.swift` | auth diagnostic | thin qualification alias or remove | MIGRATION_ONLY |
| `IOSSimSigningKeyTestHelper/main.swift` | legacy ACL prompt test | obsolete after migration | DELETE |

## New Swift files

`InstallationDomainModels.swift`, `VeyaReconciliationEngine.swift`, `ReconciliationPlanner.swift`, `InstallationObservers.swift`, `InstallationTransitions.swift`, `InstallationJournal.swift`, `InstallationJournalRepository.swift`, `InstallationEvent.swift`, `VeyaFailure.swift`, `AppleAuthorizationService.swift`, `PersonalTeamService.swift`, `SigningKeyStore.swift`, `SigningKeyEnvelope.swift`, `InProcessSigner.swift`, `CertificateReconciler.swift`, `ProvisioningProfileService.swift`, `ProfileSignInstallTransaction.swift`, `DeviceTransport.swift`, `DeveloperSupportProvider.swift`, `RuntimeReadinessService.swift`, `IOSSimMigrationReader.swift`, `VeyaMigrationCoordinator.swift`, `ProvisionerProtocol.swift`; executable `macos/Sources/VeyaQualify/main.swift`.

## Rust

| File | Current | Target | Action |
|---|---|---|---|
| `native/iossim-device-bridge/Cargo.toml` | single bridge crate | workspace member depending on signing core | MODIFY |
| `native/iossim-device-bridge/src/lib.rs` | monolithic device FFI | module root and device ABI | SPLIT |
| `native/iossim-device-bridge/include/iossim_device_bridge.h` | device ABI | versioned device + signing ABI declarations | MODIFY |
| `Cargo.lock` | device deps | signer deps/checksums included | MODIFY |

New: root `native/Cargo.toml`, `native/veya-signing-core/{Cargo.toml,src/lib.rs,src/bundle_graph.rs,src/entitlements.rs,src/sign.rs,src/verify.rs,tests/*}`, bridge modules `src/ffi.rs`, `src/device/*`, `src/signing_ffi.rs`, and repository `rust-toolchain.toml`.

## iOS

Keep location/runtime logic. Modify `AutomaticPairingInbox.swift`, `PairingStore.swift`, `RPPairingValidator.swift`, `LocalDevVPNSetupInbox.swift`, and `RichRuntimeProofInbox.swift` for authenticated generation-bound envelopes/receipts. Add envelope/replay tests to `POCUnitChecks`. Do not change product UI except actionable Apple-controlled states required by protocol.

## Scripts, qualification, tests, docs

- Modify `macos/Package.swift` for `VeyaQualify` and new tests.
- Modify `scripts/bootstrap/iossim_cli.py`, `macos/scripts/build_app.sh`, artifact identity/check scripts for workspace/toolchain/signer/SBOM/gates.
- Replace `tools/qualification/VeyaPhysicalQualification.py` with a report wrapper around `VeyaQualify`; add scenario fixture validator and schema files.
- Keep valuable current tests but move expectations to domain services. Delete `HermeticInstallationHarnessTests` after equivalent production-engine scenarios exist. Delete legacy Keychain/codesign tests after migration/no-prompt coverage supersedes them.
- New tests mirror every new production module, plus `PackagedReconciliationTests`, `SigningGoldenFixtureTests`, `ReinstallScenarioTests`, `MigrationScenarioTests`, and `FailureInjectionCampaignTests`.

