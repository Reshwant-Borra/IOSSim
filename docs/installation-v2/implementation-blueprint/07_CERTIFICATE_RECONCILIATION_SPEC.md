# Certificate Reconciliation Specification

## Inputs and identity

Inputs are local public-key descriptors, Apple team/account and certificate inventory, journal evidence, current device-installed profile, capacity response, expiry policy, and requested Mac installation ID. Certificate identity is `(teamID, serial, SHA256(DER), SHA256(SPKI))`; names are display-only.

## Ownership proof ladder

1. `unknown`: inventory presence/name only.
2. `metadataClaim`: local legacy serial/team claim; insufficient to revoke.
3. `historicalReceipt`: Veya issuance receipt binds installation/team/serial; sufficient only with Apple inventory agreement.
4. `privateKeyControl`: local challenge verifies against certificate SPKI.
5. `activePayloadCorroboration`: key control plus installed/profile evidence.

Automatic revocation requires level 4, matching team/account, non-expired obsolete status, no active/candidate reference, and explicit `destructiveOwned` policy. Unknown or unrelated certificates are never revoked.

## Pure decision algorithm

1. Normalize Apple inventory and reject duplicate serial/DER contradictions.
2. Match usable local keys to certificates by SPKI, never label or metadata alone.
3. Prefer a nonexpired matching certificate with at least 48 hours remaining and no server-revoked status.
4. If no match and capacity is available, issue using CSR from the selected candidate key; record Apple request/idempotency fingerprint before request.
5. On Apple error 7460/capacity full, refresh inventory once. Select only ownership-proven obsolete Veya certificates not active on another known Mac/install. If none exists, return `VEYA-CERT-046` user-safe capacity guidance without naming certificate internals.
6. Revoke at most one selected owned certificate, refresh inventory, and retry issuance once. Total issue attempts: two. Total revocations: one.
7. After any ambiguous network response, refresh inventory and match CSR public key before reissuing.
8. Candidate certificate is promoted only after DER validation, team/SPKI/validity proof, profile issuance, signing, and install proof.

## Cases

| Case | Result |
|---|---|
| No certificate, capacity free | Issue candidate |
| Valid SPKI match | Reuse |
| Matching cert expires inside renewal window | Keep active; create replacement candidate |
| Certificate exists, key missing | Cannot reuse; ownership from receipts may permit later retirement, not signing |
| Key exists, metadata missing | Match by SPKI to refreshed inventory; reconstruct metadata |
| Metadata points stale cert | Ignore pointer; derive from key/inventory |
| Capacity full, owned obsolete | Bounded revoke-one/retry-one |
| Capacity full, unknown/unrelated | Fail safe; never revoke |
| Second Mac | Reuse only its locally controlled key match; otherwise own candidate and safe capacity rule |
| Reinstall | Rebuild from key/inventory/public match, not cached stage |

Expiry renewal begins 72 hours before Personal Team certificate expiry or earlier if profile policy requires. Apple response schema drift, stale inventory, and clock skew are explicit failures. All Apple mutations carry attempt IDs and redacted response digests.

