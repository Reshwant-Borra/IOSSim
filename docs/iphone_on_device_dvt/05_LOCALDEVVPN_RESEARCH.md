# LocalDevVPN Research

## What It Does

STATUS: CONFIRMED SOURCE-CODE EVIDENCE

LocalDevVPN is an iOS NetworkExtension Packet Tunnel app. Its provider:

- Creates `NEPacketTunnelNetworkSettings`.
- Configures IPv4 address `10.7.0.0` with subnet mask `255.255.255.0`.
- Includes a route for `10.7.0.0/24` and excludes the default route.
- Reads packets from `packetFlow`.
- Rewrites source `10.7.0.0` to `10.7.0.1`.
- Rewrites destination `10.7.0.1` to `10.7.0.0`.
- Writes the modified packets back to `packetFlow`.

Observed defaults:

```text
tunnelDeviceIp = 10.7.0.0
tunnelFakeIp   = 10.7.0.1
subnetMask     = 255.255.255.0
```

## Packet Flow

STATUS: CONFIRMED MECHANISM / PLAUSIBLE ENDPOINT EFFECT

Corrected architecture:

```text
IOSSim or Locus iOS app
  -> TCP socket to 10.7.0.1:49152
  -> iOS route for 10.7.0.0/24
  -> LocalDevVPN NEPacketTunnelProvider packetFlow
  -> address rewrite 10.7.0.1 <-> 10.7.0.0
  -> packetFlow reinjection
  -> local Apple RemotePairing listener
  -> RPPairing / tunnel / RSD / DVT
```

This is a local virtual interface, not a remote VPN server and not an Internet tunnel.

## Why Localhost Is Insufficient

STATUS: PLAUSIBLE / NEEDS IOS EXPERIMENT

Evidence: Locus connects to `10.7.0.1:49152`, not `127.0.0.1`. LocalDevVPN gives the app a routeable local interface that can reach an endpoint otherwise unreachable through ordinary app loopback. The likely boundary is iOS network path/interface policy and the fact that Apple's developer listener is bound to a non-loopback path. This must be verified with POC probes:

- connect to `127.0.0.1:49152`;
- connect to `10.7.0.1:49152` with LocalDevVPN;
- connect to `10.7.0.1:49152` without LocalDevVPN;
- enumerate interface addresses before/after VPN.

## Entitlements

STATUS: CONFIRMED

LocalDevVPN uses:

- Main app: `com.apple.developer.networking.vpn.api` with `allow-vpn`.
- Main app and extension: `com.apple.developer.networking.networkextension` with `packet-tunnel-provider`.

Apple's NetworkExtension documentation confirms a NetworkExtension entitlement is required for Packet Tunnel providers.

## Lifecycle

STATUS: PLAUSIBLE

The LocalDevVPN app stores a `NETunnelProviderManager` configuration, starts the tunnel with options for device/fake/subnet IPs, and disconnects other active VPNs before starting. iOS allows only one active VPN-style route owner for conflicting routes. The POC must test LocalDevVPN restart and whether a developer session recovers after the virtual interface disappears.

## Cellular Relevance

STATUS: UNKNOWN

LocalDevVPN itself excludes the default route and should not require external network connectivity. The cellular cold-start uncertainty is probably not "the VPN needs the Internet." It is more likely one of:

- Apple RemotePairing listener binding changes when only cellular is active.
- iOS routing/NECP policy selects cellular/default IPv4 before the packet tunnel route is installed.
- `_remotepairing._tcp` listener or Developer Mode service lifecycle depends on Wi-Fi-like interface state.
- LocalDevVPN and cellular both being active creates route refusal until cellular is toggled, as Mirage claims.

Experiments in [14_EXPERIMENT_PLAN.md](14_EXPERIMENT_PLAN.md) isolate this.
