# V7 exact native device / install parity report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Kept the existing Swift/Rust native device stack and hardened its consumer composition; no `devicectl`, `xcodebuild`, Python, or repository fallback was added.
- Added an operation-lifetime exact-device binding. Native discovery chooses deterministically by physical UDID, preferring USB and then the lowest mux identifier, and retains the resulting UDID + mux ID + connection type + connection generation for inventory, install, uninstall, launch, House Arrest, developer-support, and RemotePairing operations.
- Added `nativeDeviceIdentity` to the device backend boundary. The packaged helper now shares one `IdeviceProvisioningBackend` between authoritative inventory and every mutation, preventing later layers from reducing the selected connection back to a bare UDID.
- Added schema-1 `NativeApplicationInstallReceipt`. Successful native installation is now backed by an exact post-operation InstallationProxy inventory match for bundle ID, team ID, and version, plus a deterministic local app-tree SHA-256 and secret-safe exact-device metadata.
- Added interruption reconciliation: if InstallationProxy loses the response after applying an install, the operation succeeds only when a fresh inventory proves the exact expected bundle/team/version; otherwise the original failure is preserved.
- Changed upgrade behavior to fail closed before mutation when an existing bundle has a different or unavailable team identity.
- Changed native uninstall to require the expected team, inspect before mutation, refuse wrong/unknown ownership, and verify absence afterward. The legacy overload without ownership context fails with `NATIVE_OWNERSHIP_CONTEXT_REQUIRED` on the packaged native backend.
- Routed signed prepared artifacts with their expected Personal Team through the production consumer path and mapped `NATIVE_OWNERSHIP_CONFLICT` to the existing explicit cross-team conflict outcome.
- Made the Rust InstallationProxy inventory reader use `CFBundleVersion` when `CFBundleShortVersionString` is absent, preserving exact version verification for minimal and test payloads.
- Updated no-Xcode routing audits to prove the shared exact-identity backend composition.

## Acceptance evidence

- Focused Swift gate: 30 tests executed, zero failures. Coverage includes exact USB selection from duplicate USB/wireless entries, no process-runner/devicectl fallback, device metadata in install receipts, exact team/version verification, wrong and unknown ownership, verified uninstall, and applied/not-applied interruption outcomes.
- Native Rust bridge: 10 tests passed, including exact UDID/mux/connection selection independent of enumeration order and rejection of ambiguous legacy selection.
- Broad safe Swift suite: 324 tests executed, 9 explicitly opt-in/local-system/physical tests skipped, zero failures, zero unexpected.
- Five synthetic device-discovery CLI tests and six artifact-identity tests passed.
- Both no-Xcode runtime/routing audits and `git diff --check` passed.
- No real phone, Apple account, production Keychain identity, app installation, uninstall, pairing record, or VPN state was touched.

## Safety and compatibility

- Unknown or wrong-team installed apps are never removed or overwritten by the packaged native path.
- An explicit Fresh Install request does not weaken deterministic ownership proof; it now stops on uncertain or cross-team native inventory rather than destroying an app based only on its bundle-name pattern.
- Existing device enumeration, retained RSD behavior, AppService launch transport, House Arrest, RemotePairing, and the Rich XCUILocation runtime were not replaced.
- Development-only devicectl code remains present for comparison tooling but is not reachable from packaged consumer composition.

## Physical validation deferred

- Confirm InstallationProxy exposes exact team/version fields on each supported iOS release.
- Exercise native fresh install and upgrade over a retained USB connection, then disconnect/reconnect between operations.
- Confirm a duplicate USB/network appearance always mutates the chosen USB handle and never silently switches connections.
- Confirm AFC/PublicStaging transfer, install interruption reconciliation, House Arrest read/write, owned uninstall, Developer Mode and lock/trust error mapping, and AppService prerequisite reporting on a real supported iPhone.

## Known limitations

- AppService operational readiness and launch receipts are completed at V12; Rich XCTest readiness remains V13.
- Transactional signing/profile candidate lifecycle is V9. V7 consumes the already prepared signed copy and enforces its expected team at the device boundary.
- Physical InstallationProxy field availability is not inferred from synthetic service fixtures. If a supported iOS build omits team/version metadata, the current code intentionally fails closed pending a stronger ownership source.

## Gate

Synthetic/unit native parity is deterministic, packaged consumer device operations retain exact connection identity, native install has an inventory-backed receipt, uninstall cannot target unknown ownership, and no packaged consumer operation requires devicectl or xcodebuild. Physical phone proof remains explicitly outstanding.
