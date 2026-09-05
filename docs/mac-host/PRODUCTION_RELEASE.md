# IOSSim Production Release

## Scope

The production release is a manually installed, Developer ID signed and Apple-notarized DMG. It contains only `IOSSim.app` and an `/Applications` shortcut. The app uses the existing consumer path:

`SwiftUI -> IOSSimMacCore -> BundledProvisioningEngine -> IOSSimProvisioner -> Xcode/codesign/devicectl`

The release does not change the iPhone runtime, install Witness, depend on a repository checkout, or add an updater.

## Customer Prerequisites

The current Personal Team flow still requires:

- macOS 13 or newer on Apple silicon or Intel;
- full Xcode 15 or newer, opened once and selected as the active developer directory;
- an Apple Account signed into Xcode with a usable Personal Team and Apple Development identity;
- a compatible iPhone that is connected, unlocked, trusted, and in Developer Mode;
- LocalDevVPN installed and approved on the iPhone;
- valid RPPairing material imported inside the iPhone app.

The DMG-installed app does not require Git, Python, Node, Rust, repository scripts, a source checkout, or development environment variables. Xcode remains a product prerequisite because it creates Personal Team profiles and provides `codesign` and `devicectl` for the proven consumer provisioning path.

## Version Source

`config/release.json` is the sole release configuration for:

- `CFBundleShortVersionString`;
- `CFBundleVersion`;
- bundle identifier and display name;
- minimum macOS version;
- production variant;
- release architectures.

The package manifest records the version, build, variant, source commit, clean/dirty state, and UTC build timestamp. The post-notarization release report also records both notarization submissions, signing Team ID, DMG size, and final SHA-256.

Changing the Mac version does not refresh or reinstall the iPhone artifacts. iPhone Personal Team refresh remains an explicit, independent dashboard operation.

## Entitlement Inventory

The direct-distribution app is not sandboxed. Hardened runtime is enabled with `codesign --options runtime` for every distributed Mach-O. The production entitlement files are intentionally empty:

| Code item | Entitlements | Reason |
| --- | --- | --- |
| `IOSSim.app` | none | SwiftUI UI and child-process launch do not require a hardened-runtime exception. |
| `IOSSimProvisioner` | none | It launches Apple command-line tools and writes user Application Support/temporary files without App Sandbox. |
| Bundled iPhone main/runner code | none at Mac distribution time | Canonical artifacts are profile-free and are re-signed at consumer install time using entitlements from Xcode-managed Personal Team profiles. |

The release does not request network client/server, keychain groups, Apple Events automation, JIT, unsigned executable memory, executable-page exceptions, or disabled library validation. It must never carry `get-task-allow` in the Developer ID distribution signature. File access and subprocess execution do not require entitlements for a non-sandboxed Developer ID app.

Every executable resource is signed inside-out with the same Developer ID Application identity and secure timestamp. The release audit inventories every Mach-O, validates its authority, Team ID, hardened-runtime flag, signature, and absence of forbidden entitlements, then runs `codesign --verify --deep --strict --verbose=4` on the app.

## Release Credentials

The release machine needs a valid `Developer ID Application` certificate and private key in its Keychain. `Apple Development`, `Mac Development`, ad hoc, and Mac App Store identities are rejected.

Create a `notarytool` Keychain profile interactively using Apple’s `notarytool store-credentials` command. Keep the Apple ID/app-specific password or App Store Connect private key outside this repository. Configure only these non-secret references in the local environment:

- `IOSSIM_DEVELOPER_ID_APPLICATION`: the installed certificate fingerprint or full common name; optional when exactly one Developer ID Application identity exists.
- `IOSSIM_NOTARY_KEYCHAIN_PROFILE`: the local `notarytool` Keychain profile name.

The command never prints the credential contents and never copies Keychain material into the package or logs. A missing/ambiguous identity or missing profile reference fails before building.

## Build

From a clean committed worktree:

```bash
./iossim release
```

The command:

1. rejects dirty source and validates the Developer ID/notary references;
2. builds the frozen iPhone artifacts and universal production Mac GUI/helper;
3. assembles the self-contained app and production metadata;
4. signs bundled executable code inside-out, then signs `IOSSimProvisioner` and `IOSSim.app` with hardened runtime and secure timestamps;
5. performs package and recursive signature audits;
6. submits an app archive with `notarytool`, staples and validates the app;
7. creates and signs a compressed DMG containing `IOSSim.app` and the Applications shortcut;
8. submits, staples, and validates the DMG;
9. performs Gatekeeper assessments;
10. writes the checksum and sanitized release/notarization records;
11. runs the final release audit.

Outputs are under `.build/iossim/release/`:

- `IOSSim-<version>.dmg`;
- `IOSSim-<version>.dmg.sha256`;
- `IOSSim-<version>.release.json`;
- `notarization/app-submission.json` and `app-log.json`;
- `notarization/dmg-submission.json` and `dmg-log.json`.

Credential material is never archived. Notarization records replace local absolute paths with stable labels.

Re-run the final checks with:

```bash
./iossim release-audit .build/iossim/release/IOSSim-<version>.dmg
```

The audit requires accepted app and DMG notarization records, valid app and DMG staples, Gatekeeper acceptance, correct version/bundle/provenance, a clean matching source commit, exact DMG contents, a valid checksum, no forbidden package material, correct universal architectures, and valid nested Developer ID signatures.

## Clean-Mac Physical Qualification

Do not treat the build Mac as a clean-Mac substitute. Use a second Mac with no IOSSim repository, prior IOSSim app/state, copied build tree, `.iossim-personal-team` directory, or development shell dependency. Do not erase unrelated data.

1. Transfer the final DMG as a normal downloaded file.
2. Open it, drag IOSSim to Applications, eject the DMG, and launch only `/Applications/IOSSim.app`.
3. Confirm Gatekeeper allows a normal open without Open Anyway, `xattr` changes, or Gatekeeper changes.
4. Complete Mac Check and confirm missing Xcode/account prerequisites are explained clearly if deliberately absent.
5. Connect/unlock/trust the iPhone, select it, select the Personal Team, and install.
6. On iPhone, approve/open LocalDevVPN, import/verify pairing, complete Set Up IOSSim, and return to the Mac dashboard until Ready.
7. Physically verify Gate 3 `FINISHED`, Rich XCUILocation, normal Spoof, Rich Drive, Rich / 2 Hz, no unexpected fallback, and no manual Disconnect.
8. Quit/reopen the Mac app and verify selected device, team, profiles, install, runtime state, runner mapping, and onboarding persistence.
9. Reboot the Mac and repeat the persistence/readiness checks.
10. Reboot the iPhone, perform any documented normal VPN/app reopen action, and verify pairing, Spoof, and Rich Drive again.
11. If practical, reboot both and repeat readiness, Spoof, and Drive.
12. Install a harmless metadata-only RC2 over RC1 through Applications. Verify Mac state is preserved and the iPhone is not refreshed automatically.

Archive screenshots/timestamps and a release qualification report, but never raw device identifiers, RPPairing material, credentials, profiles, or private keys.

## Known Time-Dependent Gate

True newly-issued Personal Team profile renewal remains a separate pending physical proof. Preserve the currently issued main and runner profiles until the renewal window. A renewal passes only when the new expiration is later than the recorded old expiration while identifiers, app data, mapping, RPPairing, Gate 3, Spoof, and Rich Drive remain intact.

## Apple References

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Configuring the hardened runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
