# IOSSim Implementations

IOSSim contains two runtime implementations. They share the product goal of setting and clearing iPhone Core Location simulation, but they run in different places and use different protocol stacks.

| Implementation | Runtime Host | Language | DVT Library | Pairing | Current Status |
| --- | --- | --- | --- | --- | --- |
| Mac-hosted IOSSim | Mac or Windows host | Python/FastAPI backend + React/TypeScript frontend | pymobiledevice3 | host-side pairing/trust | stable/current |
| iPhone on-device POC | iPhone | Swift + Rust FFI | pinned jkcoxson/idevice | imported RPPairing stored on iPhone | static simulation physically validated; Drive POC physically characterized at ~1 Hz with monotonic route progress, repeated DVT updates, no severe snap-back, and native speed/course unavailable |

## Why Both Are Retained

The Mac-hosted implementation remains the product baseline. It supports the existing web UI, USB setup, same-LAN wireless operation, Drive Mode, favorites, setup scripts, and reset behavior. It also remains the lowest-risk path when a host computer is available.

The iPhone on-device POC exists to prove and harden a narrower architecture: use a Mac once to establish trust and generate/import RPPairing, then let the stock iPhone create its own developer tunnel and DVT LocationSimulation session through LocalDevVPN at runtime.

Keeping the implementations separate avoids mixing an experimental mobile FFI path into the stable host stack.

## Entry Points

- Mac-hosted IOSSim: repository root launchers, `backend/`, `frontend/`, and [docs/mac-host/README.md](mac-host/README.md).
- iPhone on-device POC: [../ios](../ios) and [../ios/README.md](../ios/README.md).
- iPhone research and validation history: [iphone_on_device_dvt/README.md](iphone_on_device_dvt/README.md).
- Experimental iPhone Drive Mode: [iphone_on_device_dvt/DRIVE_MODE_IMPLEMENTATION.md](iphone_on_device_dvt/DRIVE_MODE_IMPLEMENTATION.md).
