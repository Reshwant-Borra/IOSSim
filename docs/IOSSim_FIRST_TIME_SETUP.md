# IOSSim First-Time Setup

This is the authoritative setup flow through `SETUP_READY_FOR_RUNTIME`. It does not start the location runtime.

## State machine

```text
discover selected phone over native usbmux
  -> inspect Lockdown identity, unlock, Trust, Developer Mode
  -> native Apple SRP/2FA session and Personal Team selection
  -> register device; create/reuse certificate, App IDs, profiles
  -> rewrite/sign prebuilt main + runner for that team/device
  -> native AFC staging + Installation Proxy install/upgrade
  -> authoritative exact main/runner inventory
  -> developer-services readiness
       CoreDeviceProxy -> software tunnel -> RSD -> service map
       -> conditional exact-build DDI/TSS only on explicit DDI_REQUIRED
       -> RemoteXPC/AppService feature readiness
  -> launch exact installed main bundle through AppService
  -> House Arrest VendContainer + AFC runtime-mapping write/readback
  -> create/reuse and validate device/team-scoped RemotePairing
  -> request phone bootstrap; encrypted envelope delivery; reactivate app
  -> phone Keychain import + bound receipt
  -> Mac verifies native pairing and receipt
  -> write a LocalDevVPN readiness request; reactivate IOSSim's bounded watcher
  -> if needed, launch installed `com.jkcoxson.LocalDevVPN` through AppService
  -> require the existing `DeveloperRouteProbe` TCP check to `10.7.0.1:49152`
  -> SETUP_READY_FOR_RUNTIME
  -> STOP
```

## Domain details

Device discovery uses the bundled bridge and stable Lockdown UDID. The connection-local usbmux ID is re-resolved and never treated as a durable identity. If the phone disappears, retry discovery for the same selected device before changing state.

Trust, unlock, Developer Mode/restart, Apple 2FA, developer-profile trust, and any Apple system confirmation are legitimate user actions. They are not implementation failures. If Developer Mode is still disabled after the phone reconnects: Settings → Privacy & Security → Developer Mode → enable → restart → unlock → confirm Turn On.

Apple authentication is IOSSim-owned GrandSlam SRP. A scoped session is held in the Mac Keychain; passwords and 2FA codes are not placed in the setup journal. IOSSim selects the Personal Team, registers the selected device when needed, creates/reuses its signing key/certificate, manages canonical App IDs/profiles, and signs the two prebuilt payloads. Normal consumers do not use Xcode Accounts or manual certificate management.

Installation is native `NATIVE_AFC_INSTALLATION_PROXY`. The current source reconciles physical inventory before trusting persisted checkpoints, installs only missing/stale owned components, and re-inventories with bounded retries. Persisted state is a hint; current phone state is authoritative.

Developer services are independent from USB trust and RemotePairing. The coordinator preserves typed errors including `DEVICE_RESOLUTION_FAILED`, `COREDEVICE_PROXY_FAILED`, `SOFTWARE_TUNNEL_FAILED`, `RSD_UNAVAILABLE`, `REMOTEXPC_FAILED`, `APPSERVICE_UNAVAILABLE`, `FEATURE_UNAVAILABLE`, `APPLICATION_NOT_FOUND`, `DDI_REQUIRED`, `LAUNCH_REJECTED`, and `PROTOCOL_ERROR`.

DDI is conditional. Only explicit `DDI_REQUIRED` evidence selects an exact iOS-build/identity artifact, verifies hashes/trust cache/manifest, asks the native bridge to personalize through Apple TSS, mounts, and re-probes. No approved asset/provider is currently configured, so an explicit requirement becomes `FIRST_TIME_SETUP_BLOCKED_AT_DDI`; do not obtain an arbitrary image.

After AppService launches the current main app, House Arrest vends that exact app container. IOSSim atomically writes schema-1 `Library/Application Support/IOSSim/runtime-mapping.json`, reads it back, decodes it, and compares device hash, team, main ID, and runner ID. Current content is retained if already semantically equal.

Automatic pairing is device/team scoped. The Mac validates or creates the pairing record, stores it in its Keychain, writes a non-secret request, launches the app, reads its one-time bootstrap, encrypts the pairing plist using AES-GCM, delivers it to the private inbox, and launches again. The phone validates/imports into its established Keychain item, writes a non-secret bound receipt, and removes request/bootstrap/envelope. Receipt or delivery repair reuses a valid pairing record rather than regenerating it.

LocalDevVPN remains an external prerequisite owned by its installed app. IOSSim does not create a NetworkExtension configuration. After pairing, the Mac writes a schema-1 non-secret request and activates the IOSSim watcher. If the existing probe is not already functionally ready, native AppService opens `com.jkcoxson.LocalDevVPN`; its established Auto Connect on Launch/start mechanism remains authoritative. The IOSSim watcher writes `ready` only after TCP connectivity to `10.7.0.1:49152`. A missing app is `LOCALDEVVPN_MISSING`; a Connect tap or Apple VPN confirmation is `LOCALDEVVPN_USER_ACTION_REQUIRED`, with the external app left visible for action.

## Recovery rules

- Restart/Try Again/reconnect: re-observe selected device and exact inventory before deriving the next checkpoint.
- Missing main or runner: install only the missing component, then revalidate container/config.
- Explicit refresh: re-sign and force-upgrade both owned payloads even when the derived IDs already exist, then inventory again. This prevents a stale installed binary from surviving a DeviceArtifacts rebuild.
- Stale/missing mapping: rewrite and semantic-readback only; do not reprovision unrelated domains.
- Expired developer-services session: rebuild proxy/tunnel/RSD/AppService readiness.
- Valid pairing but absent/invalid receipt: repeat delivery only.
- Explicit pairing semantic corruption or native rejection: rotate only that selected device/team record once.
- Locked/untrusted/Developer Mode disabled/profile trust: pause for the exact user action.
- DDI required with no approved exact asset: stop at the DDI gate.
- Never uninstall as generic recovery; never regenerate signing/pairing because a different domain timed out.

Schema 4 adds `LOCALDEVVPN_READY` between `REMOTE_PAIRING_VERIFIED` and `SETUP_READY_FOR_RUNTIME`. Schema-3 ready state migrates conservatively to `REMOTE_PAIRING_VERIFIED`, so it cannot bypass the new gate. `COMPLETE` is retained for compatibility but does not override live facts. Setup stops after VPN readiness; TestManager/XCTest/location belong to the next task.

## Current physical observation

On 2026-09-15, refresh generation 5 completed on iPhone18,1 / iOS 26.6.2 using the authoritative app. The ordered journal receipts prove main and runner upgrade, CoreDeviceProxy, software tunnel, RSD, RemoteXPC, AppService, native launch, House Arrest, runtime configuration write and semantic readback, RemotePairing creation, encrypted delivery, phone receipt verification, and `SETUP_READY_FOR_RUNTIME` at `15:27:56Z`.

The iPhone UI reported Developer Mode enabled. A bridge AMFI status probe incorrectly reported disabled even while every typed live readiness stage passed; AMFI status is therefore advisory and the live readiness result is authoritative. A genuine typed `developerModeRequired` still pauses for Apple user action. No `DDI_REQUIRED` occurred; readiness reported a developer image already mounted.

The schema-4 refresh at `2026-09-15T16:07:58Z` then opened/verified external LocalDevVPN and recorded `LOCALDEVVPN_READY`: the existing probe reached `10.7.0.1:49152`. It immediately persisted `SETUP_READY_FOR_RUNTIME` and stopped. TestManager, XCTest, location, Spoof, Drive, and Rich Drive were not started.
