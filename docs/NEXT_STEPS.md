# Next Steps

Do not merge, redesign runtime architecture, replace signing architecture, or
replace `devicectl` until the relevant phase below calls for it.

## Immediate Boundary: Download Authentication and UI

Continue only on `work/automated-xcode-rppairing-bootstrap`. Implement a
licensed, independently reviewed adapter that authenticates directly with
Apple's developer-download service and returns an ephemeral authorized request
to `AppleXcodeArchiveDownloader`. Then wire the existing bootstrap states into
the Mac setup UI.

Do not reuse the Personal Team Developer Services session without proof that
Apple supports that session for downloads. Do not copy the reviewed
`XcodesLoginKit` source unless its licensing is resolved. Password, 2FA,
cookies, and authorization headers must not enter checkpoints or logs.

## Phase 1: Local Opt-In Bootstrap Integration

With the authentication adapter and UI complete:

- exercise catalog/authentication with deterministic fixtures;
- test password, 2FA, expired-session, cancellation, resume, and low-disk paths;
- run one explicit opt-in official archive download only after displaying disk
  requirements;
- verify archive identity, signature, Apple Team ID, and Gatekeeper status;
- install under a distinct IOSSim-owned Xcode name;
- do not change global `xcode-select` or disturb existing Xcode;
- require explicit license consent before `xcodebuild -runFirstLaunch`;
- prove the selected per-process `DEVELOPER_DIR` passes the bounded
  `devicectl`/CoreDevice probe.

## Phase 2: Same-Mac/Same-iPhone Pairing Regression

Test the experimental automatic pairing path on an explicit test iPhone:

- explicit selected-device identity remains stable;
- Apple computer-trust prompts remain user-controlled;
- the bundled helper creates and validates a new record over USB;
- transfer uses only the private app data container;
- failed validation preserves the existing Keychain record;
- successful validation commits the device-updated record;
- the non-secret receipt returns for the same transaction;
- disconnecting the Mac leaves Spoof and Drive working.

The current implementation regenerates the Mac candidate after a transfer
failure. Add a protected, non-loggable retry checkpoint only if physical
testing shows regeneration is disruptive; do not persist pairing material for
convenience without a security review.

## Phase 3: Frozen Runtime Requalification

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

## Phase 4: Clean-Mac Test

Use a fresh Mac with no IOSSim repo or copied local development state:

1. Install and launch the IOSSim DMG with no Xcode installed.
2. Choose automatic Apple developer-components installation.
3. Complete Apple download authentication and 2FA only inside IOSSim.
4. Approve the macOS-owned installation prompt.
5. Explicitly consent to the Xcode license step.
6. Let IOSSim run command-line first-launch initialization and qualify
   `devicectl`.
7. Never open Xcode or configure Xcode Accounts.
8. Connect, unlock, explicitly select, and trust the iPhone.
9. Complete Personal Team authorization, signing, installation, developer
   profile trust if required, runtime mapping, automatic pairing, and receipt
   verification.
10. Reach `COMPLETE`, disconnect the Mac, and test Spoof, Rich XCUILocation,
    and Rich Drive.

This is the qualification for the target claim: Xcode may be installed but the
user does not need to open or configure it.

## Phase 5A: If Clean-Mac Automatic Xcode Passes

If Phase 4 passes, keeping an installed-Xcode dependency can remain a product
decision. Then prioritize reliability, support reporting, refresh/expiry tests,
and Developer ID/notarization.

## Phase 5B: If Clean-Mac Automatic Xcode Fails

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
