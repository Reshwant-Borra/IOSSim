# Consumer Apple Authorization and Provisioning

Status: `PRIVATE_PERSONAL_TEAM_FRAGILE` (isolated engineering POC, 2026-09-07).

This report separates Apple's supported provisioning API, the strongest
headless Xcode path, and the experimental free Personal Team protocol. It does
not claim physical qualification. The investigation Mac has Xcode installed and
no connected qualification iPhone.

## Architecture

The single product flow is:

`SwiftUI setup -> IOSSimMacCore -> Consumer backend selector -> provisioning/device backend -> selected iPhone`

Product preferences are `AUTO`, `XCODE_INVISIBLE`, and
`NATIVE_PERSONAL_TEAM`. Compatibility values `ZERO_XCODE` and
`XCODE_FALLBACK` remain development/recovery overrides. `AUTO` may choose only
a physically qualified native backend or a headless Xcode backend that can
bootstrap Apple authorization inside IOSSim. It no longer selects the manually
configured Xcode fallback merely because Xcode is installed.

`ApplePersonalTeamExperimental.swift` is the replaceable private-protocol
boundary. It contains a versioned endpoint adapter, wipeable password and 2FA
input, a this-device-only Keychain session store, authoritative team/profile
validation, the complete provisioning coordinator contract, strict install
inventory checks, and a narrow repair planner. Its live transport remains
unavailable until the cryptographic/authentication implementation is physically
tested. Mocks exercise the contract but do not qualify it.

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

Current maintained implementations show this private flow:

`GrandSlam SRP init/complete -> trusted-device or SMS 2FA -> Xcode-scoped GS token -> Developer Services session -> teams -> certificate -> device -> App IDs -> profiles`

The observed API family is
`developerservices2.apple.com/services/QH65B2/.../*.action`. The reusable
session includes account-bound DSID and an Xcode-scoped GS token. Its lifetime
is undocumented and should be tested with an innocuous team-list request.
Passwords and 2FA codes are never reusable session state.

### Current implementation study

| Project | Latest inspected commit | License finding | Auth/provisioning design | Requirements and known fragility |
| --- | --- | --- | --- | --- |
| Signr | `8ea0a52`, 2026-07-21 | README says MIT; vendored `plume_core` declares MPL-2.0, so the tree is not uniformly MIT | Local SRP; trusted-device/SMS 2FA; GS token; teams, CSR/cert, devices, IDs, profiles, signing and InstallationProxy | Uses private macOS AOSKit anisette and hardcoded emulated Xcode client info; Xcode/Rust are build requirements |
| SideStore/AltSign | `35b68f1`, 2026-08-26 | No root license in the inspected fork; dependencies have separate licenses | SRP/2FA/anisette, stored application token, full refresh flow | Frequently uses anisette infrastructure; issue #1446 reports current Xcode-token HTTP 503 failures |
| Dadoum/Provision | `7717ce1`, 2025-06-23 | LGPL-2.0 | AuthKit-like local API and persisted ADI/device identity | Requires extracted Apple Android libraries; warns against primary accounts; former sideload code was removed |
| jkcoxson/idevice | IOSSim pin `c442bd2` | MIT | No Apple Account auth; device trust, RPPairing, AFC, InstallationProxy | Preferred IOSSim device transport; no external credential server |

No source from those projects was copied, linked, or distributed. IOSSim's
adapter records only the independently observed protocol shape and validation
rules; it currently sends no Apple request.

Observed values are classified as:

- stable in concept: SRP challenge/response, explicit 2FA, account DSID, Xcode
  GS token audience, and provisioning resource operations;
- dynamic: SRP challenges, salt/iterations, anisette OTP, sessions,
  certificates, profiles, and response content;
- version-bound: Xcode/AuthKit client information and user-agent behavior;
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
| Apple development identity | certificate/key | Native replacement | Keychain key, CSR, list/reuse IOSSim identity; live issuance pending |
| Xcode App IDs/device/profile | provisioning resources | Native replacement | Private Developer Services adapter; live transport pending |
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

Because no live backend is qualified, authorization currently fails safely with
"IOSSim couldn't prepare Apple authorization". It does not pretend setup
succeeded or route AUTO users to Xcode. The manually configured path remains
only through the development `XCODE_FALLBACK` override.

## Security and Session Model

- Passwords and 2FA codes are memory-only, non-Codable inputs and are wiped
  after each operation as far as Swift's memory model permits.
- Passwords, 2FA, headers, cookies, tokens, private keys, raw auth responses,
  pairing records, TLS secrets, and raw device IDs are excluded from logs and
  support bundles.
- Authorization/cookie/Apple GS/anisette/session headers and labeled 2FA codes
  are explicitly redacted with no debug bypass.
- Future opaque session state uses a this-device-only Keychain item. Support
  export reads only safe metadata: method category, valid boolean, client
  adapter version, expiry, backend and last stage.
- No IOSSim credential server, third-party anisette server, Xcode-state theft,
  UI automation, or security bypass exists.
- Responses must use expected HTTPS hosts, status, content types and size, and
  pass team/profile/resource validation.
- Creation operations are represented as read-before-create backend calls;
  rate limits and non-idempotent operations are not blindly retried.
- No executable code is downloaded at runtime.

## Provisioning, Refresh, and Repair Contract

The mocked coordinator covers:

1. session resume or Apple Account authorization;
2. legitimate trusted-device/SMS verification;
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
| Path B Apple auth/2FA | Isolated interface, validation and mocks; live SRP/anisette transport absent |
| Path B team/cert/device/IDs/profiles | Complete mocked coordinator; live requests absent |
| Native signing/install/pair | Contracts/mappings only; no Mac host FFI implementation or physical proof |
| Gate 3/Spoof/Rich XCUILocation/Rich Drive | Not run for either new backend |

## Physical Evidence and Limitations

No qualifying physical evidence was produced. Xcode is installed on this Mac,
Homebrew happens to be installed, external `idevicepair` is absent, and no
physical iPhone is connected. The proven manually configured Xcode runtime
evidence remains baseline evidence only; it was not reclassified as headless or
native consumer proof.

Current verdict: `PRIVATE_PERSONAL_TEAM_FRAGILE`. The local package remains
`LOCAL_TEST_ONLY`.
