# iOS Location Sim - Setup From Scratch

This guide starts from a clean Windows machine and ends with the app running against your own iPhone.

## 1. Install Prerequisites

Install these first:

- Python 3.11 or newer.
- Node.js 20 or newer.
- Standalone iTunes from Apple, not the Microsoft Store version.
- Git for Windows.

Enable Developer Mode on the iPhone:

```text
Settings > Privacy & Security > Developer Mode > On
```

Connect the iPhone by USB, tap **Trust This Computer**, and enter the passcode.

For iOS 17 and newer, the backend needs Administrator privileges because it starts the pymobiledevice3 tunnel.

## 2. Clone The Repo

```powershell
cd C:\Users\$env:USERNAME\Desktop
git clone https://github.com/Reshwant-Borra/IOSSim.git ios-location-sim
cd ios-location-sim
```

## 3. Install Backend Dependencies

```powershell
cd C:\Users\$env:USERNAME\Desktop\ios-location-sim\backend
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Verify pymobiledevice3 can see the phone:

```powershell
python -m pymobiledevice3 usbmux list
```

Expected result: JSON-like output containing your iPhone. If it returns an empty list, reinstall standalone iTunes, reconnect USB, and trust the computer again.

## 4. Install Frontend Dependencies

```powershell
cd C:\Users\$env:USERNAME\Desktop\ios-location-sim\frontend
npm install
```

## 5. Start The App In Stable Mode

Stable mode supports the reliable static location workflow.

Run this from an Administrator PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\$env:USERNAME\Desktop\ios-location-sim\RUN_EVERYTHING.ps1"
```

The script starts:

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
3. Keep the backend window open. The backend keeps the active `simulate-location set` process alive.
4. Click **Reset GPS** to return the phone to real GPS.

## 8. Start Experimental Drive Mode

Drive Mode is experimental and uses public Nominatim/OSRM endpoints for address routing. These endpoints are for light personal testing only.

Run this from an Administrator PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\$env:USERNAME\Desktop\ios-location-sim\RUN_EVERYTHING.ps1" -Mode experimental
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

Backend only:

```powershell
cd C:\Users\$env:USERNAME\Desktop\ios-location-sim\backend
$env:IOS_SIM_ENABLE_EXPERIMENTAL = "1"
python -m uvicorn main:app --host 127.0.0.1 --port 8765 --reload
```

Frontend only:

```powershell
cd C:\Users\$env:USERNAME\Desktop\ios-location-sim\frontend
$env:VITE_ENABLE_EXPERIMENTAL_FEATURES = "1"
npm run dev
```

## 10. Validation Commands

Run these before changing or sharing the repo:

```powershell
cd C:\Users\$env:USERNAME\Desktop\ios-location-sim
python -m unittest discover backend
python -m compileall backend
cd frontend
npm run build
```

## Troubleshooting

- **No device connected:** reconnect USB, unlock the iPhone, trust the computer, and verify `python -m pymobiledevice3 usbmux list`.
- **Tunnel not active:** run backend as Administrator and click Initialize again.
- **Set Location only flashes briefly:** the backend must stay open because the spoof is tied to a long-lived pymobiledevice3 process.
- **Address route fails:** wait and retry. Nominatim and OSRM public endpoints can rate-limit or be unavailable.
- **Drive movement does not continue after unplug:** current Drive Mode is not offline persistence. Keep USB/tunnel/backend active.
