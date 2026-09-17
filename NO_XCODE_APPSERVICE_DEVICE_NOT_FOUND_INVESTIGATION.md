# No-Xcode AppService `deviceNotFound` Investigation

Date: 2026-09-15  
Branch: `work/final-no-xcode-setup-v1`  
Baseline HEAD: `1259da507ecded222022cc86bf82863c15640db9`

## Finding

The reported `NATIVE_LAUNCH_UNAVAILABLE: deviceNotFound` did not prove that the iPhone was absent. The old Rust bridge classifier converted any idevice diagnostic containing `not found` to `DeviceNotFound`. The pinned idevice revision exposes distinct `DeviceNotFound`, `NotFound`, and `ServiceNotFound` variants, so a service-map or application lookup failure was erased at the FFI boundary.

The exact historical first failing service cannot be reconstructed from the old app because the diagnostic contained no stage marker. Current evidence excludes installation, manual app launch, developer-profile trust, the persisted checkpoint, and Xcode absence as explanations for physical device absence. It does not yet prove whether DDI was required.

## Exact launch graph

```text
ConsumerArtifactProvisioner.advanceRuntimeConfiguration
  -> launchMainForRuntimeConfiguration
  -> IdeviceProvisioningBackend.launch
  -> NativeApplicationService.launch
  -> NativeAppServiceLauncher.launch
  -> DynamicNativeDeviceTransport.launchApplication
  -> iossim_bridge_open_device
  -> iossim_bridge_launch_app
  -> selected_device(stable Lockdown UDID + pinned usbmux connection id)
  -> IdeviceProvider
  -> CoreDeviceProxy::connect
  -> create_software_tunnel
  -> connect(server_rsd_port)
  -> RsdHandshake::new
  -> resolve com.apple.coredevice.appservice and launchapplication feature
  -> AppServiceClient::connect_rsd (RemoteXPC)
  -> launch_application(exact derived main bundle ID)
```

## Implemented correction

The bridge now uses idevice variants plus stage context and preserves these failures across C and Swift:

- `DEVICE_RESOLUTION_FAILED`
- `COREDEVICE_PROXY_FAILED`
- `SOFTWARE_TUNNEL_FAILED`
- `RSD_UNAVAILABLE`
- `REMOTEXPC_FAILED`
- `APPSERVICE_UNAVAILABLE`
- `FEATURE_UNAVAILABLE`
- `APPLICATION_NOT_FOUND`
- `DDI_REQUIRED`
- `DEVELOPER_SERVICES_NOT_READY`
- `LAUNCH_REJECTED`
- `PROTOCOL_ERROR`

`ServiceNotFound` is no longer classified as a missing physical device. DDI is reported only for an explicit `ImageNotMounted` result; an arbitrary CoreDeviceProxy failure is not promoted to `DDI_REQUIRED` merely because a mounted-image probe returned false.

The same bridge exposes a developer-services receipt for CoreDeviceProxy, software tunnel, RSD, RemoteXPC, AppService, launch-feature availability, and observed personalized-image mount state. Production setup probes this before launch. Exact current main-bundle identity continues to come from the Personal Team manifest and native inventory; it is not hard-coded.

## Physical status

No iPhone was connected during this implementation pass. `./iossim device-debug` found zero devices at every native layer. The corrected first failing layer and whether iOS 26.6.2 requires a DDI must therefore be established by the next physical run. Native AppService launch remains unvalidated, and manual phone launch must not be counted as a pass.
