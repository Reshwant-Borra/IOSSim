# M4 Result

Status: **BLOCKED — BLUEPRINT_CONTRADICTION / SECURITY_BLOCKER**. Build remains `11`.

## Implemented architecture

- RSA-2048 private key generated in process and encoded as PKCS#8.
- AES-256-GCM authenticated envelope bound to installation ID, key ID, algorithm, and public-key digest.
- Veya-owned `0700` directory and atomically persisted `0600` encrypted-key file.
- Wrapping secret stored in the signature-selected Keychain backend only: login Keychain for ad-hoc/LOCAL_TEST and Data Protection Keychain for entitled team-signed code.
- Backend choice is deterministic and has no runtime downgrade.
- Candidate create, decrypt/probe, engine promotion, replacement, rotation, and retirement paths exist.
- No SecIdentity payload-key architecture, global Keychain search-list mutation, ACL/partition repair, external private-key consumer, or `/usr/bin/codesign` payload signer was introduced.

## Focused test result

There are 11 `SigningKeyStoreTests`. Ten noninteractive tests pass (10 executed, 0 failed): creation,
fresh-store reopen/process restart, RSA-2048 PKCS#8 access, file permissions, plaintext persistence scan,
wrong/missing wrapper, missing/corrupt/tampered ciphertext and tag, wrong installation identity, unsafe
file/symlink handling, rotation/retirement, deterministic backend selection/no fallback, and engine
candidate creation/proof/promotion/replacement.

The eleventh test, the real packaged-helper clean/reopen/cross-cdhash-upgrade gate, remains red because
the approved LOCAL_TEST backend triggers authentication UI. It is not skipped for milestone accounting;
it was excluded only from the final compile/noninteractive rerun to avoid deliberately opening another
known confirmation dialog. M4 therefore does not pass.

## SecurityAgent controlled A/B

The experiment used the same packaged helper, bundle ID, LaunchServices launch mechanism, and output
capture. SecurityAgent PID state was recorded before, during, and after each run; a narrowly filtered
unified-log stream observed SecurityAgent itself.

| Run | Operation | Result | SecurityAgent |
|---|---|---|---|
| A1 | Build 11-like app, `protocol-info` (no Keychain) | exit 0, 0.54 s | absent throughout |
| B1 | Same app, key create/reconcile | exit 0, 0.48 s | absent throughout |
| A2 | Build 12 app, `protocol-info` (no Keychain) | exit 0, 0.54 s | absent throughout |
| B2 | Build 12 app, verify Build 11-created wrapper across cdhash | exit 0, 5.84 s | launched; `SC confirmation dialog detected` |

A focused test repetition produced the same confirmation-dialog log event during the cross-cdhash read.
The successful read was therefore interactive. The test now compares SecurityAgent PID sets around an
explicit non-Keychain baseline so an unrelated pre-existing process cannot create a false result.

## cdhash root cause

The test parser invoked `codesign -dv`; current `codesign` does not include `CDHash` at that verbosity.
`codesign -dvvv` reports it. The helper now requires inspection exit 0, a `CDHash=` field, and exactly 40
hexadecimal characters. Fresh strict-valid ad-hoc apps produced distinct values
`f1d5f7f77babd863f772699622c3487d5c72a08f` and
`8cfd64a4c81e6c0629a25a556bce4822848fdc56`. The root cause was test parsing, not missing signing,
LaunchServices substitution, or identical artifacts.

## Root cause and contradiction

The installed macOS SDK states that no-authentication-UI suppression applies only to Data Protection
Keychain items and that legacy Keychain items can still activate UI. The login-Keychain item receives a
creator-cdhash partition from `securityd`; the upgraded ad-hoc artifact has a different cdhash. Existing
repository physical probes independently show that even an allow-any application ACL still prompts and
that credential-free partition mutation fails with `errSecAuthFailed`.

These requirements cannot all hold simultaneously:

1. Build 12 is ad-hoc/LOCAL_TEST.
2. Ad-hoc/LOCAL_TEST must use the login-Keychain backend in ADR-001.
3. Upgrade access must cross code-identity/cdhash boundaries.
4. Normal access must be noninteractive and produce zero SecurityAgent prompts.
5. ACL/partition repair, Mac-password use, silent fallback, and file-only secret storage are forbidden.

No assertion was weakened and no alternate security architecture was selected without authorization.
Resolution requires an explicit product/security change, such as team-signing LOCAL_TEST so it can use
the Data Protection Keychain, or an amendment to the storage/no-UI requirements.

## Journal regression

Real `Date` values round-trip through JSON at millisecond precision. The repository now atomically
persists, decodes the actual on-disk journal, verifies its payload digest, and returns that persisted
value. `testRealClockWritesVerifyAndRoundTrip` passes (1 executed, 0 failed).

## Security and cleanup

Randomized service/account or installation identifiers isolated real Keychain tests. No wrapping secret,
private key, Apple credential, or authorization material was printed. The controlled A/B test item was
deleted through the exact artifact that created it. The previously documented older probe orphan remains
untouched; unrelated Keychain state was not inspected or modified.

## Exit decision

M4 exit requires clean and upgrade matrices with zero SecurityAgent prompts and noninteractive failure
semantics. That gate fails. M5-M12 and the Build 12 entry gate were not entered because M4 is a hard
predecessor and the user-designated stop conditions explicitly include blueprint contradictions and
security blockers.
