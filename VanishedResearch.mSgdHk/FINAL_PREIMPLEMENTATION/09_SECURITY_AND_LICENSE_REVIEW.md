# Security and License Review

This is engineering diligence, not legal advice. Obtain legal review before distribution.

Passwords and 2FA are ephemeral; no UI snapshots, journals, logs or crash reports. Apple sessions and signing key references are Keychain protected. Signing keys are non-exportable where possible. Pairing private data is Keychain protected; journal/support contain only references and fingerprints. Envelopes are authenticated, one-time and deleted. Support allows only status, versions, reason codes, lengths, safe hashes and timestamps; never credentials, tokens, cookies, private keys, pairing bytes, SRP data, DDI payloads or raw coordinates.

Provisioner and Rust bridge are signed, notarized and covered by a signed manifest with architecture hashes and schema. Rust receives typed calls only, allowlists paths/hosts, bounds time/bytes/retries and filters tracing. Updates are signed and schema-compatible.

Dependencies: idevice 0.1.67 MIT; transitive crates need SPDX/SBOM audit. pmd3 11.12.5 GPL-3.0-or-later and excluded from consumer; subprocess isolation does not automatically eliminate obligations. libimobiledevice LGPL-2.1 requires dynamic/static compliance review. BigInt and reference Swift projects are MIT. DeveloperDiskImage code is GPL, while Apple image payload rights are separate. AOSKit/AuthKit are system/private runtime components; do not copy frameworks. Include notices and seek counsel on static linking, LGPL, Apple assets, private APIs and Apple service terms.

## Distribution Matrix

| Component | Static link | Dynamic link | Bundled subprocess | Attribution/source/modification concern | Decision |
|---|---|---|---|---|---|
| idevice MIT | permitted subject to license notice | permitted | permitted | include copyright/license; audit all transitive crates and modifications | recommended static ABI |
| Rust transitive crates | depends on exact Cargo.lock | depends | depends | generate SPDX/SBOM, license texts and vulnerability report for every release | mandatory release gate |
| pymobiledevice3 GPL-3.0-or-later | creates serious copyleft compatibility question | still GPL-covered distribution | separate process does not automatically remove GPL distribution/source obligations or combined-work risk | provide corresponding source/license where required; product-license counsel | excluded from consumer |
| libimobiledevice LGPL-2.1 | likely requires relinkable objects or other compliance mechanism | replacement-friendly linking generally simpler | executable tools may carry different GPL licenses | notices, library source/modification offer and relinking analysis | optional only after counsel |
| BigInt MIT | already linked | n/a | n/a | retain existing notice | keep |
| isideload/xtool/XcodesLoginKit | not linked | not linked | not shipped | source references only; any future code reuse needs copyright/license tracking | research only |
| pmd3 DeveloperDiskImage Python package | GPL code not linked | not linked | not shipped | package license does not license Apple payloads | research only |
| Apple DDI/trust cache/BuildManifest | rights independent of wrapper/link mode | same | downloaded asset | Apple agreements and redistribution/runtime-download rights need actual legal review | provider gated |
| macOS AOSKit/AuthKit | cannot redistribute copied framework | dynamically loaded system copy | n/a | private API/review/service-terms and OS compatibility risk | existing use, legal/product review |

This table deliberately avoids a legal conclusion about whether a subprocess forms a combined work. Engineering should not choose a GPL helper on the assumption that IPC settles that question.

## Credential and Process Threat Model

Threats include accidental structured-log capture, crash dumps, helper substitution, IPC replay, wrong-device operation, pairing envelope replay, malicious app-container paths, redirect leakage, support archive overcollection and stale signed updates. Controls are typed/redacted events at creation, code-signature/hash verification, per-operation UUID/nonces, immutable DeviceToken, path enums rather than strings, HTTPS host allowlists, no cross-host sensitive redirects, bounded byte parsing and signed atomic updates.

The provisioner’s environment is rebuilt from a small allowlist and must not inherit DEVELOPER_DIR, DYLD insertion variables, RUST_LOG, proxy variables for Apple credential requests, or arbitrary PATH entries. It opens only known Keychain access groups and resource paths. If a subprocess remains for the signed provisioner, SwiftUI sends length-bounded versioned JSON over inherited pipes; no listening unauthenticated local socket.

## Support Bundle Allowlist

Allowed: app/provisioner/bridge versions and hashes; macOS/iOS versions; model class; redacted device hash; domain state/reason; stage timing; retry counts; safe HTTP status/content type/Retry-After; artifact/profile public IDs and expiries; certificate public fingerprint; DDI build/digests; pairing public fingerprint; runtime stage/cadence aggregates. Denied: account name, password, 2FA, DSID, GS/app tokens, cookies, anisette values, SRP bytes, signing/private pairing keys, raw pairing plist, full device IDs, VPN secrets, DDI contents and route coordinates.
