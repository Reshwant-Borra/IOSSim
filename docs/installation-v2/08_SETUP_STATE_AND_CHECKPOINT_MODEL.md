# Setup state and checkpoint model

## Current model

Schema 4 stores a single consumer manifest and event stream. It includes installation, profile-trust, runtime-configuration, RemotePairing, LocalDevVPN, and setup-ready checkpoints. The current final checkpoint verifies saved flags; it does not exercise Rich runtime. State can be overwritten by a different team/device and raced by separate helper processes. `CONFIRMED_LOCAL_IOSSIM_CODE`

## V2 identity

```text
SetupKey = releaseCompatibilityID / teamID / deviceHash / artifactSetID
OperationKey = SetupKey / operationUUID
```

`releaseCompatibilityID` changes only when persisted/wire semantics require migration. `artifactSetID` is a digest of the payload manifest and bundle IDs. Raw UDIDs are never path names. Account identifiers are not required outside the Keychain session record.

The store contains:

- immutable operation intent and selected identities;
- append-only, hash-chained journal entries with generation and safe data;
- atomic current snapshot reconstructed from the journal;
- resource references, never secret bytes;
- lease owner PID/start time/operation ID and heartbeat;
- migration version and previous compatible snapshot reference.

An advisory OS file lock covers read-check-mutate-commit. Actor isolation remains useful inside one process but is not the authority. Writes use temp file, fsync, atomic rename, directory fsync, generation compare, and restrictive modes. An expired lease is recoverable only after verifying the recorded process is gone and replaying the journal.

## Readiness domains

| Domain | Durable state | Required live proof |
| --- | --- | --- |
| Integrity | release components verified | helper handshake for this launch |
| Device trust | pair record fingerprint/reference | Lockdown session to selected mux handle |
| Provisioning | team/key/cert/profile references | signature/profile validation and expiry margin |
| Installation | installed app identities/versions | device inventory exact match |
| Developer support | asset receipt/mount identity | current device mount + RSD service map |
| RemotePairing | active/candidate public fingerprints | phone possession challenge |
| VPN | external app/version/config status | `10.7.0.1:49152` endpoint on intended path |
| Runner | mapping/installed identity | AppService launch + TestManager attach |
| Rich runtime | last proof receipt | fresh no-op/set/clear Rich command sequence |

Only the final live proof may yield `READY`. Durable proof receipts have explicit TTLs and invalidation inputs; they accelerate checks but never turn a changed device/build/release into ready.

## Migration

Schema-4 singleton state is imported once under the identity values it contains, marked `LEGACY_IMPORTED_UNVERIFIED`, and never deleted until the V2 snapshot commits. The full-profile singleton is copied into an owner-only keyed record only after envelope validation. Ambiguous or cross-device legacy state is quarantined and setup reconciles from physical inventory.
