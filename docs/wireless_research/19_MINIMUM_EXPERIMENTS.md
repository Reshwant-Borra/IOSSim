# 19 Minimum Experiments

Do not implement a large wireless architecture before these pass.

## EXP-W01: Existing tunnel survives unplug

Setup:

- USB connected.
- Developer Mode on.
- Current IOSSim Initialize succeeds.

Command/action:

```text
Set a location.
Unplug cable.
Attempt another DVT set using the stored RSD endpoint.
```

Expected result: unknown.  
Pass criteria: second set succeeds and phone updates.  
Failure interpretation: current USB-backed tunnel is cable-bound.  
Logs: tunnel process exit code, stderr, RSD endpoint, command duration.

## EXP-W02: Wireless discovery after pairing

Setup:

- Pair with Xcode over USB.
- Enable Connect via network.
- Disconnect USB.

Commands:

```text
python -m pymobiledevice3 remote browse
python -m pymobiledevice3 usbmux list
```

Expected result: at least one path discovers the device.  
Pass criteria: device appears with Wi-Fi/remote identifier.  
Failure interpretation: Bonjour/network pairing not visible to installed pymobiledevice3 or platform blocks discovery.

## EXP-W03: Fresh Wi-Fi RSD tunnel

Setup: same as EXP-W02.

Command:

```text
python -m pymobiledevice3 remote start-tunnel --connection-type wifi --script-mode
```

Expected result: RSD host/port printed.  
Pass criteria: tunnel remains open for at least 5 minutes.  
Failure interpretation: missing RemotePairing record, platform Bonjour failure, or version gap.

## EXP-W04: DVT set/clear over Wi-Fi tunnel

Setup: EXP-W03 produced `HOST PORT`.

Commands:

```text
python -m pymobiledevice3 developer dvt simulate-location set --rsd HOST PORT -- 37.7749 -122.4194
python -m pymobiledevice3 developer dvt simulate-location clear --rsd HOST PORT
```

Expected result: location changes and clears.  
Pass criteria: both commands succeed and observed phone location matches.  
Failure interpretation: tunnel exists but DVT service unavailable over Wi-Fi or DDI/Developer Mode state invalid.

## EXP-W05: iPhone Safari controls Mac backend

Setup:

- Current USB or Wi-Fi device path working.
- Mac and iPhone on trusted LAN/Tailscale.

Action:

```text
Serve UI on LAN/VPN.
Open UI from iPhone Safari.
Run status, set, clear.
```

Expected result: UI works as controller.  
Pass criteria: iPhone Safari can set/reset the same phone indirectly.  
Failure interpretation: frontend binding/CORS/proxy/mobile layout issues.

## EXP-W06: Routed/VPN wireless developer channel

Setup:

- Wireless pairing works on same LAN.
- Add Tailscale/WireGuard/private VPN.

Action:

```text
Try Bonjour browse.
Try manual IP if available.
Try Wi-Fi tunnel and DVT.
```

Expected result: unproven.  
Pass criteria: fresh RSD tunnel and DVT set over VPN without same LAN.  
Failure interpretation: Apple developer service does not bind/routably expose over VPN, or discovery/IPv6 is blocked.

## Experiment order

```text
EXP-W01 -> EXP-W02 -> EXP-W03 -> EXP-W04 -> EXP-W05 -> EXP-W06
```

Stop implementation if EXP-W03 or EXP-W04 fails on target iOS 26.x with current and latest pymobiledevice3.

