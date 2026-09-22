# M8 Result — IOSSim → Veya Migration

Status: **SOFTWARE_GATE_PASS (read-only snapshot + ledger) / LEGACY_WRITE_REMOVAL_PENDING (M11)**.

## Decision: never import the legacy signing key

Spec 06 permits importing a legacy key when a noninteractive export succeeds. The Build 1-11 signing key
lives in `Veya-Signing.keychain-db`, whose unlock password is `signing-keychain.secret`, a `0600` plaintext file
in the same user's Application Support. Its confidentiality at rest cannot be established, so Veya always
creates a new key candidate (spec 06: "create a new key candidate"). This also means no keychain read of
legacy key material is ever needed, so migration cannot trigger SecurityAgent.

## Implemented (`Installation/LegacyMigration.swift`, composed in `ProductionComposition`)

- `LocalLegacyInventoryReader`: classifies each legacy item as `absent`, `present`, `promptRequired`, or `unreadable`, and assigns a disposition: `replaceWithNewKey` (legacy keychain/login-keychain signing service), `retireOnCleanup` (plaintext-equivalent secret file), `ownedByV2Store` (auth v1 files and the login-keychain auth item, consumed by auth v2), or `evidenceOnly` (old manifests/journals, content-hashed).
- Secret-bearing files are never read or hashed. Login-keychain lookups are attribute-only with `kSecUseAuthenticationUIFail`.
- `MigrationDomain` (`.migration`, the engine prerequisite of `.signingKey`): one snapshot is written to the journal migration ledger (`phase=inventoried`, per-item `classification|disposition|digest`), proven by re-deriving the ledger digest, then promoted. It is idempotent. An isolated qualification root never inventories the real home directory.

## Tests (`LegacyMigrationTests` 3/0; M1-M4 regressions 42/0)

Sanitized Build 1-11 layout (real names, synthetic contents): classification and dispositions; secrets
unread and unhashed; legacy files byte-identical after migration; journal free of the secret canary;
idempotent rerun (0 transitions); production composition orders `.migration` before `.signingKey`.

## Not done

- Phases `importedCandidates…complete`: import is intentionally vacuous. `newActive` and `legacyWritesDisabled` depend on M7 routing and M10 proof.
- Legacy **writes** by the Build 11 code paths (`Application Support/IOSSim` provisioning state, legacy signer keychain) are removed with the legacy route in M11.
- Downgrade protection (an old binary refusing a newer journal) is provided by the schema-versioned journal (M1). Old binaries never read the v2 journal, so they cannot corrupt it; they can still write their own v1 state until retired.
- Cleanup of `retireOnCleanup` items requires an explicit user/support policy (not automated).
