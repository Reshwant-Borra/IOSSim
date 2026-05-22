# Stable vs Experimental Separation

This repo keeps the working iOS Location Sim path separate from experimental/test-build work.

## Stable working surface

These features are considered stable enough to protect on `main`:

- USB device detection through pymobiledevice3/usbmux.
- Developer Disk Image mount through `pymobiledevice3 mounter auto-mount`.
- Backend-owned tunnel startup for iOS 17+.
- RSD address/port parsing from `lockdown start-tunnel --script-mode`.
- Static Set Location over USB/RSD.
- Persistent active `simulate-location set` process while the backend stays open.
- Reset GPS / clear location.
- Drive Mode over an active USB/RSD backend session.
- Drive Mode pause/resume/stop/status controls.
- Drive Mode "Stay at end" final-location hold.
- `RUN_EVERYTHING.ps1` launcher flow.
- Frontend/backend communication for status, initialize, set, reset, and favorites.

## Experimental/test-build surface

These features are not guaranteed and must stay behind explicit opt-in flags or separate branches:

- Legacy GPX route playback.
- WiFi tunnel mode.
- Unplug persistence.
- Developer Mode OFF trick / GhostMe-style persistence.

## Runtime flags

Drive Mode is enabled by default. Disable it only for a stable demo build:

```powershell
$env:VITE_ENABLE_DRIVE_MODE = "0"
$env:IOS_SIM_ENABLE_DRIVE_MODE = "0"
```

Frontend experimental UI is disabled by default. Enable it only in a test build:

```powershell
$env:VITE_ENABLE_EXPERIMENTAL_FEATURES = "1"
npm run dev
```

Backend experimental endpoints are disabled by default. Enable them only in a test backend session:

```powershell
$env:IOS_SIM_ENABLE_EXPERIMENTAL = "1"
python -m uvicorn main:app --host 0.0.0.0 --port 8765 --reload
```

`RUN_EVERYTHING.ps1` and `start.bat` should remain stable-mode launchers unless explicitly changed for a test branch.

## Branch policy

- `main`: stable USB set/reset workflow and confirmed Drive Mode only. No WiFi tunnel or Ghost persistence behavior should be required for this branch to work.
- `experimental/*`: feature work for Drive Mode, WiFi mode, Ghost Mode, route controllers, and persistence experiments.
- Before merging experimental work into `main`, verify the stable checklist below.

## Stable verification checklist

1. `python -m pymobiledevice3 usbmux list` sees the device.
2. App `/api/status` reports device connected.
3. Initialize mounts DDI.
4. Initialize starts tunnel on iOS 17+ and stores RSD address/port.
5. Set Location starts a persistent process and location remains active while backend stays open.
6. Setting a second location replaces the old process cleanly.
7. Reset GPS terminates the active process and clears simulated location.
8. Drive Mode can start from at least two waypoints, update location, pause/resume/stop, and report status.
9. Frontend can call backend through the Vite proxy.
10. `RUN_EVERYTHING.ps1` launches backend and frontend.

## Rule

If a change touches `device_manager.py`, `location_service.py`, `/api/location/set`, `/api/location/clear`, tunnel startup, or launcher scripts, treat it as stable-path risk and test the checklist before pushing to `main`.
