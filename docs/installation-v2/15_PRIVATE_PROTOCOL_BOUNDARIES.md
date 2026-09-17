# Private protocol boundaries

## Adapter layout

```text
SetupStore
  -> ApplePersonalTeamService (stable domain interface)
     -> ApplePersonalTeamAdapter(version: research-2026-09-akd)
        -> MachineMetadataProvider
        -> GrandSlamAuthenticator
        -> DeveloperServicesClient
        -> ManagedSigningKeyStore
```

The stable service exposes `authorize`, `submitSecondFactor`, `listTeams`, `prepareIdentity`, `registerDevice`, `prepareIdentifiers`, `issueProfiles`, `refresh`, and `diagnoseCompatibility`. It returns typed domain results and opaque session/key references. GrandSlam dictionaries, anisette fields, headers, tokens, cookies, endpoint constants, and plist parsing never cross the adapter.

## Value lifetimes

| Class | Examples | Handling |
| --- | --- | --- |
| Version-bound | Xcode client info, protocol headers, endpoint schemas | adapter constant set, signed compatibility matrix |
| Machine-bound | local machine ID/OTP metadata | Keychain/system-derived; no support export |
| Account-bound | DSID, session/token/cookies | Keychain, expiry, never log |
| Team-bound | team ID, cert, App IDs | scoped state; public IDs may be salted in support |
| Device-bound | UDID registration | hash in state; raw only in process memory |
| Ephemeral | password, SRP secrets, 2FA | zero/release promptly; never persist |

## Retry and compatibility rules

Read-only team/session validation may retry bounded network failures and server `Retry-After`. Certificate creation, device registration, App ID creation, and profile issuance use read-before-create and an idempotency/reconciliation key; an ambiguous response is reconciled before retry. Auth rejection never triggers resource creation. A response shape, cryptographic parameter, or required header outside the adapter’s signed compatibility fixture yields `VEYA-APPLE-006 PROTOCOL_INCOMPATIBLE`, disables mutation, and preserves existing installed apps.

The taxonomy distinguishes credentials, 2FA required/rejected, session expiry, Apple outage, rate limit, network timeout, team ambiguity, certificate/device/App ID limits, certificate mismatch, profile failure, and protocol incompatibility. SetupStore maps these states to user actions without inspecting HTTP/plist detail.
