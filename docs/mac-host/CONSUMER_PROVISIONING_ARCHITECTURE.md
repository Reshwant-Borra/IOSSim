# Consumer Personal Team Provisioning Architecture

Status: productized flow implemented, then extended by native live Personal Team
authorization and physical-install state stabilization. See
[../PROVISIONING_AND_SIGNING.md](../PROVISIONING_AND_SIGNING.md) for the current
authoritative flow.

## Boundaries

The production path is:

`SwiftUI -> IOSSimMacCore -> BundledProvisioningEngine -> IOSSimProvisioner -> Apple tooling`

The packaged app never searches for a repository and never invokes `./iossim`,
Git, Python, repository scripts, or an IOSSim Xcode project. Xcode's installed
device tooling remains required because the current physical path uses
CoreDevice/`devicectl`. The current native Personal Team path authorizes the
Apple Account inside IOSSim rather than requiring Xcode Accounts setup.

The iPhone runtime remains unchanged:

`LocalDevVPN -> RPPairing -> local RSD -> developer services -> retained TestManager/XCTest -> installed runner -> XCUILocation`

Normal Spoof stays independent of XCTest startup. Rich Drive retains its
long-lived session, 2 Hz rich transport, 1 Hz fallback, and single-writer rules.

## Artifact Strategy

The consumer Mac bundle contains two canonical, profile-free, re-signable
artifacts:

- `com.iossim.on-device-dvt-poc`
- `com.iossim.location-control-uitests.xctrunner`, including its `.xctest` and
  required nested XCTest code

Witness is not packaged or installed. The package contains no iPhone source or
Xcode project.

At install time `IOSSimProvisioner` uses the prepared native Personal Team
profiles when available. The older compatibility path can still create an
ephemeral minimal Xcode signing shell with placeholder Objective-C targets. The
helper then:

1. validates the profile TeamIdentifier and selected-device inclusion;
2. derives stable Personal Team main, UI-test, and runner identifiers;
3. copies the bundled IOSSim artifacts to temporary Application Support;
4. writes `IOSSimGate3RunnerBundleIdentifier` into the main app;
5. updates runner and embedded-test identifiers;
6. signs nested frameworks, dylibs, `.xctest`, runner, and main app;
7. verifies deep signatures, identifiers, Team ID, executable presence, and the
   runner/test identifier relationship;
8. installs only the main app and derived runner on the explicitly selected
   iPhone;
9. verifies exact current main and runner inventory on the selected device with
   bounded retry;
10. models Apple developer-profile trust as its own recoverable checkpoint;
11. launches IOSSim once and verifies the persisted runner mapping.

The generated signing shell and prepared signed products are temporary and are
removed after the operation. Profiles and signing credentials are not packaged.

## Identity Model

Canonical source identifiers remain frozen. Installed Personal Team main and
runner IDs use:

`com.personalteam.iossim.t<stable-team-hash>.on-device-dvt-poc`

`com.personalteam.iossim.t<stable-team-hash>.location-control-uitests.xctrunner`

The hash uses the actual Team ID only. It contains no account email, personal
name, device identifier, or random value. The same team always receives the same
main and runner IDs, so refresh and repair after the first derived install remain
in-place updates.

Team discovery joins three pieces of evidence:

- Apple Development certificate SHA-1 fingerprint;
- certificate subject `OU`, treated as the signing Team ID;
- decoded local provisioning-profile `TeamIdentifier` and embedded certificate.

Certificate display-name suffixes are never presented or interpreted as Team
IDs. The current native path asks for Apple Account credentials inside IOSSim,
treats password/2FA as ephemeral, and never asks for private key export or a
`.p12` password.

## State And Errors

`ConsumerArtifactProvisioner` implements typed stages from Mac and device checks
through identity preparation, signing, installation, verification, profile
inspection, on-device setup, and completion. Failures carry a stable code,
friendly message, remediation, and redacted developer detail.

Mac-side state is atomically stored at:

`~/Library/Application Support/IOSSim/provisioning-state.json`

The schema records safe device metadata, Team ID, source and installed IDs,
profile dates and fingerprints, install/refresh timestamps, runtime setup state,
and versions. The actual runner ID is also persisted inside IOSSim's iPhone app
storage through the proven Info.plist-to-persistent-settings mechanism.

Cross-team replacement is never automatic. A
`MismatchedApplicationIdentifierEntitlement` condition becomes
`CROSS_TEAM_UPGRADE_BLOCKED`. The user must explicitly confirm a fresh install,
which removes only the prior IOSSim main app and runner. LocalDevVPN and unrelated
apps are not touched.

A legacy canonical main install is likewise never silently replaced by the new
derived main identity. IOSSim reports `INSTALLED_IDENTITY_MIGRATION_REQUIRED` and
requires explicit Fresh Install confirmation because the bundle-ID change creates
a new iPhone app container. Cleanup accepts only canonical or strictly shaped
deterministic IOSSim main/runner IDs.

## Repair And Diagnostics

Repair reuses the same typed backend and preserves app data on same-team paths.
It does not equate repair with uninstall. A sanitized support export includes
versions, safe device metadata, selected Team ID, derived main and runner IDs,
profile expiration, stage results, and sanitized runtime diagnostics. It excludes
Apple credentials, private keys, provisioning blobs, pairing records, PSKs, and
raw device identifiers.

The existing one-shot `LocationCoordinator.rebuildRuntimeSession(reason:)`
recovery remains the only post-refresh runtime lifecycle addition. It is limited
to stale `com.apple.dt.testmanagerd.remote` or related retained-session failures,
retries once, and preserves RPPairing and LocalDevVPN configuration.
