# Packaging and Artifact Gates

## Before any build number change

Package an unnumbered local candidate from a clean worktree/CI input only after M0-M10. Packaging tests operate on copied output and do not create Build 12/DMG until the entry gate authorizes it.

## Gate set

1. Compile `IOSSimMac`, provisioner, qualifier, auth diagnostic as universal where shipped; compile one universal Rust dylib containing transport + signer.
2. `lipo -archs` must report `arm64 x86_64` for every native executable/dylib required on Intel.
3. Verify load commands/rpaths resolve only inside bundle or macOS system locations; no repo, Homebrew, rustup, DerivedData, or user paths.
4. Verify helper protocol, Rust ABI, journal/event schemas, failure code registry, DDI catalog, expected payload graph, and migration manifest are present and hash-bound by `EngineIntegrity.json`.
5. Verify exact resource inventory and reject extras that can execute or influence signing.
6. Generate CycloneDX SBOM from `Package.resolved`, `Cargo.lock`, iOS dependency manifests, tool versions, and source revisions. Include MPL notices/source compliance for signer.
7. Scan binary strings/plists/scripts for secrets, local paths, Apple credentials, pairing data, and test failure-injection enablement.
8. Sign the macOS bundle as release policy requires; record signing classification, designated requirements, entitlements, hashes, and notarization status. This is separate from iOS payload signing.
9. Mount the eventual DMG and rehash bytes from the mounted copy. Execute all audits against mounted bytes, not staging.
10. On clean offline runtime hosts, prove no Python, Xcode/xcrun, Cargo/rustc/rustup, Homebrew, repository, or network dependency for local signing/inspection.

Every gate emits JSON with tool identity, inputs, result, and evidence hashes. `SKIP` is failure for required release gates. Artifact identity must bind app version/build, git commit, dirty status policy, architectures, helper/Rust ABI, payload/source hashes, schemas, and SBOM.

