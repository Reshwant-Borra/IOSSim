# Zero-Xcode Consumer Provisioning

Status: `ZERO_XCODE_PERSONAL_TEAM_BLOCKED` (engineering investigation, 2026-09-07).

This document records the zero-Xcode architecture, dependency audit, completed
safe work, and the feasibility stop condition. It does not claim physical
qualification. The investigation host has `/Applications/Xcode.app` installed
and no connected qualification iPhone, so it cannot provide the required
negative or physical evidence.

## Architecture

The product-level boundary is:

`SwiftUI setup -> IOSSimMacCore -> Consumer provisioning backend selection -> helper/device backend -> iPhone`

Backend preferences are `AUTO`, `ZERO_XCODE`, and `XCODE_FALLBACK`, selected for
development with `IOSSIM_PROVISIONING_BACKEND`. `AUTO` prefers a fully qualified
native backend. Until every native capability gate is ready, it identifies the
working Xcode path explicitly as `XCODE_FALLBACK`. `ZERO_XCODE` fails closed and
also forces the device layer away from `devicectl`; it never silently changes to
Xcode.

`XcodePresenceDetector` checks only the known `/Applications/Xcode.app` and
`/Applications/Xcode-beta.app` paths. It does not run `xcode-select`, `xcrun`, or
search other volumes. Doctor/support diagnostics record `provisioningBackend`,
`xcodePresent`, and `zeroXcodeMode`. Xcode version probing occurs only for the
fallback backend.

## Xcode Dependency Audit

| Current dependency | Current operation | Zero-Xcode classification | Replacement or disposition |
| --- | --- | --- | --- |
| Full Xcode application | Supplies iPhone SDK/platform support, Xcode account state, automatic signing, and CoreDevice tools | REMOVE from consumer runtime | Prebuild profile-free iPhone artifacts; native provisioning and bundled device bridge remain gated |
| `xcodebuild` | Builds an ephemeral signing shell with `-allowProvisioningUpdates`, causing Xcode to create/find IDs, register the device, and issue main/runner profiles | TEMPORARY FALLBACK | Paid team: documented App Store Connect provisioning API plus direct signing. Free Personal Team: blocked as described below |
| `xcrun` | Locates/runs `devicectl`; also wraps build-time SDK/notary tools | REMOVE from zero-Xcode runtime | Bundled pinned idevice bridge for device operations. Build/notarization use is not a consumer runtime dependency |
| `devicectl list devices` | Discovery, selected-device resolution, trust/developer/connection state | REPLACE | Pinned idevice `usbmuxd`, `LockdownClient`, and exact-UDID provider |
| `devicectl device info apps` | Installed inventory and duplicate detection | REPLACE | idevice `InstallationProxyClient.browse/get_apps` |
| `devicectl device info lockState` | Locked-state diagnosis | REPLACE | lockdown values/session result, with consumer-safe error mapping |
| `devicectl device install app` | Main and runner install/update | REPLACE | idevice AFC staging plus `utils::installation` / `InstallationProxyClient` |
| `devicectl device uninstall app` | Explicit IOSSim-only migration cleanup | REPLACE | `InstallationProxyClient.uninstall`, after the existing ownership allow-list |
| `devicectl device process launch` | First launch and runner-mapping verification | REPLACE | idevice CoreDevice/DVT process-control service; physical validation required |
| Xcode Accounts | Apple Account login, 2FA session, Personal Team discovery | REMOVE, BLOCKED | No documented non-Xcode free-team API. Do not import or scrape Xcode state |
| Xcode-created Apple Development identity | Certificate/private-key creation and reuse | REMOVE, BLOCKED for free team | Paid team uses local Keychain key/CSR plus documented API. Free-team issuance is private |
| Xcode-generated App IDs | Main and UI-test deterministic ID registration | REMOVE, BLOCKED for free team | Paid team uses documented bundle-ID API; free-team endpoint is private |
| Xcode device registration | Authorizes selected iPhone | REMOVE, BLOCKED for free team | Paid team uses documented device API; free-team endpoint is private |
| Xcode provisioning profiles | Main/runner profile issuance and renewal | REMOVE, BLOCKED for free team | Paid team uses documented profile API; free-team profile service is private |
| `/usr/bin/security` | Enumerates certificates/identities and accesses Keychain | NOT ACTUALLY REQUIRED FROM XCODE | Ordinary macOS tool; a native implementation should prefer Security.framework |
| `/usr/bin/codesign` | Inside-out artifact signing and verification | NOT ACTUALLY REQUIRED FROM XCODE | Ordinary macOS signing facility; retain direct use or move to Security.framework where appropriate |
| Xcode project/source at package build time | Produces canonical profile-free iPhone payloads | NOT ACTUALLY REQUIRED AT CONSUMER RUNTIME | Developer/release build concern; source/project is not packaged |

Repository development commands still use Xcode to compile the iPhone artifacts.
That is separate from the customer runtime requirement and must not be confused
with a zero-Xcode installed app.

## Apple Provisioning Classification

Apple's current account documentation states that a free account's Personal
Team App IDs, devices, certificates, and profiles are managed directly in Xcode,
with 10 App IDs, 3 devices, 3 apps per device, and seven-day expirations. Apple's
documented App Store Connect API can manage bundle IDs, certificates, devices,
and profiles for an Apple Developer Program team.

| Operation | Paid Developer Program team | Free Personal Team |
| --- | --- | --- |
| Authenticate | DOCUMENTED_SUPPORTED using App Store Connect API keys | REQUIRES_XCODE in Apple documentation; UNDOCUMENTED_BUT_OBSERVED elsewhere |
| Discover team | DOCUMENTED_SUPPORTED | REQUIRES_XCODE / UNKNOWN outside Xcode |
| Create/reuse certificate | DOCUMENTED_SUPPORTED | REQUIRES_XCODE / UNDOCUMENTED_BUT_OBSERVED |
| Register device | DOCUMENTED_SUPPORTED | REQUIRES_XCODE / UNDOCUMENTED_BUT_OBSERVED |
| Register bundle ID | DOCUMENTED_SUPPORTED | REQUIRES_XCODE / UNDOCUMENTED_BUT_OBSERVED |
| Issue/download profile | DOCUMENTED_SUPPORTED | REQUIRES_XCODE / UNDOCUMENTED_BUT_OBSERVED |
| Renew profile | DOCUMENTED_SUPPORTED | REQUIRES_XCODE / UNDOCUMENTED_BUT_OBSERVED |

Primary Apple sources:

- <https://developer.apple.com/help/account/basics/about-your-developer-account>
- <https://developer.apple.com/app-store-connect/api/>
- <https://developer.apple.com/documentation/appstoreconnectapi/profiles>
- <https://developer.apple.com/help/account/certificates/create-certificates/certificates-overview>

### Undocumented observed protocol family

Open-source AltSign/SideStore code demonstrates local Apple Account SRP/GrandSlam
authentication with anisette/device-attestation headers, followed by private
`developerservices2.apple.com/services/QH65B2/ios/*.action` requests. Observed
operations cover team lookup, certificates, devices, App IDs, and profiles.
This is evidence of feasibility, not an Apple-supported contract.

Observed sources:

- <https://github.com/rileytestut/AltSign/blob/master/AltSign/Apple%20API/ALTAppleAPI%2BAuthentication.m>
- <https://github.com/SideStore/apple-private-apis>
- <https://github.com/altstoreio/AltStore/issues/1772>

The flow can require password, trusted-device or SMS 2FA, an application token,
and anisette state. Sessions and protocol behavior are not documented. A recent
2026 report records a 2FA loop caused by Apple rejecting a stale emulated Xcode
client identity. SideStore also warns that shared anisette infrastructure can
trigger account security controls. Certificate/session limits and renewal
semantics are inferred from behavior rather than a stable contract.

IOSSim therefore does not implement or request Apple passwords/2FA through this
protocol in production. It does not send credentials to an IOSSim server, use a
third-party anisette service, copy Xcode cookies, or weaken 2FA. Any future POC
must be isolated, local-only, Keychain-backed, independently reviewed, and run
with a dedicated test Apple Account before product integration.

## Gate Status

| Gate | Status | Evidence |
| --- | --- | --- |
| A: discovery/lockdown pairing | MAPPED, NOT PHYSICALLY PROVEN | Pinned idevice exposes usbmuxd discovery, exact-device lookup, lockdown pair and session verify |
| B: free Apple auth/Personal Team | BLOCKED | No documented supported API; private alternative fails reliability/security acceptance |
| C-F: identity/device/IDs/profiles | BLOCKED BY B | Paid-team API route is documented; free-team route is private |
| G-H: inside-out signing | EXISTING XCODE-FALLBACK PROOF ONLY | Direct codesign logic exists, but native-issued profiles/identity are unavailable |
| I-J: native install/inventory | MAPPED, NOT BUNDLED OR PHYSICALLY PROVEN | idevice InstallationProxy/AFC APIs exist |
| K-M: runtime/Gate 3/Spoof/Rich Drive | NOT RUN FOR ZERO-XCODE | Frozen known-good runtime remains unchanged |

The correct verdict is `ZERO_XCODE_PERSONAL_TEAM_BLOCKED`, not PASS. Mocks,
source inspection, or a paid-team proof cannot satisfy the requested free-team
physical acceptance gate.

## Pairing Lifecycle

The pinned idevice source can perform lockdown pairing, validate the saved
record, create the iOS 17.4+ CoreDevice software tunnel, perform RPPairing, and
serialize the updated record. This makes a user-installed `idevicepair` binary
unnecessary in the target design.

The iPhone FFI now exposes `rp_pairing_file_to_bytes`. After a successful tunnel
operation, IOSSim serializes the possibly updated long-term RPPairing handle,
validates it, and updates the existing Keychain item. An invalid update cannot
replace the last usable record. The serialization contains the long-term host
identity and `alt_irk`; it does not persist ephemeral tunnel TLS secrets.

Mac-side generation, selected-device binding, AFC handoff, public-key
fingerprint metadata, and device-recognition proof remain unimplemented because
the physical POC stopped at Gate B. Structural plist validity alone is not
treated as proof.

## Signing, IDs, Profiles, and Refresh

The source IDs and deterministic Personal Team derivation remain frozen. A
future native backend must obtain the authoritative Team ID from Apple's
response, reuse an IOSSim-owned Keychain private key/certificate, validate the
selected device and certificate inside each decoded profile, sign nested code
inside-out, and preserve the existing source-to-installed main/UI-test/runner
mapping. It must never infer the Team ID from a certificate display name.

The existing 48-hour refresh policy and same-team derived IDs remain suitable.
Native refresh cannot be enabled until the same supported authentication and
profile issuance gates are solved. It must not create a new certificate each
week or revoke unrelated certificates.

## Security Model

- Apple passwords, 2FA codes, session cookies/tokens, private signing keys, raw
  pairing records, PSKs, and raw device IDs are excluded from logs/support data.
- Explicit `ZERO_XCODE` never executes Xcode tools and never falls back.
- Pairing data and future auth/session state belong in Keychain.
- Device selection is explicit when multiple devices are present; no operation
  may choose a different device.
- No executable is downloaded at runtime.
- The local RC remains `LOCAL_TEST_ONLY`.

## Physical Evidence and Limitations

No zero-Xcode physical evidence exists in this work. The investigation Mac
reported `xcodePresent=true`; `idevicepair` was absent, Homebrew happened to be
installed but was not used, and the native scaffold saw no connected device.
Gate 3, Spoof, Rich XCUILocation, Rich Drive, reboot persistence, same-profile
refresh, and the negative command telemetry therefore remain pending.

The proven Xcode-backed physical runtime evidence remains documented in
`PERSONAL_TEAM_PROVISIONING_POC.md` and was not reclassified as zero-Xcode proof.

