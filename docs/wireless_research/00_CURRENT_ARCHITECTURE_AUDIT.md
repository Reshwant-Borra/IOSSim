# 00 Current Architecture Audit

Date: 2026-07-28  
Repository: `Reshwant-Borra/IOSSim` / local workspace `C:\Users\reshw\Desktop\ios-location-sim`  
Scope: repository-only audit before external wireless research.

## A. Current architecture

The stable IOSSim path is:

```text
Frontend React UI
  -> frontend/src/api/client.ts
  -> FastAPI backend in backend/main.py
  -> DeviceManager in backend/device_manager.py
  -> LocationService in backend/location_service.py
  -> python -m pymobiledevice3 ...
  -> DVT simulate-location
  -> RSD/tunnel for iOS 17+
  -> physical iPhone
```

Concrete code path:

1. `frontend/src/components/DevicePanel.tsx` polls `api.status()`, then runs setup by calling `api.mountDdi()` and, for iOS 17+, `api.startTunnel()`.
2. `frontend/src/api/client.ts` maps those calls to `/api/status`, `/api/setup/mount-ddi`, `/api/setup/tunnel`, `/api/location/set`, and `/api/location/clear`.
3. `backend/main.py` exposes these FastAPI endpoints and delegates device/tunnel setup to `DeviceManager`, then location writes to `LocationService`.
4. `backend/device_manager.py` detects the device through `pymobiledevice3.lockdown.create_using_usbmux()` or `python -m pymobiledevice3 usbmux list`.
5. `backend/device_manager.py` mounts the Developer Disk Image using `python -m pymobiledevice3 mounter auto-mount`.
6. For iOS 17+, `backend/device_manager.py` starts a long-lived subprocess:

   ```text
   python -m pymobiledevice3 lockdown start-tunnel --script-mode
   ```

   It parses stdout for the RSD address/port and stores them in `TunnelInfo`.
7. `backend/location_service.py` uses the stored RSD endpoint for iOS 17+:

   ```text
   python -m pymobiledevice3 developer dvt simulate-location set --rsd HOST PORT -- LAT LON
   python -m pymobiledevice3 developer dvt simulate-location clear --rsd HOST PORT
   python -m pymobiledevice3 developer dvt simulate-location play --rsd HOST PORT FILE.gpx
   ```

8. For iOS <= 16, `LocationService` uses legacy:

   ```text
   python -m pymobiledevice3 developer simulate-location set -- LAT LON
   python -m pymobiledevice3 developer simulate-location clear
   ```

The active static set path intentionally keeps the `simulate-location set` subprocess alive. README and setup docs state the backend must remain open for stable operation.

## B. Current hard USB dependencies

Current code assumes USB at these points:

- Setup docs require the iPhone to be connected by USB, trusted, and unlocked before use.
- `DevicePanel.tsx` displays the setup blocker text: “Connect your iPhone via USB first.”
- `DeviceManager.detect()` uses `create_using_usbmux()` first and falls back to `python -m pymobiledevice3 usbmux list`.
- `DeviceManager.start_tunnel()` uses `pymobiledevice3 lockdown start-tunnel --script-mode`, whose default path discovers the device through usbmux.
- README and `SETUP_MAC.md` explicitly say to keep the USB cable connected and backend running.

Important nuance: the installed pymobiledevice3 help says `usbmux list` can list “USB and Wi-Fi” devices, and `lockdown start-tunnel` has `--mobdev2` and `--usbmux HOST:PORT` options. The current IOSSim implementation does not use those options and does not attempt network or remote pairing discovery.

## C. Current host dependencies

Current host requirements are:

- Python 3.11+.
- `pymobiledevice3`; local installed version during audit: `9.12.0`.
- FastAPI/uvicorn backend.
- Node/Vite frontend.
- Apple Mobile Device Support / usbmux on Windows via standalone iTunes.
- Built-in usbmux support on macOS.
- Developer Mode enabled on the iPhone.
- Trust/pairing with the host.
- Elevated privileges for iOS 17+ tunnel:
  - Windows: Run as Administrator.
  - macOS: `sudo -E python -m uvicorn ...`.

The backend owns the tunnel process so it can retain the parsed RSD address/port. A browser-only frontend cannot speak DVT/RSD directly.

## D. Current RSD/tunnel dependencies

Current iOS 17+ location injection requires:

- A paired/trusted physical device.
- Developer Mode enabled.
- Developer Disk Image mounted by `pymobiledevice3 mounter auto-mount`.
- A live RSD/tunnel subprocess.
- RSD host/port parsed from tunnel output.
- All DVT commands to include `--rsd HOST PORT`.

`LocationService.set_location()` rejects iOS 17+ writes with “Tunnel not active — call /setup/tunnel first” if `DeviceManager.tunnel` is absent. `clear_location()` also rejects iOS 17+ clears without a tunnel.

The RSD address/port are treated as ephemeral runtime state. They are not persisted and are not re-discovered after backend restart.

Local pymobiledevice3 `9.12.0` exposes additional tunnel paths not used by current IOSSim:

```text
python -m pymobiledevice3 remote browse
python -m pymobiledevice3 remote pair
python -m pymobiledevice3 remote start-tunnel --connection-type usb|wifi
python -m pymobiledevice3 remote tunneld
python -m pymobiledevice3 lockdown start-tunnel --mobdev2
python -m pymobiledevice3 lockdown start-tunnel --usbmux HOST:PORT
```

This means a network/RSD path is plausible enough to test, but not currently implemented.

## E. Existing wireless-related code

Current stable IOSSim contains no dedicated wireless transport module.

Relevant existing references:

- README lists “WiFi tunnel mode” and “Unplug persistence” as experimental/not guaranteed.
- `STABILITY.md` says WiFi tunnel and Ghost persistence must not be required for `main`.
- `SETUP_MAC.md` says the current stable fake GPS path is sent over USB, not Wi-Fi.
- `frontend/src/components/UnplugModal.tsx` implements an experimental “Lock & Unplug” walkthrough that tells the user to turn Developer Mode off, restart, and unplug. The comment claims persistence for about 12 hours, but README classifies this as undocumented and not guaranteed.
- Drive Mode uses repeated `LocationService.set_location()` calls and is not an offline/unplug persistence feature.

## F. Existing research

Existing research files are Drive Testing oriented, but some facts are directly reusable:

- `research/04_bluetooth_gps_emulation.md`: separates MFi Bluetooth Classic/iAP2 system-level GPS from BLE app-level GPS. Key claim: BLE-only GPS cannot replace system CoreLocation for all apps.
- `research/05_pymobiledevice3_protocol_audit.md`: confirms DVT `LocationSimulation` exposes only `simulateLocationWithLatitude:longitude:` and `stopLocationSimulation`; iOS 17+ changed transport to CoreDevice/RemoteXPC/RSD, not the location simulation payload.
- `research/03_commercial_spoofers_analysis.md`: distinguishes DVT desktop spoofers from external GPS hardware and jailbreak methods.
- `docs/drive_testing/*`: documents stable USB/RSD architecture, technical limits, logging redaction, and Developer Mode setup.

Commit history findings:

- `fabb92f Add macOS launcher and setup guide as Windows add-on.` introduced/changed macOS setup and cable/tunnel references.
- `5a0fbab research: add 8-file raw research audit on iOS driving detection triggering` added the existing research folder.
- `77daa23 Initial stable iOS location sim snapshot` and later commits contain the initial USB/RSD path.
- `git log -S` searches for `WiFi`, `wireless`, `start-tunnel`, `unplug`, `RSD`, and `Ghost` found historical references but no completed wireless implementation.

## G. Open questions

These require external research and/or physical-device experiments:

1. Whether Apple’s current wireless developer workflow exposes the same DVT location simulation service after initial USB pairing.
2. Whether pymobiledevice3 `remote start-tunnel --connection-type wifi` works with a modern physical iPhone on iOS 26.x.
3. Whether `remote pair` is compatible with current iOS devices and whether it requires a specific on-device pairing UI state.
4. Whether `usbmux list` shows network devices on this Windows host after Apple wireless pairing is enabled.
5. Whether a RSD endpoint created over USB survives cable removal.
6. Whether a fresh tunnel can be established after the cable is removed.
7. Whether the RSD address/port can be manually reused or are tied to a specific tunnel process and interface.
8. Whether Bonjour/mDNS is only discovery or also a transport prerequisite.
9. Whether routed private networks, VPN overlays, or same-LAN emulation can carry the Apple developer channel.
10. Whether a non-Mac host can do the same network developer-channel work for iOS 17+/26.
11. Whether any iPhone-only app/scripting/runtime can access the private developer services needed for system-wide location simulation.
12. Whether external GPS hardware can provide arbitrary coordinates system-wide without a Mac, and what MFi constraints apply.

