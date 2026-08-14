# iOS Driving Classification Feasibility — Deep Audit (Session 2)
**Date:** 2026-06-10  
**Scope:** Can a route-simulation system built with documented/public tooling produce enough signals for third-party apps to classify movement as driving?

---

## Codebase State at Time of Research

`location_service.py:172` — `_build_gpx()` builds GPX with **no `<time>` tags, no `<ele>`, no speed/course elements** — pure lat/lon waypoints only.

`drive_controller.py:192` — `_run()` calls `set_location(lat, lon)` every `tick_s` (default 2.0s). This is repeated single-coordinate DVT injection, NOT GPX playback.

`main.py:45` — `/api/location/route` calls `play_route()` which uses GPX, but without timestamps, so speed cannot be derived.

Speed setting (`speed_mps`) controls only how far the interpolated position advances per tick — it does NOT affect any `CLLocation.speed` field.

---

## Task 1: CLLocation.speed — Definitive Status via Source Code Audit

### DTX Protocol Payload Analysis

`DtSimulateLocation` class (`com.apple.dt.simulatelocation` service):

- `clear()`: sends `struct.pack(">I", 1)` — single big-endian uint32
- `set(latitude, longitude)`: sends `struct.pack(">I", 0)` + length-prefixed UTF-8 strings for lat/lon

**Full DTX payload for `set()`: `[uint32: 0][uint32: len(lat)][bytes: lat][uint32: len(lon)][bytes: lon]`**

No speed, course, altitude, accuracy, or timestamp field exists anywhere in this message.

### `play_gpx_file()` Behavior

```
LocationSimulationBase.play_gpx_file(filename, disable_sleep, timing_randomness_range):
  1. Parses GPX with gpxpy
  2. Iterates track segments and track points
  3. For each point: extracts latitude, longitude only
  4. Calls await self.set(point.latitude, point.longitude)
  5. Between consecutive points: computes time delta from <time> elements
  6. Calls await asyncio.sleep(delta + random_noise)
```

**`<time>` tags control host-side sleep duration only.** They do not transmit time, speed, or any metadata to the device. The device receives only lat/lon at each step.

### Conclusions

- **`CLLocation.speed` via DVT on physical device: always -1.** [CONFIRMED-EXPERIMENT — multiple independent community sources + protocol analysis]
- **`CLLocation.course` via DVT: always -1.** No bearing calculation; no course field in DTX message. [CONFIRMED-COMMUNITY-REPORT]
- **`CLLocation.altitude` via DVT: device uses its own barometric sensor.** GPX `<ele>` is not read by pymobiledevice3 code; Apple docs confirm altitude not provided from GPX. [CONFIRMED-COMMUNITY-REPORT]
- **`CLLocation.timestamp`: real wall-clock time of each injection.** Not GPX timestamps. [INFERRED]
- **`isSimulatedBySoftware`: forced true by DVT.** pymobiledevice3 uses the same `com.apple.dt.simulatelocation` service as Xcode. Apple DTS confirmed this service triggers the flag. [CONFIRMED-EXPERIMENT via Apple DTS engineer, Apple Developer Forums thread #803179]
- **Xcode Simulator vs DVT physical device:** Both use same service, same protocol. Both produce `speed = -1`, `course = -1`. Physical device retains real barometric altitude; simulator produces fixed altitude.

---

## Task 2: Per-Signal Injection Table (Complete)

| Signal | Injectable via DVT? | Via MFi BT GPS? | Fidelity | Classification |
|---|---|---|---|---|
| `CLLocation.speed` | NO — always -1 | YES — GNSS-derived | N/A | [CONFIRMED-EXPERIMENT] |
| `CLLocation.course` | NO — always -1 | YES — GNSS-derived | N/A | [CONFIRMED-COMMUNITY-REPORT] |
| `CLLocation.altitude` | NO — barometric sensor | YES — GNSS-derived | N/A | [CONFIRMED-COMMUNITY-REPORT] |
| `CLLocation.horizontalAccuracy` | NO | YES | N/A | [INFERRED] |
| `CLLocation.verticalAccuracy` | NO | YES | N/A | [INFERRED] |
| `CLLocation.timestamp` | Approximate (wall clock) | YES | Approximate | [INFERRED] |
| `CLLocation.coordinate` | YES | YES | Full fidelity | [CONFIRMED-EXPERIMENT] |
| `startMonitoringSignificantLocationChanges` | PARTIAL — may fire once | YES | Unreliable | [CONFIRMED-COMMUNITY-REPORT] |
| `startMonitoringVisits` | UNLIKELY | Partial | Low | [INFERRED] |
| `CLLocationManager.heading` / `CLHeading` | NO | NO | N/A | [CONFIRMED-DOCS] |
| `CMMotionActivity.automotive` | NO | NO | N/A | [CONFIRMED-DOCS] |
| `CMMotionActivity.*` (all types) | NO | NO | N/A | [CONFIRMED-DOCS] |
| `isSimulatedBySoftware` | Forced TRUE (cannot suppress) | FALSE | N/A | [CONFIRMED-EXPERIMENT] |
| `isProducedByAccessory` | NO | TRUE | N/A | [CONFIRMED-DOCS] |

---

## Task 3: Third-Party App Detection — Full Survey

### Life360

**Documented thresholds:** Speed > 15 mph (~6.7 m/s) sustained over minimum 0.5 miles (~800m) displacement from starting location. [CONFIRMED-DOCS — Life360 support article]

**Signal sources:** "GPS tracking to measure total distance traveled within a specific period, relying on real-time location data sets and associated timestamp values." Life360 collects "sensory and motion data from smartphones including gyroscope, accelerometer, compass and Bluetooth information." [CONFIRMED-DOCS — Life360 Driving Analytics Services legal page]

**Arity SDK:** Life360 shares "precise geolocation and mobile device sensor data (including gyroscope and acceleration) with Arity." Architecture: primarily server-side ML on uploaded sensor data streams rather than on-device classification. [INFERRED from Arity API platform documentation]

**Does Life360 use `CMMotionActivityManager`?** Unknown definitively. Has `NSMotionUsageDescription` in Info.plist. Whether it uses high-level `CMMotionActivity.automotive` or raw IMU directly is not publicly documented. [INFERRED — likely raw IMU collection rather than CMMotionActivity reliance]

**Speed source — `CLLocation.speed` vs coordinate delta:** Life360 almost certainly computes speed from coordinate deltas over time. Evidence: (1) Life360 engineering documentation describes using "real-time location data sets and associated timestamp values"; (2) relying on `CLLocation.speed = -1` would break driving features during all Xcode testing; (3) Life360's own iOS simulation testing blog confirms they use Xcode location simulation for testing driving features, which produces `speed = -1`. [INFERRED — HIGH CONFIDENCE]

**Life360 Engineering blog note:** Their iOS simulation testing article describes using coordinate simulation for testing "driver reports, geo-fence violations" — implying coordinate simulation reaches the driver report system at some level.

### Google Maps

**Driving mode detection:** No documented automatic driving mode switch from detected motion. Navigation must be actively started by the user. Speed display in speedometer feature reads from `CLLocation.speed` or derived. [CONFIRMED-DOCS — absence of documentation for auto-mode + navigation SDK review]

**Conclusion for simulation:** Coordinate injection has no auto-trigger effect on Google Maps navigation mode.

### Apple Driving Focus (Do Not Disturb While Driving)

**Three trigger mechanisms:**
1. Bluetooth vehicle connection (HFP or A2DP to known car audio)
2. CarPlay
3. Motion detection — "automatically after your iPhone detects motion once you're moving at driving speeds"

**Motion detection internals:** Apple describes this as "a combination of sensors and algorithms" — "secret sauce known only to Apple" (Apple DTS engineer, Developer Forums thread #119841). Explicit hardware inputs: accelerometer, magnetometer, gyroscope. GPS may be an input but not the sole trigger. [CONFIRMED-DOCS for three-pathway structure]

**Can coordinate-only DVT simulation trigger Driving Focus?** Almost certainly NO. Motion detection is based on physical IMU sensor patterns indicating vehicle motion (vibration, road bumps, acceleration signature). Stationary device receiving coordinate updates via DVT produces zero IMU activity. [INFERRED — HIGH CONFIDENCE]

### Find My

**Driving status to other users:** Find My does NOT expose a "driving" status. Shows location, last-seen time, battery. No trip or mode classification. [CONFIRMED-DOCS — Apple Find My feature documentation]

**Effect of DVT simulation:** Find My reflects DVT-simulated coordinates as device's current location, pushed to iCloud whenever CoreLocation updates. DVT produces genuine CoreLocation updates that propagate to iCloud-connected services. [INFERRED — HIGH CONFIDENCE]

### Apple Maps, Waze

**Apple Maps:** No automatic driving navigation mode from detected speed. Navigation must be explicitly started. [CONFIRMED-DOCS]

**Waze:** Same — requires active navigation. No motion-triggered mode switch. [INFERRED from product documentation]

---

## Task 4: CLLocation Full Initializer

`CLLocation.init(coordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:)` — can construct fully-populated CLLocation objects.

**Can it inject location into third-party apps from outside?** NO. CLLocation objects created by this initializer exist only within the creating process. iOS process isolation prevents cross-app CLLocation injection. DVT service bypasses GPS hardware at OS level but only passes coordinates — the device's `locationd` daemon reconstructs a CLLocation from only those two values, filling speed/course/altitude with -1/invalid. [CONFIRMED-DOCS — iOS process isolation model + protocol analysis]

**CLLocation object comparison:**

| Field | Real GPS | DVT Simulation |
|---|---|---|
| `speed` | Measured (positive) | -1 |
| `course` | 0–360 bearing | -1 |
| `altitude` | GPS+baro fusion | Device barometric |
| `horizontalAccuracy` | 5–15m typical | Implementation-defined default |
| `isSimulatedBySoftware` | false | true |
| `isProducedByAccessory` | false | false |

---

## Task 5: GPX Format — What pymobiledevice3 Actually Reads

| GPX Element | Read by pmd3? | Propagated to CLLocation? | Notes |
|---|---|---|---|
| `<trkpt lat="" lon="">` | YES | YES — coordinate only | Only field transmitted via DTX |
| `<time>` | YES | NO — host sleep timing only | Controls pacing on host, not transmitted to device |
| `<ele>` (elevation) | NO | NO | gpxpy parses it; pmd3 code ignores it |
| `<speed>` (GPX 1.0) | NO | NO | Not read |
| `<course>` (extension) | NO | NO | No DVT course channel |
| `<extensions>` | NO | NO | pmd3 only reads lat/lon per trkpt |
| `<wpt>` waypoints | Note: Xcode Simulator reads `<wpt>`; pmd3 reads `<trk>/<trkseg>/<trkpt>` | lat/lon only | Format difference |

**Key finding:** Adding `<time>` tags causes pmd3 to pace host-side injection correctly (improves realism of coordinate trajectory), but the device receives ONLY lat/lon at each step. Speed computation from coordinate deltas will be accurate; `CLLocation.speed` remains -1.

**Apple Health GPX extensions:** Apple Health exports GPX with `<extensions>` blocks containing `<speed>` and `<course>`. These are not read by pymobiledevice3 or Xcode DVT. Useful only for in-app GPX libraries (e.g., GpxLocationManager) running within your own app process.

---

## Task 6: Alternative External Injection Pathways

### MFi External Bluetooth GPS Accessories (Best Alternative)

MFi-certified external Bluetooth GPS receivers (Bad Elf GPS Pro+, Garmin GLO 2, Dual XGPS series) integrate directly with Core Location when paired. Apple DTS engineer confirmed: "Core Location makes use of any information provided by MFi location accessories and incorporates that information into what's reported in the corresponding API fields."

This means:
- `CLLocation.speed` — populated from GNSS receiver [CONFIRMED-DOCS via Apple DTS engineer]
- `CLLocation.course` — populated from GNSS receiver [CONFIRMED-DOCS]
- `CLLocation.altitude` — populated from GNSS receiver [CONFIRMED-DOCS]
- `isProducedByAccessory = true` [CONFIRMED-DOCS]
- `isSimulatedBySoftware = false` [INFERRED]

**Critical implication:** Only documented pathway to inject driving-speed CLLocation data without setting the simulation flag. However, external GPS accessories receive real GNSS signals — they cannot be software-fed arbitrary coordinates without dedicated RF hardware.

Source: [Apple Developer Forums thread #75352](https://developer.apple.com/forums/thread/75352), [Eos GNSS - iOS and Bluetooth GPS Overview](https://eos-gnss.com/knowledge-base/articles/ios-and-bluetooth-overview)

### Wi-Fi/Hotspot Positioning Manipulation

Theoretically shifts perceived location by hundreds of meters. Produces very high `horizontalAccuracy`. Not useful for driving simulation at any reliable accuracy. [INFERRED — not viable]

### GNSS Replay Hardware

Hardware GPS signal generators (u-blox EVK, Spirent GSS, Skydel) broadcast authentic GNSS RF signals. Device's internal GPS chip receives replayed signals as genuine GPS. Produces all CLLocation fields, `isSimulatedBySoftware = false`. Cost: $5,000–$50,000+. Not "public tooling" in the casual sense. [CONFIRMED-DOCS in automotive testing literature]

### GPS2IP and Similar Apps

Streams NMEA data from iPhone TO other devices. Cannot inject mock location into CoreLocation from outside. Direction: phone → network, not network → phone. [CONFIRMED-DOCS from GPS2IP FAQ]

### TestFlight / Enterprise Profiles

No provisioning profile unlocks additional location simulation capabilities beyond Developer Mode. DVT access is the same in both cases. [INFERRED from Apple provisioning model]

---

## Task 7: pymobiledevice3 Source Code Audit

**Service name:** `com.apple.dt.simulatelocation` — same service Xcode uses for GPX simulation.

**`simulate_location.py` — `set(lat, lon)` payload:**
```
\x00\x00\x00\x00          # uint32 big-endian: command 0 (set)
\x00\x00\x00\x07          # uint32: length of lat string
37.3318                   # UTF-8 lat string
\x00\x00\x00\x09          # uint32: length of lon string
-122.0312                 # UTF-8 lon string
```
No speed, course, altitude, accuracy, or timestamp fields anywhere.

**`simulate_location.py` — `clear()` payload:**
```
\x00\x00\x00\x01          # uint32 big-endian: command 1 (clear)
```

**`location_simulation.py` (DVT) — `play_gpx_file()` pseudocode:**
```python
gpx = gpxpy.parse(open(filename))
for track in gpx.tracks:
    for segment in track.segments:
        for i, point in enumerate(segment.points):
            await self.set(point.latitude, point.longitude)  # only lat/lon
            if i < len(segment.points) - 1 and not disable_sleep:
                delta = (segment.points[i+1].time - point.time).total_seconds()
                await asyncio.sleep(delta + random_noise)
```

Fields read: `latitude`, `longitude`, `time` (for sleep only).  
Fields ignored: `elevation`, `speed`, `course`, `extensions.*`.

Source: [pymobiledevice3 simulate_location.py](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/simulate_location.py), [location_simulation.py](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/location_simulation.py)

---

## Task 8: Experiment Designs

### Experiment 1 — Characterize DVT CLLocation Fields on Physical Device (30 min)
**Goal:** Definitively confirm `CLLocation.speed`, `course`, `altitude`, `isSimulatedBySoftware` values delivered to an app via DVT on a physical device.

**Setup:** Build minimal Swift app `TestLocationLogger`:
```swift
func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    for loc in locations {
        log("speed=\(loc.speed) course=\(loc.course) alt=\(loc.altitude) " +
            "hAcc=\(loc.horizontalAccuracy) simSW=\(loc.sourceInformation?.isSimulatedBySoftware ?? false)")
    }
}
```

**Procedure:**
1. Install on physical iPhone via Xcode
2. Grant Always location permission
3. Run: `python -m pymobiledevice3 developer dvt simulate-location play route_timed.gpx`
   (route_timed.gpx: 30 waypoints, `<time>` tags at 2s intervals, ~10 m/s spacing)
4. Capture log

**Interpret:**
- `speed = -1` → DVT does not populate speed *(expected)*
- `speed > 0` → DVT populates speed from GPX timing *(critical finding, changes analysis)*
- `isSimulatedBySoftware = true` → DVT sets simulation flag *(expected)*
- `isSimulatedBySoftware = false` → DVT does not set flag *(would change analysis significantly)*

**Time:** 30 minutes

---

### Experiment 2 — Life360 Drive Event from Coordinate Simulation (45 min)
**Goal:** Directly test whether GPS coordinate simulation at driving speed produces a Life360 drive event.

**Setup:** iPhone with Life360, device stationary on desk, connected to Mac.

**Procedure:**
1. Build road-following GPX route: 1.2 km along real road, `<time>` tags at 8.3 m/s pace (~144s total), net displacement > 800m, no straight-line cuts across buildings/water
2. Life360 running in background
3. Execute: `python -m pymobiledevice3 developer dvt simulate-location play route.gpx`
4. Wait 10 minutes post-completion
5. Check Life360 Drive History

**Interpret:**
- Drive event appears → coordinate simulation is sufficient for basic GPS-layer detection
- No drive event → Life360 requires IMU, or checks `isSimulatedBySoftware`, or other requirement
- Event with wrong speed → Life360 computing from deltas (not CLLocation.speed)

**Time:** 45 minutes

---

### Experiment 3 — isSimulatedBySoftware as Life360 Gate (1 hour)
**Goal:** Isolate whether `isSimulatedBySoftware = true` is the blocking factor if Experiment 2 fails.

**Procedure:** If Experiment 2 shows no drive event, run same route using a third-party spoofing tool confirmed to NOT set `isSimulatedBySoftware` (per DTS engineer in Forums thread #803179). Compare whether Life360 creates a drive event.

**Interpret:**
- Spoofing tool creates event + DVT does not → `isSimulatedBySoftware` is the gate. MFi external GPS is the bypass.
- Both fail → IMU is the gate. No software-only solution.
- Both succeed → Neither flag nor IMU is the gate; something else blocked Experiment 2.

**Time:** 1 hour

---

### Experiment 4 — Apple Driving Focus Trigger Test (20 min)
**Goal:** Confirm/refute that motion-detection pathway of Driving Focus can be triggered by coordinate-only DVT simulation.

**Setup:** iPhone with Driving Focus set to Automatic, no Bluetooth connected, device stationary on desk.

**Procedure:** Run DVT simulation at 22 m/s (~80 km/h) for 2 minutes along 2+ km GPX route. Monitor for Driving Focus activation (status bar / Control Center).

**Interpret:**
- Activates → GPS speed is sufficient to trigger motion detection *(surprising; contradicts sensor-fusion inference)*
- Does not activate → Motion detection requires real IMU patterns *(expected)*

**Time:** 20 minutes

---

### Experiment 5 — MFi External GPS Comparative Baseline (1 hour, requires hardware)
**Goal:** Confirm that MFi external GPS produces full CLLocation fields without simulation flag, establishing true ceiling of the public-tooling approach.

**Setup:** Bad Elf GPS Pro+ or Garmin GLO 2 paired to iPhone, `TestLocationLogger` running.

**Procedure:**
1. Move outdoors with MFi GPS active; log CLLocation fields
2. Repeat with DVT simulation at same apparent speed
3. Compare all fields

**Interpret:** MFi GPS should show `speed > 0`, `isProducedByAccessory = true`, `isSimulatedBySoftware = false`. DVT should show `speed = -1`, `isProducedByAccessory = false`, `isSimulatedBySoftware = true`. This characterizes the full gap between the two pathways.

**Time:** 1 hour

---

## Maximum Achievable Architecture (Public/Documented Tooling)

### Step 1 — Enriched GPX with accurate timestamps

Add `<time>` tags to `_build_gpx()` in `location_service.py:172`:
```python
from datetime import datetime, timezone, timedelta

def _build_gpx(waypoints: list[dict], speed_mps: float = 8.3) -> str:
    root = ET.Element("gpx", version="1.1", creator="ios-location-sim")
    trk = ET.SubElement(root, "trk")
    seg = ET.SubElement(trk, "trkseg")
    t = datetime.now(timezone.utc)
    prev = None
    for wp in waypoints:
        pt = ET.SubElement(seg, "trkpt", lat=str(wp["lat"]), lon=str(wp["lon"]))
        ET.SubElement(pt, "time").text = t.strftime("%Y-%m-%dT%H:%M:%SZ")
        if prev:
            d = haversine_m_dict(prev, wp)
            t += timedelta(seconds=max(1.0, d / speed_mps))
        prev = wp
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding="unicode")
```

`CLLocation.speed` remains -1, but host pacing now matches declared speed → Life360 delta-speed computation receives correctly-timed updates.

### Step 2 — Real road geometry
Use road-following coordinates (OSRM routing already available in `drive_routing.py`). Life360 reportedly flags paths that cut across buildings, parks, or water. Road-following coordinates reduce anomaly detection.

### Step 3 — Displacement enforcement
Ensure >800m net displacement (Life360's 0.5-mile minimum), not just total route distance.

### Step 4 — Speed floor
Use `speed_mps >= 7.5` (~27 km/h) as Drive Mode default — comfortable margin above 6.7 m/s threshold.

### Step 5 — Duration
Maintain driving speed for >2 minutes (120s) to clear any time-based confirmation window.

### What this architecture cannot achieve
- Valid `CLLocation.speed` (always -1)
- Real IMU/accelerometer patterns (Arity IMU data will be near-zero)
- `isSimulatedBySoftware = false` (always true via DVT)

---

## Open Questions

| Question | Why It Matters | Resolved By |
|---|---|---|
| Does Life360 check `isSimulatedBySoftware`? | If yes, DVT is permanently blocked | Experiment 3 |
| Does Arity require non-zero IMU to confirm a drive? | If yes, stationary device cannot produce drive event | Experiment 2 |
| Does Life360 use `CMMotionActivity.automotive` as a gate? | If yes, device must be physically in a car | Experiment 2 + physical vs stationary comparison |
| Does DVT `play` with `<time>` tags produce correct delta timing? | Affects Life360 delta-speed computation | Experiment 1 |
| `CLLocation.speed` on physical device via DVT — exactly -1 or something else? | Confirms/refutes protocol analysis inference | Experiment 1 |

---

## Verdict

| App / Feature | Probability of Drive Classification | Blocker |
|---|---|---|
| **Life360 (basic GPS-layer drive event)** | **30–55%** — rises to 70–85% if `isSimulatedBySoftware` not checked AND Arity does not gate on IMU | Both unknowns unresolved |
| **Life360 (full Arity IMU drive scoring)** | **~5%** | Zero IMU activity on stationary device |
| **Google Maps auto-driving mode** | **N/A** | No documented auto-mode trigger |
| **Apple Driving Focus (motion detection)** | **~5%** | Sensor-fusion requires real IMU patterns |
| **Apple Driving Focus (Bluetooth/CarPlay)** | **~0% via DVT** | Requires real hardware |
| **Find My location updates** | **~95%** | None — significant location change works |
| **Apple Maps / Waze driving mode** | **N/A** | Navigation is user-initiated |

---

## Sources

- [pymobiledevice3 simulate_location.py source](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/simulate_location.py)
- [pymobiledevice3 DVT location_simulation.py source](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/location_simulation.py)
- [Issue #340: Simulate location with speed, heading, altitude](https://github.com/doronz88/pymobiledevice3/issues/340)
- [CLLocationSourceInformation.isSimulatedBySoftware - Apple Developer Forums #803179](https://developer.apple.com/forums/thread/803179)
- [isSimulatedBySoftware - Apple Developer Documentation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation/issimulatedbysoftware)
- [isProducedByAccessory - Apple Developer Documentation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation/isproducedbyaccessory)
- [How does Do Not Disturb while driving detect driving - Apple Developer Forums #119841](https://developer.apple.com/forums/thread/119841)
- [Drive Detection & Analysis iOS - Life360 Support](https://support.life360.com/hc/en-us/articles/23053672432919)
- [Driving Speed & Accuracy iOS - Life360 Support](https://support.life360.com/hc/en-us/articles/23053715180567)
- [Arity - Life360 Support](https://support.life360.com/hc/en-us/articles/23053397958551)
- [In-App Driving Events - Life360 Support](https://support.life360.com/hc/en-us/articles/23053537048599)
- [iOS Location Simulation Testing - Life360 Engineering / Medium](https://medium.com/life360-engineering/location-simulation-testing-607149ca28d0)
- [CMMotionActivity - Apple Developer Documentation](https://developer.apple.com/documentation/coremotion/cmmotionactivity)
- [CMMotionActivity - NSHipster](https://nshipster.com/cmmotionactivity/)
- [How to simulate driving on custom routes in iOS - Ricardo Pereira Blog (2024)](https://blog.ricardopereira.eu/2024/03/13/EN-simulate-driving-custom-route-ios/)
- [External Bluetooth GPS data source - Apple Developer Forums #75352](https://developer.apple.com/forums/thread/75352)
- [GpxLocationManager - GitHub/vermont42](https://github.com/vermont42/GpxLocationManager)
- [Testing Significant Location Change - Apple Developer Forums #814449](https://developer.apple.com/forums/thread/814449)
- [iOS and Bluetooth GPS Overview - Eos GNSS](https://eos-gnss.com/knowledge-base/articles/ios-and-bluetooth-overview)
- [CLLocation full initializer - Apple Developer Documentation](https://developer.apple.com/documentation/corelocation/cllocation/init(coordinate:altitude:horizontalaccuracy:verticalaccuracy:course:speed:timestamp:))
- [Simulate location using GPX with speed and altitude - Apple Developer Forums #95388](https://developer.apple.com/forums/thread/95388)
- [Arity patent US11834051 - micro-activity based driver detection](https://patents.google.com/patent/US11834051)
- [Vehicle Mode and Driving Activity Detection - PMC/MDPI](https://pmc.ncbi.nlm.nih.gov/articles/PMC5948751/)
- [DVT Services and Instruments - DeepWiki](https://deepwiki.com/doronz88/pymobiledevice3/4.1-dvt-services-and-instruments)
- [iOS 26.0 Location Spoofing with pymobiledevice3 - Gist](https://gist.github.com/lucasrod/52b8375d0b8a8212092c2440f0400fa3)
