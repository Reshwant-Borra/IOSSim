# Target recovery model

## Persistence and serialization

The helper acquires an exclusive OS lock per setup key. A lease record contains operation ID, process identity, start/heartbeat, generation, and release. Durable files use write-to-sibling, fsync, rename, and directory fsync. The journal is append-only and contains safe identifiers, intent, observation, and commit markers. On startup, reconciliation trusts live device/Keychain/filesystem state over a checkpoint.

## Invalidation graph

- device identity change invalidates install, pairing, VPN, developer-service, runner, and runtime receipts, but not an account/team identity valid for another device;
- team change invalidates certificate/profile/prepared artifact/install ownership and downstream receipts;
- release/artifact change invalidates integrity, prepared artifacts, install verification, runner, and runtime proof;
- OS build change invalidates DDI/RSD/AppService and downstream proofs;
- profile expiry/revocation invalidates signing/install launch proof, not pairing records;
- pairing rotation invalidates tunnel/RSD/runner/runtime, not signed artifacts;
- LocalDevVPN version/config change invalidates VPN endpoint and runtime proof only.

## Recovery rules

1. Reopen the exact setup key and acquire its lease.
2. Parse snapshot; quarantine malformed state instead of overwriting it.
3. Replay only journal facts with verified completion markers.
4. Inspect device, Keychain references, caches, installed inventory, pair slots, and service readiness.
5. Derive domain states and invalidations.
6. Roll back unpromoted candidates; never remove a verified active resource during rollback.
7. Resume at the smallest nonverified domain.

Network timeouts retry only idempotent reads automatically. Create/register/install calls reconcile before retrying. Disconnect pauses with durable state. Reboot resumes from live checks. Wrong-team or unknown apps are reported and left intact until an explicit ownership-safe replacement path exists. Cancellation scrubs ephemeral credentials/workspaces and records a terminal operation event without erasing reusable valid resources.
