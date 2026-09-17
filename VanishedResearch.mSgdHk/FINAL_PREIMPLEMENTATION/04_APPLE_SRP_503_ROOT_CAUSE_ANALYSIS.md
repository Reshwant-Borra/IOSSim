# Apple SRP HTTP 503 Analysis

## Current Sequence

LiveApplePersonalTeamBackend trims/lowercases account, keeps password only in sensitive memory, snapshots machine metadata, sends GrandSlam init as XML plist to GSA, parses salt/B/protocol, computes Apple SRP, completes with cookie/c/M1, verifies M2, decrypts SPD, performs 2FA, requests Xcode-scoped app token and then Developer Services. The SRP implementation is RFC5054-style N2048/g2/SHA-256 with s2k raw SHA-256 or s2k_fo lowercase-hex PBKDF input, fixed-width fields, H(N) xor H(g), H(username), M1/M2 and SPD decryption. Local primitive tests exist.

HTTP uses ephemeral URLSession, cookies disabled, TLS validation, host allowlist and bounded timeouts. Current AOSKit path constructs an AKD identity: model, macOS version/build, com.apple.AuthKit/1 (com.apple.akd/1.0). AuthKit fallback returns raw headers and can omit or replace client-info; the final request may fall back to an unsuitable AuthKit user-agent. The fixed GSA endpoint is used rather than a current URL-bag lookup. Two-factor validation is currently POST in Live backend; current references use GET for trusted-device validation.

## Exact IOSSim Wire Contract

| Stage | Method/endpoint | Body/request fields | Important headers | Response consumed |
|---|---|---|---|---|
| SRP init | POST fixed https://gsa.apple.com/grandslam/GsService2 | Header.Version 1.0.1; Request A2k, ps=[s2k,s2k_fo], cpd, u, o=init | Content-Type/Accept text/x-xml-plist; X-MMe-Client-Info; User-Agent; X-Apple-Client-App-Name=Xcode; MD/MD-M/RINFO/Device-Id | Response.Status, sp, s, B, c, i |
| SRP complete | same POST; Connection close | M1, c, same cpd/u, o=complete | same | Status, M2, spd, np, sc |
| trusted-device code request | GET fixed request endpoint | none | identity token plus machine metadata | success/error plist |
| trusted-device validate | current POST fixed validate endpoint | security-code header | identity token, app/version headers | status plist |
| app tokens | GSA appTokens operation | dsid, audience, checksum, c/t/cpd/o | X-Apple-App-Info audience, X-Xcode-Version, identity | encrypted token payload |
| Developer Services | POST developerservices2 services path | plist clientId, protocolVersion, request UUID, locale, operation data | xcode token, dsid, machine metadata | teams/devices/certs/App IDs/profiles |

Current cpd values are bootstrap=true, icscrec=true, pbe=false, prkgen=true, svct=iCloud and locale, with X-Apple-I-Client-Time, X-Apple-Locale, X-Apple-I-TimeZone, MD, MD-LU, MD-M, RINFO, Mme-Device-Id and serial copied when present. AOSKit maps raw MD names into the expected X-Apple-I-* names, uses RINFO 84215040 and supplies machine UUID/serial. AuthKit dynamically provisions Anisette and returns its headers. Final normalization must validate presence and types rather than silently fill made-up values.

## SRP Field-Level Parity

| Primitive | IOSSim | current public references | Assessment |
|---|---|---|---|
| N/g/hash | RFC 5054 2048-bit group, g=2, SHA-256 | same | CONFIRMED parity |
| private a | 32 random nonzero bytes | 32-byte/random client secret | parity |
| A encoding | fixed 256-byte unsigned big-endian | implementations vary minimal/fixed at API boundary; XKit calculates padded hashes | retain current vectors; not init-503 cause |
| k/u | hash of 256-byte padded group elements | same mathematical rule | parity |
| protocol choice | advertises s2k and s2k_fo, accepts server sp | same | parity |
| password prehash | SHA-256(password UTF-8 bytes) | same | parity |
| s2k_fo | lowercase hex ASCII of prehash | same | parity |
| PBKDF | HMAC-SHA256, server salt/iterations, 32 bytes | same | parity |
| x | H(salt || H(colon || derived key)); no username in x | same Apple mode | parity |
| shared secret | fixed 256-byte encoding before SHA-256 | current IOSSim fixture establishes intended CoreCrypto parity | preserve/test |
| M1 | H(H(N) xor H(PAD(g)) || H(account) || salt || PAD(A) || PAD(B) || K) | equivalent current references | parity |
| M2 | H(PAD(A) || M1 || K), constant-time check | equivalent | parity |

The code caps account/password/challenge sizes and rejects B mod N=0, u=0, unreasonable iterations and malformed proofs. These are sound protections. Debug parity traces contain secrets and must remain DEBUG-only, never enter support exports or release logging.

## Reference Difference Table

| Field | IOSSim | isideload release | xtool XKit | Importance |
|---|---|---|---|---|
| Endpoint | fixed GsService2 | URL-bag lookup | URL-bag lookup | medium |
| X-MMe-Client-Info | AOSKit AKD, fallback risk | explicit AKD | current request-specific identity | high |
| Xcode token | possible stale/fallback | no com.apple.dt.Xcode token | request-specific | high |
| X-Xcode-Version | later paths | current | current | medium |
| X-Apple-App-Info | later paths | auth context | request-specific | medium |
| Cookies | disabled | no cookie jar | request state | low for init |
| SRP | N2048/g2/SHA256 | same | same | low for pre-challenge 503 |
| Pooling | bounded connection pool | release disables idle pooling after 429 | implementation-specific | only post-init |
| Anisette | AOSKit then AuthKit | remote provider | local/remote | medium |
| 2FA validation | POST | GET security-code | URL-bag operation | high after init |

September reports are strong and specific: [isideload PR 11](https://github.com/nab138/isideload/pull/11) reports Apple edge rejection of com.apple.dt.Xcode in X-MMe-Client-Info and successful auth after changing to com.apple.akd/1.0; [AltStore PR 1790](https://github.com/altstoreio/AltStore/pull/1790) reports UA, OS/hardware, HTTP version, connection reuse and edge changes did not solve it. Current IOSSim source includes the correction, so a stale packaged provisioner, AuthKit fallback, adapter overwrite or request serialization difference is the leading explanation.

## Ranked Hypotheses

H1 wrong/stale emitted client-info: highest, STRONG_EVIDENCE. Test final outbound header family/hash/length against reference without secrets. Fix final normalizer and reject com.apple.dt.Xcode.

H2 fixed endpoint: medium, LIKELY. Test URL-bag lookup versus fixed endpoint with sanitized report. Fix URL-bag and host allowlist.

H3 malformed/missing Anisette: medium-low, LIKELY. Test field names/formats/lengths and hashes only. Fix provider normalization; never invent values.

H4 edge/rate limit: possible, weaker. Test bounded retry, Retry-After, request correlation and time separation. Do not credential-retry storms.

H5 SRP/body: low for init 503 because proof is later; test only once init reaches challenge.

H6 stale session/account: low before challenge; classify rather than erase all Keychain session on any team-list failure.

HTTP 503 is currently mapped to serviceUnavailable/retryable rather than generic network failure, which is correct. It may be Apple backend unavailability, rate limiting presented noncanonically, an edge rejection, or invalid client metadata. The response’s small HTML body/Apple Server header does not by itself distinguish those cases. Location in the sequence does: an init failure precedes password proof and provisioning, so proof math, team state and certificate state cannot be the immediate cause.

## Decision

Keep IOSSim auth. Its SRP, SPD, 2FA and Developer Services implementation is substantially complete, and no evidence justifies replacing it with pmd3 or XcodesLoginKit. Change the request adapter: URL-bag endpoint, final AKD identity normalizer, raw AuthKit header normalization, redirect credential stripping, GET trusted-device validation, transient session classification and a safe diagnostic harness. This is a bounded stale-protocol fix, not a new auth stack.

Migration boundary: retain AppleSRPClient, LiveSessionEnvelope, Keychain session store, app-token decryption, Developer Services request/response models, CSR and signing identity code. Replace only GrandSlam endpoint resolution, GrandSlamRequestIdentity construction, machine-header normalization, trusted-device validation transport and HTTP/session error classification. If the current request still fails after exact parity with both current references, a maintained module replacement can be reconsidered at the GrandSlamClient boundary without rewriting signing/provisioning.

## Safe Harness

Extend IOSSimAuthDiagnostic and diagnoseSRPInitialization. Accept account/password only through protected input; log status, allowlisted endpoint, header names, token family, booleans, lengths, non-secret hashes, body field names/types/lengths, response fields/headers and Retry-After. Never log password, salt, A/B/M1/M2/SRP secrets, cookies, identity/app tokens, pairing or private keys. Never disable TLS. Compare normalized records with a known-working reference. AUTH GATE is challenge/2FA/team response rather than init 503; this research did not execute it.
