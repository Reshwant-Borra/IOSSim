# Session Persistence Findings

Date: 2026-08-27

Branch: `poc/on-device-dvt`

## Physical Observation

STATUS: PARTIAL PHYSICAL SUCCESS

The E1 path now has strong physical evidence:

- iPhone unplugged from Mac.
- LocalDevVPN active.
- valid RPPairing already imported.
- IOSSim POC launched directly on iPhone.
- no USB runtime connection.

The POC reported PASS through Pairing, LocalDevVPN, Endpoint, Developer Tunnel, RSD, DeviceInfo, DVT, and LocationSimulation. `SET TEST LOCATION` changed the iPhone's reported location.

The simulated location was not stable. One run lasted only a few seconds. A later unplugged run lasted approximately 15 seconds before reverting.

## Runtime Lifetime Trace

STATUS: CONFIRMED FROM IOSSim SOURCE

IOSSim current path:

```text
KeychainRPPairingStore.loadPairingData()
  -> RPPairingValidator.validate()
  -> temporary protected pairing plist for FFI only
  -> rp_pairing_file_read()
  -> tunnel_create_rppairing(10.7.0.1:49152)
  -> retain adapter + RSD handshake on IdeviceOnDeviceTunnelClient
  -> remote_server_connect_rsd()
  -> retain remoteServer until service creation
  -> DeviceInfo warmup over remoteServer
  -> location_simulation_new(remoteServer)
  -> retain LocationSimulation handle on IdeviceOnDeviceTunnelClient
  -> remoteServer pointer set nil after service/channel creation
  -> location_simulation_set()
```

The `OnDeviceDVTExperimentRunner` strongly retains the tunnel client. The tunnel client stores the FFI `adapter`, `handshake`, and `locationSimulation` handles as instance fields. `cleanup()` frees those handles only on explicit `clear()`, explicit `disconnect()`, or FFI error paths.

## Locus Comparison

STATUS: CONFIRMED FROM PINNED SOURCE

Pinned Locus: `83c8fb324983728e8f44759cfd834dc637ee38b5`.

| Component | Locus lifetime | IOSSim previous lifetime | Difference |
| --------- | -------------- | ------------------------ | ---------- |
| RPPairing credentials | Stored under Application Support and read into an FFI handle per connection attempt; FFI pairing handle is freed after tunnel creation. | Stored in Keychain, copied to a temporary protected plist for `rp_pairing_file_read`; FFI pairing handle is freed after tunnel creation. | Storage differs, but both keep pairing only long enough for tunnel setup. Not a likely 15-second cause. |
| Developer tunnel adapter | Static `adapter` retained until `cleanup()`. | Instance `adapter` retained by `IdeviceOnDeviceTunnelClient` until `cleanup()`. | No meaningful ownership difference if the runner remains alive. |
| RSD handshake | Static `handshake` retained until `cleanup()`. | Instance `handshake` retained by `IdeviceOnDeviceTunnelClient` until `cleanup()`. | No meaningful ownership difference if the runner remains alive. |
| RSD remote server | Static `remoteServer` retained until `location_simulation_new`, then set to nil. | Instance `remoteServer` retained until `location_simulation_new`, then set to nil. | No difference. Earlier concern about remoteServer lifetime is not supported by current Locus source. |
| DeviceInfo | Locus does not perform IOSSim's DeviceInfo warmup in the audited path. | IOSSim creates DeviceInfo, lists `/`, then frees DeviceInfo. | IOSSim extra warmup matches known host-side behavior; not a likely persistence loss cause. |
| DVT/LocationSimulation | Static `locationSimulation` retained until clear/error cleanup. | Instance `locationSimulation` retained until clear/error cleanup. | No handle-retention difference if app remains running. |
| Background execution | `SpoofSession` starts a `UIBackgroundTask`, has `UIBackgroundModes` including `location`, and starts `BackgroundKeepAlive` with `allowsBackgroundLocationUpdates = true`. | Previous POC had no background task, no background mode, and Core Location was used only as a short verifier. | Significant difference. Capable of explaining a ~15-second loss if the user leaves the POC or iOS suspends it. |
| Continued traffic | Locus schedules an 8-second resend timer and a 12-second health timer after successful set. | Previous POC sent one set and performed no health/resend loop. | Difference noted, but not used as the first fix because source only proves the DVT connection must remain alive, not that periodic coordinate resend is required. |

## idevice Ownership Evidence

STATUS: CONFIRMED FROM PINNED SOURCE

Pinned idevice: `c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5`.

`LocationSimulationClient` source says a connection must be maintained to keep location simulated. The FFI `LocationSimulationHandle` wraps `LocationSimulationClient`, and `location_simulation_free` drops that client. `RemoteServerClient` has a `Drop` implementation that aborts its reader task, but the `LocationSimulationClient` channel shares transport state after creation.

Therefore the first requirement is not "keep calling set"; it is "prove the app and handle-owning client remain alive, and prove the connection is not being torn down."

## Most Likely Cause

STATUS: EVIDENCE-BACKED HYPOTHESIS / NEEDS RECORDER CONFIRMATION

The most likely cause of the approximately 15-second loss is iOS application lifecycle/background suspension interrupting the long-lived DVT/LocationSimulation connection or the handle-owning process.

Evidence:

- The physical set command succeeds, so pairing, route, endpoint, tunnel, RSD, DVT, and LocationSimulation are all initially viable.
- IOSSim retains the critical FFI handles while the runner/client remain alive.
- Locus retains the same core handles but also starts background execution/location keepalive machinery that the previous POC lacked.
- The idevice service source explicitly says the connection must be maintained to keep simulated location active.
- A few-seconds to approximately 15-second lifetime is consistent with a foreground/background execution boundary, but this must be confirmed by diagnostic logs.

Not yet proven:

- Whether the tunnel receives EOF.
- Whether LocalDevVPN route disappears.
- Whether the developer endpoint becomes unavailable.
- Whether DVT/LocationSimulation remains alive while Core Location reverts.
- Whether a DTX idle timeout requires protocol traffic.

## Persistence Fix Implemented

STATUS: SOFTWARE READY / PHYSICAL VALIDATION PENDING

Minimum justified fix:

- Start a diagnostic session on `CONNECT`.
- Start Core Location observation at connect time.
- After one successful `SET`, keep a background task active and restart Core Location in background-capable mode.
- Add explicit `NSLocationAlwaysAndWhenInUseUsageDescription`, `UIBackgroundModes = location`, and file sharing keys through an explicit Info.plist.

No periodic coordinate resend was added. That remains intentionally excluded until the recorder shows that a live app, live route, and retained DVT session still revert solely because of idle protocol behavior.

## Validation Ladder

STATUS: READY TO RUN

Run in order, with one `SET TEST LOCATION` and no resend:

| Test | Target | Status |
| -- | -- | -- |
| P1 | 30 seconds | READY TO RUN |
| P2 | 2 minutes | READY TO RUN |
| P3 | 10 minutes | READY TO RUN |
| P4 | 30 minutes | READY TO RUN |

Do not run P2 if P1 fails. Do not run P4 before P3 succeeds.

## Failure Classification

The recorder is intended to classify the next failure as:

- A - ROUTE LOSS
- B - ENDPOINT LOSS
- C - TUNNEL LOSS
- D - RSD LOSS
- E - DVT LOSS
- F - LOCATIONSIMULATION LOSS
- G - CORE LOCATION REVERSION
- H - APP LIFECYCLE
- I - UNKNOWN

If the location reverts again, inspect the exported JSONL/summary before applying another fix.
