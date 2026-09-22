# IOSSim to Veya migration audit

## Finding

The migration intentionally changed display branding while retaining nearly every durable identifier. That avoided an immediate data split, but it also made legacy IOSSim state the permanent active substrate without a one-time inventory/migration boundary. Builds 7-11 demonstrate that compatibility reads across changing key/metadata locations can contaminate current setup.

| Identifier/state | Current value/path | Classification | Target treatment |
| --- | --- | --- | --- |
| Mac bundle ID | `com.iossim.mac-provisioner` | `MUST_RETAIN_FOR_COMPATIBILITY` for current release line | keep until a separately planned signed-app migration; document as stable |
| preferences namespace | `IOSSimMac` / bundle plist | `MIGRATE_ONCE` | read legacy, write versioned Veya state, leave tombstone/marker; do not dual-write indefinitely |
| Application Support | `~/Library/Application Support/IOSSim` | `MIGRATE_ONCE` | inventory and atomically import to `Veya`; retain read-only legacy backup through rollback window |
| diagnostics directory | `~/Library/Application Support/IOSSimMac` | `SAFE_TO_RENAME` after one-time import | new safe events under Veya; legacy diagnostics remain evidence |
| signing Keychain file | `Veya-Signing.keychain-db` | `SHOULD_REMOVE` from target signer after migration | inventory legacy keys, never ACL-repair; remove from global search list only after no rollback dependency |
| signing Keychain password file | `IOSSim/signing-keychain.secret` | `SHOULD_REMOVE` after legacy retirement | preserve during rollback; securely delete only with explicit migration completion |
| signing metadata | `IOSSim/signing-metadata-v1` | `MIGRATE_ONCE` | import ownership evidence into unified ledger; cryptographically re-prove |
| metadata service | `com.iossim.mac.personal-team-signing` | `MIGRATE_ONCE` | noninteractive read only; no continued writes |
| signing key label | `IOSSim Personal Team Signing Key` | `MIGRATE_ONCE` | legacy inventory classifier only |
| signing key tags | `com.iossim.personal-team.<team>.<uuid>` | `MIGRATE_ONCE` | recognize for ownership/key recovery; new in-process key IDs use versioned Veya namespace |
| CSR subject names | `IOSSim` | `SAFE_TO_RENAME` for new certs | use structured Veya installation marker; preserve recognition of legacy constant as weak evidence only |
| Apple machine marker | legacy constant then structured marker | `MUST_RETAIN_FOR_COMPATIBILITY` parser; `SAFE_TO_RENAME` writer versioned | parse all versions; write a versioned Veya marker with installation ID |
| authorization services | `com.iossim.mac.apple-authorization` and Veya authorization Keychain | `MIGRATE_ONCE` | retain opaque valid session if accessible without UI; otherwise reauth |
| pairing service | `com.iossim.remote-pairing.v1` and product constant `com.iossim.on-device-dvt-poc.rppairing` | `UNKNOWN` due two apparent contracts | inventory actual writers/readers, choose one canonical service, migrate by possession proof |
| Mac helper/executable names | `IOSSim`, `IOSSimProvisioner`, signing test helper | `SAFE_TO_RENAME` only with manifest/protocol migration | rename after package references and rollback plan are updated |
| phone main bundle ID | `com.iossim.on-device-dvt-poc` | `MUST_RETAIN_FOR_COMPATIBILITY` initially | preserves app data and installed ownership; display name can be Veya |
| runner bundle ID | `com.iossim.location-control-uitests.xctrunner` | `MUST_RETAIN_FOR_COMPATIBILITY` initially | required by mapping, pairing and runtime proof |
| source payload/project names | IOSSim POC/test names | `SAFE_TO_RENAME` gradually | do not change installed IDs in same milestone as signer migration |
| phone Application Support/inbox | `Library/Application Support/IOSSim/...` | `MUST_RETAIN_FOR_COMPATIBILITY` until phone migration | add versioned inbox schema and migrate in app |
| setup journal/state files | `setup-state-*`, `provisioning-state.json`, events, runtime receipt | `MIGRATE_ONCE` | consolidate into one journal with domain proofs; retain importer tests for every supported schema |
| cached artifacts/ProvisioningWork | IOSSim paths and old Xcode-produced outputs | `SHOULD_REMOVE` as active input | inventory then quarantine; never let old unsigned/signed outputs satisfy current artifact proof |
| old DMGs | Build 1-11 under repo | `MUST_RETAIN_FOR_COMPATIBILITY` as evidence, not runtime input | retain audit corpus; exclude from discovery/install logic |
| system Lockdown pairing records | Apple/system-owned | `MUST_RETAIN_FOR_COMPATIBILITY` | validate, never broad-delete |
| old diagnostics/support bundles | IOSSim names/content | `MUST_RETAIN_FOR_COMPATIBILITY` as evidence | importer/viewer only; never treat as live state |
| LaunchServices/Finder identity | Veya display with IOSSim executable/bundle ID | `UNKNOWN` clean-up timing | physical upgrade and rollback test before any rename |

## Migration algorithm

1. Inventory every legacy root read-only and write a redacted migration plan.
2. Select exact device/team generation; never merge across them implicitly.
3. Import nonsecret journal/resource references into a new versioned Veya ledger.
4. Validate opaque auth/pairing secrets through their real services without reading them into logs.
5. For legacy signing identities, prove key/cert match and noninteractive usability only for migration classification. Do not run ACL or partition repair.
6. Create the new in-process signing identity as a candidate; issue/reclaim only under the ownership rules.
7. Re-sign/install/verify/runtime-prove before marking migration complete.
8. Keep a rollback marker and legacy state untouched for one release window; later removal is an explicit, separately qualified operation.

The current `ProductBrand` constants are therefore compatibility inputs, not evidence that migration is finished.

