# Vanish Apple provisioning analysis

Electron launches the bundled `VanishSideloader` with an app-owned data directory and exchanges line-delimited JSON commands. Observed operations include `login`, `two_factor_code`, `max_certs_response`, device selection, install, pairing placement, and logout. Optional password retention uses Electron `safeStorage`; decryption failure removes the unusable saved record. Long install and user-consent operations receive larger timeouts. `CONFIRMED_VANISH_STATIC_CODE`

The resulting responsibility chain is strongly supported even where helper internals are opaque:

```text
Apple credentials -> 2FA -> developer session -> Personal Team
-> signing certificate/key -> device registration -> App IDs/profiles
-> re-sign bundled IPA -> install
```

Veya already owns equivalent responsibilities in `ApplePersonalTeamExperimental`, `ApplePersonalTeamLive`, and `NativeSigningIdentityResolver`. Veya should retain them behind a stable `ApplePersonalTeamService` contract, isolate GrandSlam/AuthKit/Developer Services details in a versioned private adapter, and avoid exposing protocol constants to `SetupStore`.

Vanish's optional password saving is a UX precedent, not a target default. Veya should keep passwords and 2FA codes ephemeral, store only refreshable session material when necessary in Keychain, require user opt-in for any password retention, and redact all auth material from journals/support bundles.

Required Veya errors remain distinct: wrong credentials, 2FA required/rejected, expired session, Apple outage, private-protocol incompatibility, team ambiguity, certificate/device/App-ID limit, certificate-key mismatch, profile failure, timeout, and rate limit. Static Vanish behavior does not make Apple's private Personal Team protocol public or stable.
