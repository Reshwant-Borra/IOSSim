# Adversarial Blueprint Review

| Attack/failure | Detected? | Safe/recoverable? | User action / test |
|---|---|---|---|
| Crash after certificate creation | CSR/idempotency + refreshed SPKI inventory | Yes; attach orphan as candidate | none; crash test |
| Certificate created, metadata write fails | Apple inventory finds SPKI; journal marks ambiguous | Yes; never issue twice blindly | none; disk fault |
| Key file exists, wrapper lookup fails | typed key observation | Active artifact survives; key may require replacement | Keychain repair/account capacity only; real test |
| Apple returns stale inventory | freshness/server digest and bounded refresh | Stop before revoke/issue ambiguity | retry later; fixture |
| Two Macs / unrelated certs | installation IDs + ownership ladder | Unknown never revoked | capacity action may be required |
| Profile expires mid-install | profile timestamp checked at each edge | Candidate rejected; active retained/rollback | retry renewal |
| Phone disconnects in install | transport ambiguity | inventory decides before retry | reconnect/unlock |
| Phone reboots after pairing delivery | candidate receipt + no promotion | Resume possession proof | reopen phone/VPN |
| VPN says running, endpoint unreachable | endpoint nonce fails | Never READY; active config retained | retry/phone action |
| AppService works, runner stale | exact inventory/artifact identity | Fail before TestManager | reinstall candidate |
| Rich proof targets wrong app/device | nonce + device/session binding | Reject and clear | none |
| Update with candidate present | schema/generation recovery before new desired state | Finish/quarantine old candidate | none |
| Partial IOSSim migration | item ledger | Idempotent resume; no dual write | none |
| Username/app path changes | no absolute user/app path in identity | Re-resolve packaged resources | none |
| Keychain reset | wrapper missing | No unsafe reuse; new key/cert candidate | Apple auth/capacity possible |
| Clock wrong | server times and skew check | Stop expiry/promotion decisions | fix system time |
| Network/API schema changes | typed transport/schema validation | No destructive mutation after ambiguity | retry/update Veya |
| DDI provider disappears | cache/provenance/status | Existing validated cache may work; otherwise unsupported | network/update |
| Helper crashes | expired lease and operation receipt | Resume observation | relaunch |
| Disk fills/journal corrupts | atomic write/corruption checks | Prior journal survives; conservative recovery | free disk/support if both copies bad |
| Repeated force quit | every step journaled/idempotent | No active retirement before promotion | relaunch |

## Blueprint corrections made by this review

1. Apple issuance is journaled before request and an ambiguous response forces SPKI inventory refresh; a plain retry is prohibited.
2. READY evidence expires on any connection generation change and requires a current liveness check.
3. The prior signed payload is retained because same-bundle install can replace the phone's active app before final promotion.
4. Keychain upgrade/no-UI behavior is a blocker, not an assumed macOS property.
5. The signer policy inventories the full bundle graph and does not copy isideload's shallow signing shortcut.
6. Production DDI sourcing remains a named external blocker/supported-build constraint.
7. A bad clock blocks certificate/profile promotion rather than guessing.
8. Disk-full after external mutation enters ambiguous recovery, never compensating deletion.

No remaining contradiction prevents implementation foundations M0-M3. M4/M5 have explicit stop gates before routing production traffic.

