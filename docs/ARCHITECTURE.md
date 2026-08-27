# IOSSim Architecture

This repository now contains two separate IOSSim runtime implementations:

- Mac-hosted IOSSim, the existing stable product path.
- iPhone on-device IOSSim POC, an experimental iPhone-resident DVT proof of concept.

## Mac-Hosted IOSSim

The Mac-hosted implementation keeps the runtime control plane on the computer. The web frontend calls the FastAPI backend, and the backend owns device discovery, tunneling, DVT access, and location commands through pymobiledevice3.

Current source layout:

- `backend/`: FastAPI API, device management, location service, wireless location session, Drive Mode, and experimental labs.
- `frontend/`: React/TypeScript/Vite web UI.
- `RUN_EVERYTHING.sh`, `RUN_EVERYTHING.ps1`, `start.bat`, `run_all.ps1`: local launch helpers.
- `docs/wireless_testing/`, `docs/wireless_research/`, `docs/drive_testing/`, and `docs/validation_evidence/`: host-side validation and research history.

Wireless userspace path:

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

Pairing and trust remain host-side. A USB connection is still required for first-time trust/setup and for USB mode. Same-LAN wireless operation can run without an attached cable after setup, but the host remains the process that owns the RSD/DVT session.

This implementation remains useful because it is the stable product path, has the existing UI and automation surface, and preserves the known-good pymobiledevice3 behavior for USB, same-LAN wireless, static location, reset, and Drive Mode.

## iPhone On-Device POC

The iPhone implementation is isolated under `ios/`. It is a Swift app plus a pinned `jkcoxson/idevice` Rust FFI boundary. Its runtime goal is:

```text
Mac used once
  -> RPPairing generated/imported
  -> Mac no longer needed at runtime
  -> iPhone performs its own developer tunnel
  -> DVT LocationSimulation
  -> Core Location
```

Runtime chain implemented by the POC:

```text
KeychainRPPairingStore
  -> RPPairingValidator
  -> DeveloperRouteProbe
  -> 10.7.0.1:49152
  -> LocalDevVPN virtual route
  -> IdeviceOnDeviceTunnelClient
  -> rp_pairing_file_read
  -> tunnel_create_rppairing
  -> remote_server_connect_rsd
  -> device_info_directory_listing("/")
  -> location_simulation_new
  -> location_simulation_set / clear
  -> CoreLocationVerifier
```

The on-device implementation intentionally does not replace the Mac-hosted app yet. It has no product map UI, Drive Mode, account layer, WLOC, custom VPN, remote Mac bridge, or production packaging. It is a focused physical proof of concept for Mac-free DVT LocationSimulation.

Detailed iPhone architecture and validation status live in [iphone_on_device_dvt/ARCHITECTURE.md](iphone_on_device_dvt/ARCHITECTURE.md).

## Security Boundaries

RPPairing records, private keys, PSKs, generated Rust build output, generated `libidevice_ffi.a`, and exported diagnostics containing sensitive local data must not be committed. The repo-level `.gitignore` keeps the iPhone POC secret/artifact paths ignored after the move to `ios/`.
