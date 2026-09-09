# Next Steps

Do not merge, redesign runtime architecture, replace signing architecture, or
replace `devicectl` until the relevant phase below calls for it.

## Phase 1: Same-Mac/Same-iPhone Regression

Test the current RC:

```text
.build/iossim/local-release/IOSSim-0.1.0-local.dmg
sha256: 5ca34d69a9a80a1bf4469026c63e879a3d147f3f0c50e1cc436f1600134e18ba
source: 06478bab66e5dc117932cff1c9575c607c35b72e
classification: LOCAL_TEST_ONLY
```

Acceptance:

- existing authorization reused where valid;
- current signing identity reused;
- profiles reused where valid;
- signing succeeds;
- main installs;
- runner installs;
- automatic post-install inventory stabilization occurs;
- no false "Cannot Verify Installation";
- no unnecessary Try Again;
- no unnecessary Fresh Install;
- no false historical-team conflict;
- developer-profile trust is shown only if actually required;
- already-trusted profile skips the trust screen correctly;
- runtime configuration writes and verifies;
- setup reaches `COMPLETE`.

Do not require the tester to delete Apple account state, delete certificates,
delete profiles, remove Xcode state, reset the iPhone, or use another Mac for
this phase.

## Phase 2: Runtime Requalification

After Phase 1 passes, requalify the frozen iPhone runtime on the current flow:

- Gate 3 runner launch through retained RSD/TestManager;
- Spoof;
- Rich XCUILocation;
- Rich Drive;
- Rich / 2 Hz status;
- DVT / 1 Hz fallback behavior;
- pause/resume;
- Stop & Hold;
- Clear Simulation;
- destination hold;
- reconnect behavior;
- single-writer semantics.

This phase should not redesign the runtime.

## Phase 3: Audit Xcode Dependencies

Determine exactly what still requires:

- Xcode installed;
- Xcode first-launch initialization;
- Xcode license acceptance;
- Xcode Accounts;
- developer directory selection;
- `xcrun`;
- `devicectl`;
- CoreDevice;
- `xcodebuild`;
- iPhoneOS SDK;
- DeveloperDiskImage/developer services.

Document whether each dependency is build-time only, packaged runtime, consumer
setup-time, or iPhone runtime.

## Phase 4: Clean-Mac Test

Use a fresh Mac with no IOSSim repo or copied local development state:

1. Install Xcode.
2. Do not open Xcode.
3. Do not configure Xcode Accounts.
4. Install the IOSSim DMG.
5. Launch IOSSim.
6. Connect/unlock/trust the iPhone.
7. Authorize Apple Account inside IOSSim.
8. Run consumer setup through installation, trust if required, runtime config,
   and `COMPLETE`.

This is the qualification for the target claim: Xcode may be installed but the
user does not need to open or configure it.

## Phase 5A: If Clean-Mac Xcode-Only Passes

If Phase 4 passes, keeping an installed-Xcode dependency can remain a product
decision. Then prioritize reliability, support reporting, refresh/expiry tests,
and Developer ID/notarization.

## Phase 5B: If Clean-Mac Xcode-Only Fails

If Phase 4 fails because Xcode must be opened/configured or `devicectl` carries
unacceptable dependencies, remove the offending dependency. The likely path is a
native macOS host backend using the pinned idevice stack:

- usbmuxd
- lockdown
- AFC/PublicStaging
- InstallationProxy install
- InstallationProxy inventory

This should be a focused task after the setup state machine has passed physical
regression.

## Phase 6: Refresh and Expiry

Prove true Personal Team refresh behavior across a real profile renewal or
expiration boundary:

- new profile expiration is later than the previous expiration;
- same-team identifiers remain stable;
- app data is preserved;
- RPPairing state is preserved;
- runner mapping is preserved;
- Gate 3, Spoof, and Rich Drive still work;
- no unnecessary Fresh Install.

## Phase 7: Public Distribution

Complete public distribution only after the previous phases pass:

- Developer ID Application identity and private key installed on release Mac;
- `notarytool` credentials stored outside the repo;
- `./iossim release` succeeds;
- app and DMG notarization accepted;
- tickets stapled;
- Gatekeeper assessment passes;
- package audit passes;
- support export remains sanitized.

## Later Runtime Roadmap

Only after setup, installation, clean-Mac behavior, and release distribution are
stable:

```text
Gate 3
  -> Spoof
  -> Rich XCUILocation
  -> Rich Drive
```
