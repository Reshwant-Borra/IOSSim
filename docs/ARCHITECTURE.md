# IOSSim Architecture

This document describes the current native IOSSim architecture. For the release
and evidence snapshot, start with [CURRENT_STATE.md](CURRENT_STATE.md).

## System Diagram

```text
Apple Developer Services
  GrandSlam/SRP + 2FA
  Xcode-scoped Developer Services session
  teams / certificates / devices / App IDs / profiles
        ^
        |
        v
IOSSim Mac app
  SwiftUI
  SetupStore
  BundledProvisioningEngine
  IOSSimProvisioner helper
  Keychain signing identity
  codesign/security
  xcrun devicectl / CoreDevice
        |
        | sign, install, launch, inventory, runtime readback
        v
Selected iPhone
  IOSSim iPhone app
  IOSSimLocationControlUITests-Runner.app
        |
        v
LocalDevVPN
        |
        v
RPPairing / RSD
        |
        v
DVT / TestManager
        |
        v
XCTest runner
        |
        v
XCUILocation(location:).simulate()
        |
        v
Simulated system location
```

## Product Components

| Component | Role | Current evidence |
| --- | --- | --- |
| macOS IOSSim app | Onboarding, device selection, Apple Account authorization, provisioning orchestration, signing, installation, refresh, repair, support export | Implemented and locally packaged; current local RC physically pending regression |
| `IOSSimProvisioner` helper | Bundled command boundary for doctor, consumer provisioning, resume, runtime confirmation, and support export | Implemented in `macos/Sources/IOSSimProvisioner/main.swift` |
| iPhone IOSSim app | User-facing runtime app for setup, Spoof, Drive, diagnostics, pairing import, and location simulation controls | Physically validated in earlier runtime gates and latest install/setup path |
| XCTest runner | Signed support app used for XCUILocation runner launch and rich location simulation | Physically validated in Gate 3 and Personal Team install paths |
| LocalDevVPN | iPhone-local network route that lets the app reach the local developer endpoint | Physically validated runtime dependency, not owned by this repo |
| RPPairing / RSD / DVT / TestManager / XCTest / XCUILocation | Runtime developer-service chain used to drive location simulation from the iPhone | Physically validated and feature-frozen |
| Witness | Owned validation app for measuring behavior | Validation-only; not packaged in the consumer Mac app and not a production component |

Source references:

- `macos/Sources/IOSSimMac/Views/SetupWizardView.swift`
- `macos/Sources/IOSSimMacCore/SetupStore.swift`
- `macos/Sources/IOSSimMacCore/Services/BundledProvisioningEngine.swift`
- `macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift`
- `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/LocationCoordinator.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/DvtLocationClient.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/DriveLocationTransport.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/DriveScheduler.swift`

## Setup / Refresh Path

Setup and refresh are Mac responsibilities:

```text
select exact iPhone
  -> authorize Apple Account inside IOSSim
  -> discover Personal Team
  -> create/reuse local signing identity
  -> register/reuse device
  -> create/reuse App IDs
  -> obtain profiles
  -> sign bundled main app and runner
  -> install both on selected iPhone
  -> verify current main and runner inventory
  -> guide Apple developer-profile trust if required
  -> launch main app only to write runtime mapping
  -> read back runtime configuration
  -> COMPLETE
```

The Mac path is stateful and checkpoint-aware. It should preserve valid Apple
authorization, profiles, signing state, install state, and runtime mapping when a
later prerequisite fails or the selected iPhone disconnects.

## Normal iPhone Runtime Path

Normal Spoof and Drive behavior run from the iPhone app. The Mac prepares and
refreshes the iPhone; it is not the intended source of every simulated location
during normal daily use.

The physically proven runtime chain is:

```text
IOSSim iPhone app
  -> saved RPPairing trust material
  -> LocalDevVPN route
  -> local RSD discovery
  -> developer-service communication
  -> retained DVT/TestManager/XCTest session
  -> installed XCTest runner
  -> XCUILocation(location:).simulate()
```

This architecture is feature-frozen. Do not redesign LocalDevVPN, RPPairing,
RSD, DVT, TestManager, XCTest, XCUILocation, Spoof, Rich Drive, transport
fallbacks, cadence, pause/resume, Stop & Hold, Clear Simulation, destination
hold, or single-writer semantics unless a future task explicitly authorizes it.

## Rich Drive

Rich Drive is part of the iPhone runtime, not the Mac setup flow. Current source
shows:

- `DriveLocationOutputMode.defaultMode` is `richXCUILocationExperimental`.
- Rich writes flow through `XCTestRichDriveLocationTransport`.
- DVT Compatibility remains a fallback/manual mode.
- Smooth 2 Hz is the default cadence, with Baseline 1 Hz Compatibility fallback.
- `DriveScheduler` uses monotonic timing.
- `LocationCoordinator` enforces single-writer ownership across static and Drive
  writes.
- Pause/resume, Stop & Hold, Clear Simulation, destination hold, reconnect
  restoration, and stale-generation handling are implemented.

Evidence labels:

| Rich Drive capability | Evidence |
| --- | --- |
| Basic Drive route changes system location | PHYSICALLY PROVEN |
| Gate 3 runner launch and XCTest handshake | PHYSICALLY PROVEN |
| Rich XCUILocation runner behavior | PHYSICALLY PROVEN |
| Rich Drive at 2 Hz in the earlier Personal Team cycle | PHYSICALLY PROVEN in historical cycle evidence |
| Automatic rich-to-DVT fallback, cadence fallback, single-writer tests | AUTOMATED TESTED / LOCAL TESTED |
| Current 06478bab RC Rich Drive requalification after setup stabilization | UNPROVEN |
| Long-duration locked-screen/background Rich Drive | UNPROVEN |

See `docs/iphone_on_device_dvt/DRIVE_MODE_IMPLEMENTATION.md` for detailed
runtime history.

## Legacy Host Web Stack

The old React/Vite + FastAPI host-controlled architecture is historical for the
current native product. It remains useful as engineering history and validation
surface, and the long-lived `desktop-legacy` branch preserves that product line.
Do not confuse it with the current packaged native Mac app.
