# 11 Protocol Stack

## Layered view

```text
Discovery
  Bonjour / mDNS / DNS-SD
  usbmux attached-device notifications
  manual IP entry
  pymobiledevice3 remote browse

Pairing
  USB Trust / lockdownd pairing
  Xcode wireless pairing record
  RemotePairing pair record

Transport
  USB usbmux
  Wi-Fi lockdown on port 62078
  RemoteXPC over network
  CoreDeviceProxy over lockdown for newer iOS
  trusted tunnel over QUIC or TCP

RSD
  Remote Service Discovery peer
  RSD host/port, usually IPv6 inside tunnel
  service metadata and service ports

DVT
  com.apple.instruments / DTX services
  LocationSimulation channel

Location Simulation
  simulateLocationWithLatitude:longitude:
  stopLocationSimulation
```

## Responsibility table

| Layer | Discovers phone | Creates secure session | Carries developer services | Carries DVT | USB dependency | Local-link dependency | Routable? |
|---|---:|---:|---:|---:|---:|---:|---:|
| Bonjour/mDNS | Yes | No | No | No | No | Usually yes | Only with mDNS relay |
| Manual IP / port 62078 | No | No by itself | Lockdown/network-device channel | Older paths maybe | No after pairing | No if routed | Possible |
| usbmux | Yes for attached/network devices | No by itself | Lockdown service access | Older iOS developer service path | Usually yes; Wi-Fi Sync possible | No for USB | Forwardable |
| lockdownd pairing | No | Yes | Starts services / validates trust | Indirect | Initial USB for iOS wireless pairing | No | Pair record portable but sensitive |
| RemotePairing | Discovery-assisted | Yes | Enables trusted tunnel | Indirect | May require USB bootstrap/version-specific | Usually Bonjour initially | Unproven across VPN |
| RemoteXPC | No | Uses pairing/tunnel | Yes for modern services | Indirect | No for Wi-Fi path | Not inherently | Theoretically IP-based |
| RSD | Service discovery within remote/tunnel context | Uses tunnel trust | Yes | Yes | No if tunnel is Wi-Fi | No, if tunnel established | Endpoint is tunnel-scoped |
| DVT/DTX | No | Uses provider | Yes | Yes | No if provider is wireless RSD | No | Only through established provider |

## IOSSim today

```text
USB/usbmux detect
  -> USB lockdownd pairing/trust
  -> DDI mount
  -> lockdown start-tunnel
  -> RSD host/port
  -> developer dvt simulate-location --rsd
```

## Wireless candidate

```text
Xcode/pymobiledevice3 wireless pairing
  -> Bonjour or IP discovery
  -> RemotePairing trusted tunnel
  -> RSD host/port
  -> same IOSSim LocationService DVT commands
```

## Key inference

The location simulation layer is already transport-agnostic once a valid `--rsd HOST PORT` exists. The hard research question is therefore not “can DVT set location wirelessly?” but “can IOSSim or pymobiledevice3 reliably obtain and maintain a valid RSD endpoint without USB on the target iOS 26.x phone?”

