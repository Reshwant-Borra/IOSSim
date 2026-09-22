# Apple Authorization Specification

## Boundary

Authorization establishes a renewable Apple API session; it never creates signing keys/certificates and never owns setup progression. Apple account password and 2FA code are ephemeral inputs and are never persisted or logged.

## Types and interface

```swift
protocol AppleAuthorizationService: Sendable {
  func observe(accountHint: AccountHint?) async -> AuthorizationObservation
  func begin(account: AppleAccountID, password: EphemeralSecret) async throws -> AuthorizationChallenge
  func submit(challenge: ChallengeID, code: EphemeralSecret) async throws -> AppleSession
  func validate(_ session: SessionID) async throws -> SessionValidity
  func invalidate(_ session: SessionID, reason: InvalidationReason) async
}
```

`AppleSession` persists only opaque cookies/tokens/device identifiers required by the Apple protocol, account hash, issued/validated/expiry timestamps, schema, and server provenance. Storage is a data-protection Keychain generic-password item service `com.veya.apple-authorization.v2`, account hash scoped, synchronizable false. The old `com.iossim.mac.apple-authorization` is migration-read-only.

## Flow

1. Noninteractive lookup uses `kSecUseAuthenticationUIFail` and never falls back to prompting.
2. Validate a recovered session using a harmless Personal Team request. Local expiry alone cannot prove validity.
3. Classify `valid`, `expired`, `revoked`, `twoFactorRequired`, `termsRequired`, `networkUnavailable`, `serverChanged`, or `keychainUnavailable`.
4. First auth accepts password in memory, performs SRP/GrandSlam flow, zeroizes it, and returns a challenge when Apple requires 2FA.
5. 2FA codes are scoped to challenge ID, single-use, time-bounded, and zeroized.
6. Atomically replace the session item only after server validation. Keep old session until candidate proves valid; then delete old.

Reinstall/upgrade reuses a validated v2 session. Multi-process access is eliminated by making the packaged provisioner the only Keychain accessor. UI and qualification pass ephemeral inputs to that already-running child through a protected stdin pipe; arguments/environment/files are forbidden. Multi-user Macs have per-user installations/sessions.

Unexpected Keychain UI, `errSecInteractionNotAllowed`, corrupt session, or access requirement drift produces a stable AUTH code. The system may ask the user for Apple Account authentication/2FA because Apple requires it; Veya must never present a macOS Keychain-password workaround.

## Tests

Hermetic fixtures cover valid/expired/revoked sessions, trusted-device and SMS 2FA, wrong code, no team, terms, schema drift, timeout, interrupted write, and network ambiguity. Real tests use a dedicated qualification account under an explicit mutation permit; normal pre-Build-12 tests do not authenticate or alter Apple resources.

