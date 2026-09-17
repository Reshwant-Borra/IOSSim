# UX Automation and Recovery

This document captures user-friction improvements discovered in Vanish and classifies them as fundamental architecture, better automation, better UX, or marketing difference.

## Key Distinction

The strongest lesson is not that Vanish has a new location primitive. It is that Vanish packages and automates many steps IOSSim currently exposes or partially implements.

Categories used below:

- `FUNDAMENTAL ARCHITECTURAL ADVANTAGE`: Vanish has a materially different subsystem IOSSim lacks.
- `BETTER AUTOMATION`: Same underlying Apple/device mechanism, but Vanish hides or orchestrates it better.
- `BETTER UX`: Presentation, guidance, defaults, diagnostics, or polish.
- `MARKETING DIFFERENCE`: Wording sounds stronger than the technical reality.

## Friction Improvements

| Feature | Classification | Evidence | Notes |
| --- | --- | --- | --- |
| No full-Xcode consumer setup | FUNDAMENTAL ARCHITECTURAL ADVANTAGE | E04-E09 | Bundled protocol clients and prebuilt IPA replace user-facing Xcode/device tooling |
| Prebuilt mobile payload | BETTER AUTOMATION | E12 | User does not compile app/test target |
| Apple Account setup flow | BETTER AUTOMATION | E08-E10 | Developer Services sequence hidden behind guided flow |
| Optional saved Apple login | BETTER UX with privacy tradeoff | E10 | Reduces password reentry, but password persistence is not session-token proof |
| Automatic pairing delivery | BETTER AUTOMATION | E11 | Pairing exists, but normal plist handling is hidden |
| Pairing repair | BETTER AUTOMATION | E11 | Targeted fix instead of restarting setup |
| Developer Mode guidance | BETTER UX | E05, E19 | Checks/reveals/guides instead of surfacing raw failures |
| Trust guidance | BETTER UX | E30 | Public setup docs and likely UI guide normal Apple trust |
| Progress events | BETTER UX | E09 | Helper emits setup/install/progress states |
| Mobile phone-local operation | FUNDAMENTAL ARCHITECTURAL ADVANTAGE if IOSSim UX cannot expose its existing runtime | E13-E16 | IOSSim already has phone runtime pieces, so advantage may be packaging/qualification |
| Cellular readiness card | BETTER UX plus possible runtime technique | E14-E15 | Off/on guidance makes tunnel limitations actionable |
| Seven-day refresh on phone | FUNDAMENTAL ARCHITECTURAL ADVANTAGE | E16 | New subsystem beyond normal Mac-only refresh |
| Refresh reminders | BETTER UX | E16 | Reduces surprise expiration |
| Live Activity | BETTER UX | E12, E19 | Shows ongoing status on iPhone |
| Saved places/recents | BETTER UX | E18-E19 | IOSSim already has equivalents in source |
| Route planning and hold | BETTER UX | E19 | Some features overlap IOSSim Rich Drive |
| Draft route editing while spoofing | BETTER UX | E19 | Useful separation of planning versus active session |
| Squirrel/GitHub updater | BETTER UX | E21 | Keeps desktop app current |
| Copy logs/diagnostics | BETTER UX | E19 | Needs privacy-safe export review |
| "No pairing file" public feel | MARKETING DIFFERENCE | E11 | Pairing is automated, not gone |
| "Works on cellular" public feel | MARKETING DIFFERENCE unless qualified | E14-E15 | Flow has bootstrap constraints; transition tests not run |
| "Cloud only validates license" narrow wording | MARKETING DIFFERENCE | E20, E30 | Backend has account/events/mobile-session roles too |

## Automated Device Detection and Selection

`STRONG_EVIDENCE`: Vanish contains device selection, per-device pairing checks, identity state, and helper events. Evidence: E09-E11.

`UNKNOWN`: Exact auto-select behavior with one or two connected iPhones.

IOSSim opportunity:

- Auto-select only when exactly one eligible device exists.
- Keep visible identity binding.
- Require explicit choice when multiple devices or stale pairing exists.

## Apple Account Automation

`STRONG_EVIDENCE`: Vanish hides CSR, certificate, App ID, device registration, profile, signing, and install operations behind its flow. Evidence: E08-E09.

UX value:

- User does not need to visit Apple Developer Portal.
- User does not need to understand Personal Team resources.
- User sees step/progress events rather than low-level errors.

Limit:

- Legitimate Apple password and 2FA cannot be promised away.

## Pairing Abstraction

`CONFIRMED`: Normal flow can place pairing and repair pairing. Manual export remains. Evidence: E11.

UX value:

- The user does not need to drag/copy a plist under normal conditions.
- Pairing becomes an internal readiness state.

Marketing reality:

- Pairing still exists.

## Recovery and Diagnostics

`CONFIRMED`: Desktop mechanisms include:

- unexpected-helper-exit watchdog.
- up to three restart attempts.
- two-second retry delay.
- RSD identity guard before replay.
- lock/reboot retry.
- Wi-Fi probe timing.

Evidence: E17.

`STRONG_EVIDENCE`: Mobile mechanisms include:

- cellular readiness flow.
- helper/session state.
- pairing repair guidance.
- diagnostics/copy logs.

Evidence: E14-E17, E19.

`UNKNOWN`: Real-world success rates and recovery times.

IOSSim opportunity:

- Build a single readiness model across Apple auth, signing, install, Developer Mode, pairing, VPN, RSD, TestManager, runner, and location transport.
- Preserve active writer generation and pending clear.
- Avoid repeating certificate/profile work when only transport failed.

## Renewal UX

`STRONG_EVIDENCE`: Vanish makes seven-day development signing survivable with reminders and phone-side refresh mechanisms. Evidence: E16.

UX value:

- Expiration becomes a managed lifecycle, not a surprise reinstall.

Limit:

- Fully expired app recovery appears to need a computer.
- Background automation is unknown.

## Map/Search UX

`CONFIRMED`: Desktop map/search stack includes:

- CARTO tiles.
- Esri satellite/boundary.
- Mapbox geocoding/Search Box.
- OSRM and Valhalla route requests.
- recents and favorites.

Evidence: E18.

`STRONG_EVIDENCE`: Mobile has saved places, recents, routes, speed/road-limit options, timed destination, Live Activity, route hold, diagnostics. Evidence: E19.

Privacy note:

- Online search/routing can send queries/proximity/route coordinates to third-party map providers. Evidence: E18.

## Revert UX

`STRONG_EVIDENCE`: Revert maps to explicit clear/stop commands rather than simply moving to current GPS. Evidence: E06, E13.

IOSSim opportunity:

- Show command acknowledged separately from real GPS observed.
- Persist pending clear after crash/disconnect.
- Do not replay movement after a user's last action was clear.

## What IOSSim Should Not Copy Blindly

- Default Apple password persistence.
- A cloud account requirement if IOSSim does not need it.
- Coordinate-only DVT runtime if IOSSim's rich runtime works.
- Public anisette dependency without review.
- Apple developer-image redistribution assumptions.
- Marketing phrasing that hides real Apple trust/security steps.

## Measurement Still Needed

Exact click counts and user prompts remain unknown:

- fresh install to first spoof.
- subsequent app launch to new spoof.
- Apple password entries.
- 2FA entries.
- cable actions.
- Trust prompts.
- Settings changes.
- restarts.
- dialogs.

No measured UX funnel was executed.
