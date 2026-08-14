# 04 Remote Mac Architecture

## Architecture under review

```text
iPhone
  <-> wireless developer connection
Mac at home / remote site
  <-> HTTPS or VPN
IOSSim control UI from another device
```

## Network paths

### Apple-supported local network path

```text
iPhone Wi-Fi
  <-> same LAN / Bonjour / port 62078
Mac running Xcode or IOSSim backend
  <-> browser on same LAN
```

Confirmed pieces:

- Initial iOS pairing with Xcode requires USB.
- After pairing, Xcode can use Bonjour on the same network.
- Apple documents manual IP-address connection for network devices.
- Apple warns sleeping devices can appear disconnected.

### Routed/VPN path

```text
iPhone
  <-> routed IP / VPN overlay?
Remote Mac
```

This is not confirmed for IOSSim. Apple’s docs allow “other network connection” and IP-address connection, but Apple troubleshooting focuses on same-network and port 62078. Apple forum/TN3158 discussion shows VPN/security products can break Xcode 15+ device communication because modern device communication uses changing direct-link IPv6 interfaces.

### Local relay path

```text
iPhone
  <-> Wi-Fi or USB
local relay / travel router / mini host near phone
  <-> Tailscale/WireGuard/HTTPS
remote Mac or cloud UI
```

This is more reliable when the iPhone cannot directly reach the Mac. The relay can either:

- expose a private command API and run pymobiledevice3 locally, or
- forward usbmux/RSD traffic to a remote host.

The first option is safer.

## Questions

| Question | Answer |
|---|---|
| Must Mac and iPhone be on same LAN? | For Bonjour discovery, yes. For manual IP connection, not necessarily if routing and ports work. |
| Could Tailscale/ZeroTier/WireGuard work? | Possible but unproven. It depends on whether Apple developer services bind to the VPN interface and whether IPv6/direct-link requirements survive. |
| Could corporate VPN work? | Sometimes no. Apple’s forum/TN3158 discussion and Cisco AnyConnect reports show VPNs can break Xcode 15+ device communication. |
| Does Bonjour/mDNS discovery matter after pairing? | It matters for automatic discovery. Manual IP may replace discovery, but not necessarily all transport requirements. |
| Can static IP/RSD coordinates replace discovery? | For a live RSD tunnel, DVT accepts `--rsd HOST PORT`. But RSD coordinates are tunnel state, not a stable permanent device address. |
| Could port forwarding preserve the developer channel? | Possibly for older lockdown/usbmux and for remote usbmuxd forwarding. RSD tunnel forwarding is more complex and should be tested, not assumed. |
| Would Apple pairing security reject NAT/routed connections? | No direct evidence found. The likely blocker is reachability/discovery/interface binding, not pair-record cryptography. |
| Could a small local relay tunnel traffic back to the Mac? | Yes. It can forward usbmux or, better, run the DVT bridge locally and expose only authenticated commands. |
| Could a travel router create a persistent same-LAN relationship? | Yes for local Wi-Fi continuity. It does not eliminate the need for a host/agent to run developer services. |

## Verdict

Remote Mac without any local relay near the iPhone is possible but unproven and likely fragile. Remote control of a Mac that remains on the same LAN as the iPhone is practical. A cloud UI plus a small local bridge is more defensible than trying to stretch Apple’s developer channel across arbitrary networks.

