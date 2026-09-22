# Reinstall Algorithms

All cases run observe/derive/plan; none trusts "setup complete." `Promote` always requires current proof.

| Scenario | Observe | Reuse / repair | Replace / promote / retire |
|---|---|---|---|
| Same build reinstall | Journal, artifact hash, installed inventory, live readiness | Reuse valid key/cert/profile/payload/pairing/VPN | Reprove runtime; replace only invalid domain |
| New build reinstall | Old journal/payload plus new manifest | Reuse key/cert/pairing if compatible | Candidate profile/payload as needed; promote after launch/runtime |
| `Veya.app` deleted | Application Support, Keychain, phone state | Reconstruct packaged artifact identity; validate state | No Apple mutation unless mismatch |
| Application Support retained | Validate journal and file ownership | Normal resume | Quarantine corrupt candidates |
| Application Support removed | Keychain inventory, Apple inventory, phone inventory | Rebuild ownership only from cryptographic/server/device evidence | New journal; unknown stays unknown |
| Key store retained | Decrypt/sign probe + SPKI match | Reuse | Rotate only on failure/expiry policy |
| Key store lost | Wrapper/ciphertext classification | Cannot reuse certificate for signing | New key/cert; retire old only with prior ownership proof |
| Metadata lost | Key SPKI + Apple inventory | Reconstruct | Never select by label |
| Certificate retained | Validity/revocation/SPKI | Reuse if controlled | Replace candidate before retiring |
| Profile retained | CMS/team/device/bundle/cert/expiry | Reuse when >24h and desired capabilities match | Renew transactionally |
| Phone payload retained | Fresh inventory/version/team/launch | Reuse if exact desired artifact | Candidate install otherwise |
| Pairing retained | Possession + service proof | Reuse | Candidate pairing before retirement |
| VPN retained | Exact app/config plus endpoint challenge | Reuse | User approval only when Apple requires |

## Resume rules

- Interrupted key/cert/profile/sign operations resume from candidate observation and idempotency key.
- Interrupted install is ambiguous until fresh inventory; never uninstall to "reset."
- Interrupted pairing/VPN retains active state and revalidates candidate receipts.
- Reboot invalidates leases and live evidence, not durable ownership.
- Expired certificate/profile creates a replacement candidate while preserving last artifact for diagnostic/rollback purposes.
- Two Macs have distinct installation IDs/keys. Neither may revoke the other's certificate without local key control plus issuance ownership and proof that it is not active.

User actions are limited to Apple auth/2FA, Trust/passcode/Developer Mode, VPN approval, reconnect/unlock, and genuinely full capacity with no safely owned victim. User-facing capacity guidance says Veya cannot safely free an account resource automatically; it does not teach certificate internals.
