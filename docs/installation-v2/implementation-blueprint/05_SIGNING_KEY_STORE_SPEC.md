# Signing Key Store Specification

## Design

Generate a 2048-bit RSA key in the packaged provisioner using audited system randomness. Store its PKCS#8 private bytes only as AES-256-GCM ciphertext. The per-installation 256-bit wrapping key is a macOS data-protection Keychain generic-password item; it is never a SecKey, SecIdentity, certificate, signing identity, or input to `/usr/bin/codesign`.

Locations:

- Ciphertext: `~/Library/Application Support/Veya/secrets/signing-keys/<keyID>.vkey`, directory `0700`, file `0600`.
- Wrapping item: service `com.veya.signing-wrap.v1`, account `<installationID>`, data-protection Keychain, `AfterFirstUnlockThisDeviceOnly`, synchronizable false.
- Public metadata: journal key ID, SPKI SHA-256, algorithm, creation time, ciphertext digest/version. No private bytes.

Ciphertext envelope fields are magic/version, key ID, algorithm, PBKDF absent, 96-bit random nonce, AES-GCM ciphertext/tag, and associated-data digest. AAD binds schema, installation ID, key ID, algorithm, and public-key hash. The wrapping key never leaves process memory longer than the unwrap call.

## Why wrapping-only Keychain changes the failure class

Veya itself reads a generic secret with `kSecUseAuthenticationUIFail`; no external `codesign` process requests use of a private SecKey. There is no Keychain search-list mutation, SecIdentity construction, trusted-application ACL, partition list, login-Keychain key lookup, or authorization prompt fallback. An interaction-not-allowed result is a classified failure and may never be retried with UI enabled.

The packaged provisioner is the sole creator/reader. Its designated requirement and access behavior must be proven across signed upgrades. If data-protection Keychain access cannot meet the no-prompt upgrade test, implementation pauses for design review; plaintext/file-only fallback is forbidden.

## Interface

```swift
protocol SigningKeyStore: Sendable {
  func inventory() async throws -> [SigningKeyDescriptor]
  func createCandidate(generation: Generation) async throws -> SigningKeyCandidate
  func withUnlockedPKCS8<R: Sendable>(keyID: KeyID,
    _ body: @Sendable (UnsafeRawBufferPointer) async throws -> R) async throws -> R
  func importCandidate(_ legacy: ExportedLegacyKey, generation: Generation) async throws -> SigningKeyCandidate
  func retire(keyID: KeyID) async throws
}
```

No API returns `Data` beyond the closure. Logs and errors contain key ID/public hash only.

## Lifecycle and recovery

- Creation writes wrapping item, encrypted candidate file, then proves decrypt/parse/sign/verify before journal promotion.
- Existing key reuse requires decryptability, RSA parameters, public hash match, certificate match, and a local sign/verify probe.
- Missing wrapper + ciphertext means unrecoverable local key; retain evidence, create a new candidate, and reconcile the Apple certificate without claiming old-key ownership unless certificate metadata independently proves it.
- Missing ciphertext + wrapper is an orphan wrapper; do not reuse. It may be deleted only after no journal/legacy reference exists.
- Corruption is detected by GCM and digest and never repaired in place.
- Retirement first removes journal active use, then ciphertext, then wrapper only when no keys use it. Deletion failures are recorded and retried.
- `ThisDeviceOnly` intentionally prevents migration via backup/another Mac. A second Mac creates its own key/certificate subject to safe capacity policy.

## Threat model

Protected: at-rest key theft from copied Application Support, casual same-user inspection, support bundles, logs, rollback substitution, tampered ciphertext. Not fully protected: a malicious process already running as the user while Veya is unlocked, debugger/root, compromised Veya binary, or memory scrape during signing. Mitigations are code signing/designated requirement, `0600`, no IPC plaintext, zeroization, no core dump, artifact verification, journal digest binding, and short key lifetime in memory. Secure Enclave is rejected because its non-exportable P-256 keys do not satisfy the RSA PKCS#8/in-memory signer and Apple Personal Team certificate path.

