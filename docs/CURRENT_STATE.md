# IOSSim Current State

Status date: 2026-09-09.

## First Screen Summary

IOSSim is a private, native Mac-to-iPhone setup and iPhone runtime project. The
Mac app onboards the user, authorizes a Personal Team Apple Account inside
IOSSim, prepares signing material, signs two iPhone artifacts, installs them on
the selected iPhone, records setup checkpoints, and exports diagnostics. The
iPhone app and its XCTest runner perform the on-device location simulation
runtime.

Current experimental branch: `work/automated-xcode-rppairing-bootstrap`

Experimental branch base, `main`, and `origin/main` at branch creation:
`ed233af070f5b751c22f6d8b9f86f4fc01885ce7`.

The physical-install stabilization history through
`f4b719fc62240eb3aa148c87c57a6862f161f2c1` is merged and pushed on `main`.

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
| Does Xcode need to be installed right now? | Yes. Detection/bootstrap primitives are implemented and tested, but Apple download authentication and consumer UI wiring remain incomplete. |
| Is automatic RPPairing implemented? | The isolated pinned helper, private transfer, and transactional iPhone import are implemented and automated-tested; a new physical pairing has not been run. |
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

The next engineering boundary is a licensed Apple developer-download
authentication adapter, followed by end-to-end UI wiring. The next physical
boundary is a clean-Mac qualification that never opens Xcode, followed by a
new-iPhone automatic pairing and frozen-runtime requalification.

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
- [Experimental Xcode and RPPairing Bootstrap](XCODE_AND_RPPAIRING_BOOTSTRAP.md)
