# Resource ownership model

| Resource | Owner / scope / location | Secret | Create and validate | Reuse, rotation, deletion | Support visibility |
| --- | --- | --- | --- | --- | --- |
| Release manifest | release pipeline; app bundle | no | generated from built/mounted artifact; signature/hash verify | immutable per release; delete with app | full public fields |
| Setup snapshot/journal | helper; release/team/device/artifact; Application Support | safe metadata | atomic journal/snapshot and CAS | migrate explicitly; delete only selected setup identity | states/codes/times, salted IDs |
| Operation lease | helper; SetupKey; Application Support | no | OS lock + PID/start/boot identity | expires only after process proof | contention/timing only |
| Apple session | Apple adapter; account/machine; Keychain | yes | auth/2FA then server validation | reuse until expiry/revocation; user sign-out deletes | status/expiry class only |
| Signing private key | signing service; team; user Keychain | yes, non-exportable | tagged RSA key, public-key/cert match, disposable signing probe | rotate when cert requires; remove only unreferenced managed orphan | never; public fingerprint prefix only |
| Certificate | signing service; team/key; Keychain + state | public DER but security-relevant | Apple issuance and exact key match | retain through referenced profiles/apps; revoke/delete deliberately | expiry and salted fingerprint |
| Device registration | Apple service; team/device | raw ID sensitive | read-before-create/list match | reuse; no automatic removal | state + salted device ID |
| App IDs | Apple service; team/bundle | no | deterministic exact ID and capability validation | reuse; do not churn | bundle role, not account data |
| Provisioning profiles | artifact service; team/device/bundle; owner-only keyed store | sensitive blob | decode, cert/team/device/entitlement/expiry validation | renew staged; delete after no artifact references | metadata only, no blob |
| Unsigned payload | release; app resources | no | release hash/manifest | immutable | hashes/roles |
| Signed staging app | operation; private staging directory | sensitive | codesign and profile verification | delete after install/recovery | metadata only |
| Installed main/runner | iPhone; team/device/bundle | no | Installation Proxy inventory and launch | staged upgrade; uninstall only explicit/reset | bundle role/version/hash |
| Lockdown pair record | usbmux/host; host/device | yes | Apple Trust flow then Lockdown session | reuse; replace without deleting good record | status/fingerprint only |
| RemotePairing active record | RemotePairing service; team/device; Mac Keychain and phone Keychain | yes | native validate + possession/operational proof | staged rotation; explicit per-device deletion | status/public fingerprint prefix |
| Pairing request/bootstrap/envelope | operation; phone container | yes | request-bound AEAD, short TTL | one use; delete on success/expiry | counts/timestamps only |
| DDI assets | DeveloperSupport service; OS build/identity; 0700 cache | Apple binary asset | signed manifest/hashes/provenance + exact BuildIdentity | content-addressed; quota; retain prior verified | provenance/build/digests, no bytes |
| TSS personalization ticket | DeveloperSupport; device/build; private cache if needed | device-specific | Apple TLS/TSS and mounter validation | TTL/build scoped; delete on invalidation | status only |
| LocalDevVPN app/config | external publisher/user/iOS | VPN config sensitive | App Store receipt/version plus Apple VPN approval | publisher updates; user removes in iOS | app/version/state only |
| Runtime mapping | main app container; team/device/artifact | contains pairing reference, sensitive | House Arrest write/read + digest | rotate with pairing/runner; remove on reset | status/digest only |
| Support bundle | user-export operation; temporary/output path | must be nonsecret | allowlist schema and post-build scanner | temporary inputs removed; user owns output | itself |

No owner may delete a resource solely because another domain failed. Reset operations enumerate the exact scope and show impact before removing Keychain or device resources.
