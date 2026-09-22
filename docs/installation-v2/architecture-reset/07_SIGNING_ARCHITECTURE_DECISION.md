# ADR: replace the production codesign identity path

- **Status:** PROPOSED, implementation requires explicit authorization
- **Decision:** Option D, a hybrid whose iOS payload signing core is Option C
- **Question:** Are we patching a fundamentally brittle signing architecture?
- **Answer:** **Yes.** The current production path should not survive as Veya's shipping signer.

## Context

The current design uses a dedicated Veya Keychain, permanent `SecKey`, imported certificate, `SecIdentity`, user search-list registration, `SecAccess` trusted applications, ChangeACL handling, partition-list repair through `/usr/bin/security`, and `/usr/bin/codesign`. Builds 1 and 7-11 encountered different failures within this boundary. Current source comments document the platform-specific ACL assumptions needed to make it work. Build 11 still failed before `KEYPAIR_CREATED`, and telemetry could not identify the first failing Security API.

The requirement is not merely “a key exists.” It is “the packaged app/helper can cause a separately launched Apple tool to use it, silently, across reinstall and upgrade, on clean Intel and Apple Silicon Macs.” That contract is unnecessarily broader than signing an iOS bundle.

## Options

| Criterion | A current dedicated Keychain + codesign | B improved isolated Keychain | C in-process signer | D hybrid |
| --- | --- | --- | --- | --- |
| consumer UX | poor until proven; prompt history | better, still OS ACL-sensitive | best potential | best potential |
| SecurityAgent risk | high | medium | none for signing | none for signing |
| login-Keychain dependency | legacy and global search-list interactions | can remove login compatibility but still Keychain mechanics | none for identity | only auth/pairing secrets |
| ACL/partition complexity | very high | high | none | none for signer |
| reinstall/key recovery | SecKey/metadata/keychain-file combinations | somewhat simpler | explicit encrypted blob + ledger | explicit per-domain recovery |
| certificate reuse/replacement | public-key match exists | same | direct public-key match | direct public-key match |
| multi-Mac | per-Mac key, confused legacy state | per-Mac key | explicit per-install key and remote marker | explicit per-install key |
| Apple compatibility | codesign is canonical but prompt-sensitive | same | must qualify apple-codesign output | dual verification during migration |
| security | nonexportable-ish key but wide process ACL | narrower ACL possible | exportable bytes require strong at-rest controls | encrypted blob; narrow signer API |
| implementation complexity | already large, recurring fixes | more Security framework work | Rust/Swift bridge and signing integration | highest transition cost, lower steady-state cost |
| migration | ongoing legacy repair | still repair old ACL/key states | one-time cryptographic migration/reissue | safest staged migration |
| testability | packaged OS behavior difficult | still difficult | excellent deterministic signer tests | excellent, plus migration lane |
| offline signing | yes while materials valid | yes | yes | yes |
| clean/package behavior | not proven | not proven | process-identity independent | process-identity independent |
| maintenance | high macOS-specific | high | dependency/security review | moderate after transition |

## Decision

Implement a hybrid:

1. A Rust in-process signing core, preferably using a pinned, reviewed `apple-codesign` implementation or a narrowly wrapped equivalent, signs main/runner/nested code from explicit inputs.
2. Veya stores RSA private-key bytes as an encrypted, versioned key blob protected by a Veya-owned generic-password/key-encryption secret. The raw key is never logged, journaled, exported to support bundles, or passed through CLI arguments.
3. The signer accepts a memory buffer/opaque handle and returns a signed-artifact manifest. It does not query user Keychains, mutate the search list, or spawn `codesign`/`security` in production.
4. Apple authorization sessions and RemotePairing secrets remain in domain-specific Keychain storage. “Hybrid” does not mean retaining SecIdentity for signing.
5. `/usr/bin/codesign` may be used as an independent qualification verifier on macOS, not as the production signing executor or readiness proof.
6. Existing ownership-safe certificate recovery remains, adapted to key fingerprints and explicit active/candidate records.

## Why not B

Option B can reduce prompt probability, but it cannot remove the second-process authorization contract. It would continue spending architecture on SecAccess, creator identity, trusted applications, partition semantics, search lists, packaged helper paths and repair behavior. The last eleven builds show that this is not a bounded one-time cost.

## Security requirements

- Per-install random wrapping secret stored with `ThisDeviceOnly`-appropriate Keychain accessibility where available.
- AES-GCM or equivalent authenticated encryption for a versioned PKCS#8 blob; atomic 0600 file in a 0700 Veya state directory.
- Minimal signer bridge with length bounds, zeroization where practical, no diagnostic dumps, and no key filenames in user-facing logs.
- Key never leaves process memory except encrypted at rest.
- Independent certificate/public-key and output-signature verification.
- No automatic certificate revocation without exact Veya ownership proof and inactive-key proof.

## Migration

Do not try to export legacy SecKeys unless a noninteractive, policy-approved export is reliably possible. Inventory the legacy metadata/key/cert and try a cryptographic proof. If the old path is usable, keep it only long enough to install a candidate signed by a newly issued in-process key. If unusable, use the ownership ladder to revoke exactly the owned inactive certificate if capacity blocks issuance. Never repair legacy ACLs as part of migration.

## Gates before removal

1. Synthetic nested app signs and independently verifies on both architectures.
2. Entitlements/profile/team/certificate checks match current strictness.
3. Actual signed apps install and launch on the supported iOS matrix.
4. Fresh/reuse/missing-key/missing-metadata/capacity/reinstall scenarios pass through production engine.
5. Packaged app on clean Intel and Apple Silicon Macs shows no SecurityAgent prompt.
6. A rollback build can continue using the prior active installed phone app without destroying legacy keys or certificates.

## Consequences

This is a material implementation change and introduces a supply-chain/security review for the signing library and key-at-rest design. It also deletes the dominant prompt class, makes the signer hermetically testable, removes global Keychain search-list mutation, and aligns the test contract with the actual operation Veya needs to perform.

