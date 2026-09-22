# LocalDevVPN Specification

## State model

`missing`, `installed`, `permissionRequired`, `configured`, `starting`, `running`, `endpointReady`, `failed` are distinct observations.

| State | Authoritative evidence |
|---|---|
| missing | Fresh device inventory lacks exact bundle ID |
| installed | Inventory has exact expected bundle/team/version |
| permissionRequired | Signed phone receipt says NetworkExtension approval pending |
| configured | Receipt binds accepted configuration generation |
| starting | Recent start receipt, endpoint not yet reachable |
| running | Phone process/tunnel status says active |
| endpointReady | Mac completes nonce challenge through tunnel to expected phone instance |
| failed | Typed phone/transport error with generation |

Only `endpointReady` can satisfy downstream runtime prerequisites. A stale "running" checkpoint cannot.

## Reconciliation and resume

The coordinator observes inventory, delivers a versioned non-secret configuration through the authenticated app container, requests start, and polls with bounded backoff for endpoint challenge. Apple's VPN/profile approval is a legitimate user action; Veya waits and re-observes rather than retrying setup.

Foreground/background does not change truth. On Mac app restart, phone restart, VPN restart, network change, or connection-generation change, endpoint evidence expires immediately and is reproved. Configuration is reused only when device, payload, protocol, and generation compatibility hold. Failures do not delete a working configuration.

Tests inject missing app, approval pending, rejected permission, stale receipt, running-but-unreachable, wrong endpoint identity, phone/Mac restart, and recovery. Physical qualification must include approval once and no-repeat behavior after restart/reinstall.
