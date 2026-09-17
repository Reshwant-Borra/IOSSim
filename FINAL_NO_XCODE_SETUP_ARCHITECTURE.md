# Final No-Xcode Setup Architecture

Date: 2026-09-15  
Setup schema: 3  
Consumer Xcode dependency: none

## Boundary

This architecture ends at `SETUP_READY_FOR_RUNTIME`. It does not open LocalDevVPN, TestManager, XCTest, XCUILocation, Spoof, Drive, or Rich Drive. The proven runtime protocol and location components are unchanged.

## Architecture

```text
Bundled IOSSim Mac app / IOSSimProvisioner
  |
  +-- existing physical reconciliation (persisted checkpoint is a hint)
  |     +-- NATIVE_IDEVICE_USBMUX discovery / Lockdown identity
  |     +-- NATIVE_AFC_INSTALLATION_PROXY exact main + runner inventory
  |
  +-- NativeDeveloperServicesCoordinator (one setup-side owner)
  |     +-- Developer Mode inspection
  |     +-- exact-build DeveloperSupportArtifact selection
  |     +-- MobileImageMounter + in-bridge TSS personalization when explicit
  |     |   ImageNotMounted evidence requires it
  |     +-- CoreDeviceProxy -> software tunnel -> RSD
  |     +-- RemoteXPC -> com.apple.coredevice.appservice feature map
  |
  +-- NativeApplicationService (shared transport)
  |     +-- NATIVE_APPSERVICE_RSD exact-bundle launch
  |     +-- House Arrest VendContainer + AFC bounded path access
  |           +-- semantic runtime-mapping.json write/readback
  |           +-- encrypted RemotePairing setup inbox
  |
  +-- RemotePairingCoordinator
        +-- pinned-idevice create/validate
        +-- device+team-scoped Mac Keychain record
        +-- phone-generated one-time bootstrap key
        +-- AES-GCM envelope into current main app container
        +-- existing phone Keychain runtime contract
        +-- bound receipt readback
```

The Swift composition creates one `DynamicNativeDeviceTransport` and one `NativeApplicationService` for developer readiness, AppService launch, House Arrest configuration, and pairing delivery. It does not create unrelated RSD managers. Live proxy/tunnel/RSD/RemoteXPC objects are session scoped inside the bridge and are never persisted.

## State machine

```text
physical inventory incomplete
  -> repair only missing main/runner -> re-inventory
inventory verified
  -> reconcile Developer Mode and developer services
developer services ready
  -> launch exact current main bundle through AppService
main launch accepted
  -> reconcile runtime mapping through House Arrest/AFC
runtime mapping semantically verified
  -> create/reuse and natively validate device-scoped RemotePairing
pairing valid
  -> request phone bootstrap -> encrypted delivery -> bound receipt
receipt verified
  -> SETUP_READY_FOR_RUNTIME
```

On setup start, Try Again, restart, or reconnect, schema-3 reconciliation rechecks exact installed inventory and House Arrest mapping. A persisted pairing/final checkpoint is deliberately derived back to `RUNTIME_CONFIGURATION_VERIFIED` until session-scoped developer services and the phone receipt have been revalidated. Missing applications still use the physically proven component-scoped install repair.

## Readiness domains

The existing setup engine now records distinct facts for connection, lock, computer trust, Developer Mode, Personal Team authorization, signing, main/runner installation and inventory, DDI, CoreDeviceProxy, software tunnel, RSD, RemoteXPC, AppService, native launch, House Arrest/runtime configuration, and RemotePairing delivery/receipt. UI copy keeps protocol terms in diagnostics and uses consumer wording such as “Preparing iPhone developer services” and “Preparing secure device connection.”

## Identity model

`IOSSimDeviceIdentity` keeps the stable Lockdown UDID authoritative while carrying the connection-local usbmux identifier, signing registration identifier, optional CoreDevice/developer-services identifier, optional RemotePairing identifier, and connection generation as separate fields. A bridge handle is opened by stable UDID and pinned to its observed usbmux id. Signing registration, AppService target selection, and RemotePairing association are never assumed to share one identifier namespace.

The launch/config/delivery bundle is the current team-derived main identifier from the provisioning manifest, checked against native inventory. The runtime mapping also contains the exact team-derived runner identifier.

## DDI and TSS

DDI is conditional, not synonymous with Developer Mode or profile trust. The bridge reports `DDI_REQUIRED` only for explicit `ImageNotMounted` evidence. The production coordinator first probes the developer-service graph; only that result enters the DDI repair path.

Artifacts are exact iOS-build selected from `~/Library/Application Support/IOSSim/DeveloperSupport/<build>/<identity>/` or an already authorized Apple cache. `iossim-developer-support.json` binds build, build identity, image size/SHA-256, BuildManifest SHA-256, mandatory trust-cache SHA-256, minimum bridge ABI, provenance id, and last validation date. Every reuse rehashes files and rejects ambiguous or corrupt matches. Pairing/Apple credentials are never stored in this cache.

The pinned Rust `ImageMounter::mount_personalized` implementation obtains device identifiers, resolves the BuildManifest identity, performs TSS personalization, uploads, mounts, and returns only a safe result across FFI. Tickets and sensitive request material do not enter Swift logs or support exports.

No approved IOSSim signed HTTPS provider URL/key or redistributable exact-build iOS 26.6.2 asset is present. Runtime acquisition therefore fails closed with `DDI_NO_APPROVED_SOURCE`; the implementation does not invent a mirror.

## AppService and diagnostics

The readiness and launch exports independently classify device resolution, CoreDeviceProxy, software tunnel, RSD connect/handshake, AppService service-map lookup, feature lookup, RemoteXPC connection, application lookup, policy rejection, and protocol errors. `ServiceNotFound` no longer aliases `DeviceNotFound`.

## Runtime configuration

The canonical file is `Library/Application Support/IOSSim/runtime-mapping.json` in the current main-app container. Schema 1 binds the safe device hash, optional team, exact main bundle, and exact runner bundle. Reconciliation decodes and compares semantics: current content is not rewritten; missing/stale content is atomically replaced through native House Arrest/AFC and read back. The phone runner resolver consumes this file first while retaining the proven environment/Info.plist/UserDefaults compatibility fallbacks.

## RemotePairing and persistence

USB Lockdown trust, CoreDevice developer-service transport, and the runtime RemotePairing plist are different relationships.

Mac secret material is a generic-password Keychain item scoped by `<team>:<stable UDID>`, accessible after first unlock on this Mac only. Plain Application Support holds no Mac pairing secret. The runtime plist remains compatible with the phone store: 32-byte `public_key`, 32-byte `private_key`, non-empty `identifier`, and optional 16-byte `alt_irk`; the phone continues using Keychain service `com.iossim.on-device-dvt-poc.rppairing`, account `primary`.

For delivery, the Mac writes a non-secret request to the current app container and launches the app. The phone creates a 32-byte one-time bootstrap key with complete file protection. The Mac reads it over trusted USB, writes an AES-GCM envelope, and activates the app again. The app imports into its existing Keychain store, writes a receipt bound to device, team, nonce, pairing identifier, and public-key fingerprint, and deletes request/bootstrap/envelope. The Mac validates the native record and receipt; it never starts the runtime to claim this setup gate.

## Recovery

- Missing main/runner: repair only that component, then revalidate the new container.
- Missing/stale config or changed container: semantic rewrite/readback only.
- Expired proxy/tunnel/RSD/AppService session: rebuild readiness on resume/reconnect.
- Valid pairing with missing receipt/container: reuse the Keychain record and repair delivery only.
- Invalid/rejected pairing: delete only that device+team item, recreate, redeliver, reverify.
- Locked, untrusted, Developer Mode disabled, missing DDI, unavailable service, and protocol failure remain distinct retryable domains.

## Security boundary

Support output contains only safe status, dates, schema, safe device identifier/hash, pairing presence/disposition, and public-key fingerprint metadata. It excludes Apple passwords, 2FA codes, cookies, tokens, signing private keys, pairing bytes, pairing private key, bootstrap key, and `alt_irk`. Native diagnostics redact sensitive field names and bound diagnostic length.

## Build-time versus consumer runtime

Build machine only: build/sign the iPhone main and runner payloads (Xcode allowed), generate the complete payload manifest, approve/package or configure lawful developer-support assets, and build/sign/notarize the Mac distribution.

Consumer runtime: bundled prebuilt payloads, pinned native bridge, Apple authorization, direct signing, native install/inventory, conditional approved DDI/TSS, developer services, AppService, House Arrest, and automatic pairing. It never runs Xcode, `xcodebuild`, `xcrun`, or `devicectl`.
