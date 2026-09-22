# AppService and Rich Runtime Readiness

## Required proof chain

```text
LocalDevVPN endpoint challenge
-> software tunnel
-> RSD handshake
-> RemoteXPC
-> AppService
-> exact installed runner identity
-> TestManager session
-> XCTest session
-> bounded Rich location write to nonce target
-> independent observation of nonce/location
-> clear
-> independent cleanup observation
-> READY evidence
```

No link may be inferred from a later checkpoint or cached success. A runner with the expected bundle ID but wrong version/team/artifact digest fails before TestManager.

## Evidence

`RuntimeReadinessEvidence` contains schema, generation, installation ID, device UDID hash, connection generation, payload/runner bundle IDs and artifact digests, certificate/profile identities, DDI build/digest, pairing ID, VPN endpoint identity, RSD service identity, TestManager/XCTest session IDs, random target nonce hash, write/observation/clear timestamps, cleanup proof, and `validUntil`.

READY is a derived UI projection of a fresh evidence object plus a current lightweight liveness observation. Default TTL is 10 minutes; any app update, profile/cert replacement, device/Mac/phone reboot, reconnect, VPN endpoint change, DDI change, pairing replacement, runner mismatch, or cleanup failure invalidates it.

The Rich proof uses a bounded test coordinate encoded with a random nonce in a controlled verification channel, never a user route. Success for the wrong target/device/session is rejected. Cleanup is mandatory; a write success followed by failed clear is `VEYA-RUNTIME-061`, not READY.

The existing `RichRuntimeReadinessCoordinator` and iOS inbox protocol survive after binding all receipts to the canonical generation. The provisioner owns orchestration; `SetupStore` only displays evidence/failure.

