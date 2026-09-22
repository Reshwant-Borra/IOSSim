# M10 Result — Authoritative Runtime READY

Status: **SOFTWARE_GATE_PASS (engine) / PHYSICAL_BLOCKED_HUMAN**.

## Implemented (`Installation/RuntimeReadiness.swift`)

- `.runtime` is satisfied only by `runtimeFullChainProof` evidence that is (a) fresh (TTL 10 minutes, `validUntil`), (b) produced on the current connection generation for the selected device, and (c) bound through the record digest to the exact active `.application`, `.developerSupport`, `.pairing`, and `.vpn` records. Any upstream replacement, reconnect, or device change makes it `stale`. Expiry makes it not fresh, and the planner re-proves.
- The proof runs in `prove` (the candidate only names the binding). The production prover `RichRuntimeProver` uses the surviving Rich inbox protocol, whose receipt validation already enforces request ID, device hash, identities, cleanup, and 300 s freshness. The prove step additionally rejects receipts not completed during this proof.
- Without upstream actives the runtime is `missing`, and nothing can be proven.

## Defect fixed (P2, M1 design gap)

Journal evidence and retiring records grew without bound. With 10-minute runtime re-proofs, the fsynced
journal would grow indefinitely. `promote` now keeps at most 4 retiring records per domain (signing keys
excepted: their SPKI digests are M6 ownership proof) and drops evidence no retained record references.

## Tests (`RuntimeReadinessTests` 5/0; engine regression 46/0)

READY needs a fresh proof and is re-proven after expiry; reconnect invalidates; cleanup failure is
never READY and an expired stored proof cannot stand in; no upstream means no proof; 12 re-proofs keep
the journal bounded.

## Production integration (continuation)

`RichRuntimeProver` (unused, with the app bundle fixed at construction) was replaced by `JournalRuntimeProver`: it
reads the installed payload's team-derived bundle IDs from the journal, takes the device's current pairing generation
from the v2 pairing store, obtains a fresh developer-services session, and binds the phone request to the engine
binding digest (application/DDI/pairing/VPN records + device + connection) and the active profile digest. It is
composed as `.runtime`'s prover in production.

## Not done

- The Build 11 cached-READY path (`ConsumerProvisioningStateStore.loadRuntimeProofReceipt` driving UI state) is still the shipping route and is removed with legacy routing (M11).
- Physical full chain (TestManager/XCTest/Rich): BLOCKED_HUMAN.
