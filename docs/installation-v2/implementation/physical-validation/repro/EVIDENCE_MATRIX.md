# PHYSICAL_DEFECT_001 — reproduction evidence matrix

Classification: **LOCAL_SYSTEM** (real Security.framework, real `/usr/bin/codesign`,
real login Keychain, throwaway CA, uniquely tagged keys deleted afterwards).

Programs in this directory:

| program | what it proves |
|---|---|
| `acl_probe.swift` | whether `SecKeyCreateRandomKey` honours `kSecAttrAccess` nested in `kSecPrivateKeyAttrs` |
| `e2e_probe.swift` | where the `PartitionID` ACL comes from, and whether `ChangeACL` can be pre-granted |
| `codesign_auth_probe.swift` | whether real `/usr/bin/codesign` can use the key **without a SecurityAgent prompt** |

A child `codesign` that has to be timed out is one that raised a SecurityAgent
prompt, i.e. it was **not** authorized.

## `acl_probe` — is the production `SecAccess` applied at all?

| case | `kSecAttrAccess` placement | resulting ACL description | Sign trusted apps |
|---|---|---|---|
| A | nested in `kSecPrivateKeyAttrs` (**as shipped**) | `<key>` (default) | **creator only** — `/usr/bin/codesign` absent |
| B | top level | our label | creator **+ `/usr/bin/codesign`** |
| C | omitted entirely | `<key>` (default) | creator only |

**A is byte-identical to C.** `SecKeyCreateRandomKey` silently discards a
`kSecAttrAccess` placed inside `kSecPrivateKeyAttrs`.

## `e2e_probe` — where the partition list comes from

* The `SecAccess` we build contains **no** `PartitionID` ACL.
* `securityd` injects one at item-store time: `Partitions = [cdhash:<creating binary>]`.
* `ChangeACL` can be pre-granted at creation (`apps=2`), but not retrofitted.

## `codesign_auth_probe` — the decisive table

| # | Keychain | Sign ACL | Partition list | Real `codesign` result |
|---|---|---|---|---|
| V0 | login | nested access (ignored → creator only) | `cdhash:creator` | **BLOCKED on SecurityAgent prompt** |
| V1 | login | top level, incl. `/usr/bin/codesign` | `cdhash:creator` | **BLOCKED on SecurityAgent prompt** |
| V2 | login | top level + in-process partition repair | repair returns **-25293 `errSecAuthFailed`** | **BLOCKED on SecurityAgent prompt** |
| V6 | login | **trusts ANY application** | `cdhash:creator` | **BLOCKED on SecurityAgent prompt** |
| V5 | Veya-owned | trusts ANY application | **none injected** | no prompt (failed only on unbuildable throwaway chain) |
| V7 | **Veya-owned** | top level, incl. `/usr/bin/codesign` | **none injected** | **SIGNED SUCCESSFULLY, no prompt** |

### What the table establishes

1. **V6 is the decisive control.** An ACL that trusts *every* application still
   prompts in the login Keychain. The trusted-application list is therefore
   **not** the gate — the **partition list** is.
2. A login-Keychain key created by a non-Apple-signed process is permanently
   stamped `cdhash:<creator>`. No other binary — `/usr/bin/codesign` included —
   can ever match it, and V2 shows the partition list cannot be rewritten
   in-process: it needs the **login Keychain password** (`errSecAuthFailed`).
3. Keys created in a **Veya-owned** keychain receive **no `PartitionID` ACL at
   all**, so the trusted-application ACL governs, and `/usr/bin/codesign`
   signs with zero prompts (V7).
4. The nested-`kSecAttrAccess` bug (A vs B) is real and must also be fixed, but
   on its own it is **not** sufficient to explain the failure — V1 and V6 prove
   the login Keychain is unusable regardless of ACL contents.

## Corroborating live capture on the development Mac

Running the repo's own gated regression
`NativeSigningIdentityIntegrationTests/testCleanConsumerMacIOSSimOwnedKeyIsUsableFromPackagedHelperWithoutInteraction`
with `IOSSIM_RUN_KEYCHAIN_INTEGRATION=1` hangs indefinitely. Process capture
while it was hung:

```
/usr/bin/codesign --force --sign <sha1> --timestamp=none .../IOSSimIdentityProbe.app   (blocked)
/System/Library/Frameworks/Security.framework/.../SecurityAgent                        (prompting)
```

The test named "without interaction" reproduces the physical defect on a
**developer** Mac. It passed qualification only because it is skipped unless
`IOSSIM_RUN_KEYCHAIN_INTEGRATION=1` is set.

## Reading of the physical support bundle (`IOSSim-Support-1789592208.zip`)

* `runningExecutablePathCategory: BUNDLED_APP_HELPER`, `setupEngine: BUNDLED_PROVISIONING_ENGINE`
  → provisioning ran in `Veya.app/Contents/MacOS/IOSSimProvisioner`.
* Generation 1 (20:55:18–19): `KEYPAIR_CREATED` → `CSR_CREATED` → `CERTIFICATE_FOUND`
  → `DEVELOPMENT_CERTIFICATE_CREATED` with `certificatePublicKeyMatchesPrivateKey: true`.
  The key, the CSR, the Apple certificate and their association are all **correct**.
* Generation 2: `PRIVATE_KEY_LOOKUP_STARTED` 20:55:40 → `PRIVATE_KEY_FOUND` 20:55:54 — a
  **14-second** gap. Generation 3: 20:56:15 → 20:56:21 — a **6-second** gap. The only
  work between those checkpoints is `authorizePrivateKeyForSigning` →
  `SecKeychainItemSetAccess`, which needs `ChangeACL` that nothing holds. Those gaps
  are the consumer answering Keychain dialogs.
* `PROVISIONING_READY` 20:56:22 — reported with no key-usability proof.
* `installing` 20:56:25 → `SIGNING_KEY_ACCESS_DENIED` 20:56:34 — a further **9-second**
  gap: the `codesign` probe/payload signing raised a third dialog and access ended denied.
