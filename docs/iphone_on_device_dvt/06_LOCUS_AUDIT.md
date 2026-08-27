# Locus Audit

Repository: `https://github.com/ChrisMack32/Locus`

Audited commit: `83c8fb324983728e8f44759cfd834dc637ee38b5`

License: MIT.

## Verdict

STATUS: CONFIRMED

Locus implements the target on-device DVT mechanism at source level. It is the strongest available evidence that IOSSim can build a Mac-once iPhone-only POC.

## Pairing

STATUS: CONFIRMED

Locus imports and stores an RPPairing plist:

- `PairingStore.fileName = "rp_pairing_file.plist"`.
- It accepts `.plist`, `.mobiledevicepairing`, `.mobiledevicepair`, and a custom UTI.
- It stores under app Application Support `Pairing/`.
- It writes atomically and sets POSIX permissions `0600`.
- It validates only plist shape, not semantic RPPairing keys; IOSSim should validate semantic keys.

Locus also has an iOS 27 same-device pairing path:

- `PairOnDeviceService` starts a worker thread and calls `pairable_host_accept`.
- It displays a six-digit PIN and writes the returned RPPairing file.
- `PairableHostAdvertiser` publishes `_remotepairing-pairable-host._tcp` via `NWListener` and relays inbound TCP to a Rust loopback listener.

## Networking

STATUS: CONFIRMED

Locus's `LocationEngine` creates an IPv4 `sockaddr_in` for `TunnelConfig.targetIP` port `49152`. `TunnelConfig.targetIP` defaults to `10.7.0.1`, matching LocalDevVPN.

It does not discover the same iPhone dynamically in the runtime path. It assumes the LocalDevVPN address and Apple's developer listener are reachable there.

## Developer Tunnel

STATUS: CONFIRMED

`LocationEngine` calls:

```text
rp_pairing_file_read(pairingPath)
tunnel_create_rppairing(10.7.0.1:49152, "LocusLocation", pairingHandle, ...)
remote_server_connect_rsd(adapter, handshake, ...)
location_simulation_new(remoteServer, ...)
location_simulation_set(...)
```

This is raw RPPairing over TCP, then TLS-PSK tunnel, then RSD/DVT. It is not QUIC in the audited Locus code path.

## DVT

STATUS: CONFIRMED

The Locus DVT call flows into idevice's `LocationSimulationClient`, which opens `com.apple.instruments.server.services.LocationSimulation`, calls `simulateLocationWithLatitude:longitude:` for set, and `stopLocationSimulation` for clear.

The source keeps `adapter`, `handshake`, and `locationSimulation` as static variables. Repeated coordinate changes reuse the active session if possible. Clearing frees the simulation/tunnel objects.

## Cellular

STATUS: STRONG EVIDENCE FOR CONTINUATION, UNKNOWN FOR COLD-START

Locus README says: "Start a teleport on Wi-Fi first; the session can keep working on cellular afterward." Its error text for tunnel creation asks whether LocalDevVPN is connected on Wi-Fi. I found no source proving cellular-only cold-start.

Locus implements:

- periodic resend every 8 seconds;
- health check timer;
- joystick updates every 0.25 seconds;
- background keep-alive helpers.

These support Drive/route readiness later, but they do not prove cellular cold-start.

## Dependencies

STATUS: CONFIRMED

- idevice FFI static library: MIT.
- SwiftUI/MapKit/CoreLocation/Network framework.
- External LocalDevVPN for packet tunnel where Locus itself lacks NetworkExtension entitlement.

Reuse assessment: study the architecture and reuse/port MIT idevice pieces where practical. Do not copy Locus app/UI/session code into IOSSim; it is product-specific and mixes pairing, maps, background, joystick, and route logic.
