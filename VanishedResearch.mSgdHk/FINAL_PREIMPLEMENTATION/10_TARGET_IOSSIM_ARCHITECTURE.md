# Target IOSSim Architecture

SwiftUI -> SetupStore/IOSSimSetupEngine -> ReadinessEngine/SetupJournal -> signed IOSSimProvisioner -> ApplePersonalTeamLive, DeviceBridge, PairingCoordinator, InstallationCoordinator, RenewalCoordinator and Diagnostics. DeviceBridge calls a pinned Rust idevice ABI for usbmux/Lockdown, AMFI, DDI/TSS, AFC/House Arrest, Installation Proxy, CoreDeviceProxy/RSD/RemoteXPC, AppService and DVT capability.

The iPhone remains: IOSSim -> LocalDevVPN -> RPPairing Keychain -> retained RSD -> TestManager/DVT -> XCTest runner -> XCUILocation -> LocationCoordinator/Rich Drive. Swift owns UI, account, Keychain, signing and policy; Rust owns device bytes; phone owns runtime. Host does not replace rich simulation.

DeviceBridge operations are discover, inspect, trust, developerMode, prepareDDI, install, upgrade, uninstall, listApps, launch, read/write container, ensure/validate pairing and open RSD. Every result contains selected identity, capability, receipt and typed error. No arbitrary shell/API.

## Component Responsibilities

| Component | Owns | Must not own |
|---|---|---|
| SetupStore | presentation and user commands | protocol retries, secret state, string error inference |
| IOSSimSetupEngine/BundledProvisioningEngine | versioned SwiftUI-to-provisioner IPC and cancellation | device protocol implementation |
| ReadinessEngine | domain dependency graph and next action | arbitrary mutation or single global ready Boolean |
| SetupJournal | safe durable evidence and workflow transactions | credentials, private keys, live handles |
| ApplePersonalTeamLive | GSA/SRP/2FA, scoped session, Developer Services | device selection, pairing or runtime recovery |
| DeviceBridge Swift facade | typed device API, identity enforcement, FFI ownership | UI policy or Apple credentials |
| Rust bridge | usbmux/Lockdown/developer/file/install protocols | arbitrary shell, Keychain or user decisions |
| DDIManager | asset source/cache, personalization/mount receipts | signing/pairing regeneration |
| InstallationCoordinator | signing-output validation, install/upgrade/inventory/launch/container receipts | Apple login or phone runtime control |
| PairingCoordinator | host Keychain record, RP policy, phone delivery/receipt | location state or certificate renewal |
| RenewalCoordinator | profile/sign/upgrade plan | autonomous phone credential storage |
| Diagnostics | allowlisted structured export | raw protocol payloads/secrets |
| iPhone setup ingress | envelope validation/import/receipt | host-device discovery or signing |
| Existing iPhone runtime | tunnel, retained service session and location intent | Mac provisioning |

## End-to-End Setup Data Flow

1. Discovery returns DeviceIdentity and DeviceToken. SetupStore selects a token, never a raw user-editable UDID.
2. ReadinessEngine observes host/device. User satisfies unlock, trust and Developer Mode.
3. ApplePersonalTeamLive authenticates, discovers team and produces Keychain/session/profile/signing receipts.
4. InstallationCoordinator verifies artifacts, stages through AFC, installs/upgrades through Installation Proxy and verifies exact inventory.
5. PairingCoordinator creates/reuses an RP record, launches phone bootstrap, transfers envelope through House Arrest and validates receipt.
6. Phone LocalDevVPN and existing runtime prove RSD/TestManager/XCTest/rich capability.
7. ReadinessEngine marks domains independently and enables Spoof/Drive only when their dependency graph is READY.

## Failure Isolation

All external mutations are transactional in the journal. Auth can be retried without touching phone state; DDI can be repaired without signing; installation can be upgraded without pairing regeneration; pairing can be repaired without re-provisioning; tunnel/runtime can reconnect without replaying user intent. The selected DeviceToken and operation UUID flow through every receipt.

## Compatibility Surfaces

There are three explicit versions: Swift IPC schema, Swift/Rust ABI, and phone setup-envelope/receipt schema. The packaged manifest states compatible ranges. A mismatch is helperIncompatible and requires a signed app update, not best-effort parsing. Rust upstream changes occur only by reviewed pin updates with fixture and physical gates.
