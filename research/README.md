# Research Notes — iOS Driving Detection

This folder contains raw research audits conducted on iOS driving detection signals, DVT simulation capabilities, and third-party app behavior.

## Files

| File | Session | Scope |
|---|---|---|
| `01_driving_signal_audit.md` | 2026-06-09 | Signal inventory, DVT simulation feasibility table, per-app detection mechanisms, definitive gaps |
| `02_driving_classification_feasibility.md` | 2026-06-10 | DVT protocol source code audit, full per-signal injection table, Life360/Apple Driving Focus/Google Maps verdict, experiment designs, maximum achievable architecture |
| `03_commercial_spoofers_analysis.md` | 2026-06-10 | Tool-by-tool analysis (iAnyGo, Dr.Fone, Locsim, GFaker, jailbreak tweaks); CLLocation.speed > 0 achievement table; Life360 compatibility evidence |
| `04_bluetooth_gps_emulation.md` | 2026-06-10 | MFi Track A (iAP2 + auth chip) vs BLE Track B (GATT LNS, app-level only); macOS CBPeripheralManager; GFaker / iTools BT 2.5; verdict table |
| `05_pymobiledevice3_protocol_audit.md` | 2026-06-10 | Complete DVT channel inventory (17 modules); full DTX interface spec for LocationSimulation; all related GitHub issues; iOS 17/18 transport changes |
| `06_life360_detection_gate_analysis.md` | 2026-06-10 | Life360 official sensor requirements; Arity SDK architecture; isSimulatedBySoftware filter verdict; two-gate model; community evidence; per-scenario confidence table |
| `07_synthesis_and_verdict.md` | 2026-06-10 | **Final synthesis.** Definitive what-is/isn't-possible table; >80% confidence path; maximum achievable architecture; recommended next steps |

## Key Findings (Quick Reference)

- **DVT sends only lat/lon** — the DTX payload contains no speed, course, altitude, or timestamp fields. Confirmed by protocol/source code analysis across pymobiledevice3, go-ios, libimobiledevice.
- **`CLLocation.speed` is always -1 via DVT** — no field in the wire protocol to carry it.
- **`<time>` tags in GPX** control host-side sleep only. They do NOT transmit timing to the device.
- **`isSimulatedBySoftware` is forced `true`** by DVT. Life360 does NOT filter on it (confirmed by Life360 engineering blog using Xcode simulation for drive testing).
- **`CMMotionActivity.automotive` is hardware-gated** — M-series coprocessor, no DVT injection channel exists. This is the hard gate for Arity SDK.
- **Life360 derives speed from coordinate deltas**, not `CLLocation.speed`. The 15 mph / 0.5 mile thresholds are meetable via coordinate injection.
- **Arity SDK (Life360's analytics engine) requires GPS + accelerometer + gyroscope**. "If Motion & Fitness access is disabled, trips won't be logged." IMU is non-optional.
- **The >80% confidence path**: Device physically in a moving vehicle + DVT GPS override from Mac. Real IMU passes Arity's gates; DVT controls the displayed GPS coordinates.

## Resolved vs. Remaining Unknowns

| Question | Status | Answer |
|---|---|---|
| Does Life360 filter on `isSimulatedBySoftware`? | **RESOLVED** | No — Life360 engineering uses Xcode (DVT) simulation for drive testing |
| Does Arity require non-zero IMU data? | **RESOLVED** | Yes — official docs + Arity architecture confirm IMU is a hard gate |
| Can DVT produce CLLocation.speed > 0? | **RESOLVED** | No — wire protocol is lat/lon only; Life360 uses delta computation instead |
| Does Locsim `--speed` propagate to CLLocation.speed? | **UNRESOLVED** | Likely no; parameter appears to control animation rate only |
| Does XCTest location with course bridge to richer DTX call? | **UNRESOLVED** | Unknown; would require packet capture on USB while XCTest runs |

## Confidence-Ordered Approaches for Life360 Drive Events

| Approach | Confidence | Complexity | Cost |
|---|---|---|---|
| Device in moving vehicle + DVT GPS override | **87%** | Low | USB cable |
| GFaker MFi hardware + device in vehicle | 93% | Medium | ~$60 hardware |
| Jailbreak CMMotionActivity hook + DVT GPS | 68% | High | Jailbroken device |
| GFaker MFi hardware, stationary device | 45% | Medium | ~$60 hardware |
| DVT route animation, stationary device | 12% | Low | Nothing |

## Recommended Next Step

**Experiment: Place iPhone in moving vehicle, run DriveController from Mac via USB.** Drive at >15 mph for >0.5 miles with DVT overriding GPS to desired coordinates. Observe Life360 for drive event creation. This is the 87% confidence path and costs nothing beyond a drive.

Before running: confirm Life360 has **Motion & Fitness** permission on the test device. Without it, Arity cannot read IMU data and the experiment will fail regardless of GPS.
