# LocalDevVPN setup lifecycle

## Ownership decision

LocalDevVPN remains the separately distributed `com.jkcoxson.LocalDevVPN` App Store application. Veya does not bundle, clone, or re-sign it. This avoids assuming rights to redistribute it or access to its packet-tunnel entitlement. The user installs it from its canonical App Store listing and approves Apple’s VPN configuration. `CONFIRMED_APPLE_DOCUMENTATION`, `PRODUCT_DECISION_REQUIRED` for commercial/support agreement

Veya owns detection, compatibility messaging, launch/request integration, retry, and runtime endpoint proof. The LocalDevVPN publisher owns the app, extension, VPN configuration UI, and App Store updates.

## State machine

```text
MISSING
  -> INSTALLED_UNSUPPORTED | INSTALLED
  -> VPN_PERMISSION_REQUIRED
  -> CONFIGURED
  -> STARTING
  -> RUNNING
  -> RUNTIME_ENDPOINT_REACHABLE
```

- **MISSING:** device inventory lacks exact bundle. Veya opens the App Store only after user action and resumes when foregrounded.
- **INSTALLED:** exact bundle/version is within a signed compatibility matrix.
- **VPN_PERMISSION_REQUIRED:** phone app displays Apple-controlled approval guidance; denial is not retried silently.
- **CONFIGURED/RUNNING:** a request-bound receipt reports state but does not prove routing.
- **RUNTIME_ENDPOINT_REACHABLE:** Veya performs a fresh authenticated/identity-bound reachability exchange at `10.7.0.1:49152`, followed by the developer-service probe. A bare TCP accept is insufficient long-term.

## Activation contract

The IOSSim/Veya phone app persists pending request ID/expiry in its container and reconciles on every `scenePhase == .active`, initial task, and relevant file-present notification. The Mac writes via House Arrest, launches the main app to ingest, then launches LocalDevVPN by AppService when supported. Polling is bounded with jitter, survives scene suspension, and never accepts a receipt from another request/device/team.

The current one-shot `.task` and 60-second watcher are replaced because foregrounding does not guarantee task recreation. `CONFIRMED_LOCAL_IOSSIM_CODE`

## Compatibility and failure

The release manifest names minimum/tested LocalDevVPN versions and protocol schema. Veya distinguishes missing app, unsupported version, VPN approval required/denied, stale receipt, app launch failure, route mismatch, endpoint timeout, and developer-service failure. An App Store update outside the matrix fails closed with upgrade/compatibility guidance.
