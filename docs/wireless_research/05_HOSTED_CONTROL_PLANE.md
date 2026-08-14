# 05 Hosted Control Plane

## Architecture

```text
Cloud dashboard / route planner / auth
  <-> HTTPS or WebSocket
IOSSim Agent on Mac/PC near device
  <-> pymobiledevice3 / pairing / RSD / DVT
iPhone
```

This separates product UI/control from Apple device control. It does not remove the local host; it minimizes it.

## Minimum code that must remain local

The local agent must:

- hold pair records and RemotePairing records;
- discover USB/network device state;
- mount or verify Developer Disk Image support when needed;
- create/maintain the RSD tunnel;
- run DVT `simulate-location set/clear/play`;
- redact logs;
- enforce local authorization policy;
- report tunnel/device state to the control plane.

The cloud can own:

- frontend UI;
- favorites;
- route search/routing/caching;
- user auth/session management;
- audit log storage after redaction;
- orchestration of commands.

## Answers

| Question | Answer |
|---|---|
| What minimum code must remain on the Mac? | Pairing, tunnel, DVT executor, and local secret store. |
| Could frontend and routing run entirely in the cloud? | Yes. |
| Could only the pymobiledevice3 bridge stay local? | Yes. That is the recommended hosted architecture. |
| Could the Mac run headless? | Yes. A launchd service or menu-bar/background agent is realistic. |
| Could it auto-start at boot? | Yes with launchd on macOS, Task Scheduler/service wrapper on Windows, or systemd on Linux. |
| Could it run as a launchd service? | Yes, but tunnel creation may require privileges. Use least privilege and explicit logs. |
| Could the user control it from Safari on the iPhone? | Yes. The iPhone can load a cloud or LAN web UI, which commands the local agent indirectly. |
| Could authentication be added safely? | Yes. Use per-user auth, per-agent enrollment keys, short-lived tokens, and command authorization. |
| Could it work over Tailscale instead of public Internet? | Yes and preferable for personal use. Tailnet-only agent API avoids public exposure. |
| What secrets must never leave the Mac/agent host? | Pair records, RemotePairing records, private keys, escrow bags, RSD/TLS secrets, full UDID unless explicitly needed, and raw logs containing secrets. |

## Recommended implementation boundary

The cloud should not receive “run arbitrary pymobiledevice3 command.” It should send narrow commands:

```json
{ "type": "set_location", "lat": 37.7749, "lon": -122.4194 }
{ "type": "clear_location" }
{ "type": "status" }
```

The local agent translates those to pymobiledevice3 and returns structured, redacted status.

## Security stance

Preferred:

```text
Tailscale-only dashboard -> local agent
```

Acceptable with more work:

```text
public cloud dashboard -> mutually authenticated local agent WebSocket
```

Not recommended:

```text
publicly exposed FastAPI with no auth
```

