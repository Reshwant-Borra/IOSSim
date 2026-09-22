# IOSSim to Veya Migration Implementation

## Identifier inventory and disposition

| Legacy identifier/path | Read old | Write old | Action | Rollback retention |
|---|---:|---:|---|---|
| `~/Library/Application Support/IOSSim` | yes | no | Import recognized state to Veya journal/content store | Keep until two successful launches |
| `com.iossim.mac.apple-authorization` | yes, noninteractive | no | Candidate import to AUTH v2 then validate | Keep until new session proven |
| `com.iossim.mac.personal-team-signing` | yes | no | Signing migration reader only | Keep until new payload proven |
| `Veya-Signing.keychain-db` and login key labels/tags | yes | no | Noninteractive key export or inventory hint | Never ACL-repair; cleanup later |
| `signing-metadata-v1` | yes | no | Evidence hint, not authority | Archive digest |
| mac bundle `com.iossim.mac-provisioner` | retain for Build 12 | n/a | Rename only in separate release migration | Current update continuity |
| phone bundle IDs `com.iossim.*` | retain initially | existing build only | Identifier migration is separate candidate install | Preserve installed rollback |
| pairing service variants | yes | no | Import to `com.veya.remote-pairing.v2` | Keep until possession proof |
| old provisioning manifests/events | yes | no | Map evidence into journal ledger | Preserve read-only |
| old DMGs/caches | inventory only | no | Never use as active artifact | User cleanup policy |

Bundle identifier renaming is deliberately decoupled from signer replacement. Changing both would confound certificate/profile/pairing/install diagnosis and update continuity. Veya branding paths and service names migrate now; externally significant bundle IDs change only after the new architecture is physically stable.

## Migration phases

`notStarted -> inventoried -> importedCandidates -> candidatesProven -> newActive -> legacyWritesDisabled -> complete`.

Each item stores source digest, classification, target reference, proof, and completion. Re-running is idempotent. Partial phase resumes item-by-item. Migration completes when all essential domains are new-active or explicitly absent, all production writes target Veya v2 paths, and a new-signer payload plus runtime proof succeeds. Legacy deletion is a later optional cleanup and is not dual-write.

If the app is downgraded after migration, the old binary receives a newer-schema/read-only failure rather than writing stale IOSSim state. Support can export the migration ledger without secrets.

