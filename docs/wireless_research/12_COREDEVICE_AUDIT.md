# 12 CoreDevice Audit

## What changed in modern iOS

pymobiledevice3’s protocol notes state that iOS 17 made developer services reachable only through the RemoteXPC/RSD trusted tunnel model. For iOS 17.4+, pymobiledevice3 documents a faster lockdown tunnel path through a newer CoreDeviceProxy-style service, avoiding some special USB-network driver requirements from early iOS 17.

This means modern device communication has moved beyond the old assumption that `usbmuxd` alone is sufficient for every developer service.

Sources: pymobiledevice3 [iOS 17+ tunnels guide](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md), [RemoteXPC.md](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md), [iDevice protocol layers](https://github.com/doronz88/pymobiledevice3/blob/master/misc/understanding_idevice_protocol_layers.md).

## Does pymobiledevice3 implement CoreDevice concepts?

Yes, through reverse-engineered tooling:

- `remote/remotexpc.py`: RemoteXPC framing and connection.
- `remote/remote_service_discovery.py`: RSD peer connection and service lookup.
- `remote/tunnel_service.py`: tunnel service discovery/creation.
- `remote/core_device/*`: CoreDevice service wrappers.
- `cli/developer/core_device.py`: CLI access to CoreDevice services.
- `cli/remote.py`: `remote start-tunnel`, `remote browse`, `remote pair`, `remote tunneld`.

This is not a public Apple SDK integration. It is community tooling that mirrors the private protocol stack.

## Does CoreDevice wireless expose the same developer services?

Likely. Xcode can run/debug apps wirelessly, and pymobiledevice3’s trusted tunnel/RSD model is designed to access developer services including DVT. The specific IOSSim location path must still be validated on the target device because Xcode-supported app run/debug does not guarantee every non-Xcode client path works.

## Is there a remote-pairing database?

Yes. pymobiledevice3 references RemotePairing pair records and helpers such as `get_remote_pairing_record_filename`. RemoteXPC notes describe saving pair records and later requesting trusted tunnels from them.

## Can IOSSim directly leverage these APIs?

Yes with a small transport abstraction after experiments:

```text
DeviceManager
  start_usb_tunnel()      -> existing lockdown start-tunnel
  start_wifi_tunnel()     -> remote start-tunnel -t wifi
  start_tunneld_client()  -> optional remote tunneld integration

LocationService
  unchanged if TunnelInfo(address, port) is valid
```

Do not use private Apple frameworks directly. Use pymobiledevice3 CLI/API as the compatibility boundary.

## Open CoreDevice questions

- Whether installed `9.12.0` is sufficient or upgrade to `10.1.0` is required.
- Whether target iOS 26.x exposes RemotePairing in the same way upstream docs describe.
- Whether Windows Bonjour/mobdev2 discovery is reliable enough or manual IP support is needed.
- Whether a userspace tunnel can be used by IOSSim’s subprocess model. Upstream docs say userspace tunnel addresses are in-process only, so IOSSim’s current separate subprocess calls likely need a persistent system tunnel, not per-command userspace tunnels.

