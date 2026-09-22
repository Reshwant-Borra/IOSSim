# ADR-001: Wrapping-secret backend selected by artifact signature class

Status: **SUPERSEDED IN PART by the M4 resolution pass** (2026-09-21, `M4_RESOLUTION_PASS.md`). Earlier status: VALIDATION BLOCKED. The product-owner decision remains recorded, but its
ad-hoc-upgrade/no-UI premise was invalidated by the controlled M4 packaged test below. This ADR cannot
authorize M4 or Build 12 until the contradiction is resolved.

## Evidence (LOCAL_SYSTEM_PROVEN on the development Mac, macOS Darwin 25.6)

| Probe | Result |
|---|---|
| Data-protection Keychain add/read, unsigned CLI | `-34018` errSecMissingEntitlement |
| Data-protection Keychain add/read, ad-hoc CLI | `-34018` |
| Data-protection Keychain, ad-hoc `.app` launched by LaunchServices | create `-34018`, read `-25300` |
| Login Keychain generic password, ad-hoc `.app` "Build 11" create, ad-hoc `.app` "Build 12" (same bundle ID, different cdhash) read with `kSecUseAuthenticationUIFail` | **INVALIDATED:** read succeeds only after a SecurityAgent confirmation dialog |
| Same item read by Apple-signed `/usr/bin/security` | blocked (ACL enforced) |
| Same item read by an unrelated ad-hoc tool | read 0 (ad-hoc callers are not isolated) |

The data-protection Keychain requires a team-ID application identifier/keychain entitlement (Developer ID + provisioning profile). Build 11/12 are ad-hoc LOCAL_TEST artifacts; this Mac holds only Apple Development identities.

## Decision

- Team-signed builds whose signature carries a team identifier and a keychain entitlement use the data-protection Keychain (`com.veya.signing-wrap.v1`, `AfterFirstUnlockThisDeviceOnly`, non-synchronizing) exactly as specified.
- Ad-hoc/unsigned builds (including Build 12 LOCAL_TEST) use a login-Keychain generic password with the same service/account, created and read only by the provisioner, always with authentication UI disabled.
- The backend is a pure function of the running code's signature class. There is no runtime fallback between backends, and a failure of the selected backend is a typed `VEYA-KEY` failure.
- Unchanged: no SecKey/SecIdentity/certificate in any Keychain, no search-list mutation, no ACL or partition edits, no `/usr/bin/codesign`, no plaintext or file-only wrapping secret.

## Accepted risk (local-test builds only)

Other processes running as the same user and signed ad-hoc can read the login-Keychain wrapping item without UI. Combined with the `0600` ciphertext this does not protect against a malicious same-user process. The threat model (doc 05/28) already lists such processes as not fully protected. Protection against copied Application Support, backups, other users, and other Macs is retained because the login Keychain is encrypted and the item is non-synchronizing. Public release requires the team-signed data-protection backend.

## Follow-up evidence: ownership of login-Keychain items

A different ad-hoc binary can read the wrapping item but cannot delete it (`-25244` errSecInvalidOwnerEdit); the item's `change_acl` owner is the creating build's code identity. After an ad-hoc upgrade, unwrap (read) keeps working; retiring the old wrapper fails with a typed `VEYA-KEY-010` and leaves an orphaned 32-byte item, which is harmless (it wraps nothing readable without the matching ciphertext). Team-signed data-protection builds are unaffected. One such orphan was left by an M4 CLI probe on the development Mac (service `com.veya.signing-wrap.v1`, label "Veya signing key wrapping secret"); it can be deleted in Keychain Access.

## Contradictory M4 validation evidence

The original row above inferred "no UI" from a successful return. A controlled same-artifact,
same-LaunchServices A/B experiment disproved that inference:

| Run | Operation | Exit/duration | SecurityAgent evidence |
|---|---|---|---|
| A1 | Build 11-like packaged helper, `protocol-info` (no Keychain) | 0 / 0.54 s | absent before, during, and after |
| B1 | Same artifact, signing-key create/reconcile | 0 / 0.48 s | absent before, during, and after |
| A2 | Build 12 packaged helper, `protocol-info` (no Keychain) | 0 / 0.54 s | absent before, during, and after |
| B2 | Build 12, verify Build 11-created wrapper across a distinct cdhash | 0 / 5.84 s | launched during the request; unified log: `SC confirmation dialog detected` |

The focused packaged test reproduced the B2 result independently: SecurityAgent launched during the
cross-cdhash read and logged the same confirmation-dialog event. The successful result therefore
depended on UI interaction and does not satisfy the M4 gate.

The current macOS SDK documents that no-authentication-UI suppression applies only to Data Protection
Keychain items and that legacy Keychain items can still activate UI. Repository physical evidence in
`physical-validation/repro/EVIDENCE_MATRIX.md` also establishes that `securityd` injects a creator-cdhash
partition when a login-Keychain item is stored. A trusted-application ACL that permits every application
still prompts across that partition, and changing the partition without credentials fails with
`errSecAuthFailed`.

Consequently the accepted LOCAL_TEST login-Keychain backend cannot simultaneously provide cross-cdhash
upgrade access and the required zero-prompt/noninteractive semantics. ACL repair, partition repair,
password automation, UI acceptance, a file-only secret, and runtime fallback are prohibited. The
remaining architectural choices require an explicit product/security decision; this implementation
does not silently choose one.

## Resolution pass addendum (2026-09-21)

- The login-Keychain LOCAL_TEST backend is **withdrawn**. Production selection returns `unavailable` for any
  build without a team identifier plus profile-authorized `keychain-access-groups`, and every key operation
  fails closed (`VEYA-KEY-001`) with no Keychain call and no UI. `loginKeychain` remains only as an explicit
  test fixture surface.
- `-34018` is fully explained by AMFI's restricted-entitlement rule (matrix A-E). The Data Protection Keychain
  remains the backend, and it is suitable: isolation and cross-cdhash upgrade follow team + access group. The
  fallback architecture report is therefore not required.
- **Consequence:** an ad-hoc Build 12 can never pass M4. The qualifying artifact must be signed by a team
  identity with an embedded provisioning profile (Developer ID for distribution), and the Keychain-accessing
  helper must be the main executable of a profile-carrying bundle.
- Remaining proof (BLOCKED_HUMAN): run the packaged gate with `VEYA_M4_SIGN_IDENTITY` / `VEYA_M4_PROFILE`.
