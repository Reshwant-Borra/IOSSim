# 14 USB-over-IP

## Architecture

```text
iPhone
  -> USB cable
local USB bridge near phone
  -> LAN/VPN
remote Mac/PC running IOSSim
```

This removes the computer from the phone’s immediate area only if a small USB bridge remains near the phone. It does not remove the cable from the phone.

## Raw USB-over-IP

Tools like VirtualHere can forward USB devices over a network. For iPhones, raw USB forwarding can conflict with `usbmuxd` because Apple’s daemon grabs iOS device interfaces early and exclusively. VirtualHere forum posts specifically discuss iOS/macOS usbmuxd conflicts.

Pros:

- Remote host may see device “as if local.”
- Can work for some USB device classes.

Cons:

- iPhone composite USB interfaces and Apple daemons are fragile.
- Latency/disconnects can break pairing and tunnel sessions.
- Security risk: exposes full USB device, not just IOSSim commands.
- Modern iOS 17+ RSD may still need additional network/tunnel handling.

## usbmux forwarding / USBFlux-style

An alternative is not raw USB passthrough but forwarding the usbmux socket/protocol. Corellium’s usbfluxd pattern exposes usbmux over TCP, and pymobiledevice3 supports `--usbmux HOST:PORT`.

```text
iPhone -> local usbmuxd -> TCP/VPN -> remote pymobiledevice3 --usbmux HOST:PORT
```

This is more protocol-aware than raw USB-over-IP. It may be sufficient for many libimobiledevice/pymobiledevice3 operations. For iOS 17+/26 DVT, the open question is whether remote tunnel creation and resulting RSD routing work reliably.

Sources: Corellium [USBFlux](https://support.corellium.com/features/connect/usbflux), [usbfluxd](https://github.com/corellium/usbfluxd), VirtualHere [iOS devices](https://www.virtualhere.com/node/3500), pymobiledevice3 CLI `--usbmux`.

## Evaluation

| Dimension | Raw USB-over-IP | usbmux forwarding |
|---|---|---|
| Latency tolerance | Low | Medium |
| Apple Mobile Device compatibility | Fragile | Better |
| Pairing | Possible | Possible |
| iOS 17+ RSD | Unproven | Unproven but more plausible |
| Security | Broad/high risk | Broad/high risk but narrower than raw USB |
| Reliability | Medium-low | Medium |
| Best use | Lab/debug fallback | Local relay experiment |

## Verdict

USB-over-IP is not a cable-free architecture. It is a “remote computer with cable to tiny local bridge” architecture. For IOSSim, a local agent that directly runs DVT and exposes a narrow API is safer and likely more reliable than forwarding usbmux/USB to a remote backend.

