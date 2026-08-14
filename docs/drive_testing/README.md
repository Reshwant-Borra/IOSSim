# IOSSim Drive Testing Lab

The Drive Testing Lab is part of the existing IOSSim web application. Nothing is installed on the iPhone. The Mac or Windows computer still performs DVT location injection through the existing FastAPI, DeviceManager, LocationService, and pymobiledevice3 path.

The system controls coordinate sequence and host timing. It does not directly control motion sensors, inject `CLLocation.speed` or `CLLocation.course`, or read third-party classification state. Third-party outcomes must be checked and entered manually.

Use only devices and test accounts owned by or authorized for the tester. A profile is an experimental input, not a guarantee of Drive or Trip classification.

## Launch on macOS

```bash
cd ~/IOSSim
chmod +x RUN_EVERYTHING.sh
./RUN_EVERYTHING.sh drive-testing
```

## Launch on Windows

```powershell
cd C:\path\to\IOSSim
.\RUN_EVERYTHING.ps1 -Mode drive-testing
```

Open `http://localhost:5173`, initialize the device, select or generate a road route, then open **Drive Testing Lab** in the existing sidebar.

## Output

Local records are written to:

```text
backend/data/drive_testing/experiments/EXP-.../
```

Generated output and personal routes are ignored by Git.

Start with [Quick Test](10_QUICK_TEST.md), then read [Technical Limits](03_TECHNICAL_LIMITS.md), [Recording Results](15_RECORDING_RESULTS.md), and [Safety and Ethics](21_SAFETY_AND_ETHICS.md).
