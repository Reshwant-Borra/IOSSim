# pymobiledevice3 Protocol Audit — All DVT Channels, Alternative Tools, Private APIs
**Date:** 2026-06-10  
**Agent:** pymobiledevice3 undocumented channels + private CoreLocation APIs  
**Scope:** Complete inventory of DVT channels; alternative tools; private API injection paths

---

## Complete DVT Instruments Channel Inventory

The complete list of DVT instrument modules in pymobiledevice3 as of early 2026:

| Module | Channel Service | Relevant? |
|---|---|---|
| `activity_trace_tap.py` | `com.apple.instruments.server.services.activitytracetap` | Read-only log consumer. NOT an injector. |
| `application_listing.py` | — | App enumeration only |
| `condition_inducer.py` | `com.apple.instruments.server.services.ConditionInducer` | **Network conditions only** — packet loss, bandwidth, latency. No sensors. |
| `core_profile_session_tap.py` | — | Kernel profiling only |
| `device_info.py` | `com.apple.instruments.server.services.deviceinfo` | Read-only device metadata |
| `energy_monitor.py` | — | Battery/power monitoring |
| `graphics.py` | — | GPU profiling |
| **`location_simulation.py`** | `com.apple.instruments.server.services.LocationSimulation` | **Only location-related channel** |
| `location_simulation_base.py` | — | GPX file parser; base class for `location_simulation.py` |
| `network_monitor.py` | — | Network traffic monitoring |
| `notifications.py` | — | Push notification dispatch |
| `process_control.py` | `com.apple.instruments.server.services.processcontrol` | App launch/kill |
| `screenshot.py` | — | Screen capture |
| `sysmontap.py` | — | CPU/memory/disk monitoring |
| `tap.py` | — | Base instrumentation |

**No channel bears any name containing "motion," "sensor," "activity," "heading," "barometer," "speed," or "course."**

---

## LocationSimulation DTX Interface — Complete Specification

The `LocationSimulation` service's COMPLETE DTX interface:

```python
@dtx_method("simulateLocationWithLatitude:longitude:")
async def simulate_location_with_latitude_longitude_(
    self, latitude: float, longitude: float
) -> None: ...

@dtx_method("stopLocationSimulation", expects_reply=False)
async def stop_location_simulation(self) -> None: ...
```

**Two float arguments — latitude and longitude — and nothing else.** No speed, course, heading, altitude, or accuracy fields exist at the protocol layer.

The ObjC selector name is literal: `simulateLocationWithLatitude:longitude:` — a two-parameter selector. There is no private overload `simulateLocationWithLatitude:longitude:speed:course:heading:altitude:` in any documented or reverse-engineered source.

---

## GPX Playback — What Gets Discarded

`location_simulation_base.py` pseudocode:
```python
gpx = gpxpy.parse(open(filename))
for track in gpx.tracks:
    for segment in track.segments:
        for i, point in enumerate(segment.points):
            await self.set(point.latitude, point.longitude)  # ONLY lat/lon
            if not disable_sleep and point.time:
                delta = (segment.points[i+1].time - point.time).total_seconds()
                await asyncio.sleep(delta + random_noise)
```

Fields **read:** `latitude`, `longitude`, `time` (for host-side sleep only)  
Fields **ignored/discarded:** `elevation`, `speed`, `course`, `extensions.*`

`<time>` tags control host-side sleep between coordinates. The device receives no timestamp information.

---

## pymobiledevice3 Issue Tracker — All Relevant Issues

| Issue | Title | Status | Conclusion |
|---|---|---|---|
| [#340](https://github.com/doronz88/pymobiledevice3/issues/340) | Simulate location with speed, heading and altitude | **Open** (Oct 2022) | Feature never implemented; no workaround |
| [#572](https://github.com/doronz88/pymobiledevice3/issues/572) | Unreliable simulate-location with iOS 17 | Open | Transport regression; no new fields |
| [#767](https://github.com/doronz88/pymobiledevice3/issues/767) | `dvt simulate-location` doesn't self-exit | Open | Hang issue; transport problem |
| [#975](https://github.com/doronz88/pymobiledevice3/issues/975) | LocationSimulation — InvalidServiceError | Open | iOS 17.3.1 connection error |

No closed issue offers a workaround for speed/course injection. No issue references a private selector beyond `simulateLocationWithLatitude:longitude:`.

---

## Alternative DVT Tools

### libimobiledevice / idevicesetlocation
- `idevicesetlocation -- LAT LONG` — confirms two positional arguments only
- iOS 17+ support still incomplete as of early 2025

### go-ios (danielpaulus)
- `setlocation --lat X --lon Y` — lat/lon only
- `setlocationgpx --gpxfilepath X` — feeds waypoints through same DVT selector; discards speed/course from GPX
- Go implementation (`dtx_codec`) mirrors pymobiledevice3's protocol exactly

### idb (Facebook)
- No location simulation on physical devices
- `FBInstrumentsClient.h`: only `launchApplication:` and `killProcess:`
- Speed/course simulation in idb is **simulator-only** via `CoreSimulator.framework` methods: `startLocationSimulationWithDistance:speed:waypoints:error:`
- idb's physical device support largely broken since iOS 17 (CoreDevice/RemoteXPC transition)

### xctrace / Instruments
- No location simulation on physical devices
- `UIAutomation.setLocationWithOptions()` (accepted speed/altitude dictionary) was deprecated Xcode 9 and fully removed
- CoreSimulator private methods with speed support are **simulator-only**

---

## iOS 17/18 DVT Changes — Transport vs. Protocol

iOS 17 introduced the **CoreDevice / RemoteXPC** transport (QUIC/TCP tunnel over `com.apple.internal.dt.coredevice.untrusted.tunnelservice`). DVT services now require establishing a virtual IPv6 tunnel first.

**What changed:** Transport layer (how you reach the service)  
**What did NOT change:** The DVT `LocationSimulation` service interface — still `simulateLocationWithLatitude:longitude:` only

No WWDC 2023, 2024, or 2025 session mentions new DVT location simulation fields. Xcode release notes for iOS 17/18 contain no DVT location protocol additions.

---

## DTX Protocol Reverse Engineering — Recon Montreal 2018

Troy Bowman's "Discovering the iOS Instruments Server" (Recon Montreal 2018) is the foundational public reverse engineering of DTXConnectionServices. It documented the DTX binary RPC framing (32-byte header + 16-byte payload header) and NSKeyedArchiver payload format.

**Key finding:** No subsequent BlackHat, DEF CON, MOSEC, or POC talk has identified a location simulation command with speed/course/heading beyond the two-argument selector. The DTX reverse engineering community consensus is that no hidden extended location method exists.

**Suggested verification:** Use Frida on a jailbroken device to dump the full method list of `DTInstrumentsServer` ObjC class to conclusively verify no hidden `simulateLocationWithLatitude:longitude:speed:course:` overload exists.

---

## CoreLocation SPI / Private Framework Injection into locationd

`locationd` communicates via XPC using bplist17-encoded messages containing `longitude`, `latitude`, and `accuracy`. Research by 8ksec using Frida confirmed these three fields in the XPC payload — no speed or course fields observed in the channel apps receive.

Injection into `locationd` from an external Mac/PC host requires:
- Entitlement `com.apple.private.location.*` (Apple-internal only)
- OR jailbreak tweak hooking locationd XPC dispatch
- OR the DVT pathway (which only accepts lat/lon)

No external-host tool that achieves locationd injection with speed/course on an unmodified device has been documented in public research.

---

## ConditionInducer — Not Relevant

Three methods: `available_condition_inducers()`, `enable_condition_with_identifier_profile_identifier_()`, `disable_active_condition()`. Strictly network conditioning: packet loss, bandwidth throttling, latency. No interaction with location services, motion sensors, barometer, magnetometer, or any physical sensor subsystem.

---

## CMMotionActivity.automotive — External Injection Verdict

No known external-host channel exists to inject `CMMotionActivity` state:
- No DVT instrument channel for motion/activity injection
- `ActivityTraceTap` is read-only log consumer only
- M-series motion coprocessor runs independently; no DTX message reaches it
- ConditionInducer is network-only
- No public CoreDevice/RemoteXPC service for motion injection exists

Only three approaches work:
1. **In-app method swizzling** (GeoFake) — requires modifying the app under test
2. **Jailbreak tweaks** hooking the motion daemon
3. **Physical device movement** — real vehicular motion triggers real automotive classification

---

## Key Open Questions

1. **Locsim's `--speed` flag**: Does it actually modify the DTX message payload, or is it post-processed by the daemon? Protocol packet capture (USB traffic analysis while Locsim runs) would resolve this definitively.

2. **CoreDevice RPC namespace**: Run `developer.supported_identifiers` via pymobiledevice3 on iOS 17/18 device to check if any motion/sensor/activity service identifiers exist in the `com.apple.coredevice.*` namespace.

3. **XCUIDevice.location in XCTest on physical device**: Does the `course` parameter in XCTest's location simulation bridge to a richer DTX call, or is it still lat/lon only?

---

## Sources

- [pymobiledevice3 location_simulation.py](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/location_simulation.py)
- [pymobiledevice3 location_simulation_base.py](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/location_simulation_base.py)
- [pymobiledevice3 condition_inducer.py](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/condition_inducer.py)
- [pymobiledevice3 Issue #340](https://github.com/doronz88/pymobiledevice3/issues/340)
- [Recon Montreal 2018 — Discovering iOS Instruments Server](https://recon.cx/2018/montreal/schedule/system/event_attachments/attachments/000/000/043/original/RECON-MTL-2018-Discovering_the_iOS_Instruments_Server.pdf)
- [dtxmsg IDA plugin — troybowman](https://github.com/troybowman/dtxmsg)
- [go-ios main.go setlocation](https://github.com/danielpaulus/go-ios/blob/main/main.go)
- [idb FBInstrumentsClient.h](https://github.com/facebook/idb/blob/main/FBDeviceControl/Management/FBInstrumentsClient.h)
- [8ksec Frida locationd XPC analysis](https://8ksec.io/advanced-frida-usage-part-4-sniffing-location-data-from-locationd-in-ios/)
- [Apple Developer Forums thread #95388 — GPX speed/altitude not provided](https://developer.apple.com/forums/thread/95388)
- [LocationSimulator Issue #175 — heading simulator-only](https://github.com/Schlaubischlump/LocationSimulator/issues/175)
- [pymobiledevice3 RemoteXPC.md](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md)
- [Ricardo Pereira blog — simulate driving iOS (Mar 2024)](https://blog.ricardopereira.eu/2024/03/13/EN-simulate-driving-custom-route-ios/)
- [GeoFake — AlohaYos](https://github.com/AlohaYos/GeoFake)
- [idevicesetlocation man page](https://www.mankier.com/1/idevicesetlocation)
