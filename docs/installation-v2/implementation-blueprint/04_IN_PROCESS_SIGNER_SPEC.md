# In-Process Signer Specification

## Decision

Use crate `isideload-apple-codesign` exactly `=0.29.11`, imported as `apple-codesign`, locked by registry checksum. License is MPL-2.0; retain notices, SBOM entry, and source-offer/compliance review. This is the maintained signing fork used by the preserved isideload source and exposes `SigningSettings`/`UnifiedSigner` with in-memory private keys.

Choose architecture C: the packaged Swift provisioner invokes a narrow Rust C ABI in the existing universal dylib. Create a pure Rust workspace crate `native/veya-signing-core`; `iossim-device-bridge` depends on it and exports ABI functions. Do not ship `rcodesign`, spawn `/usr/bin/codesign`, or create another helper.

## Why this exact choice

- It matches the verified open-source call path used by current isideload and accepts in-memory key material.
- It handles Mach-O, CMS, bundles, resource sealing, frameworks, dylibs, and nested bundles in Rust on both macOS architectures.
- It removes SecIdentity and third-party Keychain access from iOS payload signing.
- The fork is not blindly trusted: its own ecosystem still has entitlement/nested-framework edge reports. Veya adopts the primitive, not isideload's shallow policy.

## Rust API

```rust
pub struct SignRequest<'a> {
    pub input_bundle: &'a Path,
    pub output_bundle: &'a Path,
    pub pkcs8: Zeroizing<Vec<u8>>,
    pub certificate_chain_der: Vec<Vec<u8>>,
    pub profiles: BTreeMap<BundleId, Vec<u8>>,
    pub entitlements: BTreeMap<BundleId, PlistDictionary>,
    pub expected: ExpectedBundleGraph,
}
pub fn sign_and_verify(req: SignRequest<'_>) -> Result<SigningReceipt, SigningError>;
```

FFI exports ABI/version, sign, inspect, verify, cancel, and result-free. Requests use length-bounded JSON for paths/manifests plus a separate byte pointer for PKCS#8; response JSON contains no key/certificate session secret. Every panic is contained. Input key buffers are copied into `Zeroizing`, caller memory is zeroed immediately after return, and crash dumps are disabled for the signing scope where supported.

## Signing policy

1. Build a complete bundle graph before modifying output: main app, `.appex`, nested `.app`, frameworks, dylibs, XPC/bundles, and every Mach-O.
2. Require graph equality with a versioned expected manifest. Unknown signable code is a failure, not silently skipped.
3. Copy immutable source into a same-volume candidate directory. Never sign the shipped source or active candidate in place.
4. Map a provisioning profile and entitlements to each provisioned executable bundle ID. Frameworks/dylibs receive no application entitlements/profile unless the platform format specifically requires it.
5. Derive entitlements as the intersection of payload requirements, profile grants, and a Veya allowlist. Reject team/app identifier mismatch and forbidden inherited entitlements.
6. Sign leaf code before containers and main executable last. Do not use the isideload `shallow=true` shortcut as Veya's policy.
7. Independently reopen every Mach-O and verify CodeDirectory, CMS chain, sealed resources, designated identifiers, profile, entitlement equality, architectures, and executable modes.

## Required fixtures and acceptance

- Minimal app; Veya payload; XCTest runner; framework; dylib; nested app; appex; malformed Mach-O; stale signature; symlink/resource edge; arm64-only payload.
- Compare structure/entitlements against a known-good Apple `codesign` fixture without invoking codesign in production.
- Sign deterministically apart from documented CMS/time fields; inventory digests must remain stable.
- Install and launch the exact Veya payload on the qualification iPhone before the old signer is removed.
- Run packaged helper tests on clean Apple Silicon and Intel Macs with network denied during signing.

Any nested code mismatch, silent omission, executable mutation outside the candidate, private key persistence, or dependency on repository/Cargo at runtime fails M5.

