# 17 Security Model

## Sensitive assets

| Asset | Risk if exposed |
|---|---|
| USB pairing records | Broad trusted access to device services |
| RemotePairing records | Ability to request trusted wireless tunnels |
| RSD/TLS/QUIC secrets | Session compromise or traffic decryption |
| Full UDID/serial identifiers | Device tracking/privacy |
| Location commands/history | Personal location privacy |
| Raw pymobiledevice3 logs | May include identifiers, ports, secrets, paths |
| Backend command execution | Could become arbitrary device-management or host command execution |

## Architecture exposure ranking

| Architecture | Recommendation | Reason |
|---|---|---|
| Localhost-only current app | Recommended default | Smallest attack surface |
| LAN-only no auth | Not recommended | Anyone on LAN could set location/reset GPS |
| LAN-only with auth | Acceptable for trusted home lab | Still vulnerable to LAN compromise |
| Tailscale-only with auth | Recommended remote/personal architecture | Private addressing plus identity layer |
| Public Internet with auth | Possible but high effort | Needs TLS, auth, rate limits, audit, CSRF/CORS hardening |
| Public Internet no auth | Do not use | Direct unauthorized device control |
| usbmux exposed over TCP | Avoid unless inside VPN and locked down | Exposes broad device services |
| Raw USB-over-IP | Avoid for production | Full device USB exposed remotely |
| Cloud UI + local narrow agent | Recommended hosted model | Pairing secrets stay local; commands are constrained |

## Controls for any remote agent

- Bind local agent to localhost or Tailscale IP only.
- Require authentication for every state-changing operation.
- Use allowlisted commands, not arbitrary CLI passthrough.
- Store pair records with OS filesystem protections.
- Redact UDIDs and RSD details in exports.
- Use short-lived cloud tokens and revocable agent enrollment keys.
- Rate-limit set-location commands.
- Add explicit “Reset GPS” and emergency stop.
- Keep Drive Testing and Wireless Research feature flags separate.

## Secrets that must never leave the local host

```text
pair records
RemotePairing records
private keys
escrow bags
RSD/TLS secrets
raw tunnel logs
full UDID unless needed and user-authorized
```

## Preferred security architecture

```text
Safari / cloud dashboard
  -> authenticated HTTPS
cloud control plane
  -> mutually authenticated WebSocket
local IOSSim agent on Tailscale/private network
  -> local pymobiledevice3
```

For a single-user setup, simpler is better:

```text
iPhone Safari
  -> Tailscale IP of Mac/mini host
  -> authenticated local IOSSim UI/API
```

