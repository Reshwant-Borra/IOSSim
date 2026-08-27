# Apple Protocol Stack

## Relevant Stack

STATUS: STRONG EVIDENCE

```text
Application code
  -> TCP path to device developer endpoint
  -> RPPairing handshake / pair-verify
  -> TLS-PSK developer tunnel
  -> RSD
  -> DVT / DTX remote server
  -> com.apple.instruments.server.services.LocationSimulation
  -> locationd / Core Location simulated provider
```

## DVT Location Simulation

STATUS: CONFIRMED

Both pymobiledevice3 and idevice implement the same DVT service and selector names.

pymobiledevice3:

- Service identifier: `com.apple.instruments.server.services.LocationSimulation`.
- Set selector: `simulateLocationWithLatitude:longitude:`.
- Clear selector: `stopLocationSimulation`.

idevice:

- Opens channel `com.apple.instruments.server.services.LocationSimulation`.
- `set()` sends `simulateLocationWithLatitude:longitude:` with archived f64 latitude/longitude arguments.
- `clear()` sends `stopLocationSimulation`.
- Module comment says the connection must be maintained to keep location simulated.

## Tunnel Creation

STATUS: STRONG EVIDENCE

idevice FFI documents three relevant tunnel paths:

- USB via CoreDeviceProxy.
- Network via RemoteXPC after connecting to RSD and `com.apple.internal.dt.coredevice.untrusted.tunnelservice`.
- Network via raw RPPairing for `_remotepairing._tcp`, where direct TCP is followed by RPPairing JSON and tunnel creation.

The on-device Locus path uses raw RPPairing to `10.7.0.1:49152`, not pymobiledevice3's host-side userspace tunnel.

## Pairable Host On iOS 27+

STATUS: PLAUSIBLE / STRONG EVIDENCE

Apple Device Hub documentation says iOS/iPadOS 27 or later is needed to wirelessly pair an iPhone/iPad. idevice and Locus contain source for a pairable-host responder that advertises `_remotepairing-pairable-host._tcp`, displays a six-digit PIN, and receives an RPPairing file after the device completes pairing.

Important distinction:

- Apple-supported: device can pair wirelessly with a Mac/Xcode host on iOS 27+.
- Observed open-source behavior: an app can advertise a Mac-like pairable host from the iPhone and relay the pairing conversation to a local Rust responder.
- Speculative: long-term robustness and Apple supportability of same-device PairableHost are not documented by Apple.

## Core Location Verification

STATUS: CONFIRMED APPLE API

Apple exposes `CLLocationSourceInformation.isSimulatedBySoftware` and `isProducedByAccessory`. The POC verifier should record both to confirm whether DVT is producing software-simulated locations rather than accessory-derived or network-derived coordinates.
