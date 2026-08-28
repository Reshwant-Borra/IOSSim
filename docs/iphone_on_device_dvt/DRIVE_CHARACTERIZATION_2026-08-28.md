# Drive Characterization - 2026-08-28

Session:

```text
DRIVE-20260828-100624
```

Approximate active Drive duration:

```text
~2 minutes
```

Status:

```text
FIRST INSTRUMENTED PHYSICAL DRIVE CHARACTERIZATION RUN
```

This document preserves the first instrumented physical Drive result. It is a characterization record, not a fix claim. The current persistent-DVT, single-writer Drive implementation is physically valuable and must remain the baseline for subsequent experiments.

## Physical Characterization Run

PROVEN:

- Drive progressed successfully through a real route generated and followed on-device.
- Route movement continuously changed system Core Location through the existing DVT `LocationSimulation` session.
- Scheduler route progress was monotonic.
- The route remained visible to third-party location consumers.
- Drive ran while IOSSim was foregrounded and while it was backgrounded.
- The previous severe snap-back/reset behavior was absent in this run.

MEASURED:

- Route distance was approximately 1.9 km / ~1.2 miles.
- Selected simulated speed was approximately 35 mph.
- Selected route speed was approximately 15.646 m/s.
- Observed geometric route speed was approximately 16.1 m/s.

INFERRED:

- Route interpolation appears healthy in this run because geometric progress was monotonic and matched the configured speed closely.

NOT YET TESTED:

- Whether a higher update cadence reduces user-visible burstiness.
- Whether a higher update cadence changes native `CLLocation.speed` or `CLLocation.course` availability.
- Long-duration locked-screen behavior and longer background runs.

## Scheduler Findings

MEASURED:

```text
target cadence:        ~1 Hz
observed mean:        ~1.067 s
foreground mean:      ~1.053 s
background mean:      ~1.071 s
foreground p95:       ~1.084 s
background p95:       ~1.112 s
maximum:              ~1.14 s
scheduler stalls:     0
burst detector events: 0 under current thresholds
```

PROVEN:

- Scheduler progress was monotonic.
- No multi-second scheduler stalls were observed.

INFERRED:

- At 35 mph, the measured 1 Hz cadence naturally produces large route steps:

```text
15.646 m/s x 1.067 s ~= 16.7 m/update
```

- The coarse coordinate step size is the primary IOSSim-level smoothing hypothesis after this run.

## DVT Findings

MEASURED:

```text
DVT set latency mean: ~11 ms
DVT set latency p95:  ~19 ms
DVT set latency max:  ~46 ms
DVT set stalls:       0
```

PROVEN:

- DVT `LocationSimulation` accepted repeated route updates successfully.
- The retained DVT session architecture handled the physical run without creating a visible snap-back/reset pattern.

INFERRED:

- DVT set-call latency appears low relative to both 1 second and 500 ms cadences.

NOT YET TESTED:

- Physical DVT behavior under a 2 Hz Drive cadence.

## Core Location Findings

MEASURED:

- Requested and observed Core Location coordinates generally matched.
- Simulated Drive locations reported:

```text
sourceInformation.isSimulatedBySoftware == true
```

PROVEN:

- The DVT stream produced geometric movement visible through Core Location consumers.

NOT YET TESTED:

- Whether Core Location observation cadence or propagation differs materially at 2 Hz.

## Native Speed/Course Finding

MEASURED:

```text
CLLocation.speed valid:  0% of Drive observations
CLLocation.course valid: 0% of Drive observations
```

PROVEN:

- IOSSim moved geometrically at approximately the configured speed while native `CLLocation.speed` and `CLLocation.course` were unavailable in this physical run.

This is not a route math bug. The diagnostic distinction is:

```text
selectedDriveSpeed         ~= 15.646 m/s
geometricSpeed             ~= 16.1 m/s
native CLLocation.speed    invalid/unavailable
native CLLocation.course   invalid/unavailable
```

Do not fabricate `CLLocation.speed` or `CLLocation.course`, modify Core Location objects, spoof motion sensors, or target third-party app internals.

## Foreground vs Background

MEASURED:

```text
foreground mean ~= 1.053 s
background mean ~= 1.071 s
foreground p95  ~= 1.084 s
background p95  ~= 1.112 s
```

Status:

```text
SMALL MEASURED CADENCE DIFFERENCE - NOT PRIMARY CAUSE BASED ON CURRENT RUN
```

PROVEN:

- IOSSim Drive ran in both foreground and background during this run.

INFERRED:

- The measured foreground/background scheduler difference is modest and does not currently explain the large visual burstiness by itself.

NOT YET TESTED:

- Longer background sessions.
- Locked-screen sessions.
- Foreground/background behavior under a 2 Hz cadence.

## Current Smoothing Hypothesis

MEASURED:

- Existing target cadence is approximately 1 Hz.
- Actual mean cadence in this run was approximately 1.067 seconds.
- At the configured speed, that cadence corresponds to approximately 16-18 meters per route update.

INFERRED:

- Visual Drive movement may appear bursty primarily because each healthy 1 Hz coordinate update moves the simulated location a driving-distance chunk.
- A 2 Hz / 500 ms experimental cadence should reduce the expected geometric step at 35 mph to approximately:

```text
15.646 m/s x 0.5 s ~= 7.8 m/update
```

NOT YET TESTED:

- Whether 2 Hz actually improves physical visual smoothness.
- Whether 2 Hz changes native speed/course availability.
- Whether 2 Hz remains equally stable in background.

Do not claim that the 2 Hz experiment fixes bursty movement until a new physical A/B comparison is performed.

## Remaining Unknowns

- Physical A/B comparison of baseline 1 Hz versus smooth-test 2 Hz using the same route, speed, device, network, app version, and duration.
- 2 Hz foreground scheduler interval, wake jitter, DVT set latency, Core Location latency, distance per tick, snap-back behavior, and route completion timing.
- 2 Hz background scheduler interval and lifecycle behavior.
- Whether native `CLLocation.speed` and `CLLocation.course` remain unavailable at 2 Hz.
- Longer locked-screen and long-duration destination-hold behavior.
- Cellular and network-transition behavior for Drive.

## Architecture Guardrail

The characterization preserves the existing architecture:

```text
DriveView
  -> DriveSessionController
  -> DriveScheduler
  -> LocationCoordinator actor
  -> IdeviceOnDeviceTunnelClient
  -> RPPairing
  -> LocalDevVPN
  -> developer tunnel
  -> RSD
  -> DVT
  -> one retained LocationSimulation
  -> repeated location_simulation_set()
```

The next smoothing phase must preserve:

- one authoritative `LocationCoordinator`;
- one retained DVT `LocationSimulation` session per active connection;
- writer IDs and generation guards;
- no parallel static/Drive writers;
- no DVT connection per route point;
- no stale-coordinate restoration;
- `completedHolding`;
- explicit Stop/Clear;
- monotonic route-distance calculations.
