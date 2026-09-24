# Native Device Bridge (`native/iossim-device-bridge`) — checkpoint `8155901`

## Architecture

```
Swift (IOSSimMacCore)                                   Rust cdylib (libiossim_device_bridge.dylib)
─────────────────────────────────────────────           ───────────────────────────────────────────────
IOSSimDeviceBridge (actor)  ── de-dupe by UDID ──┐       iossim_bridge_*        veya_signing_*
  listDevices / inspect w/ connection-loss       │         │                      │
  fallback to the same UDID's other entries      │         │ tokio (2 workers)    │ veya-signing-core
DynamicNativeDeviceTransport ── dlopen ──────────┴──────►  │ on a 16 MiB thread   │ (apple-codesign,
  ABI == 3 + required symbols, else refuse                 │ with a timeout       │  OS CMS)
  withHandle: open → op → close per call                   ▼
  status → NativeDeviceBridgeError                  idevice @ 1838db107d38701b4044361163aac049006c2627
                                                    usbmuxd · lockdown · AMFI · installation_proxy ·
                                                    AFC / house_arrest · mobile_image_mounter + TSS ·
                                                    RemotePairing · CoreDeviceProxy → software tunnel
                                                    → RSD → RemoteXPC → AppService
```

- Crate: `iossim-device-bridge` 0.1.0, edition 2024, `crate-type = ["cdylib","staticlib"]`. The `idevice`
  git dependency is pinned to `1838db107d38701b4044361163aac049006c2627` with features
  `ring, usbmuxd, pair, amfi, afc, house_arrest, installation_proxy, mobile_image_mounter, tss,
  remote_pairing, rsd, core_device, core_device_proxy, tunnel_tcp_stack`.
- Version string: `iossim-device-bridge/0.1.0+idevice-1838db1`.
- Every export runs inside `protected()` (`catch_unwind` → `InternalError`). Async work runs in a
  fresh 2-worker tokio runtime on a dedicated 16 MiB-stack thread (`block_on_timeout`), because
  Swift cooperative threads have ~512 KiB stacks. Timeouts must be in `1..=120000` ms.
- Results use one layout, `#[repr(C)] BridgeResult { status: i32, payload: *mut u8, payload_len:
  usize, diagnostic: *mut c_char }`, and are released with `iossim_bridge_result_free`. Diagnostics
  pass through `clean_diagnostic` (`lib.rs:426`): if any of `privatekey, escrowbag, password,
  security-code, cookie, token` appears, the whole message becomes "device service returned a
  redacted error"; otherwise control characters are dropped and it is truncated to 512 chars.
- Device handles: `DeviceHandle { stable_id, usbmux_id, connection, connection_generation, cancelled }`.
  A handle is an **identity record, not a live connection**. Every operation re-resolves the device
  through `selected_device` and opens its own service connection.

## ABI and loading (Swift)

- `iossim_bridge_abi_version()` returns **3** (`lib.rs:969`). ABI 3 added `iossim_bridge_reveal_developer_mode`.
- `DynamicNativeDeviceTransport.requiredABIVersion = 3` (`NativeDeviceBridge.swift:477`+).
- Library search order (`libraryCandidates`, `NativeDeviceBridge.swift:1052`): `$IOSSIM_DEVICE_BRIDGE_PATH`
  (absolute only) → `Contents/Frameworks/libiossim_device_bridge.dylib` →
  `Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib` (the packaged location) → the
  same path resolved from the executable.
- `dlopen(RTLD_NOW|RTLD_LOCAL)`. On ABI mismatch it `dlclose`s and sets `loadError = .incompatibleABI`.
  Required symbols (all must resolve, else `.incompatibleABI`): list, open, inspect,
  pair_lockdown_once, create_remote_pairing, validate_remote_pairing, developer_support_status,
  mount_developer_support, **reveal_developer_mode**, app_inventory, install_app, uninstall_app,
  container_write, container_read, close_device, result_free. `launch_app` and
  `developer_services_status` are resolved too but checked at call time (`.incompatibleABI` if absent).
- Load diagnostics are reduced to safe categories (`safeLoadDiagnostic`).

### Integrity verification

- The packaged `Contents/Resources/EngineIntegrity.plist` records `nativeBridgeABI 3`,
  `nativeBridgeSHA256`, helper SHA-256 and payload manifest SHA-256. `PackagedEngineIntegrity.loadAndValidate`
  checks them. It is called by `BundledProvisioningEngine.live()` (`IOSSimMacApp.init`, legacy
  `SetupStore` engine), where a failure yields `UnavailableIOSSimSetupEngine`.
- **Limitation (documented, not changed):** the development-session UI does not go through
  `BundledProvisioningEngine`. `DynamicNativeDeviceTransport` loads the bridge directly, gated only by
  ABI version and required symbols, **not** by the recorded SHA-256. Code signing (`codesign --verify
  --deep --strict` on the app, and the ad-hoc signature of the dylib) is the remaining load-time
  integrity control on that path.
- The signer half (`veya_signing_*`, `SIGNING_CORE_ABI_VERSION = 1`) is loaded separately by
  `InProcessSigner` (`macos/Sources/IOSSimMacCore/Installation/InProcessSigner.swift:145`), which
  checks `veya_signing_abi_version`. There is no external-signer fallback: `UnavailablePayloadSigning`
  fails closed.

## Exported operations

Status values (`enum Status`, `lib.rs:38`) map one-to-one to `NativeDeviceBridgeError`
(`DynamicNativeDeviceTransport.error(status:)`, `NativeDeviceBridge.swift:1162`):

| # | Rust `Status` | Swift `NativeDeviceBridgeError` |
|---|---|---|
| 0 | Ok | — |
| 1 | InvalidArgument | `.invalidIdentity` |
| 2 | Unavailable | `.libraryUnavailable` |
| 3 | DeviceNotFound | `.deviceNotFound` |
| 4 | DeviceDisconnected | `.deviceDisconnected` |
| 5 | DeviceLocked | `.deviceLocked` |
| 6 | TrustRequired | `.trustRequired` |
| 7 | DeveloperModeRequired | `.developerModeRequired` |
| 8 | Cancelled | `.cancelled` |
| 9 | TimedOut | `.timedOut` |
| 10 | ProtocolError | `.protocolFailure(redacted)` |
| 11 | InternalError | `.internalFailure(redacted)` (default) |
| 12 | DeviceResolutionFailed | `.deviceResolutionFailed` |
| 13 | CoreDeviceProxyFailed | `.coreDeviceProxyFailed` |
| 14 | SoftwareTunnelFailed | `.softwareTunnelFailed` |
| 15 | RsdUnavailable | `.rsdUnavailable` |
| 16 | RemoteXpcFailed | `.remoteXPCFailed` |
| 17 | AppServiceUnavailable | `.appServiceUnavailable` |
| 18 | FeatureUnavailable | `.featureUnavailable` |
| 19 | ApplicationNotFound | `.applicationNotFound` |
| 20 | DdiRequired | `.ddiRequired` |
| 21 | DeveloperServicesNotReady (currently unused, `#[allow(dead_code)]`) | `.developerServicesNotReady` |
| 22 | LaunchRejected | `.launchRejectedStructured(NativeLaunchRejection)` if the payload decodes as schema 1, else `.launchRejected(redacted)` |
| 23 | ContainerUnavailable | `.containerUnavailable` |
| 24 | PairingRejected | `.pairingRejected` |
| 25 | PairingPending | `.trustPromptPending` |
| 26 | PairingDenied | `.trustDenied` |
| 27 | ContainerFileNotFound | `.containerFileNotFound` (AFC `ObjectNotFound`, sub-code 8, on this exact path) |

Generic idevice error classification (`classify_error`, `lib.rs:830`) is **typed first**
(`DeviceNotFound`, `DeviceLocked`, `DeveloperModeNotEnabled`, `ServiceNotFound → AppServiceUnavailable`,
`ImageNotMounted → DdiRequired`). After that it falls back to **text**: "password protected"/"locked" →
DeviceLocked, "pair"/"trust" → TrustRequired, "disconnect"/"broken pipe" → DeviceDisconnected, and
everything else → ProtocolError. `staged_device_status` (`lib.rs:852`) keeps authoritative device state
(Developer Mode, locked, trust, disconnected, not found) inside staged developer-services failures.

| Symbol | Purpose | Input | Output payload | Notable status mapping | Apple / device service |
|---|---|---|---|---|---|
| `iossim_bridge_abi_version` | ABI | — | `u32` = 3 | — | — |
| `iossim_bridge_version` | Version string | — | `const char*` | — | — |
| `iossim_bridge_list_devices` | Enumerate usbmuxd entries | timeout | `[{stableId, usbmuxId, connection: usb/wireless/unknown}]`. **One entry per connection; no de-duplication.** | TimedOut | usbmuxd `ListDevices` |
| `iossim_bridge_open_device` | Build a handle for one exact entry | UDID, expected mux id, expected connection (0/1/2), connection generation, timeout, out-handle | none | `select_exact_device`: mux 0 or connection Unknown → exactly one UDID match or DeviceResolutionFailed (ambiguous) / DeviceNotFound. Otherwise requires UDID **and** mux id **and** connection kind, else DeviceNotFound | usbmuxd |
| `iossim_bridge_inspect_device` | Name, model, OS version/build, trust, lock, Developer Mode | handle, timeout | `DeviceInspection` JSON | classify_error | lockdown `GetValue` (+ paired session); `DeveloperModeStatus` in `com.apple.security.mac.amfi`, AMFI action 3 fallback |
| `iossim_bridge_pair_lockdown_once` | Trust This Computer / validate an existing pair record | handle, host name, timeout | `LockdownPairingReceipt` (`LOCKDOWN_SESSION_VALIDATED`, created/persisted/validated) | **USB only** (else PairingRejected). PairingPending/PairingDenied/DeviceLocked from typed idevice errors | lockdown `Pair`, usbmuxd `SavePairRecord` (validated before and after save; deleted if the persisted copy fails) |
| `iossim_bridge_create_remote_pairing` | Create an RPPairing record over trusted lockdown | handle, hostname, timeout | Serialized pairing record (contains a private key, returned only for immediate Keychain storage) | classify_error | RemotePairing lockdown service |
| `iossim_bridge_validate_remote_pairing` | Verify an existing RPPairing record | handle, hostname, record bytes, timeout | none | DeviceNotFound/Locked/trust-dialog/invalid-host keep their class; else PairingRejected | RemotePairing pair-verify |
| `iossim_bridge_reveal_developer_mode` | Show the Developer Mode toggle in Settings | handle, timeout | none | classify_error | AMFI (`com.apple.amfi.lockdown`) **action 0 only** |
| `iossim_bridge_developer_support_status` | Is a personalized image mounted? | handle, timeout | `{mounted: bool}` | classify_error | mobile_image_mounter `LookupImage("Personalized")` |
| `iossim_bridge_mount_developer_support` | Personalize + mount the DDI | handle, image path, trust-cache path, BuildManifest path (absolute, normalized), timeout | none | classify_error | lockdown `UniqueChipID` (retried once in a paired session on `GetProhibited`/`SessionInactive`, `unique_chip_id` `lib.rs:913`), TSS, mobile_image_mounter `mount_personalized` |
| `iossim_bridge_app_inventory` | User-app inventory | handle, timeout | `[{bundleId, version, teamId}]`; team from `TeamIdentifier`, the signed `com.apple.developer.team-identifier`, or `application-identifier` prefix (only if its bundle part matches) | Error key in reply → ProtocolError | installation_proxy `Lookup` (ApplicationType User) |
| `iossim_bridge_install_app` | Install or upgrade | handle, local .app path, upgrade flag, timeout | none | classify_error | AFC upload + installation_proxy Install/Upgrade |
| `iossim_bridge_uninstall_app` | Uninstall | handle, bundle id, timeout | none | classify_error | installation_proxy Uninstall |
| `iossim_bridge_developer_services_status` | Read-only readiness chain | handle, timeout | `{coreDeviceProxyReady, softwareTunnelReady, rsdReady, remoteXpcReady, appServiceReady, launchFeatureReady, ddiMounted?}` | Staged: device_resolution → DeviceResolutionFailed; coredevice_proxy → DdiRequired (ImageNotMounted) / staged / CoreDeviceProxyFailed; software_tunnel; rsd_connect; rsd_handshake; appservice_resolution → DdiRequired only if DDI is known unmounted, else AppServiceUnavailable; appservice_feature → FeatureUnavailable; remotexpc_handshake | CoreDeviceProxy → userspace TCP tunnel → RSD → RemoteXPC → `com.apple.coredevice.appservice` (`feature.launchapplication`) |
| `iossim_bridge_launch_app` | Launch an exact bundle id | handle, bundle id, timeout | `{bundleId, pid, processIdentifierVersion, appServiceConnected}` | Same staging, then: NotFound → ApplicationNotFound; DeviceLocked; DeveloperModeNotEnabled; `CoreDevice(sub_code 1)` → LaunchRejected + **structured payload (envelope `coreDeviceErrorEnvelope`)**; substring match → LaunchRejected + payload (envelope `heuristic`); else ProtocolError | AppService `launch_application` |
| `iossim_bridge_container_write` | Write a file into an app container | handle, bundle id, relative path (no `/`, `.`, `..`), bytes ≤ 16 MiB, timeout | none | ServiceNotFound → ContainerUnavailable | house_arrest `VendContainer` + AFC |
| `iossim_bridge_container_read` | Read a file from an app container | handle, bundle id, relative path, timeout | bytes ≤ 16 MiB | ServiceNotFound → ContainerUnavailable, AFC ObjectNotFound → ContainerFileNotFound | house_arrest + AFC |
| `iossim_bridge_cancel` | Cooperative cancel | handle | — | — | — |
| `iossim_bridge_close_device` | Free handle | handle | — | — | — |
| `iossim_bridge_result_free` | Free result | result | — | — | — |
| `veya_signing_abi_version` | Signer ABI | — | `u32` = 1 | — | — |
| `veya_signing_operation_create` / `_free` / `_cancel` | Signing operation lifetime | — | — | — | — |
| `veya_signing_inspect` | Bundle graph of a bundle | JSON `{schemaVersion 1, bundlePath}` | graph JSON | InvalidRequest | local only |
| `veya_signing_verify` | Verify Mach-O signatures of a signed bundle | JSON `{schemaVersion 1, bundlePath}` | verification receipt (inventory SHA-256, verified Mach-Os) | — | local only |
| `veya_signing_sign` | Sign in process | operation, request JSON, PKCS#8 key bytes (borrowed; caller zeroes them) | signing receipt | — | local only (`veya-signing-core`) |
| `veya_signing_result_free` | Free result | result | — | — | — |

VPN: there is **no VPN-specific export**. LocalDevVPN setup uses `container_write` (request),
`launch_app` (Veya and LocalDevVPN), `app_inventory` (LocalDevVPN presence and version) and
`container_read` (receipt).

## Device selection

Three layers select a device, and each one preserves the exact connection identity:

1. **Swift listing** — `IOSSimDeviceBridge.listDevices` (`NativeDeviceBridge.swift:398`): increments the
   actor's `generation` on every call, stamps each descriptor with it, groups entries by UDID, sorts each
   group by `preference` (`:435`: USB 0 < wireless 1 < unknown 2, then lowest mux id), and returns the
   first per UDID. **The UI shows one row per phone, preferring USB.** Alternatives are kept.
   `inspect` falls back to the same UDID's other entries only on `deviceNotFound/deviceDisconnected`
   and only within the same generation.
2. **Open** — `select_exact_device` (`lib.rs:774`): UDID + mux id + connection kind.
3. **Per operation** — `selected_device` → `find_selected_device` (`lib.rs:950,960`): UDID **and**
   the handle's mux id, independent of list order.

Swift re-checks returned identity. `inspect` requires `identity.binds(to: returned)` (same UDID and
registration identifier; mux id and connection must match when both are present) and the same
connection generation, else `.deviceDisconnected`. `pairLockdownOnce` requires the receipt's UDID, mux,
generation and connection to equal the request.

Engine side: `EngineDeviceSelection.identity(connectionGeneration:)` (`DeviceProductionAdapters.swift`)
returns the picker's exact `transportIdentity` and throws `invalidIdentity` if its UDID or generation
disagrees with the request.

## G. USB + Wi-Fi duplicate device defect (fixed in `8155901`)

**Setup.** usbmuxd lists one entry per connection. An iPhone on a USB cable that is also reachable
over the network (Wi-Fi sync / `_apple-mobdev2._tcp` Bonjour) appears **twice with the same UDID**:
one `Usb` entry and one `Network` entry, each with its own mux `DeviceID`. The order changes when the
network entry attaches and detaches. The Mac's unified log for 2026-09-24 shows network entries
attaching and detaching repeatedly (new DeviceIDs 844…885).

**Old behavior** (`selected_device` before `8155901`):

```rust
let selected = devices().await?.into_iter().find(|d| d.udid == stable_id)
    .ok_or(DeviceNotFound)?;
if selected.device_id != expected_mux { return Err(DeviceNotFound); }
```

**Failure mode.** The handle was opened correctly on the USB entry (mux 7, say). When the network
entry was listed first, `find` returned it. Its mux id (e.g. 90) ≠ 7 → `DeviceNotFound`, **even though
the USB entry was attached**. Every per-operation call used this helper: inspect, app inventory,
install, uninstall, launch, developer-services status, DDI status and mount, container read and write,
reveal, RemotePairing create and validate, lockdown pairing.

**How it surfaced.** `ApplicationDomain.observe` turned the inventory failure into `retryableFailure`
`VEYA-INSTALL-024` "The device application inventory could not be read." This hit right after the
user completed the Developer Trust step and pressed **Continue**. Launch/DDI/container operations
failed the same way. `DeviceFailureMapping.map` gave them `VEYA-DEVICE-030`, and VPN reported
`VEYA-VPN-037`.

**Why it looked environmental or intermittent.** It depended on usbmuxd's current ordering, which
changes when the phone's Wi-Fi entry comes and goes (screen lock, Wi-Fi power state, Bonjour
refresh). The same button could pass and then fail seconds later. Nothing in Veya's own state had
changed.

**Fix** (`find_selected_device`, `lib.rs:950`):

```rust
values.into_iter().find(|d| d.udid == stable_id && d.device_id == expected_mux)
```

Order no longer matters. The connection kind isn't needed here because usbmuxd mux ids are unique
per attached entry, and `open_device` already checked the kind when the handle was created.

**Fail-closed.** If the USB entry itself disappears (cable pulled, phone rebooting), no entry has that
mux id. The call returns `DeviceNotFound` even though the UDID is still listed through Wi-Fi. **Veya
never silently moves an operation to the network entry.** Moving to a new entry happens only through
a fresh listing, which yields a new connection generation, which in turn makes every
connection-bound proof stale.

**Regression test.** `per_operation_selector_uses_udid_and_mux_not_input_order` (`lib.rs:2869`) runs
Wi-Fi-first and USB-first orders (selects mux 7 in both), the USB entry detached (Wi-Fi still listed
→ `None`), and a different UDID on the same mux → `None`. The older
`exact_selector_uses_udid_mux_and_connection_not_input_order` and
`selector_rejects_ambiguous_legacy_or_wrong_connection_identity` cover `select_exact_device`.

**Physical proof status.** See the physical validation record. The 8155901 build reached READY on
hardware. The unified log does not show that the target phone's Wi-Fi entry was listed ahead of its
USB entry at the moment of a specific 8155901 operation, so the exact failing ordering was
**not** deliberately reproduced on hardware. It is covered by the unit test above.

## Other notable native behaviors

- **Developer Mode resolution** (`resolve_developer_mode`, `lib.rs:877`): lockdown first (AMFI action 3
  has been observed closing the connection without an answer on iOS 26.6.2 while Developer Mode was
  on). An unanswered query is `unknown`.
- **DDI over network** (`unique_chip_id`, `lib.rs:913`): a network-connected iPhone refuses
  `UniqueChipID` before a paired session (`GetProhibited`). The read is retried once inside a session.
  Other failures pass through unchanged.
- **AppService absence** (`missing_app_service_status`): only a known-unmounted DDI maps to `DdiRequired`.
- **Launch-rejection chain** (`extract_error_chain`, `lib.rs:364`): parses the `plist::Value` Debug
  rendering, which is the only form the `idevice` crate exposes (`CoreDeviceServiceClient::invoke_inner`
  stringifies it privately). Depth ≤ 8. Any level missing `domain` or `code` → `chainComplete = false`.
  Key order is not assumed.
