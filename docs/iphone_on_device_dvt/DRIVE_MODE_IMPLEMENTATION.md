# Experimental Drive Mode Implementation

Status date: 2026-08-28

This document describes the testing-only Drive Mode added to the existing IOSSim iPhone app. It does not replace the proven static on-device DVT location simulation flow.

## Status

Current status:

```text
BASIC DRIVE POC PHYSICALLY DEMONSTRATED
WITH FIRST INSTRUMENTED PHYSICAL CHARACTERIZATION COMPLETE
```

Implemented:

- Experimental `Drive Mode` entry under the existing app's `Experimental` section.
- MapKit automobile route generation and SwiftUI route preview.
- Constant-speed route playback from 15-70 mph.
- Monotonic elapsed-time scheduler at approximately 1 Hz.
- Pause, resume, completed-holding, and explicit Stop/Clear controls.
- Single authoritative `LocationCoordinator` actor shared by static Set Location and Drive Mode.
- Writer IDs for static and drive ownership.
- Connection generations and stale-generation callback handling.
- Reconnect restoration through the current Drive route position provider.
- JSONL diagnostic events for Drive requests, observations, lifecycle, reconnects, generations, and possible snap-back.
- Unit checks covering route interpolation, speed timing, pause/resume, delayed ticks, monotonic progress, completed holding, stale writers, generation guards, reconnect restoration, stop behavior, clamping, and diagnostics serialization.
- iPhone target Debug iphoneos build validation.
- Basic foreground physical Drive route simulation on an actual iPhone.
- First instrumented physical Drive characterization session `DRIVE-20260828-100624`.

Proven physical results:

- Drive Mode physically runs on the iPhone.
- Route movement successfully changes simulated system Core Location.
- The route is visible to third-party location consumers.
- The scheduler maintained monotonic route progress.
- Repeated DVT `LocationSimulation` updates were accepted successfully.
- The previous severe reset-to-origin behavior was absent in the first instrumented characterization run.

Observed issues:

- D1: Native `CLLocation.speed` and `CLLocation.course` were valid for 0% of Drive observations in session `DRIVE-20260828-100624`, while geometric route speed matched the selected speed.
- D2: Visual movement remains bursty. Current diagnostics show no multi-second scheduler or DVT stalls; the primary IOSSim-level hypothesis is coarse ~1 Hz spatial stepping, approximately 16-18 meters per update at 35 mph.
- D3: Foreground/background difference is now classified as `SMALL MEASURED CADENCE DIFFERENCE - NOT PRIMARY CAUSE BASED ON CURRENT RUN`.

Not yet proven:

- Cause of missing speed.
- Cause of burstiness.
- Whether 2 Hz reduces physical visual burstiness.
- Whether 2 Hz changes native `CLLocation.speed` or `CLLocation.course` availability.
- Core Location propagation behavior under 2 Hz.
- Whether background execution causes timer coalescing in longer runs.
- Locked-screen 10-minute Drive.
- 30-minute Drive or destination hold.
- Network transition reliability.
- Cold-start over cellular.
- Long-duration reconnect behavior.
- Equivalent foreground and background performance.
- Perfect smoothness.
- Accurate speed reporting to third-party apps.

## Architecture

Drive Mode is layered above the existing native DVT implementation:

```text
DriveView
  -> DriveViewModel
  -> DriveSessionController
  -> DriveScheduler
  -> LocationCoordinator actor
  -> existing IdeviceOnDeviceTunnelClient
  -> RPPairing
  -> LocalDevVPN
  -> developer tunnel
  -> RSD
  -> DVT
  -> retained LocationSimulation
  -> repeated location_simulation_set()
  -> Core Location
```

`IdeviceOnDeviceTunnelClient` remains the only low-level native client. It still owns the FFI handles and still calls:

- `location_simulation_new`
- `location_simulation_set`
- `location_simulation_clear`

## Files Added

- `ios/Sources/IOSSimOnDeviceDVTPOC/LocationCoordinator.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/DriveSessionController.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/DriveScheduler.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/DriveTiming.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/RouteResampler.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/MapKitRouteProvider.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/DriveDiagnostics.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/BackgroundManager.swift`
- `ios/App/DriveView.swift`

## Files Modified

- `ios/Sources/IOSSimOnDeviceDVTPOC/ExperimentRunner.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/CoreLocationVerifier.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/SessionDiagnosticRecorder.swift`
- `ios/Sources/IOSSimOnDeviceDVTPOC/DiagnosticModels.swift`
- `ios/Sources/POCUnitChecks/main.swift`
- `ios/App/ContentView.swift`
- `ios/App/POCViewModel.swift`
- `ios/IOSSimOnDevicePOC.xcodeproj/project.pbxproj`

## Single-Writer Invariant

`LocationCoordinator` is the only app-level component allowed to call the existing tunnel client's `set` and `clear` operations. Static simulation and Drive Mode share the same coordinator instance through `POCAppDependencies`.

Ownership is explicit:

- Static location writer: `static:<UUID>`
- Drive writer: `drive:<UUID>`

When Drive Mode starts, it claims the coordinator writer role. A later static write from an old writer ID is rejected and logged as `STALE_WRITER`. This prevents the stale-coordinate restore race:

```text
Drive sends current coordinate
stale static/reconnect writer tries old coordinate
LocationCoordinator rejects stale writer
Drive remains authoritative
```

## Connection Lifecycle

`LocationCoordinator` owns the current connection generation. Every fresh DVT connection increments `connectionGeneration`. Stale callbacks from older generations are logged as `STALE_GENERATION` and ignored.

The native `IdeviceOnDeviceTunnelClient` continues to retain one `LocationSimulation` handle per active connection. Drive playback sends repeated `set` operations through that retained session. It does not create a new DVT connection for every route point.

The 2026-08-28 instrumented characterization confirms this architecture remains physically valuable and must be preserved for smoothing experiments.

On reconnect during Drive Mode:

1. The coordinator disconnects the failed native session.
2. It reconnects RPPairing, tunnel, RSD, DVT, DeviceInfo warmup, and LocationSimulation through the existing client.
3. It asks the Drive restore provider for the expected route coordinate at the current monotonic elapsed time.
4. It sends that one current coordinate.
5. The normal scheduler continues from elapsed time.

Missed coordinates are not replayed.

## Scheduler Design

`DriveScheduler` uses `ContinuousDriveClock`, backed by Swift `ContinuousClock`. Tick count is diagnostic only. Route position is always calculated from active monotonic elapsed time:

```text
expectedDistance = selectedSpeedMetersPerSecond * activeElapsedSeconds
```

Distance is clamped to `0...routeDistance`. The controller also prevents accidental decreasing expected route distance while state is `driving`.

If the app is suspended and resumes later, the next scheduler iteration computes the coordinate for the current elapsed time and sends that coordinate directly.

## Route Design

`MapKitRouteProvider` uses `MKDirections` with `.automobile` transport. It currently selects the first route returned by MapKit.

`RouteResampler` converts the route polyline into cumulative-distance samples and interpolates by distance. The scheduler asks for:

```text
coordinate(atDistance: meters)
```

It does not treat raw polyline vertices as scheduler ticks.

## Completion Behavior

When expected distance reaches the route distance, Drive Mode enters `completedHolding`. It holds the destination coordinate and does not call `clear`.

The user must press `STOP / CLEAR SIMULATION` to call `location_simulation_clear` and return to real location behavior.

## Background Behavior

Drive Mode reuses `BackgroundSessionKeeper` and adds `DriveBackgroundManager` to track foreground/background lifecycle state. `CoreLocationVerifier` is configured for navigation testing:

- `allowsBackgroundLocationUpdates = true` when Drive starts background-capable observation.
- `pausesLocationUpdatesAutomatically = false`.
- `activityType = .automotiveNavigation`.
- `UIBackgroundModes` already contains `location`.
- `CLBackgroundActivitySession` is used on supported iOS versions.

This does not guarantee arbitrary indefinite execution. The scheduler is recovery-safe: if execution stalls, route position is recalculated from monotonic elapsed time when execution resumes.

## Diagnostics

Drive diagnostics are written through `SessionDiagnosticRecorder` as JSONL plus the existing summary export.

Per requested update, Drive Mode records:

- drive session ID
- writer ID
- sequence number
- scheduler tick number
- monotonic elapsed time
- connection generation
- expected route distance
- expected coordinate
- requested coordinate
- latest observed coordinate when available
- nearest observed route distance when available
- calculated route speed
- CLLocation speed, speed accuracy, course, course accuracy
- horizontal and vertical accuracy
- source information simulation/accessory flags
- lifecycle state
- background activity state

Lifecycle and connection events include start, pause, resume, completion, explicit stop, clear, reconnect start/success/failure, and stale generation callbacks.

Possible snap-back is detected when observed route progress decreases by more than 50 meters while Drive diagnostics are active. The event category is `POSSIBLE_SNAP_BACK`, with previous/current/expected progress, writer ID, generation, lifecycle state, and source flags.

Sensitive material is still redacted by `SessionDiagnosticRecorder`; Drive diagnostics do not log RPPairing private keys, PSKs, auth blobs, or raw pairing plists.

## Drive Characterization Diagnostics

Phase 2 adds observability for issues D1, D2, and D3 without changing Drive playback behavior, target speed, scheduler cadence, route interpolation, reconnect strategy, or DVT write semantics.

Each scheduler cycle now carries a `tickTraceID` through:

```text
SCHEDULER_TICK
  -> COORDINATOR_UPDATE_REQUESTED
  -> COORDINATOR_UPDATE_ENTERED
  -> DVT_SET_BEGIN
  -> DVT_SET_END
  -> CLLOCATION_OBSERVED
```

Matching between DVT set calls and later Core Location observations uses the latest completed DVT set sequence. This is documented in each `CLLOCATION_OBSERVED` event as `matching_strategy=latest_dvt_set_sequence`; it is a practical correlation strategy, not proof of exact one-to-one delivery.

Timing fields use monotonic timestamps for duration calculations. Wall-clock timestamps remain in the base JSONL event for human correlation only.

Scheduler trace fields include:

- expected tick offset
- actual tick offset
- scheduler wake jitter in milliseconds
- elapsed time since previous tick
- route distance delta since previous tick
- effective scheduler speed
- expected route coordinate
- expected route bearing
- lifecycle state

Coordinator and DVT trace fields include:

- update request timestamp
- actor entry timestamp
- actor queue delay
- DVT set begin timestamp
- DVT set end timestamp
- DVT set duration
- success/failure
- native error category when available
- writer ID
- connection generation

Core Location observation trace fields include:

- callback receive monotonic timestamp
- `CLLocation.timestamp`
- coordinate
- horizontal and vertical accuracy
- altitude when available
- `CLLocation.speed`
- `CLLocation.speedAccuracy`
- `CLLocation.course`
- `CLLocation.courseAccuracy`
- `sourceInformation.isSimulatedBySoftware`
- `sourceInformation.isProducedByAccessory`
- most recent requested sequence
- time since last DVT set
- distance from the last requested coordinate
- nearest route-distance projection
- observed geometric speed
- Core Location propagation latency when a DVT set can be correlated

Speed values are intentionally separate:

- `selected_drive_speed_mps`: the constant speed selected in IOSSim.
- `effective_scheduler_speed_mps`: route-distance delta over actual scheduler interval.
- `observed_geometric_speed_mps`: observed Core Location displacement over observed callback interval.
- `cllocation_speed_mps`: the speed reported by iOS in `CLLocation.speed`, if valid.

The debug metrics panel in Experimental Drive Mode shows live lifecycle, scheduler interval, scheduler jitter, DVT set latency, Core Location latency, selected speed, `CLLocation.speed`, observed geometric speed, DVT generation, scheduler stalls, DVT stalls, Core Location observation stalls, burst detections, and snap-back detections.

Diagnostic detectors currently record facts only:

- `SCHEDULER_STALL`: scheduler interval greater than 2.5 times target interval.
- `DVT_SET_STALL`: DVT set duration above the diagnostic threshold.
- `CORELOCATION_OBSERVATION_STALL`: large gap between Core Location observations.
- `BURSTY_PROGRESS`: route-distance advance after a long scheduler interval.
- `POSSIBLE_SNAP_BACK`: observed route progress regressed by more than 50 meters.

At Drive stop/export, `DRIVE_CHARACTERIZATION_SUMMARY` records aggregate counts and summary statistics for scheduler intervals, scheduler wake jitter, DVT set durations, Core Location propagation latency, requested geometric speed, observed geometric speed, valid `CLLocation.speed` percentage, and foreground/background/locked lifecycle segments. If a category lacks data, fields are recorded as insufficient data rather than inferred.

Interpretation guardrail: these diagnostics are intended to answer where timing irregularity occurs. They do not by themselves prove why Life360 did not display speed, why motion looked bursty, or whether iOS background execution is the cause of any delay.

## First Physical Drive Result

Status: PASS for basic foreground route simulation.

Observation:

- IOSSim Drive Mode started successfully from the iPhone app.
- IOSSim advanced simulated system location through a generated driving route.
- The route visibly progressed.
- The previous catastrophic forward-then-reset-to-origin loop was not the dominant behavior.
- Life360 recognized the movement as driving.
- Life360 displayed the driven route/path.

The result demonstrates the implemented on-device Drive architecture can perform moving route simulation on a physical iPhone. It does not prove smoothness, speed reporting, long-duration locked-screen execution, network transition reliability, or cellular cold-start behavior.

### Issue D1 - Life360 Drive Speed Missing

Physical observation:

Life360 recognized the simulated movement as a Drive and displayed the route/path. However, Life360 did not display the car's speed during the simulated Drive.

This is important because route/Drive detection succeeded while speed presentation did not.

Hypotheses for future diagnostics only:

- Core Location `CLLocation.speed` behavior under DVT LocationSimulation.
- Update cadence.
- Sparse coordinate timing.
- Third-party sampling behavior.
- Background delivery.
- Differences between geometric speed and system-reported `CLLocation.speed`.

No cause is concluded from the first physical test.

### Issue D2 - Bursty / Non-Smooth Movement

Physical observation:

The simulated route works, but movement is not visually smooth. It appears roughly as:

```text
move/shoot forward
pause
move/shoot forward
pause
repeat
```

Life360 still records the route.

Hypotheses for future diagnostics only:

- Scheduler cadence.
- DVT set-call timing.
- Task scheduling jitter.
- App execution state.
- Core Location propagation.
- Map/UI sampling.
- Network/server refresh behavior.
- Background throttling.
- Delayed or batched observations.

No cause is concluded from the first physical test.

### Issue D3 - Possible Foreground vs Background Performance Difference

Classification:

```text
PHYSICAL OBSERVATION / REQUIRES MEASUREMENT
```

User impression:

Drive Mode may appear to run faster or more smoothly while IOSSim itself is open in the foreground. When the user switches to another app but does not force-close IOSSim, Drive movement may become slower, more delayed, or more bursty.

This is not yet instrumentally confirmed. Future diagnostics must compare monotonic scheduler timing, DVT set timing, Core Location observation timing, and lifecycle transitions.

## First Instrumented Physical Drive Characterization

Detailed result: [DRIVE_CHARACTERIZATION_2026-08-28.md](DRIVE_CHARACTERIZATION_2026-08-28.md).

Session:

```text
DRIVE-20260828-100624
```

Measured result:

- Approximate active Drive duration: ~2 minutes.
- Approximate route distance: 1.9 km / ~1.2 miles.
- Selected speed: ~35 mph / ~15.646 m/s.
- Observed geometric route speed: ~16.1 m/s.
- Scheduler mean interval: ~1.067 s.
- Foreground mean interval: ~1.053 s.
- Background mean interval: ~1.071 s.
- Foreground p95 interval: ~1.084 s.
- Background p95 interval: ~1.112 s.
- Maximum interval: ~1.14 s.
- DVT set latency mean/p95/max: ~11 ms / ~19 ms / ~46 ms.
- Scheduler stalls: 0.
- DVT set stalls: 0.
- Snap-back detections: 0.
- Burst detector events: 0 under current thresholds.
- `CLLocation.speed` valid: 0%.
- `CLLocation.course` valid: 0%.
- `sourceInformation.isSimulatedBySoftware == true` for simulated Drive locations.

Interpretation:

- PROVEN: route interpolation appears healthy, DVT latency is low, and snap-back was absent in this run.
- MEASURED: foreground/background cadence difference was small.
- INFERRED: at 35 mph, the ~1 Hz cadence naturally creates ~16-18 meter coordinate steps and is the primary IOSSim-level smoothing hypothesis.
- NOT YET TESTED: 2 Hz smoothing, 2 Hz background behavior, and native speed/course behavior under 2 Hz.

## Physical Test Procedure

Before testing:

1. Install the Debug iPhone app build.
2. Confirm the RPPairing file is already imported or import it from the main screen.
3. Enable LocalDevVPN and confirm the existing static `RUN DIAGNOSTICS`, `CONNECT`, `SET TEST LOCATION`, and `CLEAR SIMULATION` workflow still works.

Foreground test:

1. Open `IOSSim DVT POC`.
2. Open `Experimental` -> `Drive Mode`.
3. Tap `USE CURRENT` or enter a start address/coordinate and tap `RESOLVE START`.
4. Enter a destination and tap `RESOLVE DESTINATION`.
5. Tap `GENERATE DRIVING ROUTE`.
6. Select a speed between 15 and 70 mph.
7. Tap `START DRIVE`.
8. Let it run for 5 minutes in the foreground.
9. Tap `STOP / CLEAR SIMULATION`.
10. Tap `EXPORT DRIVE DIAGNOSTICS`.

Additional tests to run and label in diagnostics:

- Background: start Drive Mode, switch to Maps, run 5 minutes, return and export.
- Locked screen: start a 10-minute route, lock the screen, unlock, stop/clear, export.
- Long hold: complete a route and leave it in `completedHolding` for 30 minutes before Stop/Clear.
- Pause/resume: pause for at least 2 minutes, resume, confirm route progress excludes pause time.
- Forced recovery: interrupt LocalDevVPN/DVT connectivity, restore it, confirm reconnect sends current route position.

## Rollback

To disable the feature without affecting static simulation:

1. Remove the `Experimental` section's `Drive Mode` `NavigationLink` from `ios/App/ContentView.swift`.
2. Keep `LocationCoordinator` unless also reverting the static single-writer integration.
3. Rebuild the iPhone app.

To fully revert this branch, return to the previous branch or revert the files listed above. Do not delete pairing data or provisioning state as part of rollback.
