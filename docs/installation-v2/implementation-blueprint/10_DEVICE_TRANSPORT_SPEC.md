# Device Transport Specification

## Authority

`DeviceTransport` is the only Swift device abstraction. `DynamicNativeDeviceTransport` becomes its production implementation; all libimobiledevice/idevice operations remain behind the pinned Rust bridge. Setup modules may not invoke CLI tools, Xcode, or duplicate USB discovery.

## Interface groups

- Discovery: list devices, stable UDID, USB/wireless kind, select exactly one.
- Connection: open/close/cancel; connection generation; sanitized diagnostics.
- Lockdown: inspect name/model/OS build, trust, lock, Developer Mode; pair once.
- Applications: inventory, install, uninstall only under explicit policy, launch.
- Containers: bounded AFC/House Arrest read/write with bundle and path allowlists.
- Developer support: image status/mount, TSS input/output.
- Runtime: CoreDeviceProxy, software tunnel, RSD handshake, RemoteXPC, AppService.
- Remote pairing: create/validate pairing material; bytes returned directly for encrypted storage/delivery.

The existing C ABI status enum remains versioned but moves to namespaced modules. ABI requests are bounded, cancellation-aware, panic-contained, and return structured JSON receipts. Swift verifies dylib hash/ABI before first call and maps every status to a stable Veya error without exposing raw secret-bearing diagnostics.

## Identity and stale connection rules

Stable device ID is authoritative; usbmux ID is ephemeral. Every handle includes `connectionGeneration`. Reconnect, transport switch, iPhone reboot, or bridge reopen invalidates handles and all connection-bound evidence. A receipt for device A can never satisfy device B even when display names match.

## Rust/Swift division

Rust owns protocol framing, async timeouts, provider/service clients, byte bounds, and low-level statuses. Swift owns device selection policy, reconciliation, retry/user-action classification, evidence, and persistence. No Rust operation writes the installation journal.

## Safety

Default qualification operations are list/inspect/inventory/status/read-only. Pair, mount, install, container-write, and launch require named policy capabilities. Uninstall, record deletion, reset, and unknown path writes require explicit destructive permits and are excluded from planning runs.

Tests retain ABI mocks but add actual universal-dylib contract tests and safe physical list/inspect/inventory probes. Physical results prove only the connected device/build combination.

