# Legacy Signing Removal Plan

## Remove from production after M5/M7/M8 proof

- Global Keychain search-list reads/writes for payload signing.
- `Veya-Signing.keychain-db` creation/unlock as a signing identity store.
- login-Keychain private-key discovery.
- `SecIdentity` construction/resolution for iOS payload signing.
- `SecKeychainItemSetAccess`, trusted-application ACL construction, partition-list repair, and `/usr/bin/security` mutation.
- `/usr/bin/codesign` invocation or usability probes for iOS payload/nested code/runner.
- legacy signing metadata writes and label/application-tag ownership.
- `IOSSimSigningKeyTestHelper` and prompt-specific regression helper.
- any fallback from Rust signer/key store to the old signer.

Mac app release signing in `build_app.sh` is build-time distribution signing and is not this path; it remains explicitly classified and never runs on a consumer Mac.

## Retain temporarily

Read-only legacy inventory/export readers, identifier constants, and sanitized fixtures remain through the migration support window. They live under `Migration/LegacySigningReader`, are inaccessible to normal signing interfaces, never alter ACL/search lists, and are deleted after telemetry/support policy confirms the migration window.

## Enforcement

- Static check rejects prohibited symbols/commands in production Swift/Rust and packaged strings.
- Process-execution test records all subprocesses during full reconcile and rejects `codesign`/`security` for payload work.
- Dependency injection exposes only `InProcessSigner` in production composition.
- Migration completion flips `legacyWritesDisabled`; no configuration can reverse it.
- Rollback uses source/version rollback before user migration or a new fixed release after migration. A hidden runtime fallback is prohibited.

