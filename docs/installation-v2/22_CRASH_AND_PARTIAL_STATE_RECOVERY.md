# Crash and partial-state recovery

## Journal protocol

Every mutation records `INTENT` before its first external effect, including operation ID, SetupKey, expected generation, domain, input digest, candidate resource reference, and recovery procedure. After the effect it records `OBSERVED`, then after verification `COMMITTED`. Entries are append-only, length-bounded, checksummed/hash-chained, and fsynced. Snapshots contain only committed state.

## Recovery matrix

| Interrupted phase | Recovery action |
| --- | --- |
| temp state/artifact write | remove unreferenced temp after validating path containment |
| Keychain key creation before metadata | query only Veya application tag; attach if matching CSR/cert operation, otherwise mark managed orphan |
| Apple certificate/App ID/device request with ambiguous response | list/reconcile exact public-key/device/bundle identity before retry |
| profile issuance | fetch/list matching profile; never create repeatedly on timeout |
| signing | delete staging output; installed app unchanged |
| install/upgrade | query device inventory/version/signature; commit if exact, retry/repair otherwise |
| DDI upload/mount | requery mounted image/service map; do not upload blindly |
| pairing delivery | expire/delete phone/Mac candidate; retain active record |
| pairing promotion | compare active fingerprints on both sides; finish one-way promotion or roll candidate back without deleting old |
| VPN request | use request ID/expiry; accept only matching fresh receipt; otherwise recreate on scene activation |
| runner proof | reconnect, enforce single writer, send Clear; record pending Clear if connection unavailable |

## Lease recovery

A lease contains PID, process start token, operation ID, acquired/heartbeat times, and boot session. Another helper may recover it only if the OS process identity is gone or the boot session changed. It then records `LEASE_RECOVERED`, never merely overwrites the lock file. A live lease returns `VEYA-STATE-001` and the GUI observes progress from the journal.

## Corruption and downgrade

Invalid journal chains, unsupported future schemas, or identity-key collisions are quarantined read-only. Veya reconstructs from Keychain references and physical device inventory only after user-visible diagnosis. It never parses corrupt data and continues. Older app versions cannot mutate newer state; they return `VEYA-UPDATE-003`.

## Runtime safety

The last desired runtime action and writer generation are journaled separately from setup. On crash, `CLEAR_REQUESTED` remains pending until the same selected device acknowledges Clear; movement frames are never replayed. This preserves one writer/one scheduler/no-backlog invariants.
