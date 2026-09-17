# Apple Authentication, Provisioning, and Signing

This document preserves everything learned about Vanish's Apple Account automation, Developer Services provisioning, signing, installation, and renewal model.

## Core Conclusion

`STRONG_EVIDENCE`: Vanish makes Apple developer setup feel automatic by routing Apple authentication, Developer Services, signing, installation, and pairing-delivery work through a local Rust helper called `VanishSideloader`.

`UNKNOWN`: Exact live network destinations and session lifetimes remain unresolved because no Apple login was performed.

`DISPROVEN`: Vanish does not appear to avoid Personal Team expiration as a product strategy. It acknowledges seven-day signing and includes refresh/re-sign/reinstall mechanisms. Evidence: E16.

## Apple Account Authentication

| Capability | Current finding | Confidence | Evidence |
| --- | --- | --- | --- |
| GrandSlam auth | Helper contains GrandSlam endpoint/vocabulary and matching public isideload implementation | STRONG_EVIDENCE | E08 |
| SRP | SRP auth implementation indicators and srptools dependency | STRONG_EVIDENCE | E04, E08 |
| Trusted-device 2FA | Native helper and command/event bridge include 2FA paths | STRONG_EVIDENCE | E08-E09 |
| SMS verification | Native helper includes SMS/security-code paths | STRONG_EVIDENCE for capability | E08 |
| Developer Services auth | `xcode.auth` and `developerservices2.apple.com` operations | STRONG_EVIDENCE | E08 |
| Durable session reuse | Not established | UNKNOWN | E10 limitation |
| Optional password reuse | Electron safeStorage path exists | CONFIRMED | E10 |
| Apple password sent to Vanish | Not established | UNKNOWN | E08-E10 |

## Local Helper Architecture

`CONFIRMED`: Electron communicates with `VanishSideloader` through a command/event bridge. The bridge surfaces login, 2FA, certificate-limit choices, device selection, pairing placement, install progress, and helper-lost events. Evidence: E09.

`STRONG_EVIDENCE`: Apple auth and Developer Services work happen locally in the helper because the binary contains matching operation vocabulary and public isideload code implements these flows. Evidence: E08-E09.

`CONFIRMED`: The saved-login path encrypts an Apple password with Electron `safeStorage` into `sideload_accounts.json`, then later decrypts it locally to invoke helper login. Evidence: E10.

Interpretation:

- Saved password is a UX convenience.
- Saved password is not proof of durable Apple session token reuse.
- Saved password is not proof that Apple passwords are sent to Vanish servers.
- Persisting Apple passwords is not a recommended IOSSim default solely to match UX.

## Anisette

`CONFIRMED`: Candidate anisette hosts appear:

- `ani.sidestore.io`
- `ani.stikstore.app`

Evidence: E08.

`STRONG_EVIDENCE`: Matching public isideload `RemoteV3` anisette support obtains authentication support/header state from a remote service. This is compatible with local Apple password handling plus remote anisette metadata.

`UNKNOWN`: Which host is selected in a real Vanish login, when fallback occurs, exact payloads, and retention.

## Developer Services Sequence

`STRONG_EVIDENCE`: Vanish appears to follow a normal Apple Personal Team development workflow:

1. Authenticate Apple Account.
2. Obtain Developer Services/Xcode auth.
3. Discover teams, including Personal Team.
4. Select or ask for team.
5. Generate or reuse a certificate/key identity.
6. Register device.
7. Create or reuse App IDs.
8. Download provisioning profiles.
9. Sign prebuilt IPA.
10. Install to selected device.
11. Place/repair pairing material.

Evidence: E08-E09.

## Team Discovery and Personal Team

`STRONG_EVIDENCE`: Team discovery and Personal Team handling exist in the helper/library. Evidence: E08.

`UNKNOWN`:

- Multi-team UI behavior.
- How team preference is persisted.
- Whether Vanish auto-selects Personal Team over paid teams.
- Behavior when an Apple Account changes.
- Behavior when a team has multiple existing certificates.

## Certificates and Keys

Evidence indicates:

- CSR generation/submission paths.
- Development certificate list/create paths.
- Certificate-limit handling event.
- Keychain generic-password imports and security-library linking.
- PKCS/certificate vocabulary.

Confidence:

- Certificate creation/reuse capability: `STRONG_EVIDENCE`.
- Exact private-key storage location and key export policy: `UNKNOWN`.
- Whether certificate revocation is handled safely/automatically: `UNKNOWN`.

Evidence: E07-E09.

Clean-room note:

IOSSim already has native Apple auth, Keychain session/key architecture, CSR, and signing machinery. Do not replace this solely because Vanish uses a Rust helper. Evidence: E27.

## App IDs and Bundle IDs

`STRONG_EVIDENCE`: The helper contains App ID create/list/prepare operations and bundle identifier modification vocabulary. Evidence: E08.

`CONFIRMED`: The source mobile payload bundle ID is `com.vanish.stikdebug`, with a Live Activity extension under `com.vanish.stikdebug.liveactivity`. Evidence: E12.

`UNKNOWN`:

- Final installed bundle ID after user signing.
- Bundle-ID generation algorithm.
- Conflict behavior.
- Whether extension App IDs are created/reused independently.

## Device Registration

`STRONG_EVIDENCE`: `addDevice` and `listDevices` style Developer Services operations appear in helper evidence. Evidence: E08.

`UNKNOWN`:

- Behavior if device registration already exists.
- Behavior if device quota is reached.
- Behavior when replacing devices.
- Behavior with multiple connected iPhones.

## Provisioning Profiles

`STRONG_EVIDENCE`: Vanish can obtain/download team provisioning profiles and sign payloads. Evidence: E08-E09.

`UNKNOWN`:

- Installed profile expiration dates.
- Profile entitlements.
- Whether profile trust appears in Settings.
- Whether profile refresh preserves app data.
- How profile mismatch is repaired.

## Signing and Installation

`STRONG_EVIDENCE`: Vanish signs a prebuilt IPA locally and installs it using independent device protocols, likely AFC plus `installation_proxy`. Evidence: E08-E09.

`CONFIRMED`: Install dispatch points to bundled `Vanish.ipa`; legacy command naming does not prove SideStore is the installed product. Evidence: E09.

`CONFIRMED`: `Vanish.ipa` lacks an embedded provisioning profile, consistent with being re-signed for the user/device. Evidence: E12.

## Seven-Day Expiration and Renewal

### Main Finding

`STRONG_EVIDENCE`: Vanish handles the free Personal Team seven-day window through refresh/re-sign/reinstall mechanisms. It does not bypass the normal expiration model.

Evidence:

- Mobile UI copy describes re-signing every seven days.
- Wi-Fi refresh restriction is present.
- Public tutorial says an app that has fully stopped opening needs computer installation again.
- Mobile executable contains `SelfRefreshInstaller` functions for stage/copy/package/AFC/upgrade.
- `VanishSelfRefresh.ipa` staging path appears.
- Apple auth/signing code exists on phone.

Evidence: E16, E30.

### What Is Known

| Question | Finding | Confidence |
| --- | --- | --- |
| Is seven-day Personal Team expiration acknowledged? | Yes | CONFIRMED |
| Is on-phone refresh intended? | Yes | STRONG_EVIDENCE |
| Is this an expiration bypass? | No, current evidence says refresh/re-sign | STRONG_EVIDENCE |
| Is Wi-Fi required? | Shipped copy says yes | STRONG_EVIDENCE |
| Does fully expired app need Mac recovery? | Public tutorial indicates yes | STRONG_EVIDENCE |

### What Is Unknown

- Whether refresh is fully automatic in background.
- Whether refresh works after the app fully expires.
- Whether user data always survives.
- Whether Apple credentials are needed again in every case.
- Whether certificates are renewed or reused.
- Behavior with revoked certificates.
- Behavior when App IDs or bundle IDs conflict.
- Behavior when account/team changes.

## Backend Role in Auth and Signing

`STRONG_EVIDENCE`: Supabase endpoints exist for entitlement, account/access, checkout, telemetry, mobile auth, mobile entitlement, mobile app version, and mobile session accounting. Evidence: E20.

`UNKNOWN`: Whether any of these endpoints mediate Apple authentication, signing, or runtime location commands. Endpoint names alone are insufficient.

## IOSSim Relevance

IOSSim should keep and harden its native Apple Personal Team implementation:

- It already has GrandSlam/SRP, legitimate verification, teams, profile operations, Keychain sessions/keys, CSR, and signing. Evidence: E27.
- Vanish's advantage is orchestration, packaging, progress UX, pairing integration, and refresh, not a proven superior Apple auth primitive.
- Persisting the Apple password by default is not recommended as a clean-room UX shortcut.

High-value IOSSim follow-up work:

- Better first-run status for Apple auth and team readiness.
- Reuse valid sessions without hiding when Apple requires reauthentication.
- Certificate/profile health checks and proactive refresh.
- Mac-assisted renewal before trying a harder on-phone refresh subsystem.
