# IOSSim Native Device Stack

## Pin and ownership

IOSSim pins `jkcoxson/idevice` at `1838db107d38701b4044361163aac049006c2627`. Enabled features are `ring`, `usbmuxd`, `pair`, `amfi`, `afc`, `house_arrest`, `installation_proxy`, `mobile_image_mounter`, `tss`, `remote_pairing`, `rsd`, `core_device`, `core_device_proxy`, and `tunnel_tcp_stack`.

Swift owns UI/policy, Apple account/session, Keychain, signing, state reconciliation, error presentation, and support export. Rust owns device-protocol bytes and transport stages. The iPhone owns the retained runtime. Live device handles and RSD sessions are never persisted.

## Layers

| Layer | IOSSim role | Current evidence |
|---|---|---|
| usbmux | enumerate and connect to Apple usbmuxd; bind stable UDID to current connection | PHYSICAL_PASS; raw enumeration currently exposes two endpoints for one stable phone, which Swift deduplicates |
| Lockdown | metadata, trust/pairing, lock state, Developer Mode-related values | PHYSICAL_PASS |
| AFC | stage app bundles and carry container bytes after House Arrest | PHYSICAL_PASS for fresh main/runner upgrade and container transfer |
| Installation Proxy | install/upgrade/uninstall and authoritative app inventory | PHYSICAL_PASS; generation 5 inventoried exact fresh main and runner |
| House Arrest | `VendContainer` for the exact current main bundle, then bounded allowlisted AFC read/write | PHYSICAL_PASS; generation 5 mapping and pairing transfers |
| AMFI/readiness | advisory Developer Mode inspection plus live typed readiness | AMFI flag was false-negative; iPhone UI on and live readiness PHYSICAL_PASS |
| CoreDeviceProxy | establish modern developer-service proxy | PHYSICAL_PASS, generation 5 |
| software tunnel | userspace TCP adapter to RSD | PHYSICAL_PASS, generation 5 |
| RSD | handshake and service-map discovery | PHYSICAL_PASS, generation 5 |
| RemoteXPC | connect selected RSD service/feature | PHYSICAL_PASS, generation 5 |
| AppService | inventory/launch exact current main ID | PHYSICAL_PASS, generation 5 native launch receipt |
| MobileImageMounter/TSS | exact-build personalized developer support on explicit requirement | Existing DDI reported mounted; no `DDI_REQUIRED` or acquisition path exercised |
| RemotePairing | create and validate runtime pairing plist over trusted device path | PHYSICAL_PASS; create, encrypted delivery, and phone receipt verified |
| External LocalDevVPN gate | AppService opens `com.jkcoxson.LocalDevVPN`; phone reuses `DeveloperRouteProbe` and returns a bound receipt | PHYSICAL_PASS; TCP `10.7.0.1:49152` at `2026-09-15T16:07:58Z` |

## Stable C ABI

ABI version 1 exports result-owned operations for list/open/inspect, RemotePairing create/validate, developer-support status/mount, app inventory/install/uninstall/launch, developer-services status, container write/read, cancellation, handle close, and result free. Every returned result is freed by the caller.

Status codes preserve the exact first failing layer: invalid argument, unavailable, device not found/disconnected/locked/trust/developer-mode, cancellation/timeout, protocol/internal, device resolution, CoreDeviceProxy, software tunnel, RSD, RemoteXPC, AppService, feature, application lookup, DDI required, developer services not ready, launch rejection, container unavailable, and pairing rejection. `ServiceNotFound` no longer maps to physical device-not-found.

## Identity and boundaries

- Stable identity: Lockdown UDID, selected explicitly.
- Connection identity: current usbmux ID/generation, resolved per operation.
- Apple portal device ID: registration identity, not silently substituted for transport IDs.
- Developer-services/CoreDevice and RemotePairing identities: diagnostic/cryptographic namespaces, explicitly bound rather than assumed equal.
- Bundle operations accept validated bundle identifiers; container paths are relative, bounded, and reject empty, absolute, `.` or `..` components.
- Rust does not accept arbitrary shell commands. Consumer Swift composition selects this bridge and fails closed against legacy Xcode/devicectl backends.

## DDI/TSS interface

The coordinator selects an exact BuildVersion/build identity, verifies image/BuildManifest/trust-cache hashes, and calls the bridge. The Rust mounter queries device personalization data, resolves the manifest identity, obtains a TSS ticket using ordinary TLS, uploads/mounts, and rechecks service readiness. Tickets and secrets do not cross into support output. The cache/provider policy accepts only an authorized existing Apple cache or a release-approved signed provider; neither an arbitrary mirror nor a weakened validation path is allowed. In the physical generation-5 pass, a suitable developer image was already mounted and no acquisition or mount was needed.

## Runtime boundary

The Mac setup RSD/AppService path must not be conflated with the frozen iPhone retained RSD/TestManager path. Setup now opens external LocalDevVPN and verifies only its existing functional route probe. It does not open retained RSD/TestManager, XCTest, or location. After `SETUP_READY_FOR_RUNTIME`, a separate regression task validates the remaining runtime unchanged.
