# iOS Location Sim — macOS Setup

This guide covers macOS as an add-on to the Windows-first workflow in [SETUP_FROM_SCRATCH.md](SETUP_FROM_SCRATCH.md). The app behavior is the same; only install steps and launchers differ.

## 1. Install Prerequisites

Install these first:

- **Python 3.11+** (3.13 recommended):

  ```bash
  brew install python@3.13
  ```

- **Node.js 20+** — from [nodejs.org](https://nodejs.org/) or `brew install node`
- **Git** — usually preinstalled on macOS

You do **not** need iTunes on Mac. USB device support is built into macOS.

Enable Developer Mode on the iPhone:

```text
Settings > Privacy & Security > Developer Mode > On
```

Connect the iPhone by USB, tap **Trust This Computer**, and enter the passcode.

For iOS 17 and newer, the backend needs elevated privileges. On macOS that means running the backend with `sudo` (your Mac login password).

## 2. Clone The Repo

```bash
cd ~/Desktop
git clone https://github.com/Reshwant-Borra/IOSSim.git ios-location-sim
cd ios-location-sim
```

## 3. Install Backend Dependencies

```bash
cd backend
python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Verify pymobiledevice3 can see the phone:

```bash
python -m pymobiledevice3 usbmux list
```

Expected result: JSON-like output containing your iPhone. If it returns an empty list, reconnect USB, unlock the phone, and trust the computer again.

## 4. Install Frontend Dependencies

```bash
cd ../frontend
npm install
```

## 5. Start The App In Stable Mode

Stable mode supports the reliable static location workflow.

One-command launcher (recommended):

```bash
cd ~/Desktop/ios-location-sim
chmod +x RUN_EVERYTHING.sh   # first time only
./RUN_EVERYTHING.sh
```

The script installs missing dependencies, opens two Terminal windows, and opens `http://localhost:5173`. The backend window will ask for your Mac password (`sudo`).

Manual start (two terminals):

```bash
# Terminal 1 — backend
cd backend
source .venv/bin/activate
sudo -E $(which python) -m uvicorn main:app --host 127.0.0.1 --port 8765 --reload

# Terminal 2 — frontend
cd frontend
npm run dev
```

Services:

- Backend: `http://127.0.0.1:8765`
- Frontend: `http://localhost:5173`
- API docs: `http://127.0.0.1:8765/docs`

## 6. Initialize The Device

In the browser:

1. Open `http://localhost:5173`.
2. In the device panel, click **Initialize**.
3. Let it mount the Developer Disk Image.
4. On iOS 17+, let it start the tunnel.
5. Wait until the device panel says the phone is ready.

## 7. Use Stable Set Location

1. Click a location on the map.
2. Click **Set Location**.
3. Keep the backend Terminal window open. The backend keeps the active `simulate-location set` process alive.
4. Click **Reset GPS** to return the phone to real GPS.

You can turn off WiFi on the iPhone after spoofing — the fake GPS is sent over USB, not WiFi. Keep the USB cable connected and the backend running.

## 8. Start Experimental Drive Mode

Drive Mode is experimental and uses public Nominatim/OSRM endpoints for address routing. These endpoints are for light personal testing only.

```bash
./RUN_EVERYTHING.sh experimental
```

Then:

1. Open `http://localhost:5173`.
2. Initialize the device.
3. Click **Drive Mode**.
4. Select a start point on the map, or enter a start address.
5. Enter a destination address.
6. Click **Generate Road Route**.
7. Choose Walking, City driving, Highway, or Custom mph.
8. Click **Start Road Drive**.
9. Use **Pause**, **Resume**, or **Stop** as needed.

When **Stay at end** is enabled, the app keeps the final location spoof active after the route completes.

## 9. Manual Development Commands

Backend only (experimental):

```bash
cd backend
source .venv/bin/activate
export IOS_SIM_ENABLE_EXPERIMENTAL=1
sudo -E $(which python) -m uvicorn main:app --host 127.0.0.1 --port 8765 --reload
```

Frontend only (experimental):

```bash
cd frontend
export VITE_ENABLE_EXPERIMENTAL_FEATURES=1
npm run dev
```

## 10. Validation Commands

```bash
cd ~/Desktop/ios-location-sim
source backend/.venv/bin/activate
python -m unittest discover backend
python -m compileall backend
cd frontend
npm run build
```

## macOS vs Windows

| Windows | macOS |
|---|---|
| `start.bat` / `RUN_EVERYTHING.ps1` | `RUN_EVERYTHING.sh` |
| Run as Administrator | `sudo` for backend (iOS 17+ tunnel) |
| Standalone iTunes required | Not required |
| Global `python` / `pip` | `backend/.venv` recommended |

## Troubleshooting

- **No device connected:** reconnect USB, unlock the iPhone, trust the computer, and verify `python -m pymobiledevice3 usbmux list`.
- **Tunnel not active:** run the backend with `sudo` and click Initialize again.
- **Set Location only flashes briefly:** the backend must stay open because the spoof is tied to a long-lived pymobiledevice3 process.
- **`/api/location/drive/status` errors in stable mode:** Drive Mode is experimental — use `./RUN_EVERYTHING.sh experimental` or ignore if you only need static Set Location.
- **Address route fails:** wait and retry. Nominatim and OSRM public endpoints can rate-limit or be unavailable.
- **Drive movement does not continue after unplug:** current Drive Mode is not offline persistence. Keep USB/tunnel/backend active.
