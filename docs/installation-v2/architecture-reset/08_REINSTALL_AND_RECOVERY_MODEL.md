# Reinstall and recovery model

## Policy

Every resource is either **active**, **candidate**, **retired**, **unknown**, or **absent**. Detection inventories local encrypted key records, Veya metadata, Apple certificate/profile inventory, installed apps, pairing receipts, and live device services independently. Metadata is evidence, never sole ownership proof. Irreversible revocation requires a persisted intent plus exact serial/fingerprint and Veya installation ownership evidence. Unknown resources are preserved.

## Scenario matrix

| Scenario | DETECT / PROVE OWNERSHIP | REUSE | REPAIR / REPLACE | REVOKE / FAIL SAFE | USER ACTION |
| --- | --- | --- | --- | --- | --- |
| A. clean Mac + clean account | empty local inventory; Apple team/cert list | none | create key, cert, resources, profiles and install as candidates | no revoke | auth/2FA, Trust, Developer Mode, profile/VPN approval as required |
| B. unrelated cert occupies slot | Apple cert exists without Veya machine marker, ledger or matching key | never treat as Veya | use free slot if any | never revoke unknown; if full, stop with account-capacity action that does not expose certificate internals | user may manage Apple account outside Veya |
| C. Veya previously installed | validate journal, key/cert public-key match, installed IDs/team and live services | all still-valid exact resources | smallest stale domain | only owned inactive cert if issuance is blocked | only expired Apple-controlled actions |
| D. app deleted, certificate remains | local ledger + Apple serial/machine marker; key may or may not remain | cert only if matching key exists | reinstall app; issue replacement only if key absent | revoke owned inactive cert only if capacity blocks | normally none |
| E. app deleted, private key remains | encrypted key fingerprint plus signer proof | key; match remote cert by public key | reconstruct metadata, profile and app | no revoke unless matched cert is expired/inactive and capacity blocks | normally none |
| F. app deleted, metadata remains | metadata is a locator; prove key and Apple cert independently | proven pair only | rebuild missing app/state | never revoke from metadata alone | normally none |
| G. cert remains, key gone | exact ledger/machine marker plus absence of every key candidate | cannot reuse identity | create new key/cert candidate | revoke old cert only if Veya-owned, inactive and capacity blocks; otherwise preserve | none unless no safe slot |
| H. key remains, cert gone | signer proves key; Apple list has no public-key match | reuse key | submit CSR for same key, new profile | no revoke | none |
| I. metadata gone, key+cert remain | enumerate Veya encrypted keys, public-key match Apple cert, validate team/date | pair and reconstruct metadata | regenerate profiles if necessary | no revoke | none |
| J. metadata points stale cert | public-key/serial/date mismatch against Apple | reuse key if valid | find matching cert or request replacement; retire metadata | only exact owned inactive stale cert when needed | none |
| K. certificate expired | certificate dates and Apple inventory | key may be reused | request new cert/profile and upgrade install | expired owned cert may be retired/revoked only under capacity policy | auth if session expired |
| L. profile expired | decode profile dates/bindings; cert/key still valid | identity and App IDs | request profile, re-sign, upgrade, re-prove runtime | no certificate revoke | profile Trust only if Apple/device asks |
| M. Apple account reused on another Mac | remote machine marker/install ID differs; no local key match | never reuse other Mac's cert without key | use separate local key/cert if capacity | never auto-revoke other-install cert | explain account capacity without asking user to choose blindly |
| N. Veya on two Macs | each has installation ID/key marker; Apple inventory shows both | each reuses its own pair | renew independently | each may revoke only its own inactive cert, never the other's active cert | capacity action may be unavoidable |
| O. interrupted during cert issuance | persisted candidate key/CSR request ID; relist Apple certs by public key/request ID | issued match if found | resume same candidate; do not create another key first | reconcile recovery intent/serial before any revoke | none |
| P. interrupted during signing | candidate workspace/digest lacks completed signed manifest | source/profile/key | discard workspace and re-sign | no revoke | none |
| Q. interrupted during installation | install intent plus current device inventory | installed exact components | install only absent/mismatched owned component; upgrade, no broad uninstall | preserve unknown/wrong-team app and block overwrite | profile Trust if needed |
| R. interrupted during pairing | active/candidate generation and phone receipt | prior active if proof valid | resume candidate delivery/challenge or discard candidate | never delete valid active pairing | Trust if pairing daemon requires it |
| S. interrupted during VPN setup | phone inbox/approval status and live tunnel probe | approved configuration if live | relaunch/poll; restage only setup message | fail without altering other domains | install/approve/enable VPN |
| T. iPhone reboot | device disappears/returns; volatile proofs invalid | durable signing/install/pairing if revalidated | remount developer support, re-establish VPN/RSD/AppService, rerun runtime proof | no provisioning mutation | unlock; Developer Mode confirmation only if Apple asks |
| U. Mac reboot | lease expiry and interrupted intent; live services gone | durable Apple/resource/install state | reconcile intent, reconnect volatile services | never infer irreversible call failed/succeeded; relist first | reconnect/unlock phone |
| V. Veya upgrade | artifact/schema/version changes; resource bindings inventoried | compatible state and phone data | migrate journal once; candidate-sign/install new artifacts; prove before promote | retain rollback state until promotion | normal OS security prompt only |
| W. IOSSim -> Veya | legacy IDs/paths/services explicitly classified | stable bundle IDs, phone IDs, pairing and valid account session where safe | one-time import into new journal/key store; reissue signing key if legacy ACL cannot be used silently | never broad-delete or revoke legacy resources | no certificate concepts; only Apple-required actions |

## Recovery precedence

1. Observe without mutation.
2. Verify selected device, account and team continuity.
3. Reconcile any previously persisted irreversible intent against Apple/device truth.
4. Prove resources cryptographically or by live authoritative inventory.
5. Reuse exact active resources.
6. Repair metadata or volatile services.
7. Replace through a candidate transaction.
8. Revoke only an owned inactive certificate when issuance is actually blocked.
9. Fail safe and preserve unknown state.

## Expiration and renewal

Renew before the configured safety window. Create candidate certificate/profile/signed artifacts, install as an upgrade, verify inventory and Rich runtime, then promote. The existing active installation remains authoritative until the candidate proves READY. After six months, certificate expiry is handled by the same transaction; after seven days, free-team profile renewal is expected, not exceptional.

