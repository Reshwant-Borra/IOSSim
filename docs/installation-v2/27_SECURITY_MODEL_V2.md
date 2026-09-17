# Security model V2

## Assets and threats

Protected assets are Apple credentials/session tokens, signing/private pairing keys, device identifiers, profiles, DDI tickets/assets, signed payloads, release identity, VPN/runtime mapping, and route/location data. Threats include helper substitution, path/environment injection, cross-device operation, replayed pairing/VPN files, destructive repair, concurrent helpers, malicious/corrupt state, untrusted update artifacts, server response changes, support overcollection, and secret-bearing crash/log output.

## Trust boundaries and controls

| Boundary | Controls |
| --- | --- |
| GUI -> helper | embedded fixed path, signature/hash/schema handshake, bounded versioned pipe JSON, operation IDs |
| helper -> native bridge | manifest path/hash, C ABI version, typed lengths, no arbitrary dylib override in production |
| helper -> Apple | TLS validation, host allowlist, redirect policy, response size/schema bounds, adapter version/kill switch |
| helper -> device | exact device hash + mux handle + connection type on every call; reject first-UDID ambiguity |
| Mac -> phone files | House Arrest allowlisted names, request ID/expiry, AEAD/AAD, one-use bootstrap, bounded size |
| persistent state | 0700 directories, 0600 files, Keychain secrets, OS file lock, journal/CAS, atomic replacement |
| release/update | Developer ID/notarization plus signed content manifest, artifact-derived hashes/schemas/architectures |

Production rebuilds a small environment and rejects `DYLD_*`, `DEVELOPER_DIR`, proxy overrides for credential calls, `RUST_LOG`, arbitrary `PATH`, bridge/helper overrides, and repository roots. Temporary directories are private and path-contained; archive extraction rejects traversal/symlink escapes.

## Logging and support

Events are redacted at creation. The support exporter serializes a new allowlist DTO rather than full persistence structs. It includes release versions/hashes, state/reason enums, stage timings, retry counts, OS/device model class, salted per-export device/team/fingerprint aliases, public expiry classes, DDI provenance IDs/digests, and runtime aggregates. It excludes passwords, 2FA, DSID, tokens/cookies, anisette/SRP bytes, private keys, pair records/PSKs, raw IDs, profile blobs, TSS tickets, VPN secrets, DDI contents, raw server bodies, environment, and coordinates.

A post-export scanner searches filenames and content for known secret fields, plist profile/pairing signatures, PEM/private-key markers, raw current identifiers, tokens, cookies, and absolute home paths; any hit aborts export. Salt is random per export so bundles cannot be correlated by stable hashes.

## Fail-closed rules

Integrity/schema/protocol incompatibility, wrong identity, stale generation, unknown LocalDevVPN version, unapproved DDI source, or release mismatch forbids mutation. Existing installed runtime is preserved where safe, but the setup UI does not call it READY without current proof.
