# Implementation Phases and Validation Gates

## Phase 0: baseline protection

Freeze runtime and add regression tests for Gate 3, rich samples, smooth 2 Hz, pause/resume/hold/clear, generations, auth vectors, artifact manifests and journal interruptions. Success is repeatable tests with runtime files unchanged.

## Phase 1: auth

Final AKD normalizer, URL-bag endpoint, safe redirects, 2FA parity, transient session classification and redacted diagnostic harness. AUTH GATE is challenge/2FA/team response rather than init 503. Rollback is adapter flag, no device mutation.

## Phase 2: native identity/readiness

Rust USB/Lockdown identity, trust/lock, Developer Mode and transport. NO-XCODE DEVICE GATE: clean Mac without full Xcode detects model/iOS/UDID and reports trust/Developer Mode. Rollback is native feature flag, never hidden devicectl.

## Phase 3: DDI/RSD

DDI cache/provider, TSS personalization, AMFI, CoreDeviceProxy/RSD and capability. DDI gate requires approved asset provenance and physical iOS 17.4/18/26 cells. Failure becomes unsupported/action, not re-sign.

## Phase 4: application operations

AFC staging, Installation Proxy install/upgrade/uninstall, inventory, AppService launch, House Arrest read/write. INSTALL GATE: no devicectl, sign/install both artifacts, exact IDs, launch and receipt readback. Upgrade must preserve app data in physical fixture.

## Phase 5: automatic pairing

RemotePairing create/reuse, Keychain, app inbox/receipt, RSD/TestManager proof. PAIRING GATE: no ordinary plist handling, stale repair bounded and device-bound.

## Phase 6: readiness/onboarding

Domain graph, setup journal, recovery and simple UI; crash/reboot/disconnect/network resume without repeating valid work.

## Phase 7: renewal

Mac-assisted expiry/profile refresh/re-sign/upgrade with pairing/data preservation.

## Phase 8: clean-host release

Universal signed/notarized app, bridge integrity, SBOM/license review, fresh Mac without full Xcode/repo/Python/Node/Rust completes setup.

## Phase 9: cellular

Qualify existing automatic pairing, LocalDevVPN, retained RSD/TestManager and rich runner for Mac-off and carrier/network transitions. Later, not architectural blocker.

## Phase 10: optional autonomous refresh

Only after reliable Mac-assisted renewal and account-security design.

Hard gates: AUTH; NO-XCODE DEVICE; DDI; INSTALL; PAIRING; runtime sequence RSD_READY -> TESTMANAGER_CONTROL_READY -> TESTMANAGER_MAIN_READY -> DVT_READY -> RUNNER_LAUNCHED -> PID_AUTHORIZED -> XCTEST_HANDSHAKE_READY -> TEST_PLAN_STARTED -> FINISHED; RICH LOCATION; DRIVE; CLEAN HOST; RECOVERY; RENEWAL. Physical results are not claimed by this research.

## Phase Execution Contract

| Phase | Prerequisites | Main source areas | Required tests | Success criteria | Failure criteria | Rollback boundary |
|---|---|---|---|---|---|---|
| 0 | current HEAD and historical fixtures | iOS runtime tests, Mac auth/provisioning tests | unit, deterministic scheduler/generation, fixture snapshots | frozen behavior represented and green | missing deterministic coverage for clear/drive/Gate 3 | tests only |
| 1 | Phase 0 auth fixtures | ApplePersonalTeamLive, Experimental adapter, AuthDiagnostic | metadata matrices, SRP vectors, redirect/TLS/redaction | AUTH GATE on current packaged build | init still 503 or diagnostics could leak secrets | request-identity adapter feature flag |
| 2 | pinned Rust lock/ABI skeleton | RuntimeProvisioningSupport, new bridge/identity, provisioner | Rust fixtures, fake usbmux/Lockdown, Swift ABI tests | NO-XCODE DEVICE GATE with stable identity | wrong-device possibility, unknown treated ready, helper integrity failure | native bridge feature flag; no device mutation |
| 3 | Phase 2 trusted DeviceSession, approved development fixture | DDIManager, Rust mounter/TSS/RSD | manifest selection, cache corruption, TSS fixture, fake RSD | exact DDI and developer service capabilities on target matrix | stale asset accepted, unbounded retry, no approved source | evict only failed cache entry; preserve signing/pairing |
| 4 | Phases 2-3 | ConsumerArtifactProvisioner, InstallationInventory, Rust install/AFC/AppService | staged bytes, callback/error parsing, inventory, path allowlist, upgrade data | INSTALL GATE and zero consumer devicectl | exact IDs/receipt/readback absent or data lost | journaled operation; uninstall requires consent |
| 5 | Phase 4 main app installed/launchable | PairingCoordinator, phone PairingStore/validator/setup UI | semantic/replay/identity fixtures, fake pair/RSD, inbox cleanup | PAIRING GATE and no manual plist | wrong peer, secret leak, regeneration on generic error | quarantine one device record |
| 6 | all lower layer observations | ReadinessEngine, journal, SetupStore, IPC | transition graph, crash point fault injection, multi-device | RECOVERY and consumer onboarding gates | repeated valid work, wrong device, giant Boolean | retain prior manifest adapter read-only |
| 7 | phases 1,4,6 | RenewalCoordinator, artifact/signing stores | expiry/revocation/interruption/upgrade preservation | RENEWAL GATE | uninstall/data loss/pairing destruction | retain old installed app/profile until verified |
| 8 | phases 0-7 | packaging/release scripts, notices, support export | universal launch, signature/notarization, secret scans | CLEAN HOST GATE | Xcode/repo/Python dependency or unreviewed asset | do not ship |
| 9 | stable release candidate | phone runtime integration tests only | carrier/Wi-Fi transitions, Mac-off retained session | documented supported cellular matrix | fresh retarget/transition unproven | cellular feature remains unqualified |
| 10 | reliable renewal and explicit security design | future phone refresh components | threat model, account/session lifecycle, expiry | separately approved autonomous flow | credential/session risk | omit feature |

## Gate Evidence Artifacts

Every physical gate records product/bridge build hashes, macOS/iOS versions, device model class with redacted identifier, action sequence, typed readiness transitions, duration, outcome and support-bundle secret scan. AUTH evidence records no account identifier or request values. DDI evidence records asset/build hashes but not payload. Runtime/Drive evidence records stage/cadence metrics without route coordinates unless the tester explicitly authorizes a private fixture.

The CLEAN HOST gate uses a Mac without full Xcode and verifies there is no xcrun, devicectl, xcodebuild, xcode-select or DEVELOPER_DIR dependency in consumer logs/processes. Build-time Xcode use is outside that host. A failed gate reopens the phase that owns it, not the frozen phone runtime by default.
