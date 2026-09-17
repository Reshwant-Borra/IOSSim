# Keep, refactor, replace, delete matrix

| Component | Decision | Target |
| --- | --- | --- |
| `SetupStore` | REFACTOR | UI/application state only; typed actions/errors; no protocol/persistence details |
| `IOSSimSetupEngine` | KEEP + REFACTOR | Versioned V2 operation/status contract |
| `BundledProvisioningEngine` | KEEP + REFACTOR | Fixed embedded helper, integrity/schema handshake, bounded pipe protocol |
| `DevelopmentCLIEngine` | DELETE from product; temporary dev-only | Direct in-memory fakes and explicit developer CLI replace it |
| `UnavailableIOSSimSetupEngine` | KEEP + REFACTOR | Typed integrity failure, never “doctor” wording |
| `IOSSimProvisioner` | KEEP + REFACTOR | Sole mutation composition root and cross-process lease owner |
| `ConsumerArtifactProvisioner` | KEEP + REFACTOR | Domain reconciliation state machine and receipts |
| `ConsumerProvisioningBackend` | REFACTOR | Remove public backend preference/automatic fallback; native production only |
| `IdeviceProvisioningBackend` | KEEP | Native production composition, split into domain services as needed |
| `ConsumerProvisioningStateStore` | REPLACE implementation | Keyed schema-5 journal/snapshot/lease store with legacy importer |
| `NativeProvisioningArtifactStore` | REPLACE implementation | Team/device/artifact-keyed owner-only profile records |
| `ApplePersonalTeamExperimental` | REFACTOR/RENAME | Stable `ApplePersonalTeamService` domain API |
| `ApplePersonalTeamLive` | REFACTOR | Versioned private adapter hidden below service; kill switch/compat fixtures |
| `NativeSigningIdentityResolver` | KEEP + REFACTOR | Exact managed identity, candidate rotation, cleanup inventory |
| `NativeDeviceBridge.swift` | KEEP + REFACTOR | ABI v2, initial Lockdown pairing, exact mux selector, typed receipts |
| `NativeApplicationManagement` | KEEP | Inventory/install/upgrade/uninstall; add candidate/receipt contracts |
| `NativeDeveloperServicesCoordinator` | KEEP + REFACTOR | DDI/RSD/AppService service receipts and retry boundary |
| `DeveloperSupportCoordinator` | KEEP + REFACTOR | Existing-cache provider plus policy-gated approved provider |
| `RemotePairingLifecycle` | REFACTOR | Request-bound AEAD, candidate slots, possession/operational proof, promotion |
| `LocalDevVPNSetupCoordinator` | REFACTOR | External-app state machine, version compatibility, authenticated endpoint proof |
| `RuntimeProvisioningSupport` | REFACTOR | Preserve Rich runtime; delete production devicectl/Xcode backends |
| `SupportBundleExporter` | REPLACE export schema | Explicit allowlist DTO, per-export salt, secret scanner |
| `AutomaticPairingInbox` | REFACTOR | Request-bound bootstrap, candidate store/proof/promotion |
| `LocalDevVPNSetupInbox` | REFACTOR | Persistent pending request and scene activation reconciliation |
| `DvtLocationClient` | KEEP | Preserve supplied-RSD and fallback behavior; adapt only proof hooks |
| iPhone app root | REFACTOR | `scenePhase` activation for pairing/VPN; retain runtime |
| Rust native bridge | KEEP + REFACTOR | Pairing ABI, selector fix, ABI receipts, bounded inputs |
| `macos/scripts/build_app.sh` | REPLACE as thin wrapper or DELETE | One Python/release-library assembler, no duplicate schema literals |
| `scripts/bootstrap/iossim_cli.py` | REFACTOR | Canonical builder/auditor/publisher; split testable modules if needed |
| `./iossim release-local` | KEEP + REFACTOR | Same pipeline/gates as public, local distribution class |
| `./iossim release` | KEEP + REFACTOR | Canonical Veya build, sign, notarize, mount, manifest, publish |
| Release manifest/sidecar | REPLACE | Signed artifact-derived manifest V2 |
| Legacy Xcode/devicectl fallbacks | DELETE from production | Xcode remains release build-time only |
| Existing payload/runtime | KEEP | Rich/XCUILocation/TestManager, DVT fallback, scheduler invariants |
| Bundle/signing identifiers | KEEP during functional work | Migrate only in branding milestone with dual-ID plan if approved |

Deletion is gated by source checks, migration coverage, and physical parity. No milestone deletes a last-known-good resource or fallback before the replacement passes its acceptance gate.
