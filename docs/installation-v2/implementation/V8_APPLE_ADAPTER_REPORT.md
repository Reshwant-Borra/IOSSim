# V8 Apple Personal Team adapter report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Retained the existing native Swift Apple Personal Team implementation, GrandSlam/SRP primitives, legitimate Apple 2FA, Xcode-scoped token exchange, Developer Services operations, Keychain session storage, and managed signing-key storage.
- Established `ApplePersonalTeamService` as the domain-facing typed interface. The prior experimental protocol name remains only as a source-compatibility alias for existing fixtures.
- Added `VersionedPrivateAppleProvisioningAdapter` between SetupStore/coordinator code and the private protocol service. Setup and UI code continue to consume only typed authorization, team, identity, device, App ID, profile, signing, installation, and pairing outcomes.
- Added `PrivateAppleProvisioningAdapterPolicy`, an adapter-version allowlist, and the explicit `VEYA_DISABLE_PRIVATE_APPLE_PROVISIONING` kill switch. Disabled or unapproved adapters stop before invoking credential-bearing service operations.
- Added stable `APPLE_PRIVATE_ADAPTER_DISABLED` and retained `APPLE_AUTH_PROTOCOL_MISMATCH` as typed safe outcomes.
- Changed stored-session resume on response-shape/protocol drift to preserve the protected session and report protocol incompatibility. It no longer deletes a potentially valid session or converts schema drift into a destructive authentication retry.
- Kept password and 2FA values transient through `SensitiveInput`; protected sessions and private signing keys remain in Keychain-backed stores; raw secrets are absent from diagnostics.

## Existing adapter capabilities verified

The retained live adapter already owns the version-bound implementation details required by V8: GrandSlam/SRP requests and proof validation, legitimate trusted-device 2FA, Xcode-scoped token parsing, Apple host/content/redirect/size bounds, versioned client constants, Developer Services response parsing, retry metadata, session-expiration classification, Personal Team selection, device/App ID registration, certificate/profile limits, and typed protocol incompatibility.

## Acceptance evidence

- Apple adapter focused suite: 76 tests executed, one credentials-free local-system probe skipped by default, zero failures.
- New tests prove the kill switch stops before the underlying authorization call, an unapproved adapter version cannot retry into the private protocol, environment policy is explicit, and malformed team response fields preserve the stored session while returning `APPLE_AUTH_PROTOCOL_MISMATCH`.
- Existing offline fixtures cover valid auth, legitimate 2FA, session expiration, Apple service failures, rate limiting, HTTP/transport distinction, response field changes, protocol mismatch, certificate/device/App ID limits, App ID collision, profile failure, and secret-redacted diagnostics.
- Broad safe Swift suite: 328 tests executed, 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected.
- Both no-Xcode routing audits and `git diff --check` passed.
- No real Apple password, 2FA code, account mutation, production Keychain session, certificate creation, device registration, or profile request was used by this gate.

## Physical validation deferred

- Fresh Apple Account authorization and legitimate 2FA against current Apple services.
- Xcode-scoped token issuance, Personal Team discovery, limits/error behavior, session resume/expiration, device registration, App ID registration, certificate request, and profile generation against a test account approved for physical qualification.
- Kill-switch support procedure in a packaged app and protocol-version rollover behavior after an actual upstream change.

## Known limitations

- Apple private protocol compatibility remains version-bound and cannot be called publicly stable. The adapter is intentionally fail-closed and independently disableable.
- `LiveApplePersonalTeamBackend.isPhysicallyQualified` remains false until the V19 physical matrix succeeds.
- V9 owns transactional certificate/profile promotion and retirement; V8 only hardens the Apple service boundary and typed outcomes.

## Gate

UI/setup code is isolated from SRP and Developer Services wire details, the implementation can be disabled independently, response incompatibility is explicit and non-destructive, and the required offline fixture matrix passes. Live Apple service qualification remains physical evidence.
