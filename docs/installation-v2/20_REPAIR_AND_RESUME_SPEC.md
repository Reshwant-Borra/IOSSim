# Repair and resume specification

## Repair selection

Repair starts with physical/current-state reconciliation and chooses the smallest owning domain. It does not replay the whole setup sequence.

| Observed fault | Repair boundary | Explicitly preserved |
| --- | --- | --- |
| helper/component mismatch | reinstall Veya | all Keychain/device resources |
| Lockdown record invalid | initial USB trust | RemotePairing and installed apps until new trust works |
| Apple session expired | authorization only | key/cert/App IDs/profiles/installed apps |
| profile near expiry | issue profiles, re-sign, upgrade | active old app until upgrade verified |
| one app missing | sign/install that component | identity, other app, pairing |
| DDI wrong build | acquire/personalize/mount support | signing/install/pairing |
| AppService tunnel stale | reconnect tunnel/RSD | DDI and all provisioning |
| RemotePairing invalid | staged candidate replacement | active old pairing |
| LocalDevVPN missing | guide App Store install | pairing and developer support |
| runner mapping stale | rewrite/verify mapping, relaunch | main app, identity, pairing |
| Rich runtime proof fails | runner/session repair | never regenerate certificate first |

## Resume protocol

On launch the helper acquires the SetupKey lease, validates the journal hash chain and generation, resolves any `STARTED` entry without `COMMITTED`, and rechecks its domain. If the external mutation is visible, it commits a reconciled receipt; if not, it retries safely or marks the candidate abandoned. It never assumes an interrupted call failed.

Human-action states persist an action ID, reason, safe instructions, prerequisite digest, creation/expiry, and last observation. Resume requires the same selected device/team/release; otherwise the action is invalidated and recomputed.

## Renewal

Profiles/certificates have warning and hard-expiry margins. Renewal uses read-before-create, creates candidate profiles, signs into a staging directory, validates entitlements and identity, upgrades one component at a time, verifies device inventory/launch, then promotes state. Old cache/state remains until both main and runner succeed. A certificate is replaced only when required and the old managed key is retained while any installed/artifact state references it.

## Retry budgets

- Device reconnect/tunnel: 3 quick attempts, then user action.
- Apple/TSS network: 3 transient attempts honoring `Retry-After`; rate limit suspends until server time.
- Install/DDI upload: one retry only after inventory/mount reconciliation.
- Human trust/Settings/VPN: no artificial failure countdown; pending action expires after a documented session window and is recreated.
- Rich runtime: one session rebuild, then typed failure and Clear.

Support can invoke a named domain repair with the same reconciliation engine. There is no “delete everything” button in normal UI.
