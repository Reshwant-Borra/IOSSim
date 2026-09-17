# No-Xcode Native App Launch Investigation

Investigation date: 2026-09-15 (America/New_York)
Branch: `work/investigate-native-app-launch-v1`
HEAD at start: `1259da507ecded222022cc86bf82863c15640db9`

## 1. Current physical state

Xcode is intentionally absent. The target phone is reported as `iPhone18,1`
running iOS `26.6.2`.

Frozen physical gates:

- `APPLE_USBMUX = PHYSICAL_PASS`
- `RUST_DEVICE_BRIDGE = PHYSICAL_PASS`
- `C_ABI = PHYSICAL_PASS`
- `SWIFT_DEVICE_DISCOVERY = PHYSICAL_PASS`
- `LOCKDOWN = PHYSICAL_PASS`
- `NO_XCODE_DEVICE_DISCOVERY = PHYSICAL_PASS`
- `NATIVE_AFC_INSTALLATION = PHYSICAL_PASS`
- `NATIVE_MAIN_INSTALL = PHYSICAL_PASS`
- `NATIVE_RUNNER_INSTALL = PHYSICAL_PASS`
- `NATIVE_POST_INSTALL_INVENTORY = PHYSICAL_PASS`
- `NO_XCODE_INSTALLATION = PHYSICAL_PASS`

The authoritative install backend is `NATIVE_AFC_INSTALLATION_PROXY`.
The install evidence showed `INSTALLING_MAIN` success, `INSTALLING_RUNNER`
success, post-install inventory with `mainPresent=true`, `runnerPresent=true`,
`retries=0`, `staleArtifactsPresent=false`, then `INSTALLATION_VERIFIED`.

## 2. Current blocker

After install verification, setup reaches:

```text
NATIVE_LAUNCH_UNAVAILABLE: serviceUnavailable
```

The GUI displays:

```text
IOSSim installed the apps, but native app launch is not available in this build.
```

The current blocker is `NATIVE_APP_LAUNCH`.

## 3. Existing launch call graph

```text
SetupStore provisioning continuation
  -> ConsumerArtifactProvisioner.advanceRuntimeConfiguration
  -> ConsumerArtifactProvisioner.launchMainForRuntimeConfiguration
  -> deviceBackend.launch(bundleIdentifier:rawDeviceIdentifier:context:)
  -> IdeviceProvisioningBackend.launch
  -> NativeApplicationService.launch
  -> AwaitingPhysicalAppServiceLauncher.launch
  -> throws NativeApplicationManagementError.serviceUnavailable
  -> IdeviceProvisioningBackend maps to:
       NATIVE_LAUNCH_UNAVAILABLE: serviceUnavailable
  -> ConsumerArtifactProvisioner maps to:
       ConsumerProvisioningErrorCode.nativeLaunchUnavailable
```

Source anchors:

- `macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift:1106`
- `macos/Sources/IOSSimMacCore/Services/RuntimeProvisioningSupport.swift:380`
- `macos/Sources/IOSSimMacCore/Services/NativeApplicationManagement.swift:71`

## 4. Exact serviceUnavailable source

`AwaitingPhysicalAppServiceLauncher.launch(bundleIdentifier:on:)` throws
`NativeApplicationManagementError.serviceUnavailable`.

`IdeviceProvisioningBackend.launch(...)` catches that error and emits
`NATIVE_LAUNCH_UNAVAILABLE: serviceUnavailable`.

Therefore the exact function returning the current blocker is:

```text
AwaitingPhysicalAppServiceLauncher.launch(bundleIdentifier:on:)
```

## 5. Current IOSSim launch implementation status

Status: `STUB`.

IOSSim has:

- A native app-management interface.
- Native install, uninstall, inventory, House Arrest container read/write.
- A launch protocol named `NativeRSDApplicationLaunching`.

IOSSim does not currently have:

- An IOSSim bridge symbol for application launch.
- A Swift `DynamicNativeDeviceTransport.launchApplication` wrapper.
- A production `NativeRSDApplicationLaunching` implementation.
- A proven RSD/AppService readiness gate for host-side setup launch.

## 6. Pinned idevice capabilities

Current Mac bridge pin:

```text
idevice rev = 1838db107d38701b4044361163aac049006c2627
bridge version = iossim-device-bridge/0.1.0+idevice-1838db1
```

`native/iossim-device-bridge/Cargo.toml` enables:

```text
rsd, core_device, core_device_proxy
```

The exact pinned revision already contains:

- `core_device::AppServiceClient`
- `AppServiceClient::rsd_service_name() = com.apple.coredevice.appservice`
- `AppServiceClient::connect_rsd(...)`
- `AppServiceClient::launch_application(...)`
- FFI functions `app_service_connect_rsd` and `app_service_launch_app`
- DVT `ProcessControlClient::launch_app(...)`

The required launch primitive exists in the pinned dependency. IOSSim has not
exposed it through its own bridge ABI.

## 7. Upstream idevice comparison if necessary

No dependency update is required to obtain AppService launch. Current upstream
also contains the same AppService surface, but the pinned revision is sufficient.

Because discovery and installation are already physical-pass gates, the preferred
solution is to expose pinned functionality through IOSSim's own bridge, not to
broadly update the device stack.

## 8. pymobiledevice3/public reference comparison

Public pymobiledevice3 documentation states that iOS 17+ developer services moved
to CoreDevice/RemoteXPC flows and require an RSD tunnel. It also documents that
CoreDevice commands require both an RSD tunnel and a mounted Developer Disk Image.

The pymobiledevice3 DVT process-control source launches apps through:

```text
launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:
```

That is an alternate developer-service launch path. The pinned `idevice`
AppService path is a better fit for IOSSim's setup launch because it launches an
ordinary installed app by bundle identifier and returns a process token/PID
without requiring XCTest runner orchestration.

References:

- https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md
- https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/cli-recipes.md
- https://raw.githubusercontent.com/doronz88/pymobiledevice3/master/pymobiledevice3/services/dvt/instruments/process_control.py

## 9. Modern iOS 26.6.2 launch architecture

For iOS 26.6.2, IOSSim should launch the already-installed main app through the
native CoreDevice AppService exposed over RSD:

```text
macOS IOSSim
  -> IOSSimProvisioner / IOSSimMacCore native application service
  -> IOSSim-owned Swift/C ABI
  -> Rust iossim-device-bridge
  -> idevice CoreDeviceProxy tunnel
  -> RSD handshake / RemoteXPC service map
  -> com.apple.coredevice.appservice
  -> com.apple.coredevice.feature.launchapplication
  -> installed main IOSSim bundle identifier
```

DVT ProcessControl is available but is not the minimum host-side setup launch
semantics. XCTest/TestManager remains frozen for the runner runtime and must not
be confused with this main-app setup launch.

## 10. DDI requirement

`DDI_REQUIRED = YES` for the reliable CoreDevice developer-service path.

DDI is not part of AFC install or Installation Proxy inventory, which are already
physical-pass. It is a prerequisite for CoreDevice/RSD developer services such as
AppService launch on modern iOS.

Current IOSSim has DDI status/mount calls, but the broader developer-support
readiness path is incomplete and its RSD proof is still stubbed.

## 11. RSD requirement

`RSD_REQUIRED = YES`.

The pinned AppService implementation is explicitly an RSD service:

```text
com.apple.coredevice.appservice
```

IOSSim must establish a CoreDeviceProxy software tunnel, perform an RSD handshake,
then connect AppService from the RSD service map.

## 12. RemoteXPC requirement

`REMOTE_XPC_REQUIRED = YES`.

AppService is a CoreDevice service. The pinned implementation wraps the stream in
`CoreDeviceServiceClient`, which performs a `RemoteXpcClient` handshake before
invoking the launch feature.

## 13. Developer Mode requirement

`DEVELOPER_MODE_REQUIRED = YES`.

This app launch path is a modern developer-service operation. If Developer Mode
is disabled or cannot be confirmed, IOSSim must surface a typed readiness failure
instead of mapping it to generic `serviceUnavailable`.

## 14. Pairing requirement

`PAIRING_REQUIRED = YES`.

The host must be trusted/paired for usbmux/Lockdown and developer-service access.
Remote pairing material is relevant to the iPhone-side runtime architecture, but
the host-side setup launch should bind to the selected physical UDID and current
connection generation rather than substituting RP identifiers.

## 15. Minimum IOSSim launch semantics

IOSSim needs only simple foreground launch of the main installed app:

- Input: main app bundle identifier.
- Args: none.
- Environment: none.
- Kill existing instance: yes, acceptable for deterministic setup.
- Start suspended: no.
- Debugger attachment: no.
- PID: useful diagnostic receipt if returned, not required by setup logic.

The setup launch exists to test developer-profile trust and allow the main app to
write/persist its deterministic runner mapping before House Arrest/container
readback verifies it.

## 16. Root cause

Root cause:

```text
IOSSim completed native install/inventory, then called a native launch abstraction
whose default production implementation is AwaitingPhysicalAppServiceLauncher, a
stub that always throws serviceUnavailable.
```

The native Apple capability is not absent from the pinned Rust dependency.
The missing IOSSim implementation is:

```text
CoreDeviceProxy/RSD readiness
  -> AppService connection
  -> launch_application bridge ABI
  -> Swift native launcher wiring
  -> typed launch/readiness errors
```

## 17. Minimum implementation plan

1. Preserve existing discovery and AFC/Installation Proxy install paths.
2. Add a small IOSSim-owned Rust bridge export for AppService launch using the
   pinned `idevice` revision.
3. In that export, bind to the selected UDID/usbmux identity, create the
   CoreDeviceProxy software tunnel, perform RSD handshake, connect
   `com.apple.coredevice.appservice`, and invoke
   `com.apple.coredevice.feature.launchapplication`.
4. Return a minimal launch receipt containing PID/process identifier version when
   available.
5. Add a Swift C-ABI wrapper and replace `AwaitingPhysicalAppServiceLauncher`
   with an AppService launcher backed by `DynamicNativeDeviceTransport`.
6. Keep DDI/RSD/developer-mode failures typed and observable.
7. Add a `launch-debug` probe if physical boundary diagnosis is needed.

Implemented in this pass:

- Added `iossim_bridge_launch_app` to IOSSim's Rust bridge.
- Enabled the pinned `idevice` `tunnel_tcp_stack` feature required by
  `CoreDeviceProxy::create_software_tunnel` without changing the pinned revision.
- Added the bridge header declaration.
- Added Swift dynamic loading for `iossim_bridge_launch_app`.
- Added `NativeAppServiceLauncher` and made `NativeApplicationService` default to
  it.
- Kept the new launch symbol optional for bridge loading so already-built older
  dylibs do not regress discovery/install; launch itself requires the symbol.
- Added `launchBackend=NATIVE_APPSERVICE_RSD` to packaged build provenance.

## 18. Risks/regression surface

- Shared Rust bridge changes could regress physical discovery/install if ABI
  loading or symbol checks are broken.
- CoreDeviceProxy/RSD may expose the next physical gate: missing DDI, Developer
  Mode disabled, RSD unavailable, or AppService denied.
- Launch may reveal developer-profile trust requirements.
- Do not update `idevice` unless the pinned API proves insufficient.
- Do not route consumer setup through `xcrun`, `devicectl`, `xcodebuild`, or
  private Apple framework linkage.

## 19. Physical test plan

1. Confirm Xcode remains absent.
2. Run `./iossim device-debug` and verify Apple usbmux, Rust bridge, C ABI,
   Swift discovery, Lockdown.
3. Run setup with the native build.
4. Verify main and runner remain recognized as installed.
5. Verify `LAUNCH_BACKEND=NATIVE_APPSERVICE_RSD`.
6. Confirm no `devicectl` route is selected.
7. Confirm main IOSSim app launches on the iPhone.
8. Confirm setup advances past launch.
9. If the next failure is DDI/RSD/House Arrest/container readback/profile trust,
   surface it as the next gate without collapsing it to `serviceUnavailable`.

## 20. Verification from implementation pass

Commands run:

```text
PATH=/Users/rishiborra/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH \
  cargo test --manifest-path native/iossim-device-bridge/Cargo.toml

swift build   # from macos/

python3 scripts/checks/check_no_xcode_install_routing.py

IOSSIM_MAC_BUILD_ROOT=.build/iossim/native-launch-retest \
IOSSIM_MAC_BUILD_VARIANT=LOCAL_NO_XCODE_NATIVE_LAUNCH_RETEST \
IOSSIM_DEVICE_ARTIFACTS_SOURCE=.build/iossim/device-discovery-retest/IOSSim.app/Contents/Resources/DeviceArtifacts \
  macos/scripts/build_app.sh
```

Results:

- Rust bridge tests passed: 6/6.
- Swift package build passed.
- Static no-Xcode routing audit passed.
- Authoritative app created:
  `.build/iossim/native-launch-retest/IOSSim.app`
- Optional DMG created and verified:
  `.build/iossim/local-release/IOSSim-0.1.0-no-xcode-native-launch-retest.dmg`
- Packaged bridge exports:
  `iossim_bridge_launch_app`, `iossim_bridge_app_inventory`,
  `iossim_bridge_install_app`, `iossim_bridge_uninstall_app`.
- Packaged provenance reports:
  `launchBackend=NATIVE_APPSERVICE_RSD`.
- Artifact hashes:
  - bridge:
    `b01903fa70f67ad72fb8294155e238da083caf91a105a7fb5efe05185f83b702`
  - DMG:
    `98b05e044bad41db996da70cad635760c599c4a02f1ab7dee0a97f0ed9ae5ee8`
- Full `swift test` could not run in this no-Xcode environment because the
  `XCTest` module is unavailable.
- `./iossim device-debug` found zero devices at Apple usbmux during this run, so
  physical launch could not be validated here.

## 21. Dependency change

Old revision:

```text
1838db107d38701b4044361163aac049006c2627
```

New revision:

```text
1838db107d38701b4044361163aac049006c2627
```

Revision changed: `NO`.

Feature change:

```text
added idevice feature: tunnel_tcp_stack
```

Reason: the pinned `CoreDeviceProxy::create_software_tunnel` method is feature
gated by `tunnel_tcp_stack`; AppService over RSD needs a software tunnel adapter.

Discovery/install risk: low-to-moderate because shared dependency features changed
and new transitive crates were added, but existing usbmux/Lockdown/AFC/Installation
Proxy code paths were not redesigned. Physical regression still required.
