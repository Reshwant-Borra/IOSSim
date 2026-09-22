# Qualification Harness Implementation

## Product-driven architecture

Add an executable target `VeyaQualify`. It is a typed client of `IOSSimProvisioner`; both the UI and CLI call the same helper protocol and therefore the same `VeyaReconciliationEngine`. The harness contains no setup engine, signing logic, Apple logic, or alternate persistence.

## Commands

```text
veya-qualify inspect [--device ID]
veya-qualify plan --desired ready [--stage DOMAIN]
veya-qualify reconcile [--stage DOMAIN] [--resume RUN]
veya-qualify verify artifact|key-store|signature|device|ddi|pairing|vpn|runtime
veya-qualify scenario NAME --fixture PATH [--inject SPEC]
veya-qualify full
```

`inspect`, `plan`, and local verification are non-mutating. `reconcile` requires a capability manifest; Apple/account/device mutations are disabled unless the scenario and operator explicitly grant the named capability. `--stage` constrains planning to a domain and prerequisites; it does not call a private test implementation.

## I/O contract

- Human mode: concise stage/result/user action and run ID.
- `--json`: one versioned `QualificationResult` on stdout; JSONL events on an optional file descriptor.
- Exit 0 success/desired proven; 2 user action; 3 retryable external; 4 qualification assertion; 5 product failure; 6 unsafe/refused; 64 usage; 70 internal protocol.
- Result contains schema, command, run/generation, artifact/helper/bridge identities, environment fingerprint, observations, planned/executed transitions, evidence references, first failure, redacted event digest, and skipped proofs with reasons.
- Secrets never appear in argv, environment, stdout, events, fixtures, or support bundles.

## Artifact and device selection

Default engine path is the currently packaged helper and bridge. Development override requires `--artifact`, verifies its manifest, and labels the run non-packaged. Device selection refuses ambiguity. Scenario fixtures are signed/hashed repository files and cannot carry real credentials.

## Cleanup/resume

Safe cleanup removes unreferenced temp candidates created by the run after journal proof. It does not revoke, uninstall, delete keys/profiles/pairing/VPN, or clear phone data. `--resume` reopens the journal run and observes truth. A scenario crash point exits without cleanup to exercise recovery.

The existing Python physical script becomes a wrapper/report collector or is deleted; hard-coded build history and separate logic are forbidden.

