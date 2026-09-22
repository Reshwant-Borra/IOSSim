# Signing Migration Specification

## Principle

Migration is candidate-first. Legacy state is read-only evidence; the new signer is proven before any legacy item is retired. There is no automatic fallback from new signing to legacy signing.

## Discovery inventory

The migration reader records, without changing state:

- login-Keychain labels/application tags and legacy service `com.iossim.mac.personal-team-signing`;
- dedicated `Veya-Signing.keychain-db` SecKeys/SecIdentities;
- `Application Support/IOSSim/signing-metadata-v1` and secret/keychain metadata;
- Apple certificate inventory, serials, expiration, and public keys;
- active installed payload/profile and current signing certificate;
- journal-free legacy provisioning manifests.

Each item is classified `absent`, `readable`, `nonExportable`, `promptRequired`, `ambiguous`, or `corrupt`. Discovery uses `kSecUseAuthenticationUIFail`; migration must never trigger SecurityAgent.

## Ownership and import

An export is safe only when all are true: exactly one private key matches the certificate public key; noninteractive `SecItemCopyMatching(...returnData)` succeeds; metadata team/serial agrees with Apple inventory; and a local challenge signature verifies. The exported bytes are immediately imported as a new encrypted candidate, zeroized, signed with the new signer, and independently verified.

If any condition fails, do not weaken ACLs, repair partitions, prompt, or export via shell. Create a new key candidate. Preserve the legacy active state until the new certificate/profile/payload installs and launches. A new key does not prove ownership of the old Apple certificate.

## Sequence

1. Create migration ledger and snapshot all legacy resources.
2. Attempt noninteractive import once. Record reason if unavailable.
3. Reconcile a new-store key with Apple certificate inventory.
4. Build/sign/install a candidate through the new path.
5. Prove inventory, launch, runtime prerequisites, and journal promotion.
6. Mark legacy signer disabled permanently for this installation.
7. Retire local legacy metadata/keychains only under explicit cleanup policy. Revoke old Apple certificate only when old key/certificate ownership is proven and capacity requires it.

Crash at any boundary resumes from observation. Migration completion is `newSignerProven + newPayloadActive + legacyWritesDisabled`; cleanup is not required for completion.

## State table

| Legacy state | Action |
|---|---|
| Exportable matching key/cert | Import as candidate; retain old until proof |
| SecIdentity usable but key nonexportable | Create new key/cert; no ACL repair |
| Metadata + cert, key missing | New key; old cert owned only if serial/team/install ledger corroborate |
| Key + cert, metadata missing | Public-key match proves control, but team/account must also match |
| Metadata only | Treat as hint, never ownership |
| Stale/expired certificate | New key/cert or reuse key for new CSR; no need to revoke expired cert |
| Ambiguous duplicate identities | New key; preserve all; require support review for cleanup |

Rollback before promotion leaves legacy active and new candidate quarantined. After promotion, rollback means reinstalling last known-good new-signer payload; legacy payload signing is not re-enabled.

