# Personal Team Provisioning POC

Status: Cycle 2 physical validation PASS.

Productization status: the consumer orchestrator, packaged artifact boundary,
SwiftUI flow, refresh foundation, and sanitized diagnostics are implemented on
`work/consumer-personal-team-provisioning`. This does not retroactively expand
the POC proof. Productized-flow physical validation is recorded independently,
and true profile renewal remains pending until Xcode issues a profile with a
later expiration date.

The POC physically proves that IOSSim can use a free Apple Personal Team to sign,
install, refresh, and run the required on-device runtime pieces without changing
the Drive, XCUILocation, or XCTest feature behavior.

## Scope

The proven consumer install set is:

- IOSSim iPhone app
- IOSSimLocationControlUITests runner app
- Embedded `IOSSimLocationControlUITests.xctest`
- Nested XCTest frameworks and support dylib

Witness remains validation infrastructure and repository source. It is not part
of the consumer Personal Team install set for this POC.

The normal install backend remains `devicectl`. Replacing `devicectl` or solving
no-Xcode provisioning is out of scope for this POC.

## Physical Proof

Cycle 2 physically proved:

- free Personal Team main-app signing and install
- deterministic derived XCTest runner identity
- derived runner signing and install
- Gate 3 launch with the derived runner
- Rich XCUILocation
- normal Spoof
- Rich Drive at 2 Hz
- same-team refresh/update without uninstall
- repeated refresh/update
- persistent app data preservation
- persistent derived-runner mapping
- RPPairing state preservation
- no Witness requirement
- no duplicate runner
- automatic post-refresh runtime recovery architecture
- no changes to Drive/XCUILocation/XCTest feature behavior

Final on-device validation was completed without a manual Disconnect. Gate 3
reached `FINISHED`, rich XCUILocation worked, normal Spoof worked, Rich Drive
worked at 2 Hz, Drive Diagnostics reported Rich / 2 Hz, and no unexpected
fallback was observed.

## Source IDs

Protected source bundle identifiers remain:

- `com.iossim.on-device-dvt-poc`
- `com.iossim.location-witness`
- `com.iossim.location-control-tests`
- `com.iossim.location-control-uitests`
- `com.iossim.location-control-uitests.xctrunner`

The bundle-ID guard remains the source-of-truth check for development
configuration. Personal Team identifiers are derived only for generated artifacts
and local manifests.

## Derived IDs

For a selected team, generated Personal Team identifiers use:

`com.personalteam.iossim.t<stable-team-hash>.<role>`

The runner keeps the XCTest relationship:

`<derived-ui-test-bundle-id>.xctrunner`

The main app keeps `com.iossim.on-device-dvt-poc`. This preserved existing app
data during same-bundle-ID update testing. The UI-test bundle and xctrunner use
deterministic derived identifiers because the canonical runner bundle ID was not
available under the Personal Team.

The hash is deterministic from the Team ID and does not use Apple credentials,
email, device IDs, pairing material, or passwords. The same team receives the
same derived IDs on refresh.

The installed runner ID is written into the refreshed main app's
`IOSSimGate3RunnerBundleIdentifier` Info.plist key. On launch, the app validates
that value, persists it to user defaults, and reuses the persisted runner mapping
on later refreshes if bundled configuration is temporarily absent.

## Refresh Result

Same-team update installs succeeded without uninstalling the IOSSim app. Repeated
refresh/update installs preserved:

- app data in the IOSSim data container
- imported RPPairing state
- the derived runner mapping

The refresh tests proved repeated re-sign/update/install behavior with currently
valid Xcode-managed 7-day Personal Team profiles.

Do not overstate profile renewal: Xcode reused currently valid 7-day profiles
during the immediate refresh tests. The POC has not yet physically demonstrated
expiration-date extension from an actually renewed profile.

## Runtime Recovery

After a refresh, retained RSD/TestManager service state can become stale even
though the app data and pairing state are preserved. The runtime now has a
one-shot automatic recovery path:

- detect XCTest startup failures that indicate stale RSD/TestManager service
  state
- disconnect the stale developer runtime handles
- reconnect through the existing pairing and tunnel path
- restore the active writer's current simulated position
- retry the Gate 3 or Rich Drive runner launch once

Cycle 2's final pass required no manual Disconnect, proving the recovery
architecture works for the post-refresh case while preserving Drive ownership and
current-position restoration.

## Issues And Resolutions

| Issue | Resolution |
| --- | --- |
| Cross-team same-bundle-ID update rejection | Use same-team refresh/update for preserved app data. Cross-team updates remain rejected by iOS and require a separate migration/uninstall path. |
| Unavailable canonical runner bundle ID under Personal Team | Keep source bundle IDs protected and derive Personal Team UI-test/runner IDs from the Team ID. |
| Derived runner-ID requirement | Added deterministic derived IDs with the runner as `<derived-ui-test-bundle-id>.xctrunner`. |
| Stale TestManager/RSD state after refresh | Added stale XCTest service detection and automatic runtime-session rebuild before one retry. |
| One-shot runtime-session rebuild recovery | Added coordinator-level rebuild that disconnects stale handles, reconnects, restores current position, and preserves the active writer. |
| Runner mapping persistence/AppNotInstalled issue | Persist the validated installed runner ID so a refreshed app continues targeting the derived runner instead of falling back to the canonical source runner. |
| Corrected persistent runner-ID configuration | Main app Info.plist carries `IOSSimGate3RunnerBundleIdentifier`; resolver validates, persists, and reuses it across refreshes. |
| Vendored idevice patch malformed after service-error diagnostic change | Corrected the patch hunk so the pinned FFI rebuild applies cleanly in regression. |

## Validation Evidence

Final pulled diagnostics:

`.iossim-personal-team/final-cycle-2-20260905T034410Z/final-cycle-2-diagnostics.tar.gz`

Final PASS sessions:

- `E1-20260904-233153`: Gate 3 reached `FINISHED`; normal Spoof reached
  `EXPECTED_SIMULATED_LOCATION`; no runtime rebuilds; no unexpected failure or
  fallback markers.
- `DRIVE-20260904-233239`: Gate 3 reached `FINISHED`; Rich Drive produced 223
  acknowledged rich-drive samples; 2 Hz scheduler metadata was recorded; no
  runtime rebuilds; no unexpected failure or fallback markers.

Validation commands run:

- `./iossim test`: PASS
- `python3 scripts/checks/check_bundle_identifiers.py`: PASS
- `./iossim audit-app .build/iossim/self-contained/IOSSim.app`: PASS
- source secret scan excluding ignored build/output directories: no committed
  secret material found; matches were limited to scanner/test fixtures and a
  local variable named `token`
- feature-freeze diff audit: limited to Personal Team provisioning scaffolding,
  derived runner configuration, one-shot stale runtime recovery, diagnostics, and
  tests; no Drive cadence, route, XCUILocation behavior, XCTest behavior, pairing,
  LocalDevVPN, frontend, or backend feature changes

## Local Artifacts

Generated Personal Team outputs must stay ignored:

- `.iossim-personal-team/`
- `PersonalTeamProvisioningPOC/`
- `personal-team-provisioning/`
- `*.mobileprovision`
- `*.provisionprofile`
- `*.xcarchive`
- `*.xcresult`
- `DerivedData/`

Do not commit signed customer apps, provisioning profiles, device identifiers,
Apple credentials, private keys, or pairing material.

## Productization Recommendation

Move from POC to a consumer Mac provisioning system in three increments:

1. Build a Mac-side provisioning orchestrator that signs the main app and derived
   XCTest runner with the selected Personal Team, writes the installed runner ID
   into the main app, installs both apps, verifies installed bundle identities,
   and records a redacted local manifest.
2. Add automatic refresh scheduling based on profile expiration, with same-team
   update installs, no uninstall by default, post-install app launch, app-data and
   runner-mapping verification, and one-shot runtime recovery if stale service
   state is detected.
3. Add consumer safety rails: preflight Xcode/account/device readiness checks,
   explicit cross-team migration handling, redacted diagnostics export, profile
   renewal evidence capture after actual expiration or renewal, and rollback
   instructions that never discard pairing material without user approval.

Implementation details for these increments are now maintained in:

- `CONSUMER_PROVISIONING_ARCHITECTURE.md`
- `CONSUMER_SETUP_FLOW.md`
- `AUTOMATIC_REFRESH.md`
- `PRODUCTION_VS_DEVELOPMENT.md`
