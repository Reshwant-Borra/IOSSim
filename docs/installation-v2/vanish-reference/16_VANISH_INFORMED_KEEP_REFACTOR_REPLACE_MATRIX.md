# Vanish-informed keep, refactor, replace, and delete matrix

| Component/path | Decision | Vanish behavior matched | Replacement/exit gate |
| --- | --- | --- | --- |
| `SetupStore` | REFACTOR | one guided setup and actionable failures | presentation-only store passes V2 state/action tests |
| `IOSSimSetupEngine` | REFACTOR | stable packaged engine contract | protocol handshake/action/cancel/status schemas pass |
| `BundledProvisioningEngine` | HARDEN | bundle-relative helper | signature/hash/schema/path checks pass in mounted DMG |
| `DevelopmentCLIEngine` | DELETE_LATER from consumer target | none; Vanish has no repo consumer path | packaged source scan + helper parity + rollback release complete |
| `IOSSimProvisioner` | REFACTOR | bundled installation owner | single reconciler surface and lease owner pass crash tests |
| `ConsumerArtifactProvisioner` | REFACTOR | automated sign/install/repair | domain reconciler fault tests pass |
| `ConsumerProvisioningBackend` | REFACTOR | one production backend | native policy proven; Xcode/devicectl selectors development-only |
| `ConsumerProvisioningStateStore` | REPLACE | resumable per-device state | keyed store, lease, journal, migration tests pass |
| `NativeProvisioningArtifactStore` | REPLACE | account/team/device-aware material | keyed encrypted/reference store migration passes |
| `ApplePersonalTeamExperimental` | REFACTOR/RENAME | helper-owned Apple flow | stable service boundary adopted |
| `ApplePersonalTeamLive` | REFACTOR | embedded account/2FA/provisioning | versioned adapter fixtures/kill switch/error taxonomy pass |
| `NativeSigningIdentityResolver` | HARDEN | reusable signing identity | renewal candidate/promotion/access probe tests pass |
| `NativeDeviceBridge.swift` | REFACTOR ABI v2 | bundled device stack | exact connection and first-pair tests pass |
| native bridge header/lib | REFACTOR | usbmux/trust/device-service ownership | ABI compatibility, pair_once, connection identity gates pass |
| `Cargo.toml`/lock | KEEP PIN; HARDEN audit | bundled stack | reproducible build, SBOM/license gate |
| `NativeApplicationManagement` | KEEP/HARDEN | inventory/install/repair | staged install/post-inventory fault gates |
| `NativeDeveloperServicesCoordinator` | KEEP/REFACTOR | DDI then tunnel/RSD | provider receipts and AppService gates |
| `DeveloperSupportCoordinator` | REFACTOR | on-demand DDI acquisition | approved provider decision + clean-cache qualification |
| `RemotePairingLifecycle` | REFACTOR | automatic place/repair | candidate/challenge/operational proof/crash gates |
| `AutomaticPairingInbox` | REFACTOR | phone-side automatic pairing | request binding, candidate slots, promotion tests |
| `LocalDevVPNSetupCoordinator` | REFACTOR | guided external runtime dependency | install/approval/endpoint state gates |
| `LocalDevVPNSetupInbox` | REFACTOR | phone-side setup request | scene/resume/replay tests |
| `DvtLocationClient` | KEEP/HARDEN proof hook | Veya-specific Rich runtime | no cadence/writer regression; bounded proof gate |
| `RuntimeProvisioningSupport` | REFACTOR | ready means actual operation | proof service and no production legacy routes |
| `SupportBundleExporter` | REPLACE | useful consumer diagnostics | allowlist/secret-negative corpus passes |
| `ArtifactManifest` | REFACTOR | one identifiable artifact | mounted-artifact-derived V2 manifest |
| `ConsumerProvisioning` | REFACTOR schema 5 | explicit progress/recovery | migration, invalidation, serialization gates |
| `DoctorStatus` | REFACTOR | dependency health, not command error | typed integrity/domain health UX |
| `build_app.sh` | REPLACE/DELETE_LATER | one package path | canonical assembler equivalence proven |
| `iossim_cli.py` | REFACTOR | canonical DMG/update source | artifact-derived manifest and publish verification |
| no-Xcode checks | KEEP/EXTEND | clean consumer dependency boundary | CI rejects regressions |
| Xcode/devicectl consumer fallbacks | DELETE_LATER | no Vanish analog | native physical parity and rollback release |
| repo lookup/environment backend selector | DELETE_LATER | violates self-contained rule | production factory/integrity tests pass |
| old release builder/desired-value sidecars | DELETE when canonical pipeline lands | one artifact identity | two consecutive audited releases |
| schema 4 reader | KEEP for migration, DELETE_LATER | upgrade continuity | supported migration window expires |

No component is replaced merely because Vanish uses Python or Rust differently. Decisions follow ownership and evidence in the Veya worktree.
