# Consumer Apple Authorization and Provisioning

Status: historical zero-Xcode investigation, superseded in part by the current
native Personal Team and physical-install stabilization handoff. See
[../CURRENT_STATE.md](../CURRENT_STATE.md) and
[../RELEASE_AND_DISTRIBUTION.md](../RELEASE_AND_DISTRIBUTION.md).

This report separates Apple's supported provisioning API, the strongest
headless Xcode path, and the experimental free Personal Team protocol. It does
not claim clean-Mac qualification. Later work physically proved native Personal
Team authorization/provisioning/signing/install on the current Mac/iPhone, but
the clean-Mac "Xcode installed, never opened/configured" claim is still
unproven.

## Architecture

The single product flow is:

`SwiftUI setup -> IOSSimMacCore -> Consumer backend selector -> provisioning/device backend -> selected iPhone`

Product preferences are `AUTO`, `XCODE_INVISIBLE`, and
`NATIVE_PERSONAL_TEAM`. Compatibility values `ZERO_XCODE` and
`XCODE_FALLBACK` remain development/recovery overrides. `AUTO` may choose only
a physically qualified native backend or a headless Xcode backend that can
bootstrap Apple authorization inside IOSSim. It no longer selects the manually
configured Xcode fallback merely because Xcode is installed.

`ApplePersonalTeamExperimental.swift` remains the replaceable private-protocol
boundary. `ApplePersonalTeamLive.swift` now implements its local live transport
through profile retrieval. It includes bounded HTTPS, Apple SRP-6a, trusted-
device verification, Xcode-scoped token decryption, Keychain session storage,
Developer Services operations, local key/CSR generation, selected-device and
derived-App-ID registration, CMS profile validation, and safe checkpoints.
Physical account/device proof later succeeded on the current Mac/iPhone. AUTO
and clean-Mac behavior still need qualification in the final consumer flow.

## Supported Apple Path

For paid Apple Developer Program teams, the App Store Connect API supports
bundle IDs, certificates, registered devices, and provisioning profiles. It is
authenticated with API-key-signed JWTs. The account holder or administrator
must first request API access and generate/download a team key in App Store
Connect; individual keys cannot use provisioning endpoints. This supports
managed paid-team automation, not the normal free-account login experience.

Sign in with Apple (`AuthenticationServices`) authenticates a person to an app's
service. It does not establish Xcode developer-account state or grant
Certificates, Identifiers & Profiles authority.

Primary Apple sources:

- <https://developer.apple.com/help/account/basics/about-your-developer-account>
- <https://developer.apple.com/app-store-connect/api/>
- <https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api>
- <https://developer.apple.com/documentation/appstoreconnectapi/profiles>

## Headless Xcode Path

Hard conclusion: `PATH_A_BLOCKED_AT_INITIAL_ACCOUNT_AUTH` for a brand-new free
Personal Team consumer.

Xcode 26.6's local `xcodebuild -help` says:

- `-allowProvisioningUpdates` creates/updates automatically managed profiles,
  App IDs, and certificates and downloads missing manual profiles;
- `-allowProvisioningDeviceRegistration`, used with the first flag, registers
  the destination device;
- authentication requires either a developer account already added in Xcode
  Accounts or an App Store Connect key supplied with
  `-authenticationKeyPath`, `-authenticationKeyID`, and
  `-authenticationKeyIssuerID`.

No supported `xcodebuild` option, public Xcode API, macOS authorization
framework, or delegated browser flow lets IOSSim submit a free Apple Account
login/2FA and create that initial Xcode account state. Existing automatic
signing is therefore headless only after a user has configured Xcode, which
fails the product criterion. GUI automation was not implemented.

Paid teams can use the API-key variant headlessly after an administrator creates
the key, but that remaining setup is inappropriate for the primary consumer.

## Experimental Private Personal Team Path

The LOCAL_TEST_ONLY build implements this private flow:

`GrandSlam SRP init/complete -> trusted-device or SMS 2FA -> Xcode-scoped GS token -> Developer Services session -> teams -> certificate -> device -> App IDs -> profiles`

The implemented API family is
`developerservices2.apple.com/services/QH65B2/.../*.action`. The reusable
session includes account-bound DSID and an Xcode-scoped GS token. Its lifetime
is taken from the returned token when supplied; IOSSim invents no expiry. Every
reuse is validated with a team-list request.
Passwords and 2FA codes are never reusable session state.

SRP uses RFC 5054's 2048-bit group with SHA-256, a 256-bit `SecRandom` client
secret, no username in `x`, and Apple's `s2k`/`s2k_fo` password preprocessing.
The password digest is processed with PBKDF2-HMAC-SHA256 using the server salt
and bounded iteration count. IOSSim validates `B`, the server SRP proof, the
GrandSlam negotiation proof, AES-CBC protected session data, and AES-GCM
protected app-token data. Password-derived buffers are wiped where Swift permits.

### Current implementation study

| Project | Latest inspected commit | License finding | Auth/provisioning design | Requirements and known fragility |
| --- | --- | --- | --- | --- |
| Signr | `8ea0a52`, 2026-07-21 | README says MIT; vendored `plume_core` declares MPL-2.0, so the tree is not uniformly MIT | Local SRP; trusted-device/SMS 2FA; GS token; teams, CSR/cert, devices, IDs, profiles, signing and InstallationProxy | Uses private macOS AOSKit anisette and hardcoded emulated Xcode client info; Xcode/Rust are build requirements |
| Riley Testut/AltSign | `1c44cfd`, 2020-07-24 | No license was relied upon; no source copied | Conceptual GrandSlam request/proof, 2FA and Developer Services field behavior | Historic implementation, used only to cross-check protocol shape |
| Dadoum/apple-crates | `a505b2a`, 2026-08-01 | Repository license files inspected; no source copied or linked | Maintained Rust GrandSlam and Xcode Developer Services behavior | Source for current Xcode 16.4 adapter identity and response models |
| attaswift/BigInt | `63feef7`, 2026-08-20 | MIT; notice packaged | Pure-Swift arbitrary precision integer arithmetic | Pinned source dependency; SRP protocol/derivation remains IOSSim code |
| Dadoum/Provision | `7717ce1`, 2025-06-23 | LGPL-2.0 | AuthKit-like local API and persisted ADI/device identity | Requires extracted Apple Android libraries; warns against primary accounts; former sideload code was removed |
| jkcoxson/idevice | IOSSim pin `c442bd2` | MIT | No Apple Account auth; device trust, RPPairing, AFC, InstallationProxy | Preferred IOSSim device transport; no external credential server |

No protocol implementation source from those projects was copied. BigInt is the
only new linked dependency and its MIT notice is packaged. IOSSim independently
implements the protocol and can now send the expected Apple requests.

Observed values are classified as:

- stable in concept: SRP challenge/response, explicit 2FA, account DSID, Xcode
  GS token audience, and provisioning resource operations;
- dynamic: SRP challenges, salt/iterations, anisette OTP, sessions,
  certificates, profiles, and response content;
- Apple-system-provided: AOSKit OTP/machine data and macOS AuthKit generic headers;
- derived locally: local-user header from the system machine UUID, current time,
  locale, timezone, model/OS/build client description, SRP/CSR material;
- version-bound: Xcode/AuthKit client information, user-agent behavior, and the
  AOSKit production routing value isolated in the machine adapter;
- machine-bound: anisette device/local-user/machine identifiers and ADI;
- account-bound: DSID, GS token, teams, certificates, devices, IDs and profiles.

A SideStore report dated 2026-08-31 shows GrandSlam succeeding while the
`com.apple.gs.xcode.auth` application-token request returned HTTP 503 across
multiple anisette sources. This is direct current evidence that the private
path is too fragile to claim an IOSSim authorization POC without physical IOSSim
evidence.

Observed sources:

- <https://github.com/rursache/Signr>
- <https://github.com/SideStore/AltSign>
- <https://github.com/SideStore/SideStore/issues/1446>
- <https://github.com/altstoreio/AltStore/issues/1772>
- <https://docs.sidestore.io/docs/advanced/anisette>
- <https://github.com/Dadoum/Provision>

## Dependency Audit

| Dependency | Operation | Classification | Replacement/disposition |
| --- | --- | --- | --- |
| Full Xcode | SDK/platform, stored account, signing, CoreDevice | PATH A hidden dependency | Acceptable only if initial account auth becomes headless; currently blocked |
| `xcodebuild` | IDs, certs, device, profiles | XCODE_INVISIBLE candidate / DEVELOPMENT FALLBACK | Fully automates after supported account or API-key auth exists |
| `xcrun`/`devicectl` | device operations | Allowed for XCODE_INVISIBLE; remove for native | Pinned idevice bridge |
| Xcode Accounts | initial Apple login and 2FA | PATH A BLOCKER | No supported headless bootstrap; do not scrape/import private Xcode state |
| Apple development identity | certificate/key | Native replacement | Keychain RSA key, local CSR, IOSSim ownership metadata, public-key-matched certificate reuse/issuance |
| Xcode App IDs/device/profile | provisioning resources | Native replacement | Live versioned private Developer Services adapter through validated profiles |
| BigInt | SRP modular arithmetic | MIT Swift package pinned to `63feef7` | Source-linked at build; no runtime service; notice packaged |
| `/usr/bin/security` | Keychain/cert inspection | Ordinary macOS | Prefer Security.framework for secrets |
| `/usr/bin/codesign` | inside-out signing | Ordinary macOS | Existing signing order retained; no `--deep` shortcut |
| repo/Xcode project | build canonical artifacts | Release engineering only | Not packaged or needed at customer runtime |

Native device-operation mapping:

| Operation | Pinned idevice capability |
| --- | --- |
| enumerate/select | usbmuxd exact-device enumeration |
| trust/pair/state | lockdown pair/validate/session |
| inventory | InstallationProxy browse/get-apps |
| staging | AFC/PublicStaging |
| install/update | InstallationProxy install |
| IOSSim-only uninstall | InstallationProxy uninstall behind existing ownership allow-list |
| container handoff | HouseArrest/AFC when required |
| RPPairing | remote pairing plus serialized long-term state |

## Consumer UI

The current production setup page no longer instructs consumers to open Xcode,
choose a Personal Team, or manage certificates. It presents Apple Account and
password fields, an Apple verification-code state, and a concise privacy
disclosure. Password and verification bindings are cleared immediately after
conversion to wipeable buffers. One authoritative Personal Team is selected
automatically; ambiguous teams can be selected without certificate/profile
terminology.

Only the separately compiled LOCAL_TEST_ONLY RC selects the native backend by
default and shows an unmistakable experimental badge and safe stage. It runs
authorization through profiles in one attempt. Normal builds keep AUTO and do
not select the unproven backend. The Xcode fallback remains available only as
an explicit development/recovery override.

## Security and Session Model

- Passwords and 2FA codes are memory-only, non-Codable inputs and are wiped
  after each operation as far as Swift's memory model permits.
- Passwords, 2FA, headers, cookies, tokens, private keys, raw auth responses,
  pairing records, TLS secrets, and raw device IDs are excluded from logs and
  support bundles.
- Authorization/cookie/Apple GS/anisette/session headers and labeled 2FA codes
  are explicitly redacted with no debug bypass.
- Opaque minimum session state uses a non-synchronizing, this-device-only
  Keychain item. Support
  export reads only safe metadata: method category, valid boolean, client
  adapter version, expiry, backend and last stage.
- No IOSSim credential server, third-party anisette server, Xcode-state theft,
  UI automation, or security bypass exists.
- Responses use normal platform TLS and must use expected Apple HTTPS hosts,
  status, content types and strict streaming size limits, and
  pass team/profile/resource validation.
- Creation operations are represented as read-before-create backend calls;
  rate limits and non-idempotent operations are not blindly retried.
- No executable code is downloaded at runtime.

## Provisioning, Refresh, and Repair Contract

The live coordinator now covers steps 1-7; mocks retain regression coverage for
the complete contract:

1. session resume or Apple Account authorization;
2. legitimate trusted-device verification (SMS phone selection remains pending);
3. authoritative Personal Team preference;
4. Keychain identity reuse or local CSR/certificate creation;
5. selected-device registration;
6. existing deterministic ID registration;
7. main/runner profile retrieval and validation;
8. inside-out signing;
9. installation and exact inventory verification;
10. selected-device pairing verification.

Refresh reuses session, signing identity, team, deterministic IDs and pairing.
The existing 48-hour threshold remains. Session expiration preserves the key
and installed state and requests Apple authorization again.

Repair selects only the first broken prerequisite: reauthorize, refresh
profiles, reinstall main, reinstall runner, or repair pairing. It does not
destroy unrelated settings or identities.

## Pairing Lifecycle

The pinned idevice source provides lockdown pairing, remote pairing, AFC and
InstallationProxy operations. A user-installed `idevicepair` executable is not
part of the architecture.

The iPhone FFI serializes RPPairing state updated during tunnel creation,
validates it, and atomically updates its Keychain record. Invalid updates cannot
replace the last usable record, and ephemeral tunnel TLS secrets are not
persisted. Mac-side generation, secure handoff and selected-device physical
verification remain pending.

## Gate Status

| Gate | Status |
| --- | --- |
| Path A initial auth | `PATH_A_BLOCKED_AT_INITIAL_ACCOUNT_AUTH` |
| Path A remaining provisioning | Existing headless-capable machinery after auth; not a brand-new-user solution |
| Path B local machine identity | Live AOSKit/AuthKit adapter; credentials-free probe passed on macOS 26.6.2 |
| Path B Apple auth/2FA | Live SRP and trusted-device 2FA implementation; current-Mac/iPhone proof exists, clean-Mac proof pending |
| Path B session/team | Live Xcode-scoped token and team discovery; current-Mac/iPhone proof exists, clean-Mac proof pending |
| Path B cert/device/IDs/profiles | Live read-before-create operations and strict validation; current-Mac/iPhone proof exists, clean-Mac proof pending |
| Native signing/install/pair | Native signing and `devicectl` install are proven on current Mac/iPhone; native macOS idevice install backend remains unimplemented |
| Gate 3/Spoof/Rich XCUILocation/Rich Drive | Proven in earlier runtime/Personal Team cycles; current stabilization RC runtime requalification pending |

## Physical Evidence and Limitations

This investigation did not itself produce qualifying account or physical-iPhone
evidence. Later work did produce current-Mac/iPhone evidence for live Personal
Team authorization, provisioning, native signing, main install, runner install,
developer-profile trust handling, and setup completion. It still did not prove
clean-Mac, Xcode-never-opened behavior, true profile renewal, public
distribution, or a native macOS idevice install backend.

Current verdict for this historical document: superseded by
`docs/CURRENT_STATE.md`. Current RC classification remains `LOCAL_TEST_ONLY`.
