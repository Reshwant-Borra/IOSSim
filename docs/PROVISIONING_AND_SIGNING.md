# Provisioning and Signing

This document is the current handoff for Apple Personal Team authorization,
provisioning, signing, installation setup state, and security boundaries.

## Consumer Goal

```text
Download IOSSim
  -> connect iPhone
  -> select device
  -> Apple Account login inside IOSSim
  -> legitimate Apple 2FA
  -> IOSSim discovers Personal Team
  -> create/reuse IOSSim-managed signing identity
  -> register/reuse device
  -> create/reuse App IDs
  -> obtain main and runner profiles
  -> sign artifacts
  -> install artifacts
  -> guide required Apple trust steps
  -> runtime setup
  -> Ready
```

The current product still requires Xcode to be installed because physical device
operations use Apple's `xcrun devicectl` / CoreDevice tooling. The current user
flow does not ask the user to open Xcode, sign into Xcode, configure Xcode
Accounts, manage certificates in Xcode, build in Xcode, or install from Xcode.
That "Xcode installed but never opened/configured" target is not yet clean-Mac
qualified.

The experimental bootstrap keeps Xcode download authentication separate from
the existing Developer Services session. There is no evidence that those
session types are interchangeable, and IOSSim does not reuse or scrape Xcode
Accounts. Download password and 2FA inputs must remain ephemeral when that
adapter is completed.

## Apple Authorization

`ApplePersonalTeamLive.swift` implements the private Personal Team flow used by
the current LOCAL_TEST_ONLY product:

```text
GrandSlam SRP init/complete
  -> trusted-device or SMS 2FA
  -> Xcode-scoped GS token
  -> Developer Services session
  -> teams
  -> certificate
  -> device registration
  -> App IDs
  -> provisioning profiles
```

Engineering notes:

- The account string is canonicalized to lowercase for the SRP exchange.
- Password and 2FA inputs are accepted only at the UI boundary and are treated
  as ephemeral sensitive input.
- IOSSim stores reusable opaque authorization/session material in Keychain-backed
  storage where applicable.
- Session reuse is validated by a team-list request; IOSSim does not invent an
  expiration when Apple does not provide one.
- Diagnostics record checkpoints, structure, result codes, and safe lengths, not
  secrets.

Do not document or commit Apple passwords, 2FA codes, cookies, opaque Apple
tokens, session payloads, private keys, pairing records, or provisioning blobs.

## Security Model

Current intended guarantees:

- Passwords are not persisted.
- 2FA codes are not persisted.
- No public anisette server is used.
- No third-party credential proxy is used.
- IOSSim does not steal or scrape Xcode account state.
- The IOSSim-managed signing private key remains local, permanent, and
  Keychain-backed.
- The private key is not exported through temporary files.
- Keychain access remains scoped to IOSSim-owned material.
- iOS developer-profile trust is not bypassed. The user is guided through
  Apple's Settings flow.
- Diagnostics redact sensitive values and exclude private keys, auth payloads,
  provisioning profile blobs, RPPairing material, PSKs, and raw device IDs.

## Bundle Identifiers

Canonical source IDs are protected and must remain stable:

| Role | Source identifier |
| --- | --- |
| Main iPhone app | `com.iossim.on-device-dvt-poc` |
| Witness | `com.iossim.location-witness` |
| Hosted unit tests | `com.iossim.location-control-tests` |
| UI tests | `com.iossim.location-control-uitests` |
| XCTest runner | `com.iossim.location-control-uitests.xctrunner` |
| Mac app | `com.iossim.mac-provisioner` |

Personal Team installed IDs are derived because canonical identifiers cannot be
assumed available across arbitrary Personal Teams. The current algorithm in
`PersonalTeamBundleIdentifierSet` normalizes the Team ID to uppercase, computes
SHA-256 over `IOSSimPersonalTeam:<TEAM_ID>`, takes the first 12 lowercase hex
characters, prefixes them with `t`, and uses:

```text
com.personalteam.iossim.t<12-hex>.on-device-dvt-poc
com.personalteam.iossim.t<12-hex>.location-control-uitests
com.personalteam.iossim.t<12-hex>.location-control-uitests.xctrunner
```

The derivation does not use Apple Account email, personal name, raw device ID,
RPPairing material, passwords, or randomness.

## Signing Architecture

The current native signing path is implemented in
`NativeSigningIdentityResolver` and `ConsumerArtifactProvisioner`:

1. Validate that the provisioning profile certificate exists and matches the
   recorded SHA-256 fingerprint.
2. Materialize/reuse the certificate in the user Keychain.
3. Find the IOSSim-owned permanent RSA private key by application tag or public
   key label.
4. Compare certificate public key bytes to the private key's public key.
5. Reconstruct/validate `SecIdentity`.
6. Run `security find-identity` without redacting output for the internal SHA-1
   visibility comparison.
7. Run a disposable codesign probe.
8. Sign nested code deepest-first.
9. Sign main app and runner with controlled entitlements.
10. Verify signatures, identifiers, teams, nested code, and entitlements.

Resolved issue: a previous signing failure was not caused by a missing
certificate or private key. The failure was caused by comparing the certificate
SHA-1 to redacted `security find-identity` output. The 40-character fingerprint
had become `[REDACTED_HEX]` before comparison. The corrected implementation uses
cryptographic Keychain/Security.framework resolution and disables redaction only
for that internal process result.

Do not replace deepest-first signing with `codesign --deep --force`.
`--deep` remains appropriate for verification only where the current code uses
it.

## Nested Signing

The current packaged device artifact contains:

| Nested item type | Count |
| --- | --- |
| `.xctest` bundle | 1 |
| Frameworks | 7 |
| Dylibs | 1 |

Current framework/dylib set:

- `XCUnit.framework`
- `XCTAutomationSupport.framework`
- `XCUIAutomation.framework`
- `XCTestSupport.framework`
- `XCTest.framework`
- `XCTestCore.framework`
- `Testing.framework`
- `libXCTestSwiftSupport.dylib`

The helper signs nested code before signing the containing runner and main app,
then verifies with strict signature checks.

## Entitlements

`ConsumerArtifactProvisioner.signingEntitlements` signs with a controlled
profile-derived allowlist:

- `application-identifier`
- `com.apple.developer.team-identifier`
- `get-task-allow`
- `keychain-access-groups`

The code does not pass the entire provisioning profile entitlement dictionary to
codesign. It validates team, application identifier, development entitlement,
profile device inclusion, certificate continuity, dates, and keychain group
shape before signing.

## Installation and Trust State

Installation, trust, and runtime readiness are separate:

| Concept | State |
| --- | --- |
| Install commands exited | `INSTALL_COMMANDS_SUCCEEDED` checkpoint |
| Current main and runner inventory found | `INSTALLATION_VERIFIED` checkpoint |
| Apple developer profile trust needed | `DEVELOPER_PROFILE_TRUST_REQUIRED` checkpoint |
| Developer profile trust verified | `DEVELOPER_PROFILE_TRUSTED` stage/status |
| Runtime mapping written | `RUNTIME_CONFIGURATION_WRITTEN` checkpoint |
| Runtime mapping read back | `RUNTIME_CONFIGURATION_VERIFIED` checkpoint |
| User confirmed iPhone setup | `COMPLETE` checkpoint |

Experimental pairing adds independent generate, validate, private transfer,
and iPhone functional-verification phases before runtime readiness. The
candidate uses an in-memory iPhone staging store; the primary Keychain record
is replaced only after the pinned runtime establishes a real connection.

The current consumer-facing trust UI says "Trust IOSSim on your iPhone" and
guides the user through Settings -> General -> VPN & Device Management ->
developer profile -> Trust. Continue retries only trust/launch verification. It
does not reprovision, reissue profiles, recreate App IDs, regenerate keys,
resign, or reinstall merely to check trust.

Computer trust, Developer Mode, and developer-profile trust are independent:

| Requirement | Meaning | User action |
| --- | --- | --- |
| Computer trust | USB "Trust This Computer?" relationship | Tap Trust on iPhone and enter passcode |
| Developer Mode | iOS Developer Mode required for developer services | Enable in Settings -> Privacy & Security |
| Developer-profile trust | Trust the Personal Team developer profile for installed development apps | Settings -> General -> VPN & Device Management -> Trust |

## Post-Install Inventory Policy

Post-install verification reads authoritative selected-device app inventory from
`devicectl device info apps`.

Current policy:

- attempt immediately;
- then wait 0.2, 0.4, 0.8, 1.2, 1.6, and 2.0 seconds;
- maximum seven reads;
- maximum scheduled backoff 6.2 seconds;
- stop early on exact current main and runner success;
- stop and classify device unavailable, locked, computer trust, or Developer
  Mode separately;
- never accept Witness, canonical runner, stale-team runner, old main app, or a
  wrong-team bundle as success.

The retry loop is bounded, cancellable, generation-aware through `SetupStore`,
device-aware through exact selected-device identifiers, and invisible to the
normal user unless verification genuinely fails.

## Checkpoint-Aware Retry

Try Again and Continue retry the smallest prerequisite:

| Deepest checkpoint | Retry behavior |
| --- | --- |
| `INSTALL_COMMANDS_SUCCEEDED` | Retry inventory only |
| `INSTALLATION_VERIFIED` | Retry launch/developer-profile trust only |
| `DEVELOPER_PROFILE_TRUST_REQUIRED` | Stay on trust instructions; Continue retries launch only |
| `RUNTIME_CONFIGURATION_WRITTEN` | Retry runtime readback |
| `RUNTIME_CONFIGURATION_VERIFIED` | Continue to iPhone setup confirmation |
| `COMPLETE` | No setup replay |

`ConsumerArtifactProvisioner.resumeSetup` never authenticates, provisions,
signs, installs, or uninstalls.

## Fresh Install and Stale Team State

Fresh Install is a deliberate repair operation. It must not be suggested merely
because trust is pending, runtime setup failed, inventory propagation is delayed,
or stale historical metadata exists.

Known team history:

- Historical physical qualification team: `5337SALD55`
- Current physical Personal Team observed: `T8SL4SG87F`

If authoritative current selected-device inventory contains the exact current
main and runner for the current team, that physical evidence wins safely over
stale local metadata. Historical team metadata may be used to identify old
IOSSim-owned artifacts for explicit repair/removal, but it must not override the
current provisioning/install state.

## Source References

- `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift`
- `macos/Sources/IOSSimMacCore/Services/NativeProvisioningArtifactStore.swift`
- `macos/Sources/IOSSimMacCore/Services/NativeSigningIdentityResolver.swift`
- `macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift`
- `macos/Sources/IOSSimMacCore/Services/InstallationInventory.swift`
- `macos/Sources/IOSSimMacCore/Models/ConsumerProvisioning.swift`
- `macos/Sources/IOSSimMacCore/SetupStore.swift`
- `macos/Sources/IOSSimMac/Views/SetupWizardView.swift`
