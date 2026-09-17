# IOSSim Security Model

## Secrets and persistence

| Material | Owner/storage | Lifecycle | Never allowed |
|---|---|---|---|
| Apple password | transient authentication input | consumed by GrandSlam SRP flow | logs, journal, support bundle, repository |
| Apple 2FA code | transient challenge input | single challenge attempt | persistence or automatic replay |
| Developer Services session/cookies/tokens | Mac Keychain-backed scoped session | validate expiry/team; refresh through classified auth | plaintext Application Support/support export |
| Signing private key | Mac Keychain / IOSSim signing identity | reused while certificate/profile remain valid | payload bundle, journal, logs |
| Mac RemotePairing plist | generic-password Keychain item `com.iossim.remote-pairing.v1`, account `<team>:<stable UDID>` | validate/reuse; rotate only on corruption or explicit rejection | UserDefaults, ordinary files, support export |
| Phone RemotePairing plist | iPhone Keychain service `com.iossim.on-device-dvt-poc.rppairing`, account `primary` | atomic update/add after semantic validation | UserDefaults, Documents, receipt, logs |
| Bootstrap import key | protected app-private setup inbox | phone creates; Mac reads over trusted House Arrest; delete after success | receipt/support logs/long-term storage |
| Pairing envelope | AES-GCM ciphertext in app-private Application Support | one-time delivery; delete after successful import | plaintext pairing bytes |
| Receipt | protected app-private Application Support | safe validation evidence | private key, `alt_irk`, import key, plaintext pairing |
| LocalDevVPN readiness request/receipt | protected app-private setup inbox | non-secret request ID, app binding, endpoint, status, timestamp | Apple credentials, pairing material, VPN configuration or traffic |

Keychain accessibility for the phone pairing record and transient protected writes is after-first-unlock/complete file protection as appropriate. USB Lockdown trust, developer-services transport, and runtime RemotePairing are separate security relationships.

## Validation and binding

Pairing records require 32-byte public/private keys, non-empty identifier, and optional 16-byte `alt_irk`. Mac records are bound to stable Lockdown UDID and team, then natively validated. Delivery binds request/envelope/receipt to device, team, exact main bundle, nonce, pairing identifier, and SHA-256 public-key fingerprint. Timestamps and schema versions prevent unbounded replay. A transient timeout does not justify key regeneration.

Runtime mapping contains no secret; it binds a safe device hash, team, current main ID, and runner ID. Mac-side semantic readback is authoritative and the phone additionally checks current app identity before accepting it.

## Logs and support reports

Protocol diagnostics are length-bounded and redacted. Support schema 7 contains component HEAD/dirty provenance, public hashes/fingerprints, state/error names, versions, and safe device metadata. It excludes passwords, 2FA, SRP values, tokens/cookies, signing keys, pairing bytes/private key/`alt_irk`, bootstrap keys, encrypted-envelope plaintext, and route coordinates unless a separate authorized diagnostic explicitly supplies them.

Static inspection found no print/log call in the phone inbox implementation. POC checks verify receipt binding and that serialized receipt bytes do not contain the bootstrap key. The inbox writes only bootstrap, encrypted envelope supplied by the Mac, and non-secret receipt under private Application Support; pairing plaintext moves directly from AES-GCM decryption into semantic validation and Keychain storage.

The fresh prepared main, runner, and embedded UI-test bundle were inspected after Xcode 27.0 compilation. None contains an embedded provisioning profile or an added distribution entitlement. The compiled inbox markers are present, and the serialized receipt test confirms that no bootstrap key or private pairing field is emitted. Successful inbox processing removes request/bootstrap/envelope; a persistent startup error terminates the bounded watcher for that activation rather than creating an infinite retry loop.

Physical refresh generation 5 completed encrypted delivery and verified the phone receipt without exposing pairing material in the journal or command output. The recorded stages contain only classifications, timestamps, safe identifiers/fingerprints, and status—not the private key, `alt_irk`, bootstrap key, or decrypted plist.

The LocalDevVPN gate does not request NetworkExtension entitlements, create a VPN manager, inspect tunnel traffic, or persist secrets. It launches the separately installed app and records only whether the established TCP endpoint is reachable. Its physical receipt contains no pairing or Apple-account material.

## Trust boundaries

- Build machine: trusted to compile with Xcode/SDK and create verified profile-free artifacts; must record dirty source truth.
- Distributed Mac app: signed bundle/manifest/bridge integrity boundary; no runtime source build.
- Consumer Mac account: Keychain boundary for Apple/signing/pairing secrets.
- usbmux/Lockdown: selected physical-device transport and computer trust boundary.
- iPhone app sandbox/House Arrest VendContainer: exact app-private transfer boundary with allowlisted paths.
- Apple Developer Services/TSS: TLS-validated external signing/personalization authority.
- Release operations: only authority that may approve a DDI provider/asset provenance policy.

## Failure policy

Verify before mutation; repair one layer; keep retries bounded. Never clear all Keychain entries, uninstall as generic recovery, log raw native payloads, weaken DDI hashes, use an unofficial DDI mirror, or regenerate signing/pairing because another layer failed. User actions such as unlock, Trust, Developer Mode, 2FA, and developer-profile trust pause setup explicitly.
