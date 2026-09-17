# Setup engine inventory

| Component | Current responsibility | Production reachability | Finding |
| --- | --- | --- | --- |
| `SetupStore` | UI state, doctor/device refresh, auth/2FA/team selection, calls engine, maps errors | Direct | Keep as presentation/application coordinator; remove persistence and protocol detail |
| `IOSSimSetupEngine` | Typed GUI-to-engine contract | Direct | Keep and version responses |
| `BundledProvisioningEngine` | Executes embedded helper with bounded deterministic environment | Direct | Keep; add signature/hash/schema handshake and operation ID |
| `UnavailableIOSSimSetupEngine` | Represents missing helper | Direct on packaging failure | Keep, but emit `VEYA-INTEGRITY` rather than “doctor” process wording |
| `DevelopmentCLIEngine` | Invokes repository/development CLI | Development build | Keep outside public target, then delete once test harness has direct fakes |
| `IOSSimProvisioner` | Process boundary, JSON CLI, composition root | Direct | Keep; make one versioned protocol and cross-process lease owner |
| `ConsumerArtifactProvisioner` | Provision/reconcile/install/checkpoint orchestration | Direct | Keep/refactor into explicit domain steps |
| `ConsumerProvisioningBackend` | Selects native/legacy backend | Native path direct; legacy code remains | Collapse public configuration to native only |
| `IdeviceProvisioningBackend` | Native device/developer/pairing/VPN composition | Direct | Keep |
| `ConsumerProvisioningStateStore` | One manifest + JSONL events | Direct | Replace storage layout/API with keyed transactional store |
| `NativeProvisioningArtifactStore` | One profile-blob envelope | Direct | Replace singleton with keyed encrypted/owner-only artifact records |
| `ApplePersonalTeam*` | Private auth and provisioning | Direct | Keep behind `ApplePersonalTeamService` adapter boundary |
| `NativeDeviceBridge`/Rust | Device C ABI | Direct | Keep/refactor ABI and selector |
| `RemotePairingCoordinator` | RemotePairing create/validate/deliver | Direct | Refactor proof and replacement transaction |
| `LocalDevVPNSetupCoordinator` | Request/launch/receipt/endpoint readiness | Direct | Refactor lifecycle and compatibility checks |
| `DeveloperSupportCoordinator` | Existing cache discovery | Direct | Keep as provider; add approved-source policy later |
| `SupportBundleExporter` | Schema-7 support JSON and zip | Direct | Replace whole-struct export with allowlisted V2 schema |

## Ownership conclusion

There should remain one production engine. The GUI owns user interaction; the embedded helper owns serialized mutations; domain services own checks and repairs; stores own atomic persistence; Rust owns typed device protocols. SetupStore must never know GrandSlam constants, filesystem layout, pairing bytes, DDI paths, or helper command construction.

The helper’s top-level development commands and source-level legacy backends create audit noise and accidental routing risk. V2 first disconnects them from the public product, then deletes them after equivalent developer diagnostics exist. `CONFIRMED_LOCAL_IOSSIM_CODE`
