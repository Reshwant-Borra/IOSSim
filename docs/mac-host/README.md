# Mac-Hosted IOSSim

Status: stable/current implementation.

The Mac-hosted implementation is the existing IOSSim product path. It runs the control plane on a Mac or Windows host and uses pymobiledevice3 to reach iPhone developer services.

## Source Layout

- `backend/`: FastAPI backend, pymobiledevice3 command boundary, device setup, tunnel/session ownership, location set/clear, Drive Mode, and experimental wireless/drive testing routers.
- `frontend/`: React/TypeScript/Vite UI.
- `RUN_EVERYTHING.sh`: macOS launcher.
- `RUN_EVERYTHING.ps1`, `start.bat`, `run_all.ps1`: Windows launchers/helpers.
- `SETUP_MAC.md`, `SETUP_FROM_SCRATCH.md`, `STABILITY.md`: setup and stability guidance.

The Mac-hosted source remains at the repository root because moving it would touch many launcher, setup, backend, and frontend paths without improving runtime safety.

## Runtime Path

```text
Mac
  -> pymobiledevice3
  -> UserspaceRsdTunnel
  -> RSD
  -> DvtProvider
  -> DeviceInfo warmup
  -> LocationSimulation
  -> iPhone
```

For stable USB and same-LAN wireless location, the backend owns the long-lived process/session that keeps the simulated location active. Pairing and trust are handled by the host.

## Relationship To The iPhone POC

The iPhone on-device POC in `ios/` is separate. It tests whether a stock iPhone can hold its own RPPairing-based developer tunnel and DVT LocationSimulation session after one-time Mac setup.

The Mac-hosted implementation remains useful because it is broader, better validated, and already provides the web UI, Drive Mode, favorites, reset behavior, and host-side diagnostics.

## Non-Committed Data

Do not commit host runtime state from `backend/data/`, Python caches, frontend build output, logs, or process files. These are ignored by the repo-level `.gitignore`.
