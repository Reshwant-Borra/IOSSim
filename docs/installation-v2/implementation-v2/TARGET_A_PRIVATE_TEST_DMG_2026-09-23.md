# Target-A private test DMG — 2026-09-23

Private clean-Mac qualification artifact only. This is not a public release, is not Developer ID
signed or notarized, and does not change the physically proven Veya runtime flow.

## Artifact

- Source branch: `work/final-no-xcode-setup-v1`
- Protected app source HEAD: `6a0c7e8f8a87033e9461c574868fa834b3858cf3`
- Input app: `.build/iossim/development-session/Veya Development.app`
- DMG: `.build/iossim/release/Veya-Test-6a0c7e8.dmg`
- Mounted volume: `Veya Test`
- Size: `33,129,986` bytes
- SHA-256: `e8bc2c0148394f105ed753f47cb7620bd6c205697670f0693d1543742848a92a`

The ignored `.build` artifact is not committed to Git. The digest above is the transfer identity for
the separately delivered DMG.

## Exact contents

```text
Veya Development.app/
Applications -> /Applications
```

There are exactly two top-level entries. No source, repository, DDI cache, Application Support
state, logs, support bundles, LocalDevVPN IPA, Xcode assets, credentials, certificates, private
keys, pairing records, or Apple authentication state are included.

## Packaging implementation

The existing `create_release_dmg()` implementation now accepts optional `volume_name` and
`app_bundle_name` keyword arguments. Existing public and local-release defaults are unchanged.
Target A calls that shared function with `Veya Test` and `Veya Development.app`; no second DMG
implementation exists.

The protected app was not rebuilt, resigned, or launched. Packaging copied its existing bytes into
the image. The source app's complete per-file SHA-256 manifest matched before and after packaging.

## Verification evidence

- `hdiutil verify`: PASS.
- Read-only mount: PASS; volume name `Veya Test` confirmed.
- Exact top-level contents: PASS.
- `codesign --verify --deep --strict`: PASS for the source app, mounted app, and app copied back out.
- GUI architectures: `x86_64 arm64`.
- `IOSSimProvisioner` architectures: `x86_64 arm64`.
- Native bridge architectures: `x86_64 arm64`.
- Bundled main-app and XCTest-runner payload hashes: PASS in all three app copies.
- Mounted and copied-back per-file hashes match the protected source app exactly.
- No quarantine attribute was added during local packaging. A real browser/cloud download may add
  quarantine on the receiving Mac; that is intentional and must use macOS's user-approved
  **Open Anyway** flow.
- App audit: no private keys, pairing/auth material, provisioning profiles, forbidden development
  material, or world-writable files. Expected Development-only findings remain: development bundle
  identity and debug/source path strings.
- `./iossim installation-baseline --defer-m4`: PASS.
- Focused DMG tests: 3/3 PASS. Artifact identity tests: 6/6 PASS.

## Qualification limitations

- Ad-hoc signed, not Developer ID signed.
- Not notarized or stapled.
- M4 remains deferred; relaunch may require Apple sign-in and setup again.
- The existing pinned third-party development DDI provider is intentionally retained. The receiving
  Mac must have network access for the mirror download and Apple personalization; Xcode must not be
  installed merely as a workaround.
- LocalDevVPN remains an external iPhone App Store dependency. The fresh-device test should begin
  with it absent and exercise the existing missing-app guidance.
- Intel slices are present, but clean Intel behavior remains a physical qualification item.

## Brother installation flow

1. Deliver the DMG separately from Git and send its SHA-256 through a second message.
2. Verify with `shasum -a 256 Veya-Test-6a0c7e8.dmg`.
3. Open the DMG and drag `Veya Development.app` to Applications.
4. Eject `Veya Test`; do not run the app from the mounted image.
5. Launch from Applications. If macOS blocks it, use System Settings → Privacy & Security →
   **Open Anyway**, authenticate, and confirm. Do not disable Gatekeeper or clear quarantine.
6. Connect the tester's iPhone and use only the tester's Apple account, Personal Team, signing state,
   and pairing state.
7. Do not install Xcode unless the captured first failure proves it is unavoidable.
8. Exercise DDI download/personalization/mount, missing LocalDevVPN onboarding, automatic pairing,
   Run Setup, Continue / Verify Setup, READY, intentional spoofing, and M4-deferred relaunch behavior.

Stop at the first failure and preserve the exact error before installing unrelated tools.
