# V18 IOSSim to Veya migration report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Changed the release product/display identity to `Veya` while retaining `Veya (formerly IOSSim)` in the migration-window Mac UI.
- Added `ProductBrand` as the explicit migration contract and user-facing translation boundary.
- Kept the Mac bundle identifier (`com.iossim.mac-provisioner`), executable names, Application Support namespace, preferences keys, phone and runner bundle identifiers, Keychain service, signing-key labels, pairing paths, and provisioning identities unchanged.
- Kept the release/setup identity independent of the product display name, so the branding change cannot by itself select another device/team state domain or trigger destructive reprovisioning.
- Changed canonical DMG presentation to `Veya.app` and a `Veya-<version>-build<build>-<sha>-local-test.dmg` filename while retaining internal compatibility executable names.
- Made release DMG audits and SPDX product-root identity derive from the configured product name rather than a hard-coded IOSSim display name.
- Updated only superseded user-facing test expectations; compatibility-path and low-level IOSSim identity expectations remain unchanged.

## Compatibility proof

- `ProductBrandMigrationTests` asserts the Veya display identity and all frozen compatibility identities.
- `SetupError` translates only headline/recovery text; safe developer details retain precise legacy namespace references.
- The packaged-consumer source audit asserts Veya product branding together with the unchanged Mac bundle ID, state namespaces, payload IDs, runner ID, and pairing Keychain service.
- Existing stored setup identity remains keyed by release, team, device, and artifact set, not product display name.
- No dual Mac bundle-ID migration is required because the Mac bundle identifier did not change.

## Automated evidence

- Focused migration tests: 3/3 passed.
- Broad safe Swift suite: 356 executed, 9 explicit opt-in/local-system/physical skips, 0 failures, 0 unexpected.
- Artifact-identity tests: 6/6 passed.
- Native-only packaged consumer audit passed, including the new migration invariants.
- `git diff --check` passed.
- The first broad run exposed four stale IOSSim display-name expectations. They were classified `SUPERSEDED_EXPECTATION` and updated to Veya; the rerun was clean.
- The first Veya artifact attempt correctly failed its SBOM gate because the audit still required an IOSSim-named product root. The generator and auditor were changed to derive that root from release product identity; the complete release was rebuilt and passed.
- Final qualification found two legacy product-name strings in the shared action interpreter. They were translated at the user-facing boundary, followed by a full source regression, artifact rebuild, separate audit, and independent mount inspection.

## Final Veya local-test artifact

- Path: `.build/iossim/local-release/Veya-0.1.0-build1-1259da5-local-test.dmg`
- Size: `16,139,473` bytes
- SHA-256: `0bbc112d7ef191190da2afce0067012392e6ec31719330d9e85a8aa7633d4a72`
- Mounted contents: `Applications`, `Veya.app`
- Product name: `Veya`
- Mac bundle ID: `com.iossim.mac-provisioner` (intentionally retained)
- Source: `1259da507ecded222022cc86bf82863c15640db9`, dirty=`true`
- Mac GUI/helper/bridge architectures: `arm64`, `x86_64`
- Schemas: helper 2; setup state 5; provisioning manifest 4; artifact manifest 2; native bridge ABI 2
- Signing: `AD_HOC`; local-test only; not Developer ID signed, notarized, stapled, or Gatekeeper-qualified
- DDI provider: `THIRD_PARTY_MIRROR_DEVELOPMENT_PINNED_V030`
- Mounted app tree SHA-256: `af4388bf18067d7bc046c2bfa6b48779f339d8f28cd8a4b25b1e148be278d87a`

The canonical build audit, a separate `release-local-audit`, and an independent artifact-identity mount all passed. The final post-qualification rebuild is captured in `V19_MOUNTED_ARTIFACT_IDENTITY.json`; it supersedes the earlier V18 identity after the last user-facing legacy-name translation was corrected. Every created audit mount was detached. Pre-existing unrelated mounted legacy test images were not touched.

## Physical validation deferred

- Upgrade the last qualified IOSSim V2 installation to Veya and confirm the same managed state, signing identity, pairing generation, phone app/runner, and runtime mapping are reused.
- Confirm Finder/LaunchServices presentation and migration-window wording on a clean supported Mac user account.
- Exercise repair and refresh after the display-brand upgrade on a supported iPhone.

## Gate

The branding migration changes presentation and artifact naming without changing low-level installation identity or forcing reprovisioning. Automated and mounted-artifact gates pass. Physical upgrade proof is still required.
