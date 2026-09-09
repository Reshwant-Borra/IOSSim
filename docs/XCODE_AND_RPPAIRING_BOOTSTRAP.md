# Experimental Xcode and RPPairing Bootstrap

Status date: 2026-09-09.

Branch: `work/automated-xcode-rppairing-bootstrap`.

Evidence level: implementation and deterministic automated tests only. No clean
Mac, real Xcode download, administrator-authorized install, or new physical
iPhone pairing was performed for this document.

## Verdict

The branch is a partial implementation. Xcode discovery, per-process developer
directory selection, download/install/verification primitives, an isolated
pairing helper, private app-container transfer, and transactional iPhone import
exist. A licensed, independently verified Apple developer-download
authentication adapter is still missing, so the Mac UI does not offer a
nonfunctional Install Xcode button.

The existing Personal Team Developer Services session is not assumed to be
interchangeable with an Apple developer-download session. `XcodesKit` was
reviewed at `f254dcd06662fc20d660044fcf8e93418cde2d11` (MIT). The related
`XcodesLoginKit` checkout reviewed at
`9bece1ada36006b18b84caec62d14dc91b47ae2b` did not contain a license file, so
its authentication source was not integrated or copied.

## Xcode Dependency Map

| Dependency | Phase | Why it remains |
| --- | --- | --- |
| Full Xcode bundle | Consumer setup | Supplies the current Apple-supported CoreDevice/`devicectl` implementation. |
| `xcrun devicectl list devices` | Consumer setup | Device discovery, exact selection resolution, and CoreDevice qualification. |
| `xcrun devicectl device info lockState` | Consumer setup | Locked/unlocked prerequisite and selected-device continuity. |
| `xcrun devicectl device install app` | Consumer setup | Proven main and runner installation path. |
| `xcrun devicectl device info apps` | Consumer setup | Authoritative post-install inventory. |
| `xcrun devicectl device process launch` | Consumer setup | Developer-profile trust classification, runtime mapping, and pairing-inbox launch. |
| `xcrun devicectl device copy from` | Consumer setup | Runtime mapping and non-secret pairing receipt readback. |
| `xcrun devicectl device copy to` | Consumer setup | Private app-data-container pairing candidate delivery. |
| `xcodebuild -checkFirstLaunchStatus` | Xcode prerequisite | Detects installed but unfinished Apple first-launch work. |
| `xcodebuild -runFirstLaunch` | Xcode bootstrap | Performs Apple's command-line component setup and license agreement only after explicit user consent. |
| `DEVELOPER_DIR` | All controlled Xcode processes | Selects the best compatible Xcode per process without changing global `xcode-select`. |
| Xcode iPhoneOS/macOS SDKs, XCTest frameworks | Build/release machine | Builds the iPhone app, runner, tests, and Mac release. These are not separately shipped as loose tools. |
| `codesign`, `security` | Consumer setup and release | Native signing and Keychain identity handling; these are macOS system tools, not Xcode Accounts. |
| `notarytool`, `stapler` | Public release machine | Developer ID distribution only, not consumer setup. |
| CoreDevice/DDI support | Consumer setup | Used indirectly by `devicectl`; no separate private DDI installer was added. |

No Mac/Xcode dependency is used after the prepared iPhone is disconnected for
normal Spoof or Drive runtime operation.

## Xcode Policy and Detection

`XcodeCompatibilityPolicy` owns the bundle ID, Apple team ID, minimum baseline,
pinned clean-Mac release, and conservative device-OS compatibility map. The
clean-Mac target is stable Xcode 26.6 build 17F113 on macOS 26.2 or later. Beta
and RC names lose selection priority.

`XcodePrerequisiteDetector` scans system and user Applications plus an explicit
`DEVELOPER_DIR`. Xcode-named damaged bundles remain visible to inspection rather
than disappearing from the result. It validates bundle metadata and developer-directory shape,
runs `-checkFirstLaunchStatus`, resolves `devicectl`, executes
`devicectl --version`, and runs a bounded CoreDevice device-list JSON probe. It
distinguishes no Xcode, CLT only, incompatible, damaged, uninitialized,
`devicectl` unavailable, globally selected ready, and ready via a better
alternative installation.

Build identity uses `Contents/version.plist` `ProductBuildVersion`, not the
different internal `DTXcodeBuild` value in `Info.plist`.

IOSSim records only the path of the last capability-qualified developer
directory and injects it into later subprocess environments. It does not call
`xcode-select --switch`.

## Xcode Download and Installation Boundaries

`AppleXcodeArchiveDownloader` accepts only HTTPS URLs on an explicit Apple host
allowlist. It uses an ephemeral URL session without persistent cookies/cache,
streams to a deterministic `.partial` file, resumes with an HTTP Range request,
validates the returned content range before appending, supports task
cancellation, reports byte progress, and checks conservative disk capacity
before network work. It never persists URLSession resume blobs because they may
contain authorization headers.

`EphemeralXcodeDownloadAuthorization` is non-Codable, can be cleared, and owns
only an already-authorized request. The missing adapter must authenticate
directly with Apple and provide the authenticated catalog URL/request without
persisting password or 2FA.

The extraction/verification/install sequence is:

```text
authenticated official archive
  -> /usr/bin/xip --expand in deterministic staging
  -> exact Xcode bundle metadata/version check
  -> codesign --verify --deep --strict
  -> Apple TeamIdentifier 59GAB85EFG check
  -> spctl assessment
  -> macOS authorization dialog
  -> ditto to distinct /Applications/IOSSim-Xcode-26.6.app
  -> explicit license consent in IOSSim
  -> macOS authorization dialog for xcodebuild -runFirstLaunch
  -> full prerequisite detector/devicectl probe
```

The installer refuses an existing destination and never deletes another Xcode.
Its fixed AppleScript delegates administrator authentication to macOS; no admin
password enters IOSSim. A production privileged-helper review remains required
before public release.

## Pairing Flow

The existing manual flow imported a user-selected plist into
`KeychainRPPairingStore`. The pinned runtime then loaded it through a protected
temporary file and persisted device-updated pairing bytes back to Keychain.

The experimental automatic path is:

```text
exact selected USB iPhone
  -> normal Apple computer trust via usbmuxd/lockdown
  -> IOSSimPairingHelper at pinned idevice c442bd2
  -> RPPairing generate and fresh-connection device validation
  -> owner-only Mac staging file
  -> devicectl private appDataContainer copy
  -> iPhone PairingInbox
  -> structural validation into an in-memory staging store
  -> real pinned-runtime tunnel/RSD/DVT validation
  -> commit device-updated record to primary Keychain item
  -> owner-only, non-secret receipt
  -> devicectl private-container receipt readback
  -> delete Mac candidate and iPhone inbox candidate
```

The helper is a narrow MIT-licensed binary pinned to the same idevice commit as
the runtime. It requires an exact UDID and a USB connection; it never chooses
the first device. The runtime idevice pin and iPhone FFI library are unchanged.

House Arrest, AFC, public Documents sharing, and `UIFileSharingEnabled` are not
used. Manual file selection remains only under iPhone Settings as an advanced
recovery path.

## Retry and Recovery

Non-sensitive Xcode checkpoints separately record archive downloaded,
application verified, installed path, initialized, and `devicectl` verified.
Partial HTTP data survives cancellation/restart; partial extraction is isolated
and can be discarded without deleting a verified archive. Credentials are not
checkpointed.

Pairing binds the UDID hash and operation generation before transfer, validates
again after generation, and checks again after receipt. The iPhone uses a
candidate store and commits only after functional validation. A failed
candidate cannot replace the prior Keychain item. The current implementation
deletes a Mac candidate after a transfer attempt, so a transfer retry generates
a new candidate rather than persisting pairing material on the Mac.

## Clean-Mac Qualification

Start with supported macOS, no Xcode, no IOSSim state, no developer state, no
Homebrew dependency, internet, an Apple Account, and a test iPhone.

1. Install and launch the LOCAL_TEST_ONLY IOSSim candidate.
2. Confirm IOSSim reports Xcode missing.
3. Authenticate directly with Apple in the future download-auth UI, including 2FA if requested.
4. Download stable Xcode 26.6 and verify progress/resume behavior.
5. Approve the macOS-owned installation prompt.
6. Read and explicitly accept Apple's Xcode license step in IOSSim.
7. Let IOSSim run first-launch initialization and verify `devicectl`/CoreDevice.
8. Never launch Xcode or configure Xcode Accounts.
9. Connect, unlock, explicitly select, and trust the test iPhone.
10. Enable Developer Mode if Apple requires it.
11. Authorize the Personal Team account inside IOSSim.
12. Let IOSSim sign/install the main app and runner; trust the developer profile if Apple requires it.
13. Enable LocalDevVPN and continue Mac setup.
14. Confirm automatic USB pairing, private transfer, on-device functional validation, and receipt readback.
15. Reach Complete, disconnect the Mac, and physically test Spoof, Rich XCUILocation, and Rich Drive.

Record the earliest failed boundary. Only a complete pass with the Xcode GUI
never launched qualifies `XCODE_INSTALLED_BUT_NEVER_OPENED_FLOW` as physically
proven. This branch does not currently qualify that claim.
