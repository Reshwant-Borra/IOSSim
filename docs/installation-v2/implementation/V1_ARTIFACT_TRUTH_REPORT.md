# V1 canonical artifact truth report

Verdict: `PASS`

## Implemented

- Added one reusable artifact identity inspector at `scripts/bootstrap/artifact_identity.py`.
- The inspector reads actual Info.plist fields, Mach-O slices, helper-reported schemas, native bridge ABI, payload bundle metadata/hashes, code-signing classification, component hashes, source provenance, app-tree hash, and final DMG hash/size.
- Added the helper `protocol-info` operation. It reports built `helperProtocol=1`, `setupState=4`, `artifactManifest=2`, and expected bridge ABI 1. The inspector independently calls the built bridge ABI function and requires equality.
- `iossim_cli.py` now derives payload/build provenance schemas from the compiled helper/bridge instead of duplicated release literals.
- Release/local sidecar schema 2 is generated from a read-only mounted DMG identity report. Desired release config is only an assertion and any mismatch raises `ARTIFACT_IDENTITY_MISMATCH`.
- The direct development builder now queries compiled schemas, records them in BuildProvenance, signs the sanitized native bridge before the outer app, and emits an artifact identity report.
- Artifact manifests now reject stale schema values before payload verification.
- Public release fails closed while `developerSupportProviderClassification` is `UNRESOLVED_PRODUCTION_PROVIDER`. Local-test metadata remains explicitly nonpublic.
- Dirty source is permitted only for `LOCAL_TEST_ONLY`; its dirty state is read from the mounted app's BuildProvenance rather than invented by a sidecar.

## Acceptance evidence

### Architecture mismatch

The newly built self-contained app contained actual `arm64` slices for the Mac GUI, helper, and native bridge while `config/release.json` requires `arm64+x86_64`. Both app and mounted-DMG expectation checks failed with exact per-component mismatches. No sidecar claimed universal output.

### Schema mismatch

- Five Python artifact-identity tests passed, including stale setup/helper/bridge schema rejection and payload hash mismatch rejection.
- A copied app with BuildProvenance `setupStateSchema=3` failed against the built helper's `setupState=4`.
- Six Swift `ArtifactManifestTests` passed, including explicit stale manifest schema rejection.

### Mounted-DMG actual inventory

V1 test artifact (not a final release):

- Path: `.build/iossim/v1-artifact-test/IOSSim-0.1.0-build1-1259da5-v1-artifact-test.dmg`
- Size: 9,073,343 bytes
- SHA-256: `9ae3a2316d8ab4930dbac5303810a68ba15dca9df8506916d27c37cd74c88cc7`
- Bundle: `com.iossim.mac-provisioner`, version `0.1.0`, build `1`
- Actual Mac architectures: `arm64`
- Schemas: helper 1; setup state 4; artifact manifest 2; expected/actual bridge ABI 1
- Signing: ad hoc, no Team ID
- Mounted app tree SHA-256: `8eb9cf4f8a73c8df2aa288b9916194f13759dd2f8b7e388c876c152c0ccbde4a`
- Full mounted inventory: `V1_MOUNTED_ARTIFACT_IDENTITY.json`

The inspector detached only its own mount. No V1 mount remained active after the audit.

## Tests

- `UNIT`: 5 Python artifact identity tests — PASS.
- `UNIT`: 6 Swift ArtifactManifest tests — PASS.
- `ARTIFACT`: fresh self-contained app build — build/sign/structural checks passed; release-architecture gate correctly failed arm64 vs universal.
- `ARTIFACT`: mounted V1 DMG inspection — PASS for actual-value inventory; configured universal expectation correctly failed.
- Safe no-Xcode composition/routing checks — PASS.
- Synthetic device discovery tests — 5 PASS.
- `git diff --check` — PASS.

## Limitations and next ownership

- The current Rust bridge build is arm64-only. V1 now detects this truth; V17 must produce a universal bridge or change architecture policy explicitly.
- This V1 DMG is an artifact-test fixture, not the final `LOCAL_TEST_ONLY` qualification DMG.
- Developer ID, notarization, stapling, Gatekeeper, SBOM, publication, and final canonical filename remain V17 work.
- Public release remains blocked by the unresolved production DDI source.
