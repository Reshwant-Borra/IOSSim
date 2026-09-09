# IOSSim Implementations

IOSSim contains two runtime implementations. They share the product goal of setting and clearing iPhone Core Location simulation, but they run in different places and use different protocol stacks.

| Implementation | Runtime Host | Language | DVT Library | Pairing | Current Status |
| --- | --- | --- | --- | --- | --- |
| Legacy Mac-hosted IOSSim | Mac or Windows host | Python/FastAPI backend + React/TypeScript frontend | pymobiledevice3 | host-side pairing/trust | historical baseline, preserved on `desktop-legacy` |
| iPhone on-device runtime | iPhone | Swift + Rust FFI | pinned jkcoxson/idevice | imported RPPairing stored on iPhone | static simulation, Gate 3, rich XCUILocation, and Rich Drive have physical evidence in earlier cycles; current 06478bab RC runtime requalification is pending |

## Why Both Are Retained

The legacy Mac-hosted implementation remains useful history. It supports the existing web UI, USB setup, same-LAN wireless operation, Drive Mode, favorites, setup scripts, and reset behavior. It also remains a fallback reference when a host computer owns the runtime session.

The iPhone on-device runtime exists to preserve the current product direction:
use the Mac for setup/refresh/provisioning, then let the stock iPhone create its
own developer tunnel and location-simulation session through LocalDevVPN at
runtime.

For the authoritative current handoff, see [CURRENT_STATE.md](CURRENT_STATE.md).

Keeping the implementations separate avoids mixing an experimental mobile FFI path into the stable host stack.

## Entry Points

- Legacy Mac-hosted IOSSim: repository root launchers, `backend/`, `frontend/`, and [docs/mac-host/README.md](mac-host/README.md).
- iPhone on-device POC: [../ios](../ios) and [../ios/README.md](../ios/README.md).
- iPhone research and validation history: [iphone_on_device_dvt/README.md](iphone_on_device_dvt/README.md).
- Experimental iPhone Drive Mode: [iphone_on_device_dvt/DRIVE_MODE_IMPLEMENTATION.md](iphone_on_device_dvt/DRIVE_MODE_IMPLEMENTATION.md).
