# Installation observability specification

## Event envelope

Every operation emits start and terminal events. A terminal event is mandatory even when an error is mapped for UI.

```json
{
  "schemaVersion": 1,
  "runId": "random-correlation-id",
  "generation": 12,
  "sequence": 87,
  "timestamp": "RFC3339",
  "stage": "SIGNING_IDENTITY_READY",
  "operation": "key.generate",
  "phase": "END",
  "result": "FAILURE",
  "safeErrorCode": "VEYA-SIGNING-STORE-004",
  "osStatus": -25291,
  "retryable": false,
  "userActionRequired": false,
  "destructiveRepairRequired": false,
  "underlyingSubsystem": "Security.Keychain",
  "durationMs": 23,
  "attempt": 1,
  "selectedDeviceAlias": null,
  "teamAlias": "sha256:...",
  "resourceAlias": "sha256:...",
  "message": "Signing wrapping key unavailable",
  "proof": null
}
```

## Required fields and rules

| Field | Rule |
| --- | --- |
| stage | canonical state-machine ID, not UI phase |
| operation | stable verb/object such as `certificate.list`, `key.load`, `bundle.sign.nested`, `app.install.main` |
| result | `SUCCESS`, `FAILURE`, `USER_ACTION_REQUIRED`, `SKIPPED_PROVEN`, `CANCELLED`, `INTERRUPTED` |
| safe error code | required for every non-success terminal event; no `UNEXPECTED_ERROR` at a subsystem boundary |
| OSStatus | numeric only when relevant; never the sole error |
| retryable | derived from exact operation/result, not generic exception type |
| user action | true only when a named Apple/product action is available |
| destructive repair | true only for a separately authorized operation; normal setup should remain false |
| generation | monotonic workflow generation; stale events cannot update UI/state |
| sequence | monotonic per run; identifies the first terminal failure unambiguously |
| aliases | salted/hash aliases scoped to support export; no raw UDID/team/account/cert serial by default |
| proof | proof kind and safe digest/reference, never secret material |

## First-failure rule

The first event in sequence with terminal `FAILURE`, `INTERRUPTED`, or unresolved `USER_ACTION_REQUIRED` is the first failing operation. Missing later checkpoints is not diagnostic evidence. Wrappers may add context but cannot replace or suppress the original event/cause chain.

## Taxonomy

Top-level namespaces: `INTEGRITY`, `STATE`, `DEVICE`, `TRUST`, `DEVELOPER_MODE`, `APPLE_AUTH`, `APPLE_TEAM`, `APPLE_RESOURCE`, `SIGNING_STORE`, `CERTIFICATE`, `PROFILE`, `SIGNING`, `INSTALL`, `DEVELOPER_SUPPORT`, `PAIRING`, `VPN`, `RSD`, `APPSERVICE`, `RUNTIME_PROOF`, `PACKAGING`, `INTERNAL`.

Each maps to numeric stable support codes in `VeyaDiagnostics`; generated tests assert every production error maps exactly once. `INTERNAL.UNCLASSIFIED` is permitted only at the process top-level, includes the last started operation and type-safe cause chain, and fails qualification.

## Secret policy

Never log Apple account/password, 2FA, SRP material, cookies/tokens/session blobs, private keys/wrapping keys, Keychain passwords, raw certificate/profile bytes, pairing records/PSKs, raw UDIDs, device serials, exact coordinates, request/response bodies, or subprocess environments. Allowlist fields rather than redact arbitrary dumps. A secret-scanner test runs on every generated report.

## Persistence and support export

- Append JSONL using atomic/synchronized writes; rotate by size while retaining the active run.
- Store 0600 files in 0700 directories inside the repository for qualification and Application Support for product runs.
- Record commit/dirty digest, artifact/helper/signer hashes, architecture, OS and schema versions in the run header.
- Support export applies a new per-export alias salt, validates the schema, scans for secrets, and includes an event completeness check.
- Screenshots are optional evidence associated with `runId`, `sequence` and stage; filenames are not proof.

## Qualification assertions

Every injected failure asserts exact `stage`, `operation`, code, OSStatus where controlled, retry/action flags, generation, attempt count, first-failure sequence and absence of secrets. Build 11's metadata-missing path would therefore identify `key.enumerate`, `key.access.construct`, `keychain.open`, or `key.generate` directly instead of collapsing to `UNEXPECTED_ERROR`.

