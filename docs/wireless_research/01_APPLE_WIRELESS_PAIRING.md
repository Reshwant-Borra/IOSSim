# 01 Apple Wireless Pairing

## Apple-supported workflow

Apple supports running on physical iOS devices over a network after pairing with Xcode. Current Xcode Help says an iOS wireless device must first be paired with Xcode using a cable, Trust must be accepted, “Connect via network” must be selected, and then the cable can be disconnected. Apple also documents two discovery/connection modes:

- Bonjour when Mac and device are on the same network.
- Manual IP-address connection for a network device.

Sources: Apple Help [Pair a wireless device with Xcode](https://help.apple.com/xcode/mac/current/en.lproj/devbc48d1bad.html), [Run an app on a wireless device](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html), [Troubleshoot a wireless device](https://help.apple.com/xcode/mac/current/en.lproj/devac3261a70.html), [network device](https://help.apple.com/xcode/mac/current/en.lproj/dev2a1a3824e.html).

## Question-by-question classification

| Question | Answer | Classification |
|---|---|---|
| Can a physical iPhone be paired to Xcode over Wi-Fi after initial USB pairing? | Yes. Apple documents cable pairing, Trust, “Connect via network,” then disconnect. | CONFIRMED |
| Does it work on current iOS versions? | Apple current Help still documents it and requires iOS 11+. iOS 26-specific Apple text was not found, but current Xcode Help applies to current Xcode. | LIKELY |
| Does Apple still require Mac and iPhone on same network? | Same network is required for Bonjour discovery. Apple also documents connecting by IP address, so same LAN is not an absolute transport rule if routing works. | CONFIRMED / LIKELY |
| Does Developer Mode need to remain enabled? | For app/debug/developer services, yes. Apple Device Hub docs and Xcode workflows require Developer Mode for modern devices. DVT location simulation also requires Developer Mode. | CONFIRMED |
| Does the Mac remain trusted after USB is removed? | Yes. Apple’s pairing workflow expects use after cable removal. | CONFIRMED |
| Does wireless pairing survive reboot? | Pair records are persistent unless unpaired or network settings are reset. Runtime reachability after reboot still depends on network/wake state. | LIKELY |
| Does it survive network changes? | The pairing should survive; discovery may not. Manual IP may be needed on the new network. | LIKELY |
| Does it work across different subnets? | Bonjour usually does not without mDNS relay. Manual IP-address connection may work if port 62078 and related traffic are routable. | UNCONFIRMED |
| Does it work over personal hotspot? | Same-network/IP routing can theoretically work, but Apple does not document hotspot as a supported case. | UNCONFIRMED |
| Does it work over VPN? | Apple forum/TN3158 discussion shows VPNs often break Xcode 15+ device communication, especially IPv6/direct-link behavior. Some VPNs may work if they preserve needed routes. | UNCONFIRMED |
| Does it work over Tailscale/ZeroTier/WireGuard? | No Apple-supported confirmation found. It is plausible only if the iPhone service binds to the VPN interface and required discovery or IP routing works. | UNCONFIRMED |
| Does Xcode expose the device through normal developer-service channels once paired wirelessly? | Xcode can run/debug apps wirelessly, so developer channels are available to Xcode. Whether every private DVT service is equally exposed to non-Xcode tooling requires testing. | LIKELY |
| Does DVT location simulation function over that channel? | Xcode’s own location simulation uses developer services. pymobiledevice3 exposes a Wi-Fi tunnel path. Direct IOSSim confirmation is still required. | LIKELY |
| Does Remote Service Discovery behave differently over wireless pairing? | pymobiledevice3 documents remote pairing/trusted tunnel/RSD over Wi-Fi as a distinct path from USB lockdown/CoreDeviceProxy. | LIKELY |
| Can the connection remain active while the phone is locked? | Apple warns that previously paired disconnected devices may be asleep and recommends Auto-Lock Never during testing. Locked-but-awake is likely; asleep is unreliable. | LIKELY |
| Can the phone leave the immediate area of the Mac? | Yes if it remains reachable on a supported/routable network. No if it leaves Wi-Fi and becomes cellular-only behind carrier NAT. | POSSIBLE BUT UNPROVEN |
| Does the device become unavailable when Wi-Fi sleeps? | Apple explicitly warns a paired network device may be asleep and suggests disabling Auto-Lock for testing. | CONFIRMED |
| Does cellular-only operation break the connection? | Bonjour and LAN IP paths break. A VPN path is unconfirmed and should be treated as experimental. | LIKELY |

## Practical implication for IOSSim

Apple-supported wireless pairing proves “no cable after initial pairing” is a real concept for Xcode. It does not by itself prove current IOSSim can reconnect wirelessly, because IOSSim currently uses usbmux detection plus `lockdown start-tunnel`, not Xcode’s Device Hub state or pymobiledevice3’s `remote start-tunnel -t wifi`.

The lowest-risk experiment is to use Xcode/pymobiledevice3 to establish or verify wireless pairing, then run:

```text
python -m pymobiledevice3 remote browse
python -m pymobiledevice3 remote start-tunnel --connection-type wifi --script-mode
python -m pymobiledevice3 developer dvt simulate-location set --rsd HOST PORT -- LAT LON
```

