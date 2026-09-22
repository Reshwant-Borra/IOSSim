# Transaction Journal Specification

## Storage

Use one JSON document at `~/Library/Application Support/Veya/installation/journal-v1.json` plus append-only redacted events at `events-v1.jsonl`. JSON is chosen for inspectability and atomic whole-document replacement; secret material and large artifacts are referenced by opaque IDs and SHA-256, never embedded.

```json
{
  "schemaVersion": 1,
  "installationID": "uuid",
  "revision": 42,
  "generation": 7,
  "lease": {"runID":"uuid","ownerPID":123,"acquiredAt":"...","expiresAt":"..."},
  "active": {"key":{},"certificate":{},"profile":{},"payload":{},"pairing":{}},
  "candidates": {"certificate":{}},
  "transition": {"id":"uuid","kind":"issueCertificate","phase":"proving"},
  "evidence": [{"id":"sha256:...","kind":"certificateKeyMatch","capturedAt":"..."}],
  "migration": {"legacyVersion":1,"phase":"notStarted","items":[]},
  "recovery": {"required":false,"reason":null},
  "lastSafeCheckpoint": {"revision":41,"generation":6,"digest":"sha256:..."}
}
```

Each resource record includes resource ID, generation, lifecycle (`candidate|active|retiring|retired|invalid`), created/observed/expiry times, ownership level, evidence IDs, non-secret location, digest, and domain metadata. Unknown fields are preserved during compatible reads.

## Atomic write protocol

1. Acquire `journal-v1.lock` with `flock(LOCK_EX)` and verify lease/revision.
2. Encode deterministic sorted-key JSON; validate schema and invariants in memory.
3. Write `journal-v1.json.tmp.<runID>` mode `0600` with `O_CREAT|O_EXCL|O_NOFOLLOW`.
4. `fsync` the file, rename over the journal in the same directory, then `fsync` the directory.
5. Reopen without following symlinks, decode, and verify revision/digest.
6. Append the corresponding redacted event and `fsync` according to durability policy.

The event log is diagnostic, not a recovery source. `lastSafeCheckpoint` lives in the journal. Disk-full before rename preserves the old journal; a failed directory fsync is reported as ambiguous and forces read-only recovery inspection.

## Promotion transaction

Candidate creation allocates generation G and records it before external mutation. Validation attaches evidence. Promotion atomically changes candidate G to active and previous active to retiring in one journal write. Physical retirement is a later idempotent transition; failure leaves both the new active and old retiring records discoverable.

## Corruption and recovery

- On decode/digest failure, do not infer state or create/revoke resources. Move nothing automatically.
- Attempt the single validated `.previous` checkpoint retained via hard-copy before rename; if valid, enter `recovery.required` and inspect external truth.
- If neither file validates, emit `VEYA-STATE-003`, preserve both, and offer non-destructive reconstruction from local/Apple/device observations. Reconstruction creates a new journal only after explicit review; unknown ownership remains unknown.
- Orphan temp files are retained in diagnostics and may be removed only after digesting and proving they are not newer valid state.

## Schema migration and access

Readers support current and immediately previous schema. Migration writes a new candidate journal, validates it, then atomically promotes it. Downgrade is read-only when encountering a newer schema. The packaged provisioner is the only writer; main app and qualification clients use its protocol. All directories are `0700`, files `0600`, owner UID checked, symlinks rejected.

