# 15 Local Relay Options

## Candidate architectures

### A. Local DVT bridge

```text
iPhone
  -> USB or Wi-Fi
Raspberry Pi / mini PC / old Mac mini
  -> authenticated HTTPS/WebSocket/VPN
cloud UI or remote IOSSim frontend
```

The relay runs pymobiledevice3 and owns pairing/tunnel/DVT. This is the preferred relay model.

### B. usbmux bridge

```text
iPhone
  -> USB
local Linux relay
  -> usbmux TCP forwarding over VPN
remote IOSSim backend
```

This keeps IOSSim backend remote but exposes broad device-management transport.

### C. network-discovery relay

```text
iPhone
  <-> Wi-Fi
travel router/local relay
  <-> VPN
remote Mac
```

This tries to preserve discovery/routing. It is the least proven for DVT.

## Minimum local capabilities

| Capability | Needed for local DVT bridge | Notes |
|---|---:|---|
| USB host or reliable Wi-Fi developer connection | Yes | USB most reliable |
| Python 3.11+ / pymobiledevice3 | Yes | Pin and log version |
| Pair record storage | Yes | Protect filesystem |
| Privileged tunnel capability | Maybe/yes | Depends userspace/system tunnel |
| Stable network uplink | Yes | Tailscale recommended |
| Authenticated command API | Yes | Narrow commands only |
| Secret redaction | Yes | Never export raw pair records |

## Device options

| Device | Best role | Feasibility |
|---|---|---|
| Old Mac mini | Full local DVT bridge | High |
| Cheap Windows mini PC | Full local DVT bridge | Medium-high for USB, Wi-Fi unproven |
| Linux x86 mini PC | Full local DVT bridge | Medium-high |
| Raspberry Pi 4/5 | Local DVT bridge or usbmux relay | Possible but needs performance/dependency validation |
| Travel router with USB | Usually too limited for DVT; maybe network helper only | Low |
| Orange Pi / SBC | Similar to Raspberry Pi | Possible |

## Verdict

The smallest practical local component is a local DVT bridge, not a transparent network tunnel. Start with a headless Mac mini or x86 mini PC. Only move to Raspberry Pi after confirming pymobiledevice3 can establish the iOS 26 tunnel and DVT set/clear reliably on ARM Linux.

