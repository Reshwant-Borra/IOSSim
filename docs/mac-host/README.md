# Mac-Host Documentation

Status: historical and supporting documentation. The authoritative current
handoff starts at [../CURRENT_STATE.md](../CURRENT_STATE.md).

Some documents in this directory were written before the live native Personal
Team and physical-install stabilization work. When this directory conflicts with
`docs/CURRENT_STATE.md`, `docs/ARCHITECTURE.md`, or
`docs/PROVISIONING_AND_SIGNING.md`, the current handoff wins.

## Historical Mac-Hosted IOSSim

The older Mac-hosted implementation kept the control plane on a Mac or Windows
host and used pymobiledevice3 to reach iPhone developer services.

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

## Current Consumer Mac Application

- [Current State](../CURRENT_STATE.md)
- [Provisioning and Signing](../PROVISIONING_AND_SIGNING.md)
- [Physical Validation](../PHYSICAL_VALIDATION.md)
- [Release and Distribution](../RELEASE_AND_DISTRIBUTION.md)
- [Next Steps](../NEXT_STEPS.md)
- [Zero-Xcode provisioning feasibility and dependency audit](ZERO_XCODE_PROVISIONING.md)
- [Third-party provisioning components and licensing](THIRD_PARTY_PROVISIONING_COMPONENTS.md)
