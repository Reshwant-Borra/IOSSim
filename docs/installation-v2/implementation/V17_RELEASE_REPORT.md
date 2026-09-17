# V17 canonical distribution report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Consolidated production and local-test release behavior around the existing canonical Python assembler/auditor and shared artifact-identity library.
- Canonical filenames now include product, semantic version, build, short source commit, and local-test classification where applicable.
- The native Mac device bridge is built independently for every configured release architecture and lipo-assembled; a post-build architecture check rejects missing slices.
- Added an SPDX 2.3 dependency inventory derived from actual Cargo.lock and Package.resolved inputs, with lock digests and packaged license-notice hashes in mounted-artifact identity and release metadata.
- Strengthened iPhone capability gates for candidate Keychain pairing import and the Rich runtime proof inbox in source membership and built binary markers.
- Corrected schema identity: durable keyed setup state is schema 5, while the nested provisioning manifest is separately reported as schema 4.
- Public filenames now use the same canonical identity stem. Public release checks the approved production DDI classification before credentials or builds and fails closed while it remains unresolved.
- Local-test release remains ad hoc signed, not notarized, not stapled, not Gatekeeper-qualified, and explicitly nonpublic.

## Local artifact

- Path: `.build/iossim/local-release/IOSSim-0.1.0-build1-1259da5-local-test.dmg`
- Size: `16,125,098` bytes
- SHA-256: `d4e28a0be88b812ac5964d508f658496ed1e685608c1589aabfef6e89572efee`
- Source: `1259da507ecded222022cc86bf82863c15640db9`, dirty=`true`
- Architectures: `arm64`, `x86_64` for Mac GUI, helper, and native bridge
- Schemas: helper 2; setup state 5; provisioning manifest 4; artifact manifest 2; native bridge ABI 2
- Signing: `AD_HOC`, no Team ID
- DDI provider: `THIRD_PARTY_MIRROR_DEVELOPMENT_PINNED_V030`
- SBOM: SPDX 2.3, 208 packages, SHA-256 `f0f317834af1fabc765645b46e9754c35293de3d16fa8848b4f48045ec5f7d05`
- iPhone main: `com.iossim.on-device-dvt-poc`, version `0.1`, tree SHA-256 `a95d87e24d7083d1fc93e918de3e9ed0bc085b6830644d2dfd05bbedb8c10d38`
- Runner: `com.iossim.location-control-uitests.xctrunner`, version `1.0`, tree SHA-256 `c605a3311bdbbd2a477a5217066023dbe41c5833586ef25b77276a2939715a11`

## Audit evidence

- Canonical build rebuilt current iPhone main/runner, both Mac architectures, and both native-bridge architectures.
- Final local-release audit mounted the DMG read-only, checked only `Applications` and `IOSSim.app`, audited actual plist/schema/hash/architecture/signature/dependency facts, and detached its mount.
- A separate artifact-identity inspection mounted and detached the DMG and produced `V17_MOUNTED_ARTIFACT_IDENTITY.json`; no implementation-session audit mount remained.
- Source/path/secret/provisioning-profile/world-writable scans passed on the mounted app.
- Recursive ad hoc/hardened-runtime signature inspection passed for six executable code items.
- Broad safe macOS suite: 353 tests executed, 9 explicit skips, zero failures, zero unexpected.
- iPhone `POCUnitChecks`, 11 Rust bridge tests, six artifact-identity tests, no-Xcode routing audits, Python compile, and `git diff --check` passed.
- Full build and independent audit output are retained in `v17-release-local.log`, `v17-release-local-audit.log`, and `v17-swift-test.log`.

## Public release gate

`./iossim release` fails immediately with: no approved fresh-acquisition developer-support source is configured. No Developer ID signing, notarization, stapling, Gatekeeper qualification, publication, or public zero-Xcode claim was attempted.

## Physical validation deferred

- Clean-machine install/launch, Gatekeeper behavior for a future Developer ID build, and complete iPhone setup/runtime qualification.
- Developer ID Application signing, Apple notarization, ticket stapling, and final public DMG assessment after production DDI approval.

## Gate

The local artifact has unambiguous identity derived from mounted bytes and passes local distribution gates. Public production distribution remains correctly closed.
