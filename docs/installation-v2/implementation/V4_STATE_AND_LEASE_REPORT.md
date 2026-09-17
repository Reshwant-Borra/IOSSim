# V4 durable keyed state and cross-process lease report

Verdict: `PASS`

## Implemented

- Added `SetupIdentity` using the authoritative key shape: SHA-256 over length-framed release, Personal Team, canonical selected device UDID, and artifact-set identities. Raw identifiers are not written to the key, snapshot, journal, or lease.
- Added schema-5 snapshots under `Application Support/IOSSim/SetupState/<SetupKey>/snapshot-v5.json`, a hash-chained `journal-v1.jsonl`, `lease.lock`, and a short-lived `lease.json` record. Setup directories are mode `0700`; state files are mode `0600`.
- Added an OS `flock` lease held across the entire mutation, monotonic generations, compare-and-swap snapshot writes, fsync of files/directories, atomic snapshot rename, operation IDs, and intent/observed/committed/abandoned/recovered journal phases.
- Recovery handles interruption before external observation, after observation, and in the narrow window after the snapshot rename but before the commit journal entry. Unknown effects must be reconciled; the store never assumes an interrupted external call failed.
- Corrupt snapshots and journals fail closed with stable `VEYA-STATE-001...006`/`VEYA-UPDATE-003` descriptions and do not overwrite the last snapshot.
- Added one-way schema-4 import. Only the legacy manifest digest is recorded in schema-5 state. The compatibility manifest itself remains in the protected per-key domain store for the supported migration window.
- Routed packaged `consumer-provision`, `consumer-resume-setup`, `consumer-reconcile`, and keyed runtime-readiness mutation through the lease. The provisioner now constructs a distinct protected domain store for every release/team/device/artifact key.
- Changed GUI/helper status routing to include the selected device and team. When team selection has not yet been restored, the helper accepts a keyed manifest only if its protected manifest recomputes to the current release/artifact/device key; ambiguous multiple-team matches return no implicit selection.
- Concurrent mutation maps to `OPERATION_IN_PROGRESS` with `VEYA-STATE-001`; uncertain/corrupt state maps to repair guidance rather than destructive replacement.

## Acceptance evidence

- Same key, two independent store actors: the second OS lock attempt is rejected while the first owns the lease.
- Stale generation: expected generation 0 cannot overwrite committed generation 1.
- Device, team, release, and artifact changes: four distinct keys and directories; no shared snapshot.
- Crash after intent: exact observed recovery commits once; unobserved recovery abandons without advancing generation and permits retry.
- Crash after atomic snapshot rename: recovery detects the matching operation/generation and completes only the missing commit record.
- Tampered journal and corrupt snapshot: both fail closed; committed bytes are not replaced.
- Schema-4 migration: current schema decoded, digest recorded, and raw team/device identifiers absent from snapshot/journal.
- Secret-shaped journal detail is rejected before creating a journal.
- Bundled status request carries the exact device/team tuple to the helper.

## Tests

- `UNIT` / `HERMETIC_INTEGRATION`: `KeyedSetupStateStoreTests` — 12/12 passed.
- Focused packaged boundary plus state tests — 22 executed, one opt-in V3 artifact test skipped, zero failures.
- Broad safe Swift package suite — 298 executed, two opt-in artifact/local-system probes skipped, zero failures, zero unexpected.
- Explicitly excluded: six `NativeSigningIdentityIntegrationTests` and the real-Keychain persistence test. V4 did not authorize mutation of the user's Keychain/codesigning identities.
- Safe no-Xcode runtime/routing checks and five synthetic device-discovery checks — passed.
- `git diff --check` — passed.

Broad regression log: `.build/iossim/logs/v4-safe-swift-test.log`.

## Known limitations and deferrals

- The schema-4 compatibility reader remains intentionally available for the supported upgrade window; V16 owns its eventual retirement.
- Candidate subdirectories will be added by the transactional signing/pairing milestones that own candidate resources. V4 supplies the keyed ownership and mutation substrate.
- A stale operation's external effect still requires domain reconciliation before promotion; later milestones provide the domain-specific physical observers.
- This milestone did not touch a phone, Apple account, production Keychain, or pairing record. Physical crash/reboot qualification remains V19.

## Gate

No lost update, stale overwrite, cross-key state reuse, or unleased packaged mutation was observed. Crash recovery, corrupt-state fail-closed behavior, schema migration, and safe retry passed. V4 is complete and V5 may begin.
