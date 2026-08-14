# 07 iPhone-Only Options

## Stock iOS boundary

On stock iOS, App Store apps, sideloaded apps, Shortcuts, and scripting apps run inside Apple’s sandbox. They do not get the host-side trust material, lockdown/usbmux socket, RemoteXPC/RSD developer services, or privileges needed to override system-wide CoreLocation for other apps.

Core Location APIs let an app read the device location and create `CLLocation` objects inside its own process. They do not let that app replace the system location provider for every other app.

## Candidate audit

| Candidate | Python/native code | Subprocesses | Apple developer services | Talk to itself via lockdown/RSD | Override system CoreLocation | Affect other apps | Persistent background | USB/device-management protocols | Jailbreak required | App Store compatible | IOSSim relevance |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Pythonista | Python sandbox | No useful host subprocess | No | No | No | No | Limited | No | No | App Store app | Not useful |
| Pyto | Python sandbox | Very limited | No | No | No | No | Limited | No | No | App Store app | Not useful |
| a-Shell | Unix-like sandbox | Limited sandbox commands | No | No | No | No | Limited | No | No | App Store app | Not useful |
| iSH | User-mode Linux sandbox | Inside sandbox only | No | No | No | No | Limited | No | No | App Store app | Not useful |
| Shortcuts | Automation actions | No | No | No | No | No | Limited | No | No | Yes | Not useful |
| Scriptable | JS sandbox | No host process | No | No | No | No | Limited | No | No | Yes | Not useful |
| Swift Playgrounds | App sandbox | No arbitrary host subprocess | No | No | No | No | Limited | No | No | Yes | Not useful |
| Local web server app | App sandbox | No | No | No | No | No | Background-limited | No | No | Maybe | UI only |
| Sideloaded app / AltStore / SideStore | Native app sandbox | No arbitrary privileged subprocess | No | No | No | No | Background-limited | No | No | Not App Store | UI/helper only |
| Custom signed app | Native app sandbox | No | No private dev services | No | No | No | Background-limited | No | No | Yes if compliant | Cannot replace IOSSim host |
| Network Extension / Local VPN | Native networking entitlement | No | No | No | No | No | More persistent but restricted | No | No | Entitlement-controlled | Can route traffic, not location |
| CoreBluetooth app | Native BLE | No | No | No | No system override | Only app using it | Limited/background modes | No | No | Yes if compliant | Can consume BLE GPS in own app only |
| ExternalAccessory app | Native accessory comms | No | No | No | No system override by app | Only app protocol session | Limited | Accessory only | No | Yes with MFi protocol | Companion UI only |
| TrollStore | Native with elevated signing on vulnerable versions | Maybe | Maybe private APIs, not host RSD | No general stock path | Possibly with private entitlements/tweaks | Maybe | Better | Version-dependent | Exploit-dependent | No | Not viable for iOS 26.x normal devices |

## Why sandboxing blocks hostless IOSSim

IOSSim’s working method is a host-to-device developer service:

```text
host pair record -> lockdown/CoreDevice/RemoteXPC -> RSD tunnel -> DVT LocationSimulation -> locationd/CoreLocation
```

An ordinary iPhone app is on the wrong side of that boundary. It cannot become its own trusted host, cannot access the private pairing database, cannot bind to Apple’s internal developer service endpoints, and cannot instruct `locationd` to set a system-wide simulated location.

## Verdict

No stock iPhone-only path can replace IOSSim’s host. iPhone-only apps can provide a controller UI, companion workflow, or app-local fake location for apps you control, but not system-wide location simulation for arbitrary apps.

