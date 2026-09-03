# Personal Team Provisioning POC

Status: engineering proof scaffold only. No Drive, XCUILocation, XCTest runner implementation, iPhone UI, Mac UI, transport, cadence, fallback, route, pairing, or LocalDevVPN behavior is changed by this POC.

## Scope

This POC answers whether the existing IOSSim device artifacts can be provisioned with a normal user's Apple Personal Team:

- IOSSim iPhone app
- IOSSimLocationControlUITests runner app
- Embedded `IOSSimLocationControlUITests.xctest`
- Nested XCTest frameworks and support dylib
- Witness only as validation infrastructure

The normal install backend remains `devicectl`. Replacing `devicectl` or solving no-Xcode provisioning is out of scope.

## Source IDs

Protected source bundle identifiers remain:

- `com.iossim.on-device-dvt-poc`
- `com.iossim.location-witness`
- `com.iossim.location-control-tests`
- `com.iossim.location-control-uitests`
- `com.iossim.location-control-uitests.xctrunner`

The bundle-ID guard remains the source-of-truth check for development configuration. Personal Team identifiers, when required, are derived only for generated artifacts and local manifests.

## Derived IDs

For a selected team, generated Personal Team identifiers use:

`com.personalteam.iossim.t<stable-team-hash>.<role>`

The runner keeps the XCTest relationship:

`<derived-ui-test-bundle-id>.xctrunner`

The hash is deterministic from the Team ID and does not use Apple credentials, email, device IDs, pairing material, or passwords. The same team receives the same derived IDs on refresh.

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

Do not commit signed customer apps, provisioning profiles, device identifiers, Apple credentials, private keys, or pairing material.

## Inspector

Run the read-only POC inspector against packaged resources:

```sh
swift run --package-path macos IOSSimProvisioner personal-team-poc \
  --resources .build/iossim/self-contained/IOSSim.app/Contents/Resources \
  --json \
  --team <TEAMID> \
  --team-kind personal \
  --device <EXPLICIT_DEVICE_IDENTIFIER>
```

The command reports:

- available Apple Development signing identities
- source bundle identifiers
- derived Personal Team identifiers
- embedded profile type, team, creation date, expiration date, device eligibility, and refresh recommendation
- signing graph for main app, witness, runner, nested XCTest bundle, and nested frameworks
- refresh plan states: `VALID`, `REFRESH_RECOMMENDED`, `REFRESH_REQUIRED`, `EXPIRED`, `TEAM_CHANGED`, `DEVICE_MISMATCH`, `SIGNING_UNAVAILABLE`

It does not sign, install, launch, uninstall, or mutate device state.

## Required Physical Gate

A valid proof still requires a genuine free Apple Account / Personal Team and an explicitly selected physical iPhone:

1. Add the free Apple Account in Xcode Settings > Accounts.
2. Confirm the account is not the normal IOSSim paid/development team.
3. Connect the selected iPhone, unlock it, trust the Mac, and enable Developer Mode.
4. Run the read-only inspector with `--team <TEAMID> --team-kind personal --device <identifier>`.
5. Attempt Xcode-managed signing from generated output first.
6. Attempt prebuilt artifact re-signing only after the direct Xcode-managed signing relationship is understood.

Do not run refresh automation until main app install, runner install, runner launch, rich point, Rich Drive, and one manual refresh all pass.

## Current Baseline Observation

The packaged artifacts are 7-day-class development profiles, but current local signing metadata is not a final Personal Team proof:

- embedded profiles/application identifiers are for team `T8SL4SG87F`
- the locally available Apple Development signing authority is for a different team, `ZNXP73K59P`
- no explicit free Personal Team or test iPhone was selected for this run

This is a physical/account gate, not a Drive/runtime blocker.
