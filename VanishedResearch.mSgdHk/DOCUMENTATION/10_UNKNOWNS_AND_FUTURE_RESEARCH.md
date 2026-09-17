# Unknowns and Future Research

This document lists unresolved questions without asking for experiments or beginning new research.

## Can Likely Be Answered Through Additional Static Analysis or Public Research

- More precise dependency/license inventory for every packaged Python, Rust, and Node component.
- Exact update-electron-app and Squirrel configuration details beyond the current summary.
- More historical release-note comparison across v2.x, v3.0, v3.1, v3.2, and v3.2.1.
- More public reports of iOS/macOS update resilience.
- More public StikDebug fork/provenance and license history.
- Additional ASAR-internal markdown notes beyond those already summarized, while staying within clean-room documentation.
- More precise endpoint classification from static code paths, without inspecting secrets or protected traffic.
- Additional public documentation comparison for idevice/isideload/pymobiledevice3 APIs and licenses.
- Better mapping of public DeveloperDiskImage asset sources and redistribution/legal constraints.
- Static scan of every package notice/license bundled with Vanish.

## Requires Controlled Runtime Observation

These cannot be resolved from current static evidence alone:

- First-use success on a clean Mac without full Xcode or cached development components.
- Actual process tree and subprocess command lines during launch, setup, signing, install, spoof, and revert.
- Live network destinations, timing, port use, and process association during each setup stage.
- Whether Apple authentication goes only Mac to Apple/anisette or also through Vanish backend.
- Exact Apple session persistence after relaunch and reboot.
- Device inventory before and after setup.
- Installed bundle IDs, teams, entitlements, profiles, and expiration dates.
- Whether Developer Mode is required and how disabled-mode setup presents.
- Whether developer-profile trust is required in Settings.
- Trust This Computer prompt timing and reuse.
- Exact LocalDevVPN setup, consent, and readiness behavior.
- Pairing creation, placement, validation, and repair results without exposing pairing secrets.
- Multiple-device picker and identity binding behavior.
- Fresh retarget after Mac app quit, force-kill, sleep, reboot, internet loss, and power-off.
- USB connected/disconnected behavior.
- Wi-Fi to cellular and cellular to Wi-Fi transitions.
- Wi-Fi A to Wi-Fi B transitions.
- iPhone lock/unlock/reboot behavior.
- Airplane Mode and Personal Hotspot behavior.
- Offline entitlement/backend behavior.
- System-wide witness behavior in Apple Maps, browser geolocation, Weather, and benign CoreLocation apps.
- Rich delivered location metadata: speed, course, heading, altitude, accuracy, timestamps, floor.
- Revert/clear acknowledgment and real-GPS return latency.
- Setup interruption/resumption at each stage.
- Error messages and diagnostics for trust missing, Developer Mode missing, device locked, internet unavailable, and helper unavailable.
- App update behavior and whether pairing/auth/profile/runtime state persists.

## Requires Long-Duration Observation

These need time-based or repeated trials:

- Seven-day profile expiration rollover.
- Refresh before expiry.
- Fully expired app behavior.
- Automatic background renewal.
- Certificate expiry or revocation recovery.
- Account change behavior.
- Team conflict behavior.
- Device replacement/migration.
- Battery impact in idle, teleport, route, cellular, Wi-Fi, locked, and unlocked modes.
- Mac CPU/energy impact.
- Persistent network activity over hours/days.
- Reliability across iOS updates.
- Reliability across macOS updates.
- Reliability across new iPhone models and OS versions.
- Long-running cellular session lifetime.
- Reconnect rates across real carrier/Wi-Fi environments.

## Cannot Currently Be Determined Safely From This Package Alone

- Contents of Apple credentials, session tokens, private keys, or real pairing records.
- Whether Vanish stores user Apple credentials on its server, absent lawful runtime metadata or vendor documentation.
- Server-side retention policy beyond public privacy statements and observable request construction.
- Any private Vanish source code not shipped as readable packaged assets.
- Any secret protocol material or access-controlled server behavior.
- Whether undocumented Apple security mechanisms are bypassed. No evidence currently supports such a bypass, and attempts to bypass would be out of scope.
- Apple developer-image redistribution rights from the mere fact of public GitHub availability.
- Whether every compiled library feature is actively used.
- Whether absence of a string proves absence of a hidden or downloaded runtime path.

## Experiment Matrix Status

`EXPERIMENTS.tsv` contains 26 rows. All are `NOT_RUN`, with outcome fields `UNKNOWN`.

Important unrun discriminators:

- `T01`: Wi-Fi to cellular.
- `T02`: cellular to Wi-Fi.
- `T10`: Mac completely powered off.
- `T15`: iPhone rebooted.
- `T21`: cold cellular start with helper active.
- `T22`: cellular off bootstrap then cellular restored.
- `T23`: fresh retarget after Mac power-off.
- `T24`: clear after Mac power-off.
- `T25`: revert while transport disconnected then reconnect.

## Cautions for Future Work

- A static coordinate remaining after disconnect is not evidence of active phone-side control. Use fresh retarget, advancing route, pause/resume, and clear.
- A string in a binary is not proof that a code path runs.
- A public marketing claim is not architecture.
- A compiled open-source library feature is not evidence that Vanish invoked it.
- A VPN icon is not proof that the relevant developer service is reachable.
- A saved password file is not proof of durable Apple session reuse.
- A backend endpoint name is not proof of a coordinate relay.
- A profile expiration strategy is not the same thing as certificate expiration or Apple session lifetime.

## Stop Condition for This Phase

This documentation package intentionally stops before additional research or implementation. Future work should begin by choosing a specific question from this file, then designing evidence that discriminates competing explanations without crossing the clean-room boundary.
