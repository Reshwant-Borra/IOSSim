# V3 packaged engine/helper boundary report

Verdict: `PASS`

## Implemented

- Added a versioned `EngineIntegrity.plist` to packaged apps. It is generated only after the helper and native bridge have their final nested signatures, and before the outer app is signed.
- The integrity manifest binds the fixed helper path, helper SHA-256 and protocol, setup schema, artifact schema, native bridge path/SHA-256/ABI, and payload-manifest path/SHA-256.
- `BundledProvisioningEngine.live()` now accepts only `Contents/MacOS/IOSSimProvisioner`, requires `Contents/Resources`, loads the integrity manifest, verifies all declared hashes, and performs full payload manifest/capability/bundle/hash validation.
- Every packaged helper operation rechecks helper/bridge/payload-manifest hashes and completes `protocol-info` negotiation before invoking the requested domain operation.
- Added stable packaged integrity failures `VEYA-INTEGRITY-001` through `VEYA-INTEGRITY-006` for missing helper, non-executable helper, missing resources, invalid manifest, hash mismatch, and protocol/handshake mismatch.
- Startup preserves the precise integrity error instead of replacing it with a generic unavailable-engine message. Setup UI maps these errors to reinstall guidance and never describes `doctor` as an executable.
- The shared artifact inspector now verifies the bundled engine-integrity hashes and schemas against actual mounted bytes.
- DevelopmentCLIEngine remains compiled out of the `IOSSIM_BUNDLED_ENGINE` build. Its explicit development-only source remains until V16 parity removal.

## Acceptance evidence

- Missing helper: `VEYA-INTEGRITY-001`; no repository fallback and no “find doctor” language.
- Non-executable helper: `VEYA-INTEGRITY-002`.
- Missing integrity manifest: `VEYA-INTEGRITY-004`.
- Tampered helper: `VEYA-INTEGRITY-005`, rejected before process invocation.
- Wrong helper protocol: `VEYA-INTEGRITY-006` with expected/actual protocol tuple.
- SetupStore user-visible route: “IOSSim installation integrity check failed,” with reinstall guidance and stable code.
- Production/package source scans passed: the packaged branch contains no DevelopmentCLIEngine; deterministic environment exposes no repository root; no consumer Xcode/devicectl fallback is selected.

## Packaged artifact proof

V3 test artifact, not a release candidate:

- App: `.build/iossim/v3-packaged/IOSSim.app`
- DMG: `.build/iossim/v3-packaged/IOSSim-v3-integrity-test.dmg`
- DMG size: 10,063,208 bytes
- DMG SHA-256: `fae0d98ee58d62796fff3222bd0cf7490b5317187ba8894f15263d911d56a1f5`
- Actual architecture: arm64
- Schemas: helper 1; setup 4; artifact 2; bridge expected/actual 1
- Signing: ad hoc
- Mounted app tree SHA-256: `f579fdb3dc9c6f16cd2f5fc865a26b4e958c84a9cfc59bae36dbb084d91dabad`
- Full mounted identity: `V3_MOUNTED_ARTIFACT_IDENTITY.json`

The DMG was mounted read-only by the artifact inspector, its actual packaged helper completed `protocol-info`, all engine-integrity hashes matched the mounted bytes, and the inspector detached only its own mount. No V3 mount remains active.

## Tests

- `UNIT` / `HERMETIC_INTEGRATION`: 9 BundledProvisioningEngine tests with the packaged artifact supplied — PASS.
- `UNIT`: SetupStore integrity UX test — PASS.
- `UNIT`: 5 Python artifact identity tests — PASS.
- `ARTIFACT`: direct packaged app build, engine-integrity reinspection, read-only mounted-DMG audit, and actual helper handshake — PASS.
- Safe source/routing checks — PASS.
- Broad safe Swift suite — 285 executed, 1 opt-in local-system probe skipped, 0 failures, 0 unexpected.
- `bash -n`, Python compile, and `git diff --check` — PASS.

## Deferred

- Process output framing/size/time budgets can be strengthened with the V4 mutation lease and V15 diagnostics envelope; current cancellation remains `ProcessRunner`-backed.
- The V3 artifact is host-only arm64 and ad hoc. Universal architecture and release signing/notarization remain V17.
- Physical launch from a clean installed DMG remains V19.
