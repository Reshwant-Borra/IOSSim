# Mobile, Cellular, and Location Runtime

This document preserves all current evidence about Vanish mobile mode, LocalDevVPN, cellular operation, Mac dependency, and location simulation.

## Core Findings

`STRONG_EVIDENCE`: Vanish mobile mode runs a phone-local location simulation controller using LocalDevVPN, pairing/RPPairing, and local developer services.

`STRONG_EVIDENCE`: Cellular support appears to depend on establishing a retained local developer session, often by temporarily disabling cellular during bootstrap, then re-enabling cellular.

`UNKNOWN`: The important physical-transition behaviors remain untested.

Evidence: E13-E15, `EXPERIMENTS.tsv`.

## Mobile Payload

`CONFIRMED`: `Vanish.ipa` contains:

- Main app: `Payload/StikDebug.app/StikDebug`
- Display name: Vanish
- Source bundle ID: `com.vanish.stikdebug`
- Version: 3.2.0
- Minimum iOS: 17.4
- Live Activity extension: `com.vanish.stikdebug.liveactivity`

Evidence: E12.

`CONFIRMED`: No XCTest runner, `.xctest` bundle, embedded provisioning profile, bundled Apple framework directory, or VPN extension was found in the inspected IPA. Evidence: E12.

## LocalDevVPN

`STRONG_EVIDENCE`: Vanish mobile interacts with LocalDevVPN rather than embedding its own Packet Tunnel extension. Evidence includes:

- LocalDevVPN URL scheme.
- App Store URL.
- Local tunnel probe strings.
- pairing filename references.
- cellular readiness flow.

Evidence: E14.

`UNKNOWN`:

- Exact LocalDevVPN setup screens.
- Whether an already installed helper is reused.
- Exact VPN configuration details.
- Whether VPN consent is required in every setup.

## Developer Services

`CONFIRMED`: Desktop helper uses RSD/DVT LocationSimulation. Evidence: E06.

`STRONG_EVIDENCE`: Mobile binary contains idevice-like DVT location symbols and tunnel-state helpers:

- `_location_simulation_new`
- `_location_simulation_set`
- `_location_simulation_clear`
- `_ls_simulate_location`
- `_ls_retarget`
- `_ls_stop_simulated_location`
- `_ls_location_tunnel_is_up`

Evidence: E13.

Interpretation:

- Vanish likely talks to iPhone developer services through a local tunnel.
- It does not need a Vanish cloud relay to explain local location changes.
- The current evidence favors coordinate-only DVT simulation over IOSSim's richer XCTest/XCUILocation path.

## Cellular Bootstrap

`STRONG_EVIDENCE`: Shipped mobile copy and packaged handoff notes describe this general sequence:

1. LocalDevVPN is active.
2. Cellular is turned off during setup/bootstrap.
3. Vanish establishes a local developer location session.
4. Cellular is turned back on.
5. Vanish retargets the retained local session.

Evidence: E14-E15.

Technical meaning:

- Cellular support is likely not "Mac sends commands to the iPhone through carrier internet."
- It is likely "phone has a retained local authenticated developer-service session, and the app continues using it while normal data connectivity is cellular."
- The off/on step suggests route/interface conflicts during cold bootstrap.

`PLAUSIBLE`: Carrier private addressing or wrong utun/private-address selection can break cold local tunnel discovery. Vendor notes mention private address collisions, wrong interface matching, and misleading local probes. Evidence: E15.

Limitation:

- The vendor handoff notes are corroborating but not independent runtime evidence.
- Some packaged notes contain internally inconsistent test-status wording.

## Cellular Architecture Candidates

| Candidate | Current assessment |
| --- | --- |
| Mac remains connected by USB while phone uses cellular | Plausible for desktop mode, but does not explain mobile-phone-local design |
| Mac reaches phone through cellular/local VPN | Not established; local-network wireless tunnel exists but carrier WAN reachability was not proven |
| iPhone maintains local session | STRONG_EVIDENCE for mobile mode |
| iPhone receives location commands from Vanish internet service | UNKNOWN; not needed to explain current static evidence |
| Mac uses Vanish relay | UNKNOWN; no strong static support |
| Simulator installed/runs on iPhone after setup | STRONG_EVIDENCE |
| Sticky last location after disconnect | Plausible for apparent persistence; insufficient for fresh retargets |

## Mac Dependency

### Desktop Mode

`CONFIRMED`: Desktop movement writer is a Mac Python process. It holds DVT context and sends point/GPX/clear commands. Evidence: E06.

Implication:

- Desktop-mode movement cannot continue generating new route points if the Mac process is gone.
- A stale simulated coordinate may remain briefly or longer, but that is not active route generation.

### Mobile Mode

`STRONG_EVIDENCE`: Mobile app contains local simulation and refresh machinery, supporting operation after setup without an active Mac. Evidence: E13-E16.

`UNKNOWN`: Fresh retarget after Mac power-off was not tested. This is the decisive test for phone-local runtime control.

## Location Simulation Technique

### Desktop

`CONFIRMED`: `vanish_loc_stream.py` imports RSD, DvtProvider, and LocationSimulation, maintains a provider context, sets latitude/longitude, plays GPX, and clears simulation. Evidence: E06.

### Mobile

`STRONG_EVIDENCE`: Native mobile symbols match DVT location simulation through idevice-style APIs. Evidence: E13.

`UNKNOWN`: Whether mobile injects richer metadata such as:

- altitude
- speed
- course
- heading
- horizontal accuracy
- vertical accuracy
- floor
- timestamps

Targeted scans found no `XCUILocation`, XCTest runner, or `testmanagerd` indicators in the bundled IPA. Evidence: E12-E13.

## Revert

`CONFIRMED`: Desktop clear exists and clear-on-EOF exists. Evidence: E06.

`STRONG_EVIDENCE`: Mobile clear/stop functions exist. Evidence: E13.

`UNKNOWN`: Whether disconnected sessions can clear, whether crash recovery clears, how fast real GPS returns, and whether reboot is ever required.

## Runtime Unknowns Required by the User

These remain unresolved and must not be treated as confirmed:

- Mac-off operation.
- Wi-Fi to cellular behavior.
- Cellular to Wi-Fi behavior.
- Wi-Fi A to Wi-Fi B behavior.
- Mac Wi-Fi off.
- iPhone Wi-Fi off.
- Mac internet disconnected.
- Vanish backend unavailable.
- Mac sleeping.
- Mac app quit.
- Mac force-killed.
- Mac rebooted.
- USB connected/disconnected.
- iPhone locked/unlocked.
- iPhone rebooted.
- Airplane Mode toggled.
- Personal Hotspot enabled/disabled.
- Session lifetime.
- Expiration behavior.
- Automatic recovery time and success rate.
- User action needed for each transition.

Every row in `EXPERIMENTS.tsv` is `NOT_RUN`.

## IOSSim Implication

Vanish suggests a practical cellular experiment path for IOSSim:

- Preserve IOSSim's phone-local rich runtime.
- Test a guided bootstrap sequence: helper active, cellular off, establish authenticated local session, cellular on, fresh retarget and clear.
- Treat "fresh retarget after Mac shutdown" and "clear after Mac shutdown" as decisive, not simply observing a previously set coordinate.
- If this works, the IOSSim change may be mostly readiness orchestration, interface selection, and recovery UX.
- If this fails, investigate tunnel/interface binding and session health without adding a cloud relay by default.
