# 02 pymobiledevice3 Wireless Audit

## Local and upstream versions

- Installed locally: `pymobiledevice3 9.12.0`.
- Latest available on PyPI during audit: `10.1.0`.
- IOSSim requirement: `pymobiledevice3>=4.14.0`, so the environment may install a newer version on fresh setup.

Local help output confirmed these command groups:

```text
python -m pymobiledevice3 remote browse
python -m pymobiledevice3 remote pair
python -m pymobiledevice3 remote start-tunnel --connection-type usb|wifi
python -m pymobiledevice3 remote tunneld
python -m pymobiledevice3 lockdown start-tunnel --mobdev2 --usbmux HOST:PORT --rsd HOST PORT --tunnel ...
python -m pymobiledevice3 usbmux list  # "USB and Wi-Fi"
```

Local `9.12.0` does not expose:

```text
python -m pymobiledevice3 lockdown remotepairing --pair
```

Upstream docs currently mention that command as a way to bootstrap a RemotePairing record over USB. Treat this as a version delta; experiments must log exact command availability.

## Relevant installed source paths/functions

Local package root:

```text
C:\Users\reshw\AppData\Local\Programs\Python\Python311\Lib\site-packages\pymobiledevice3
```

Important files:

| File | Relevant code |
|---|---|
| `cli/remote.py` | `browse_rsd`, `browse_remotepairing`, `cli_browse`, `cli_tunneld`, `start_tunnel_task`, `cli_start_tunnel`, `start_remote_pair_task`, `cli_pair` |
| `remote/tunnel_service.py` | remote pairing and CoreDevice tunnel service discovery/creation helpers |
| `remote/remote_service_discovery.py` | `RSD_PORT = 58783`, `RemoteServiceDiscoveryService`, `start_lockdown_service`, `start_lockdown_developer_service`, `start_service` |
| `remote/remotexpc.py` | `RemoteXPCConnection` framing/handshake |
| `service_connection.py` | `create_using_usbmux(udid, port, connection_type=None, usbmux_address=None)` |
| `usbmux.py` | usbmux device selection and connect logic; supports connection type filtering and usbmux address override |
| `services/dvt/instruments/location_simulation.py` | DVT `simulateLocationWithLatitude:longitude:` and `stopLocationSimulation` |
| `services/dvt/instruments/location_simulation_base.py` | GPX host-side playback loop |

`cli/remote.py` maps `ConnectionType.USB` to CoreDevice tunnel services and `ConnectionType.WIFI` to remote-pairing tunnel services. That is the key installed-code evidence that a Wi-Fi tunnel path exists in pymobiledevice3.

## Answers

| Question | Answer | Classification |
|---|---|---|
| Can pymobiledevice3 discover a device over Wi-Fi? | It has `remote browse` for Bonjour RemoteXPC devices and `usbmux list` says it lists USB and Wi-Fi. Real discovery depends on pairing, Bonjour, platform networking, and version. | POSSIBLE BUT UNPROVEN LOCALLY |
| Does it support Apple CoreDevice wireless connections? | It implements RemoteXPC/RSD/tunnel services and has `remote start-tunnel -t wifi`. This is reverse-engineered, not Apple-supported API. | LIKELY |
| Does it support remote pairing? | Installed `remote pair` exists. Upstream also documents RemotePairing records. | CONFIRMED TOOLING EXISTS |
| Does it support RSD without USB? | Upstream docs and installed CLI support `remote start-tunnel --connection-type wifi`, which should produce RSD host/port after RemotePairing. | LIKELY |
| Does `start-tunnel` require USB? | Current IOSSim’s `lockdown start-tunnel` path uses the trusted lockdown/usbmux path and effectively assumes USB. `remote start-tunnel -t wifi` is the non-USB candidate. | CURRENT APP: YES; PMD3: NO/UNPROVEN |
| Can an existing pair record be reused wirelessly? | RemoteXPC notes describe saved pair records requesting a trusted tunnel. Version-specific behavior must be tested. | LIKELY |
| Can current IOSSim DVT command work with a remotely discovered RSD endpoint? | Yes in principle: `LocationService` already passes arbitrary `--rsd HOST PORT`; it does not care whether the tunnel came from USB or Wi-Fi. | LIKELY |
| Can tunnel endpoint be specified manually? | DVT commands accept `--rsd HOST PORT`; `lockdown start-tunnel` accepts `--rsd` for device options. IOSSim stores endpoint in memory only. | CONFIRMED |
| Can a tunnel be established over a network-paired iPhone? | `remote start-tunnel -t wifi` says yes at tooling level; requires experiment on target iOS 26.x device. | POSSIBLE BUT UNPROVEN |
| Can RSD address/port survive cable removal? | Unknown. RSD endpoint is tunnel-process/interface state; if the underlying tunnel remains up after unplug, it may survive. If tunnel was USB-backed, expect collapse. | UNCONFIRMED |
| Does the tunnel collapse when USB disconnects? | Current USB lockdown/CoreDeviceProxy tunnel likely collapses when USB transport disappears. Needs W02 test. | LIKELY |
| Is there a supported way to reconnect automatically? | pymobiledevice3 top-level has `--reconnect`, and `remote tunneld` monitors USB/Wi-Fi/mobdev2, but IOSSim does not use this. Wireless auto-reconnect is experimental. | POSSIBLE |

## Directly applicable IOSSim change, if experiments pass

The smallest future code path is not a rewrite. It is:

```text
DeviceManager.start_tunnel(mode="usb"|"wifi")
  usb  -> existing lockdown start-tunnel
  wifi -> pymobiledevice3 remote start-tunnel --connection-type wifi --script-mode

LocationService
  unchanged: use stored --rsd HOST PORT
```

Do not build this until experiments prove Wi-Fi RSD plus DVT location works on the target phone.

Sources: pymobiledevice3 [README](https://github.com/doronz88/pymobiledevice3), [iOS 17+ tunnels guide](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md), [RemoteXPC.md](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md), [iDevice protocol layers](https://github.com/doronz88/pymobiledevice3/blob/master/misc/understanding_idevice_protocol_layers.md).

