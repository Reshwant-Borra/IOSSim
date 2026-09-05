# Consumer Setup Flow

Status: implemented in the production SwiftUI variant. Physical product-flow
validation must be recorded before release.

## User Flow

1. Open IOSSim on the Mac and choose **Get Started**.
2. IOSSim checks macOS, Xcode developer tooling, and bundled components.
3. Connect and unlock an iPhone. Trust the Mac and enable Developer Mode if
   prompted.
4. Choose the iPhone. If more than one eligible phone is present, IOSSim requires
   an explicit selection before any install action.
5. Choose a Personal Team discovered from Xcode's existing signed-in accounts.
6. Choose **Install**. IOSSim prepares, signs, installs, and verifies the main app
   and its support runner.
7. On the iPhone, enable LocalDevVPN, open IOSSim, tap **Set Up IOSSim**, and run
   Setup until the iPhone shows **Setup Complete**.
8. Return to the Mac and choose **I Finished Setup**.
9. The dashboard shows the selected iPhone, install/runtime status, profile
   validity, refresh timing, **Refresh Now**, **Repair**, and support export.

Normal Spoof and Drive use happen on the iPhone. The Mac is required for initial
provisioning and later refresh, not for every location session.

## Device Selection Rules

- One eligible connected iPhone may be selected automatically.
- Multiple connected iPhones require a current explicit choice unless the user
  has a still-connected remembered device.
- A disconnected remembered device is shown as disconnected and never used as a
  command target.
- Reconnecting the same remembered device restores the preference.
- A newly connected replacement is selected only when it is the single eligible
  device; ambiguous choices are never guessed.
- Every signing, install, verification, refresh, and repair command receives the
  selected CoreDevice identifier. The hardware UDID is resolved separately only
  for profile device-inclusion validation.

## Account And iPhone Actions

IOSSim does not collect Apple credentials. When account or certificate state is
missing, the UI directs the user to Xcode Settings > Accounts. Apple-required
trust, Developer Mode, VPN approval, and in-app setup remain explicit user steps;
the Mac app does not automate iPhone taps.

## Failure Behavior

Primary UI errors answer what happened and what to do next without exposing raw
bundle IDs, profiles, XCTest, RSD, or service names. Development diagnostics keep
the raw failure detail.

A cross-team update requires an explicit **Fresh Install** confirmation and warns
that IOSSim app data will be removed. Same-team install, refresh, and repair do
not uninstall by default.
