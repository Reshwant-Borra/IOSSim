# Security Threat Model

## Assets and trust boundaries

Assets: signing private key, Apple session, pairing record, wrapping key, profiles, journal promotion authority, DDI/TSS artifacts, payload source/candidate, diagnostics. Boundaries: UI -> provisioner, Swift -> Rust FFI, local filesystem -> Keychain, Mac -> Apple, Mac -> iPhone, build -> packaged artifact.

| Threat | Control | Residual risk / required test |
|---|---|---|
| Copied/stolen state directory | AES-GCM key ciphertext; wrapper ThisDeviceOnly | live same-user compromise; copy test cannot decrypt |
| Apple session theft | data-protection Keychain, provisioner-only access, no password | compromised process/session replay; invalidation tests |
| Malicious local process | file modes, designated requirement, no secret IPC/files | same-UID debugging remains; document limitation |
| World-readable/symlink state | `0700/0600`, owner checks, `O_NOFOLLOW` | filesystem policy variance; adversarial tests |
| Support/log leakage | denylist + typed safe fields + canary scanning | new library errors; CI secret scan |
| Pairing material theft/replay | Keychain, encrypted one-time envelope, nonce/device/generation | phone compromise; replay/wrong-device tests |
| Profile leakage | profiles treated sensitive; excluded/redacted | profile necessarily embedded in installed app |
| Ownership spoofing | SPKI challenge + team/serial/server evidence | stale Apple inventory; refresh and ambiguity stop |
| Rollback attack | monotonic schema/generation, artifact hashes, newer-schema read-only | malicious journal deletion; external re-observation |
| Journal corruption/promotion spoof | lock, atomic fsync/rename, digest, proof references | disk/hardware loss; reconstruction is conservative |
| Helper impersonation | packaged path/hash/code requirement + protocol/ABI | compromised signed app; artifact gate |
| TOCTOU candidate swap | same-volume fd/path checks, digest before/after signing/install | filesystem race; swap injection tests |
| Multi-user Mac | per-user state/Keychain/installation ID | shared device/account capacity interactions |
| Second Mac | independent keys, owned-only revocation | capacity can require manual action |
| Keychain reset | wrapper loss classification, active preservation | key unrecoverable; replacement required |
| Malicious signer input | bounded graph/parser, staging sandbox, Rust panic containment | parser vulnerabilities; fuzzing/dependency audit |

## Old versus target

Old architecture exposed a nonexportable signing key to an external `codesign` process via fragile ACL/search-list/partition configuration and persisted Keychain passwords/files. The target accepts exportable PKCS#8 in Veya memory, increasing memory-exfiltration impact, but encrypts it at rest and eliminates broad external-process authorization. The trade is acceptable only with provisioner-only access, zeroization, no IPC plaintext, real no-prompt tests, hardened artifact verification, and signer supply-chain review.

Secure Enclave is not an available drop-in because the selected signer and Personal Team flow require RSA PKCS#8/in-memory signing. Apple session and signing wrapper must use separate Keychain services/keys. Compromise of one must not decrypt the other.

## Security verdict

Design is stronger and more predictable than the old path, with two implementation blockers: prove data-protection Keychain access across packaged upgrades/architectures without UI, and audit/fuzz the exact signer version against Veya bundle fixtures. Failure of either reopens architecture review; insecure fallback is not permitted.

