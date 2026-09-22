# Vanish signing and certificate architecture

## Provenance warning

The Vanish binary contains isideload identifiers, including an abbreviated commit `3c1a008`. The preserved public checkouts used for source tracing are different commits (`b6d1113` and an iLoader dependency at `f6a4d5d...`). Fork changes are possible. Public source facts are **VERIFIED_FROM_OPEN_SOURCE** and become only **INFERRED** when applied to Vanish.

## Public isideload call graph

```text
SideloaderBuilder
  -> storage + machine_name + MaxCertsBehavior
  -> CertificateIdentity::retrieve_private_key
       storage key = sha256(email) + "/key"
       retrieve PKCS#8 or generate RSA-2048 and store PKCS#8
  -> CertificateIdentity::find_matching
       listAllDevelopmentCerts
       machine_name/machine_id filters
       compare certificate public key with local RSA public key
  -> CertificateIdentity::request_certificate
       create CSR once
       submitDevelopmentCSR, at most four attempts
       on DeveloperError(7460): revoke_others, retry
  -> setup_signing_settings
       InMemoryPrivateKey + X.509 cert + Apple chain + team ID
  -> sign
       derive entitlements from embedded profile
       UnifiedSigner::sign_path_in_place for sorted bundles
  -> install
       AFC upload to PublicStaging
       InstallationProxy install PackageType=Developer
```

## Private key

- **VERIFIED_FROM_OPEN_SOURCE**: `CertificateIdentity` holds an RSA private key and wraps it as `InMemoryPrivateKey` for signing.
- **VERIFIED_FROM_OPEN_SOURCE**: `retrieve_private_key` uses a storage abstraction. It loads PKCS#8 bytes or generates an RSA-2048 key and stores PKCS#8 DER under an account-derived key.
- **VERIFIED_FROM_OPEN_SOURCE**: a `KeyringStorage` implementation stores generic-password blobs; a filesystem storage implementation also exists. The caller selects storage.
- **OBSERVED**: `VanishSideloader` imports generic-password Keychain APIs, not the SecIdentity/ACL API pattern Veya uses.
- **INFERRED**: Vanish stores software private-key bytes through its selected generic-password storage and reconstructs an in-memory signer.
- **UNKNOWN**: Vanish's exact storage backend, access-control policy, key export posture, and deletion behavior.

## Certificate API and matching

- **VERIFIED_FROM_OPEN_SOURCE**: listing uses `listAllDevelopmentCerts`.
- **VERIFIED_FROM_OPEN_SOURCE**: issuance uses `submitDevelopmentCSR` with `teamId`, CSR content, a machine name, and a fresh uppercase UUID machine ID.
- **VERIFIED_FROM_OPEN_SOURCE**: matching compares the public key in an Apple-returned certificate with the locally held private key's public component, and also considers machine metadata.
- **VERIFIED_FROM_OPEN_SOURCE**: revocation uses `revokeDevelopmentCert` with `teamId` and certificate `serialNumber`.
- **OBSERVED**: Vanish helper strings/capabilities include these Developer Services operations and a `max_certs` event/response bridge.
- **UNKNOWN**: Vanish's actual machine name, reuse filters, and ownership ledger.

## Apple error 7460 and capacity

- **VERIFIED_FROM_OPEN_SOURCE**: certificate request loops at most four attempts.
- **VERIFIED_FROM_OPEN_SOURCE**: error code 7460 invokes `revoke_others` according to `MaxCertsBehavior`, then retries.
- **VERIFIED_FROM_OPEN_SOURCE**: behaviors are `Error`, `Revoke`, or `Prompt(callback)`. Default builder behavior is `Error`.
- **VERIFIED_FROM_OPEN_SOURCE**: `Revoke` pops a certificate from the returned candidates and revokes its serial; it does not implement Veya's installation ownership proof.
- **VERIFIED_FROM_OPEN_SOURCE**: `Prompt` passes serial-bearing certificate choices to the callback and revokes the selected serials. iLoader binds this mode and allows up to 300 seconds for a user selection.
- **OBSERVED**: Vanish Electron understands a max-certificates event and response.
- **INFERRED**: Vanish likely uses an interactive policy at capacity.
- **UNKNOWN**: which `MaxCertsBehavior` Vanish selects, which certificate it presents or revokes, whether it protects another Mac's active certificate, and retry outcomes.

Veya should adopt 7460-as-authoritative plus bounded relist/retry, but must not adopt arbitrary revocation or expose certificate selection to consumers.

## Signing

- **VERIFIED_FROM_OPEN_SOURCE**: isideload uses the Rust `apple-codesign` library's `SigningSettings` and `UnifiedSigner`.
- **VERIFIED_FROM_OPEN_SOURCE**: the key is provided as an in-memory signing key; the certificate and Apple chain are attached to signing settings.
- **VERIFIED_FROM_OPEN_SOURCE**: entitlements are read from the embedded provisioning profile and assigned to the main signing scope.
- **VERIFIED_FROM_OPEN_SOURCE**: bundles are collected/sorted and signed in place. The signer handles code objects rather than spawning `/usr/bin/codesign`.
- **VERIFIED_FROM_OPEN_SOURCE**: the profile is embedded as part of the sideload preparation path.
- **OBSERVED**: Vanish's helper contains matching signing capability and no inspected call path established a `/usr/bin/codesign` dependency.
- **INFERRED**: Vanish performs the relevant iOS payload signing in process.
- **UNKNOWN**: exact Vanish fork handling for every nested framework/extension, entitlement rewrite, unusual Mach-O, DER entitlements, and verification policy.

## SecurityAgent/Keychain implication

An in-memory software signer does not require a `SecIdentity`, global Keychain search-list entry, trusted-application ACL for `/usr/bin/codesign`, ChangeACL rights, or partition-list repair. Therefore the specific SecurityAgent failures seen in Veya Builds 1 and 7-11 are structurally absent from the open-source design. This is **VERIFIED_FROM_OPEN_SOURCE** for isideload and **INFERRED** for Vanish.

It does not make key storage trivial. Veya must encrypt key bytes at rest, limit access to the app/helper boundary, zero transient buffers where practical, redact all output, and model backup/multi-Mac semantics explicitly.

