# V11 LocalDevVPN consumer lifecycle report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Kept LocalDevVPN explicitly external. Veya owns detection, compatibility policy, request delivery, lifecycle interpretation, launch guidance, resume, endpoint proof, and diagnostics; the user retains App Store installation and Apple's VPN approval.
- Replaced the former missing/action/ready collapse with explicit lifecycle states: `MISSING`, `INSTALLED_UNSUPPORTED`, `INSTALLED`, `VPN_PERMISSION_REQUIRED`, `CONFIGURED`, `RUNNING`, and `RUNTIME_ENDPOINT_REACHABLE`.
- Added typed `VEYA-VPN` failures and distinct setup guidance for incompatible app, permission pending, configured-but-not-running, and runtime-endpoint unavailable states.
- Bound phone setup requests and receipts to request ID, device UDID, team identity, and release identity. Stale or cross-context receipts fail closed.
- Made the phone inbox scene-aware. Pending setup and pairing work is reprocessed whenever the scene becomes active instead of relying on a one-shot `.task` invocation.
- Retained pending LocalDevVPN requests until readiness so foreground/reopen can resume after App Store installation, VPN approval, or tunnel restart.
- Added an explicit compatibility contract for `com.jkcoxson.LocalDevVPN` (App Store ID `6755608044`), minimum `1.0.0`, supported major `1`, observed current App Store version `1.3.0`, setup protocol schema `2`. No version is marked physically qualified yet.
- Added the external dependency contract to artifact/release metadata and raised the phone payload capability schemas for scene-resumable setup and pairing receipts.

## Acceptance evidence

- Focused macOS LocalDevVPN/artifact suite: 11 tests passed, zero failures.
- Tests cover missing app, unsupported version, VPN permission pending, configured but stopped, running with endpoint unavailable, endpoint ready, and bound receipt behavior.
- iPhone `POCUnitChecks` passed with the schema-2 lifecycle expectations.
- Unsigned generic iOS-device build succeeded, compiling and linking the scene-reactivation changes against the target's device-only native library.
- The simulator build compiled sources but was rejected at link because the existing vendored `libidevice_ffi.a` contains iOS-device objects rather than simulator objects; this is a target-fixture limitation, not a LocalDevVPN source failure.
- Broad safe macOS suite executed 335 tests with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected.
- Six artifact-identity tests, no-Xcode runtime/routing audits, and `git diff --check` passed.

## Safety and ownership

- Veya does not install LocalDevVPN, approve its VPN configuration, or bypass iOS consent.
- Compatibility detection requires the exact bundle identifier and a supported semantic version range.
- Receipt state is contextual, not global: a receipt for another request/device/team/release cannot satisfy the current setup.
- Request/receipt files contain lifecycle metadata only; no pairing record, PSK, Apple credential, token, or private signing key is written.

## Physical validation deferred

- App Store installation and the currently published LocalDevVPN build on a supported iPhone.
- Apple's VPN configuration approval and denial paths.
- Scene foreground/reopen after installation, approval, expiration, tunnel stop, and tunnel restart.
- Real software-tunnel endpoint reachability and compatibility across supported iOS versions.

## Known limitations

- The current endpoint check is bounded TCP reachability to the configured RSD endpoint. Cryptographically bound developer-services and AppService proof is owned by V12; the bounded Rich runtime proof is owned by V13.
- App Store version `1.3.0` is observed metadata, not a physical compatibility claim. `physicallyTestedVersions` intentionally remains empty.
- The external dependency remains a public-production dependency and must be disclosed in the final release manifest and user experience.

## Gate

Veya now distinguishes missing app, unsupported version, missing VPN approval, configured/stopped, running/endpoint unavailable, and endpoint-ready states; resumes work on scene activation; and preserves all Apple approval boundaries. Real phone and VPN validation remains required.
