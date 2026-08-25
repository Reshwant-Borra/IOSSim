# Stable vs Experimental Separation

This repo keeps the working iOS Location Sim path separate from experimental/test-build work.

## Stable working surface

These features are considered stable enough to protect on `main`:

- USB device detection through pymobiledevice3/usbmux.
- Developer Disk Image mount through `pymobiledevice3 mounter auto-mount`.
- Backend-owned tunnel startup for iOS 17+.
- RSD address/port parsing from `lockdown start-tunnel --script-mode`.
- Static Set Location over USB/RSD.
- Wireless userspace Set Location and Reset GPS for saved same-LAN iPhones using explicit UDID, userspace RSD, DVT, `DeviceInfo(dvt).ls("/")`, and `LocationSimulation`.
- One-time USB wireless setup that runs RemotePairing bootstrap, enables Wi-Fi connections, and saves stable iPhone identity.
- Persistent active `simulate-location set` process while the backend stays open.
- Reset GPS / clear location.
- `RUN_EVERYTHING.ps1` launcher flow.
- Frontend/backend communication for status, initialize, set, reset, and favorites.
- Drive Mode (manual waypoints, address geocoding, road routing via Nominatim/OSRM, pause/resume/stop/status, "Stay at end").

## Experimental/test-build surface

These features are not guaranteed and must stay behind explicit opt-in flags or separate branches:

- **iOS Drive Simulation** — visual iPhone display simulation showing the drive in progress (next planned experimental feature).
- Legacy GPX route playback.
- **Advanced Wireless Diagnostics** — isolated same-LAN Wi-Fi discovery and persistent QUIC/TCP tunnel diagnostics. These are not part of normal wireless location.
- Unplug persistence.
- Developer Mode OFF trick / GhostMe-style persistence.

## Runtime flags

Drive Mode is stable and requires no flags.

`IOS_SIM_ENABLE_EXPERIMENTAL=1` enables remaining experimental features (Lock & Unplug, legacy GPX route playback):

```powershell
$env:IOS_SIM_ENABLE_EXPERIMENTAL = "1"
$env:VITE_ENABLE_EXPERIMENTAL_FEATURES = "1"
```

`RUN_EVERYTHING.ps1` and `start.bat` remain stable-mode launchers by default.

Advanced Wireless Diagnostics requires both generic experimental flags plus dedicated wireless flags:

```powershell
$env:IOS_SIM_ENABLE_EXPERIMENTAL = "1"
$env:IOS_SIM_ENABLE_WIRELESS_TESTING = "1"
$env:VITE_ENABLE_EXPERIMENTAL_FEATURES = "1"
$env:VITE_ENABLE_WIRELESS_TESTING = "1"
```

Use `RUN_EVERYTHING.ps1 -Mode wireless-testing` on Windows or `./RUN_EVERYTHING.sh wireless-testing` on macOS. It is separate from Drive Testing and must not be required for stable USB Set Location, stable USB Reset GPS, or normal userspace wireless location.

## Branch policy

- `main`: stable USB set/reset, userspace wireless set/reset, and Drive Mode workflow. Persistent Wi-Fi tunnel diagnostics and Ghost persistence behavior should not be required for this branch to work.
- `experimental/*`: feature work for iOS Drive Simulation, WiFi/Wireless Testing, Ghost Mode, and persistence experiments.
- Before merging experimental work into `main`, verify the stable checklist below.

## Stable verification checklist

1. `python -m pymobiledevice3 usbmux list` sees the device.
2. App `/api/status` reports device connected.
3. Initialize mounts DDI.
4. Initialize starts tunnel on iOS 17+ and stores RSD address/port.
5. Set Location starts a persistent process and location remains active while backend stays open.
6. Setting a second location replaces the old process cleanly.
7. Reset GPS terminates the active process and clears simulated location.
8. Saved wireless iPhones can show Wireless Ready without USB when reachable on the same LAN.
9. Wireless Set Location keeps the userspace session alive for coordinate changes.
10. Wireless Reset GPS clears and tears down the userspace session.
11. Drive Mode can start from at least two waypoints or a generated road route, update location, pause/resume/stop, and report status.
12. Frontend can call backend through the Vite proxy.
13. `RUN_EVERYTHING.ps1` launches backend and frontend.

## Rule

If a change touches `device_manager.py`, `location_service.py`, `wireless_location/`, `/api/location/set`, `/api/location/clear`, tunnel startup, or launcher scripts, treat it as stable-path risk and test the checklist before pushing to `main`.
