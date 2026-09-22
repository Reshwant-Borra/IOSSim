# Implementation Simulation

## Fresh install

Artifact observer proves package -> journal creates installation/generation -> device observer requests Trust/unlock/Developer Mode as needed -> auth candidate validates -> team/device reconcile -> key candidate wraps/proves -> certificate candidate issues -> profile candidate validates -> payload candidate builds/signs/verifies -> install inventory/launch prove -> DDI/pair/VPN reconcile -> Rich proof clears -> all evidence promotes -> READY.

## Reinstall and app restart

Engine loads journal, expires lease/live proof, observes key/cert/profile/phone/pair/VPN. Valid durable resources are reused; only liveness/Rich proof reruns. Missing metadata reconstructs from key SPKI + Apple inventory. No linear replay and no repeated Apple auth when session validates.

## IOSSim migration

Migration ledger inventories legacy state without UI. Exportable matching key becomes encrypted candidate; otherwise a new key is made while legacy active remains. New pipeline installs/proves, journal promotes, legacy writes disable, cleanup deferred. Crash at any item resumes ledger.

## Capacity full / second Mac

Certificate planner refreshes inventory. If one obsolete Veya certificate is proven by local key/control and not known active, it records intent, revokes once, refreshes, issues once, then continues. Unknown/unrelated or another Mac's unproven certificate causes safe user-action result. Second Mac uses a distinct installation/key and cannot claim the first Mac's resources.

## Certificate or profile expired

Active resource is observed invalid. A new certificate/profile is created as candidate; prior artifacts stay recorded. Candidate payload is signed/installed/proven and promoted. Expired Apple resources need not be revoked unless capacity and ownership policy require it.

## Interrupted sign/install

Signing touches only generation staging; crash leaves source/active intact and candidate is verified or discarded on resume. Install disconnect is `ambiguous`; reconnect inventory determines whether exact candidate is present. If present, continue proof; if absent, retry; if present but invalid, reinstall prior valid artifact when possible.

## Pairing or VPN failure

Pairing candidate may be delivered but cannot promote without possession + developer-service proof; active remains. VPN configuration may be installed/running but cannot advance until endpoint nonce succeeds. User approval creates a waiting state. Restart observes phone receipts and resumes.

## Mac or phone reboot

Lease and connection/live evidence expire. Durable key/cert/profile/payload/pairing records remain candidates/active. Engine opens a new connection generation, validates durable resources, resumes VPN and full runtime proof. It does not reissue certificates merely because READY expired.

## Determinism check

In every simulation the next transition is a pure function of the same snapshot/desired/policy; every external mutation has a pre-recorded idempotency identity; active retirement follows candidate proof; and ambiguous results force observation. There is no scenario requiring the UI, test harness, or legacy signer to choose hidden behavior.

