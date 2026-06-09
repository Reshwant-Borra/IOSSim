# iOS Location Sim

Free, open-source iOS location testing tool. Windows-first with macOS support, USB connection, no paid Apple Developer account required.

**Stack**: Python 3.11+ / FastAPI / pymobiledevice3, React 18 / TypeScript / Vite, OpenStreetMap via Leaflet.

---

## Stability Model

The default app surface is intentionally stable-only. Experimental features are hidden or blocked unless explicitly enabled for a test build.

Stable working features:

- USB device detection.
- Developer Disk Image mount.
- Backend-owned tunnel startup for iOS 17+.
- RSD parsing.
- Static Set Location over USB/RSD.
- Persistent active `simulate-location set` process while backend stays open.
- Reset GPS / clear location.
- `RUN_EVERYTHING.ps1` launcher (Windows) and `RUN_EVERYTHING.sh` launcher (macOS).
- Frontend/backend communication for status, initialize, set, reset, and favorites.

Experimental or not guaranteed:

- Drive Mode over an active USB/RSD backend session.
- Address-based road route Drive Mode through Nominatim and OSRM public endpoints.
- Legacy GPX route playback.
- WiFi tunnel mode.
- Unplug persistence.
- Developer Mode OFF trick / GhostMe-style persistence.

See [STABILITY.md](STABILITY.md) before changing device, tunnel, set, clear, launcher, Drive Mode, route, WiFi, or persistence behavior.

For a full clean-machine setup walkthrough, see [SETUP_FROM_SCRATCH.md](SETUP_FROM_SCRATCH.md) (Windows) and [SETUP_MAC.md](SETUP_MAC.md) (macOS).

---

## Feature Flags

Drive Mode is experimental. Keep it off for stable static-location sessions. To enable it for a test build:

```powershell
cd backend
$env:IOS_SIM_ENABLE_EXPERIMENTAL = "1"
python -m uvicorn main:app --host 0.0.0.0 --port 8765 --reload

cd ..\frontend
$env:VITE_ENABLE_EXPERIMENTAL_FEATURES = "1"
npm run dev
```

Do not enable these in the normal launcher unless the branch is explicitly a test branch.

---

## Prerequisites

| Requirement | Windows | macOS |
|---|---|---|
| Python 3.11+ | Required (3.13 recommended) | Required — `brew install python@3.13` |
| iTunes / device support | Standalone iTunes from apple.com, not Microsoft Store | Not required — built into macOS (`usbmuxd`) |
| Node.js 20+ | Required | Required |
| Elevated privileges | Run as Administrator for iOS 17+ tunnel | `sudo` for backend on iOS 17+ tunnel |
| iPhone with Developer Mode ON | Settings > Privacy & Security > Developer Mode | Same |
| USB cable | Trust this computer on the iPhone | Same |

---

## iOS Compatibility

| iOS | Works | Command path |
|-----|-------|--------------|
| <= 16.x | Yes | Direct developer simulate-location |
| 17.0-17.3.1 | Risky | QUIC tunnel path; avoid if possible |
| 17.4+ | Yes | TCP lockdown tunnel |
| 18.x | Yes | TCP lockdown tunnel |
| 26.x | Yes | TCP lockdown tunnel, confirmed on target device |

Do not use libimobiledevice/idevicesetlocation for iOS 17+.

---

## Quick Start

### Option A: Windows launcher

```text
Right-click start.bat -> Run as administrator
```

This starts the backend and frontend and opens `http://localhost:5173`. The backend must run as administrator because it owns the iOS 17+ tunnel and stores the parsed RSD address used by Set Location.

For the PowerShell launcher, stable mode is the default:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\reshw\Desktop\ios-location-sim\RUN_EVERYTHING.ps1"
```

To launch the same stack with experimental Drive Mode enabled:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\reshw\Desktop\ios-location-sim\RUN_EVERYTHING.ps1" -Mode experimental
```

### Option B: Manual

```bat
REM Terminal 1, run as Administrator
cd backend
pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8765 --reload

REM Terminal 2
cd frontend
npm install
npm run dev
```

Open `http://localhost:5173`.

### Option C: macOS launcher

macOS uses the same stable/experimental modes as Windows. The backend runs with `sudo` because the iOS 17+ tunnel needs elevated privileges (you will be prompted for your Mac login password).

```bash
cd /path/to/IOSSim
chmod +x RUN_EVERYTHING.sh   # first time only
./RUN_EVERYTHING.sh
```

Experimental Drive Mode:

```bash
./RUN_EVERYTHING.sh experimental
```

This opens two Terminal windows (backend + frontend) and launches `http://localhost:5173`. For a full macOS walkthrough, see [SETUP_MAC.md](SETUP_MAC.md).

### Option D: macOS manual

```bash
# Terminal 1 — backend (sudo for iOS 17+)
cd backend
python3.13 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
sudo -E $(which python) -m uvicorn main:app --host 127.0.0.1 --port 8765 --reload

# Terminal 2 — frontend
cd frontend
npm install
npm run dev
```

---

## Stable Workflow: Set Location

1. Connect iPhone via USB.
2. In the app, click **Initialize** in the Device panel.
3. Initialization mounts the Developer Disk Image.
4. On iOS 17+, initialization starts the backend-owned tunnel.
5. Click anywhere on the map to pick a location.
6. Click **Set Location**.
7. Keep the backend open. The active `simulate-location set` process keeps the fake GPS active.
8. Click **Reset GPS** to clear the simulated location.

---

## Experimental Drive Mode

Drive Mode is experimental and requires `IOS_SIM_ENABLE_EXPERIMENTAL=1` on the backend and `VITE_ENABLE_EXPERIMENTAL_FEATURES=1` on the frontend. It uses timed static-location updates, exposes pause/resume/stop/status endpoints, and can keep the final destination active when "Stay at end" is enabled.

1. Click **Drive Mode**.
2. Either enter a destination address and generate a road route, or click at least two manual waypoints on the map.
3. Choose a speed preset or custom mph.
4. Click **Start Road Drive** or **Start Manual Drive**.
5. Use **Pause**, **Resume**, or **Stop** as needed.

Limit: Drive Mode is not an unplug/offline persistence feature. Keep the backend and tunnel running for movement updates.

Nominatim and OSRM public endpoints are for light personal testing only. The backend caches geocode and route responses locally under `backend/data/route_cache`.

---

## Experimental Workflow: Lock & Unplug

Lock & Unplug is behind the frontend experimental flag and is not guaranteed.

The Developer Mode OFF trick is an undocumented side effect. It may or may not preserve the last simulated location after unplugging. It should be treated as a test workflow, not a stable feature.

For the persistence research and experiment plan, see:

- `Projects/iOS_Location_Sim_Research/Ghost_Mode_Persistence.md`
- `Projects/iOS_Location_Sim_Research/Ghost_Mode_Experiments.md`

---

## Hard Limits on Stock iOS

| Claim | Reality |
|---|---|
| Location survives every reboot | No, expect reboot to clear or recalibrate |
| First-time setup without USB | No, USB trust/pairing is required first |
| Per-app spoofing | No, DVT simulation is system-wide |
| Permanent offline location | No supported stock iOS API found |
| Undetectable spoofing | No, apps may inspect simulated-location signals |

---

## Project Structure

```text
ios-location-sim/
  backend/
    main.py
    device_manager.py
    location_service.py
    favorites.py
    requirements.txt
  frontend/
    index.html
    tsconfig.json
    vite.config.ts
    package.json
    src/
      main.tsx
      App.tsx
      api/client.ts
      components/
        DevicePanel.tsx
        FavoritesList.tsx
        UnplugModal.tsx
  RUN_EVERYTHING.ps1
  RUN_EVERYTHING.sh
  SETUP_FROM_SCRATCH.md
  SETUP_MAC.md
  start.bat
  STABILITY.md
  README.md
```

---

## Legal

Use only on devices you own or are authorized to test. Using location simulation to violate an app's terms or deceive others can have consequences.
