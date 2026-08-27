# Current IOSSim Baseline

## Repository State At Audit Start

- Branch: `main`
- Starting commit: `70a925b85f2653527e7a12461a055c9d5193390c`
- Working tree: dirty before this research task; existing modified/untracked app files were left untouched.

## Existing Architecture

STATUS: CONFIRMED

The documented approximate path is accurate for the current wireless implementation:

```text
saved iPhone UDID
  -> UserspaceRsdTunnel(serial=UDID)
  -> RSD
  -> DvtProvider
  -> DeviceInfo warmup
  -> LocationSimulation
  -> set(latitude, longitude)
```

Source: `backend/wireless_location/session.py`.

- Imports `UserspaceRsdTunnel`, `DeviceInfo`, `DvtProvider`, and `LocationSimulation` at lines 11-16.
- `connect()` creates `UserspaceRsdTunnel(serial=self.device_udid)` at line 104.
- It awaits `tunnel.aopen()` for RSD at line 105.
- It verifies the RSD UDID at line 106.
- It creates and connects `DvtProvider` at lines 107-108.
- It runs the DeviceInfo warmup at lines 109 and 221-224.
- It creates/connects `LocationSimulation` at lines 110-111.
- `set_location()` calls `self.location.set(lat, lon)` at line 129.
- `clear_location()` calls `self.location.clear()` at line 144.

## Setup And Discovery

STATUS: CONFIRMED

The current setup is host-side and network-discovery dependent.

Source: `backend/wireless_location/discovery.py`.

- USB list: `pymobiledevice3 usbmux list --usb`, lines 43-45.
- Network list: `pymobiledevice3 usbmux list --network`, lines 47-49.
- RemotePairing bootstrap: `pymobiledevice3 lockdown remotepairing --pair`, lines 112-131.
- Wi-Fi connection enablement: `pymobiledevice3 lockdown wifi-connections --state on`, lines 133-152.

Source: `backend/wireless_location/controller.py`.

- `begin_setup()` requires a single USB device and saves only the selected UDID/metadata, lines 69-113.
- `verify_setup_unplugged()` requires USB absent and network presence, lines 115-146.
- `connect_wireless()` refuses to connect when `network_present` is false, lines 148-178.
- `should_use_wireless()` only selects wireless if the saved device is visible over the network, lines 191-207.

## Reconnect Behavior

STATUS: CONFIRMED

Current reconnect restores the last desired coordinate only if host-side network discovery still sees the same device.

- `WirelessUserspaceLocationSession.reconnect_and_restore()` disconnects, reconnects, then calls `set_location()` for the cached target, lines 153-173.
- `WirelessLocationController._recover_if_same_device_visible()` refuses recovery when the selected UDID is no longer network-present, lines 321-336.

This does not solve the on-device target because a carried iPhone cannot depend on the Mac host, usbmuxd, or same-LAN discovery.

## USB / Existing Stable DVT Path

STATUS: CONFIRMED

`backend/location_service.py` implements the host-side DVT CLI path.

- iOS 17+ commands use `developer dvt simulate-location`, lines 65-69.
- `set_location()` requires an active RSD tunnel and starts a long-lived pymobiledevice3 process, lines 71-108.
- `clear_location()` calls the DVT clear command over the existing RSD tunnel, lines 110-132.
- GPX/route playback delegates to the pymobiledevice3 DVT play command, lines 168-286.

## What IOSSim Already Proves

STATUS: CONFIRMED BY LOCAL DOCS

`docs/validation_evidence/wireless_userspace_location.md` records a known-good host-side wireless userspace path:

```text
UserspaceRsdTunnel(real_udid)
  -> RemoteServiceDiscoveryService
  -> DvtProvider
  -> DeviceInfo(dvt).ls("/")
  -> LocationSimulation(dvt)
  -> set() / clear()
```

That document states that USB was absent during spoofing, the same UDID was reachable over Wi-Fi, Maps and Find My followed the spoofed location, multiple coordinate changes worked, and TCP/QUIC native paths were not the stable path. This is a strong baseline for the DVT layer but not proof of same-device/on-iPhone operation.
