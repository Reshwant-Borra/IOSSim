# Pairing lifecycle

## Separate pairings

- **Lockdown pairing** establishes Mac/iPhone USB trust and a usbmux pair record after Apple’s Trust UI.
- **RemotePairing/RPPairing** gives the phone app credentials for phone-local developer-service access.
- **Developer profile trust**, **Developer Mode**, and **VPN approval** are separate gates.

## Initial Lockdown pairing

The native ABI adds `lockdown_pair_begin/poll/validate` around pinned idevice `LockdownClient::pair_once`, usbmux `get_buid`, serialization, and `save_pair_record`. The wrapper selects USB connection ID, returns typed pending/denied/passcode errors, bounds polling, persists only a complete record, and validates a Lockdown session. Wi-Fi is not eligible for first onboarding. `CONFIRMED_OPEN_SOURCE_REFERENCE`

```text
NO_PAIR_RECORD -> PAIR_REQUESTED
 -> WAITING_FOR_UNLOCK_OR_PASSCODE
 -> WAITING_FOR_USER_TRUST
 -> PAIR_RECORD_CREATED
 -> PAIR_RECORD_PERSISTED
 -> PAIR_RECORD_VALIDATED
```

## RemotePairing staged replacement

```mermaid
sequenceDiagram
  participant M as Mac helper
  participant P as Phone app
  participant D as Developer service
  M->>M: keep active A; create candidate B
  M->>P: request(requestID, identities, expiry, challenge)
  P->>P: fresh key/nonce bound to requestID
  M->>P: AEAD envelope(B, AAD=context)
  P->>P: import B into candidate slot
  P-->>M: import receipt + possession response
  M->>P: fresh challenge / pair-verify
  M->>D: authenticated RSD/developer-service probe using B
  M->>P: promote B
  M->>M: promote B; retire A
```

The AEAD additional data binds schema, requestID, selected device hash, team, app bundle/artifact set, creation/expiry, bootstrap public material, and candidate fingerprint. Bootstrap material is single-use and never reused across request IDs. Receipts contain no private record.

Possession proof must use a protocol operation whose response can only be produced by the imported candidate key/record, or a cryptographic challenge signed/MACed by candidate material with a verifiable public binding. A copied receipt file is insufficient. Operational proof then establishes authenticated RSD/developer-service use; Rich runtime remains a later state.

Failures delete only candidate B and transient files. Active A remains until both sides acknowledge promotion. If one-sided promotion crashes, journal reconciliation compares public fingerprints and completes/rolls back safely. Stale request/envelope/receipt files have short TTLs and exact request IDs.
