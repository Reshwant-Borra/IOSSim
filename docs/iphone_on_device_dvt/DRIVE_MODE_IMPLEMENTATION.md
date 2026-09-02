# Experimental Drive Mode Implementation

Status date: 2026-09-01

This document describes the testing-only Drive Mode added to the existing IOSSim iPhone app. It does not replace the proven static on-device DVT location simulation flow.

## Status

Current status:

```text
BASIC DRIVE POC PHYSICALLY DEMONSTRATED
WITH FIRST INSTRUMENTED PHYSICAL CHARACTERIZATION COMPLETE
ABSOLUTE-DEADLINE 1 HZ / 2 HZ CADENCE EXPERIMENT SOFTWARE-VALIDATED
RICH XCUILOCATION DRIVE IS THE DEFAULT TRANSPORT
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
- Configurable Drive playback cadence: baseline 1 Hz and smooth-test 2 Hz.
- Absolute-deadline scheduler timing based on `ContinuousClock`.
- Rich XCUILocation Drive transport as the default Drive output.
- DVT LocationSimulation retained as the explicit compatibility fallback.
- IOSSimLocationWitness JSON Export Metrics control for owned validation recordings.

Proven physical results:

- Drive Mode physically runs on the iPhone.
- Route movement successfully changes simulated system Core Location.
- The route is visible to third-party location consumers.
- The scheduler maintained monotonic route progress.
- Repeated DVT `LocationSimulation` updates were accepted successfully.
- The previous severe reset-to-origin behavior was absent in the first instrumented characterization run.
- Rich native speed/course propagation was physically proven in owned controls.
- Gate 1, Gate 2, and Gate 3 were physically proven for the Rich XCUILocation architecture.
- Rich Drive was manually observed working at 15 MPH, 35 MPH, and 60 MPH.
- A downstream Drive/car indicator and speed display were manually observed during Rich Drive. This is not a product guarantee for any third-party app.

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
- Full long-duration Rich Drive hardening.
- Background Rich Drive reliability.
- Locked-screen Rich Drive reliability.
- Reboot and developer image implications for the Rich runner path.

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

Rich Drive is now the normal Drive output. It uses the same `DriveSessionController`
and `DriveScheduler`, but writes rich samples through a long-lived preinstalled
XCTest runner and localhost JSON-lines IPC after the runner is ready:

```text
DriveView
  -> DriveViewModel
  -> DriveSessionController
  -> DriveScheduler
  -> XCTestRichDriveLocationTransport
  -> retained RSD / developer services
  -> preinstalled signed XCTest runner
  -> localhost TCP JSON-lines IPC
  -> XCUIDevice.shared.location / XCUILocation
  -> Core Location
```

DVT Compatibility remains available from the Drive Output picker. It preserves
the original DVT `LocationSimulation` path for fallback, diagnostics, and
emergency compatibility.

Fresh installs and unmigrated existing installs select Rich Drive by default.
The migration writes `richXCUILocationExperimental` into
`DriveLocationOutputMode.selection.v1` and records migration version `1`.
After that migration, a user can manually choose DVT Compatibility and that
manual choice is preserved.

Rich Drive still depends on Developer Mode, LocalDevVPN, saved RPPairing, a
preinstalled signed XCTest runner, and developer-service availability. Startup
failure is surfaced in the UI and diagnostics. IOSSim does not silently auto
fallback to DVT because unsafe automatic fallback can reintroduce duplicate
writers; fallback is a manual Drive Output selection.

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
- `ios/Sources/IOSSimOnDeviceDVTPOC/LocationWitnessMetrics.swift`
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

Scheduler wake deadlines are absolute offsets from the active scheduler segment start:

```text
tick 0: start + 0.0s
tick 1: start + interval
tick 2: start + interval * 2
```

The scheduler sleeps until the next absolute deadline. Work duration from DVT writes and diagnostics does not get added to the following nominal deadline.

If work or app execution overruns a deadline, missed deadlines are collapsed. The scheduler sends one coordinate for the current active elapsed time, then selects the next future deadline. It does not replay missed route points or issue rapid catch-up DVT writes.

Pause stops route progression through the controller's existing active-elapsed calculation. While paused, the scheduler does not write Drive coordinates. Resume starts a fresh active scheduler segment so it does not replay deadlines that occurred during the pause.

## Playback Cadence

Drive Mode exposes an explicit playback cadence:

```text
Baseline - 1 update/sec:      1.0s interval
Smooth Test - 2 updates/sec:  0.5s interval
```

Baseline 1 Hz remains the default to preserve the physically characterized behavior as the regression baseline. Smooth Test 2 Hz is an experimental comparison mode only.

Route speed is cadence-independent:

```text
expectedDistance = selectedSpeedMetersPerSecond * activeElapsedSeconds
```

At 35 mph / ~15.646 m/s, expected spatial step is approximately:

```text
Baseline 1 Hz:     ~15.65 m/update
Smooth Test 2 Hz:  ~7.82 m/update
```

The 2 Hz mode is not yet physically proven to improve visual smoothness or native speed/course metadata.

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

Drive diagnostics are written through `SessionDiagnosticRecorder` as JSONL plus a summary export. JSONL events remain append-only and the important trace categories are preserved.

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
- update cadence name
- target interval and effective update frequency
- missed-deadline count
- spatial step distance

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

At Drive stop/export, `DRIVE_CHARACTERIZATION_SUMMARY` records aggregate counts and summary statistics for scheduler intervals, scheduler wake jitter, expected distance delta per tick, DVT set durations, Core Location propagation latency, requested geometric speed, observed geometric speed, valid `CLLocation.speed` percentage, valid `CLLocation.course` percentage, foreground/background/locked lifecycle segments, cadence metadata, and diagnostic recorder write/flush metrics. If a category lacks data, fields are recorded as insufficient data rather than inferred.

`SessionDiagnosticRecorder` now keeps one JSONL file handle open per session and writes events through that retained handle. It flushes periodically and at lifecycle/finalization/export boundaries. The human-readable summary is generated at session start, abnormal/lifecycle events, Drive finalization, and export rather than being atomically rewritten for every trace event. This reduces per-tick I/O overhead while keeping the JSONL event stream available.

Interpretation guardrail: these diagnostics are intended to answer where IOSSim timing irregularity occurs. They do not by themselves prove why native `CLLocation.speed`/`course` were unavailable, why motion looked bursty, or whether iOS background execution is the cause of any delay.

## First Physical Drive Result

Status: PASS for first physically characterized route simulation.

Observation:

- IOSSim Drive Mode started successfully from the iPhone app.
- IOSSim advanced simulated system location through a generated driving route.
- The route visibly progressed.
- The previous catastrophic forward-then-reset-to-origin loop was not the dominant behavior.
- The route was visible to third-party location consumers.

The result demonstrates the implemented on-device Drive architecture can perform moving route simulation on a physical iPhone. It does not prove smoothness, speed reporting, long-duration locked-screen execution, network transition reliability, or cellular cold-start behavior.

### Issue D1 - Native Speed/Course Unavailable

Physical observation:

In session `DRIVE-20260828-100624`, native `CLLocation.speed` and `CLLocation.course` were valid on 0% of Drive observations while the route moved geometrically at approximately the configured speed.

This is important because geometric route movement succeeded while native speed/course metadata remained unavailable.

Hypotheses for future diagnostics only:

- Core Location `CLLocation.speed` behavior under DVT LocationSimulation.
- Update cadence.
- Sparse coordinate timing.
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

The route remained visible to Core Location consumers.

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
3. Use approximately the same route, selected speed, device, network, app build, and test duration for all comparison runs.

Test A - Baseline 1 Hz:

1. Set `Playback Cadence` to `Baseline - 1 update/sec`.
2. Select approximately 35 mph.
3. Use the same short route.
4. Keep IOSSim foregrounded initially.
5. Drive approximately 2-5 minutes.
6. Stop/Clear.
7. Export diagnostics.

Test B - Smooth Test 2 Hz:

1. Use the same route.
2. Use the same speed.
3. Set `Playback Cadence` to `Smooth Test - 2 updates/sec`.
4. Keep the same foreground state.
5. Drive a similar duration.
6. Stop/Clear.
7. Export diagnostics.

Test C - 2 Hz Background:

1. Run only after foreground 2 Hz works.
2. Start a 2 Hz Drive.
3. Keep IOSSim visible approximately 30 seconds.
4. Switch to another normal app without force-closing IOSSim.
5. Leave IOSSim backgrounded several minutes.
6. Return to IOSSim.
7. Stop/Clear.
8. Export diagnostics.

Compare visual smoothness, tick interval, distance per tick, DVT latency, Core Location latency, native `CLLocation.speed` availability, native `CLLocation.course` availability, snap-backs, and route completion timing.

## Rollback

To disable the feature without affecting static simulation:

1. Remove the `Experimental` section's `Drive Mode` `NavigationLink` from `ios/App/ContentView.swift`.
2. Keep `LocationCoordinator` unless also reverting the static single-writer integration.
3. Rebuild the iPhone app.

To fully revert this branch, return to the previous branch or revert the files listed above. Do not delete pairing data or provisioning state as part of rollback.

## Rich XCUILocation Default Checkpoint - 2026-09-01

Status:

```text
RICH DRIVE DEFAULT IMPLEMENTED
DVT FALLBACK PRESERVED
WITNESS EXPORT METRICS IMPLEMENTED
```

### PHYSICALLY PROVEN

From the preserved checkpoint at commit `728c745929d585a529854fb1944c2e449c453d0a`:

- DVT Drive route playback moves smoothly enough to remain a working fallback.
- Approximately 2 Hz DVT route updates work, but native DVT `CLLocation.speed` and `CLLocation.course` are invalid.
- `XCUILocation` preserves rich `CLLocation` metadata in owned-app physical tests.
- A 20-point `XCUILocation` route preserved speed/course on 20/20 points.
- The separate owned `IOSSimLocationWitness` app received rich metadata.
- Gate 1 ran without `xcodebuild test`.
- Gate 2 physically passed a caller-supplied RSD path.
- Gate 3 launched XCTest Mac-free using retained RSD.
- A witness point was physically observed with `speed=15.646 m/s` and `course=90 degrees`.
- The Rich continuous Drive path is implemented using a long-lived XCTest runner, localhost TCP IPC, `RichDriveSample`, route-derived course, selected-speed propagation, and the existing absolute-deadline `DriveScheduler`.
- User manual Rich Drive observations:
  - 15 MPH worked.
  - 35 MPH worked.
  - 60 MPH worked.
  - downstream Drive/car indicator appeared.
  - downstream speed display matched/updated appropriately during Rich Drive.

### IMPLEMENTED IN THIS PASS

- Rich Drive is now `DriveLocationOutputMode.defaultMode`.
- The normal picker label is `Rich Drive`.
- DVT remains selectable as `DVT Compatibility`.
- Stored selection migration prefers Rich Drive for unmigrated active-development installs.
- Manual DVT selection after migration is preserved.
- Rich startup failure cleanup stops any partially-started transport and clears coordinator ownership.
- Rich reconnect restores current route position through Rich IPC and avoids a DVT restore set.
- IOSSimLocationWitness has a visible `Export Metrics` ShareLink backed by a JSON file.
- Witness exports include metadata, summary, simulated_summary, optional speed_plateaus, and raw observations.

### UNRESOLVED RISKS

- Full long-duration hardening.
- Background reliability.
- Locked-screen reliability.
- Reboot/developer image implications.
- Third-party behavior is manually observed only and is not guaranteed.
- No new owned-Witness long-duration matrix was collected in this implementation pass.

### VALIDATION

- `swift run POCUnitChecks`
- Generic physical-iOS IOSSim build with `CODE_SIGNING_ALLOWED=NO`
- `AppleXCUILocationControl` build-for-testing with `CODE_SIGNING_ALLOWED=NO`
