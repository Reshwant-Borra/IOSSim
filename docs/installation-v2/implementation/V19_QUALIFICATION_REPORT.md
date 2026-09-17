# V19 qualification report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Automated qualification

- macOS Swift: 356 tests executed, 9 explicit skips, 0 failures, 0 unexpected.
- Packaged artifact integrity/handshake skip was executed separately against the final assembled app and passed (1/1).
- iPhone `POCUnitChecks`: passed.
- Native Rust bridge: 11/11 passed.
- Artifact identity: 6/6 passed.
- Synthetic discovery CLI: 5/5 passed.
- Packaged native-only consumer and native install-routing audits: passed.
- Python compilation and `git diff --check`: passed.
- Final local DMG canonical audit, separate read-only audit, independent mounted identity inspection, secret/source/profile/path/world-writable scans, recursive signatures, and final SHA-256: passed.
- Public release command: failed closed before build/sign/publication because no approved production developer-support provider exists.

## Skips and failure classification

There are no remaining automated failures.

The broad Swift suite's nine skips are classified:

- one intentional `ARTIFACT`-class skip in the broad invocation because no packaged-app path was supplied; it passed separately with `IOSSIM_V3_PACKAGED_APP` set to the final assembled app and is not a remaining failure;
- one real-network development DDI acquisition: `PHYSICAL_DEPENDENCY` / opt-in local-system; the empty-cache network case passed earlier in V6 and was not repeated during final safe regression;
- one credentials-free local Apple system adapter probe: `PHYSICAL_DEPENDENCY` / opt-in local-system;
- six real Keychain/codesign integration cases: `PHYSICAL_DEPENDENCY`; intentionally not run because the qualification session did not authorize mutation of real signing/Keychain state.

The V18 gate exposed four stale display-name assertions, classified `SUPERSEDED_EXPECTATION`, and one product-root SBOM audit defect, classified `REAL_PRODUCT_DEFECT`. Both were corrected and the complete gates rerun successfully.

## Final A–L architecture audit

- **A — architecture followed:** PASS. SetupWizard/SetupStore/BundledProvisioningEngine/helper/domain/native boundaries remain intact; reports V0–V18 match the master responsibility map.
- **B — no new implicit dependency:** PASS. Mounted app scans and native-only audits show no consumer repo, Git, Homebrew, host Python/Node/Rust/Cargo, Xcode, DerivedData, PATH, or manual-pairing dependency. LocalDevVPN is explicit.
- **C — packaged app cannot reach repo/dev tooling:** PASS. Compile-time engine/backend selection and packaged source/integrity audits reject development routes.
- **D — repair cannot delete unrelated resources:** PASS in automated policy. Exact ownership/team checks and smallest-repair tests fail closed; physical confirmation remains required.
- **E — pairing repair preserves last working record:** PASS in candidate/crash/replay tests. Active A survives until B completes possession and developer-service proof plus promotion.
- **F — READY requires real Rich proof:** PASS in state/receipt tests. Stored state, mounted DDI, RSD, or AppService alone cannot mark READY; physical execution remains required.
- **G — public release cannot use development DDI mirror:** PASS. Provider types/provenance are revalidated and `./iossim release` fails immediately while production provider policy is unresolved.
- **H — metadata cannot disagree with binaries:** PASS. Wrong architecture/schema tests fail and final sidecar is derived from mounted bytes.
- **I — support bundle cannot leak modeled secrets:** PASS. One-file allowlist and sentinel negative corpus passed; mounted artifact secret scan passed.
- **J — concurrent helpers cannot corrupt state:** PASS. OS lease, CAS generation, fsync/atomic snapshot, journal recovery, and concurrent-process tests passed.
- **K — duplicate same-UDID connections are deterministic:** PASS in Swift/Rust tests. Exact UDID+mux+connection/generation is retained; ambiguity fails closed. Physical USB/network proof remains required.
- **L — stale team/device/release state is rejected:** PASS. Setup keys and operational receipts bind all relevant identities and tests cover cross-key/stale changes.

## Local artifact

- Path: `.build/iossim/local-release/Veya-0.1.0-build1-1259da5-local-test.dmg`
- SHA-256: `0bbc112d7ef191190da2afce0067012392e6ec31719330d9e85a8aa7633d4a72`
- Size: `16,139,473` bytes
- Mounted contents: `Applications`, `Veya.app`
- Architectures: universal `arm64`, `x86_64` for GUI, helper, and bridge
- Schemas: helper 2; setup 5; provisioning 4; artifact 2; bridge ABI 2
- Signature: ad hoc/hardened runtime; `LOCAL_TEST_ONLY`
- Source: `1259da507ecded222022cc86bf82863c15640db9`, dirty=`true`

## Physical and production status

No physical pass is claimed. `PHYSICAL_VALIDATION_HANDOFF.md` defines the exact clean-Mac/iPhone sequence. Public release additionally remains blocked by the unapproved production DDI source/rights policy, Developer ID signing, notarization, stapling, Gatekeeper, clean-machine validation, and publication authorization.

## Gate

All safe software and artifact gates pass, the local-test artifact is auditable and usable for controlled physical validation, public production fails closed, and the unexecuted physical work is explicitly handed off.
