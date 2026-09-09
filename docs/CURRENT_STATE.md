# IOSSim Current State

Status date: 2026-09-09.

## First Screen Summary

IOSSim is a private, native Mac-to-iPhone setup and iPhone runtime project. The
Mac app onboards the user, authorizes a Personal Team Apple Account inside
IOSSim, prepares signing material, signs two iPhone artifacts, installs them on
the selected iPhone, records setup checkpoints, and exports diagnostics. The
iPhone app and its XCTest runner perform the on-device location simulation
runtime.

Current branch: `work/physical-install-state-stabilization`

Current HEAD: `06478bab66e5dc117932cff1c9575c607c35b72e`

Base before physical-install stabilization: `e43aa181379f0b35f2aa6d11809136acc2fc0ab2`

`main` and `origin/main`: `b938c8898afabffc0329ad096773349a0b544e02`

Current local RC:

```text
.build/iossim/local-release/IOSSim-0.1.0-local.dmg
sha256: 5ca34d69a9a80a1bf4469026c63e879a3d147f3f0c50e1cc436f1600134e18ba
size: 15,603,686 bytes
source: 06478bab66e5dc117932cff1c9575c607c35b72e
classification: LOCAL_TEST_ONLY
```

What currently works:

| Question | Current answer |
| --- | --- |
| Is Personal Team Apple authorization implemented? | Yes. Locally implemented GrandSlam/SRP + 2FA + Xcode-scoped Developer Services session. Physical evidence exists on the current Mac/iPhone. |
| Does the user need to open Xcode in the current intended flow? | Target answer: no. Current product flow asks for Apple Account login inside IOSSim, not Xcode Accounts. |
| Does Xcode need to be installed right now? | Yes. Current physical device operations still use Apple's `xcrun devicectl` / CoreDevice tooling supplied with Xcode. |
| Is "Xcode installed but never opened/configured" physically proven on a clean Mac? | No. The current development Mac has historical Xcode/development state. |
| Is the iPhone runtime architecture feature-frozen? | Yes, unless a future task explicitly authorizes runtime architecture changes. |
| Is the current RC public-release ready? | No. It is ad-hoc signed, not notarized, and LOCAL_TEST_ONLY. |

## Physically Proven

Physical iPhone evidence currently supports these claims:

- Personal Team Apple authorization worked on the current Mac.
- Personal Team discovery, device registration or reuse, App ID preparation,
  profile retrieval, and native signing reached a working state.
- The main iPhone app installed.
- The XCTest runner installed.
- Installation inventory was capable of verifying both current artifacts.
- iOS developer-profile trust was required before launching the Personal Team
  installed app.
- After trust and retry, setup evidence could reach `COMPLETE`.
- Earlier runtime work physically proved the LocalDevVPN -> RPPairing -> RSD ->
  DVT/TestManager -> XCTest runner -> `XCUILocation(location:).simulate()` path,
  including Gate 3 and Rich Drive evidence captured in the runtime documents.

Do not expand those claims to clean-Mac, no-Xcode, public release, or profile
expiration renewal qualification.

## Current Setup Boundary

The consumer setup path is:

```text
IOSSim.app
  -> SwiftUI SetupStore
  -> BundledProvisioningEngine
  -> Contents/MacOS/IOSSimProvisioner
  -> Apple Personal Team services, Keychain, codesign, xcrun devicectl
  -> selected physical iPhone
```

The packaged app should not require a repo checkout, Git, Python, Node, Rust,
Homebrew, source scripts, or Xcode project files at runtime. It still requires
Xcode's installed command-line/device tooling for the current proven install
backend.

## Current Runtime Boundary

The normal product goal is that the Mac prepares or refreshes the iPhone. The
iPhone runtime path should then handle normal location simulation without the Mac
streaming every simulated location during daily use.

Preserve this separation:

- Setup/refresh: Mac app, Apple authorization, provisioning, signing,
  installation, setup diagnostics.
- Normal iPhone runtime: iPhone app, LocalDevVPN, saved RPPairing material, local
  RSD/developer service access, XCTest runner, XCUILocation, Spoof, and Drive.

## What Remains Before Consumer Release

The next required test is a same-Mac/same-iPhone physical regression of the
current stabilization RC. Acceptance is no false "Cannot Verify Installation",
no unnecessary Try Again, no unnecessary Fresh Install, no stale historical-team
failure, correct developer-profile trust handling, runtime configuration
verified, and `COMPLETE`.

After that, requalify the runtime gates, audit clean-Mac Xcode requirements, run
a clean-Mac "Xcode installed but never opened/configured" test, choose whether
to keep or replace `devicectl`, test profile refresh/expiry, then complete
Developer ID/notarization/public distribution.

## Read Next

- [Architecture](ARCHITECTURE.md)
- [Provisioning and Signing](PROVISIONING_AND_SIGNING.md)
- [Physical Validation](PHYSICAL_VALIDATION.md)
- [Release and Distribution](RELEASE_AND_DISTRIBUTION.md)
- [Next Steps](NEXT_STEPS.md)
- [Engineering History](ENGINEERING_HISTORY.md)
