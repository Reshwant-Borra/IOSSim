# V6 developer-support / DDI provider report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

Public-production provider verdict: `UNRESOLVED_PRODUCTION_PROVIDER`; public zero-Xcode release remains fail-closed.

## Implemented

- Kept `DeveloperSupportCoordinator` / `NativeDeveloperServicesCoordinator` as the orchestration owner and the pinned Rust bridge as the Apple TSS, upload, personalized-mount, and live developer-service owner.
- Added schema-2 `DeveloperSupportArtifact` and schema-1 `DeveloperSupportProvenance`. Provider output now records product/device build compatibility, developer-support build identity, provider ID/classification, immutable source revision and URL, acquisition time, expected and actual SHA-256 values, manifest/trust-cache identities, rights and revocation policy IDs, cache location, bridge ABI, and personalization status.
- Restricted the default cache provider to `Library/Application Support/IOSSim/DeveloperSupport`. It no longer treats Xcode or CoreDevice developer-machine caches as a hidden consumer dependency.
- Added `ThirdPartyMirrorDevelopmentProvider`, compiled into the selected setup composition only under `IOSSIM_LOCAL_TEST_ONLY`. It implements the Vanish-demonstrated three-file acquisition behavior without adding Python, pymobiledevice3, or repository tooling.
- Pinned the local-test provider to immutable source commit `1daa8aa4adf12ab6974c2fac378685ce55dd3907` (`v0.3.0` evidence), DDI build `27A5228h`, exact file sizes, and exact SHA-256 hashes. It never resolves a moving `main` or `latest` reference.
- Added HTTPS/final-host checks, bounded downloads, exact size/hash checks, BuildManifest structure and `ProductBuildVersion` validation, source/artifact denylist support, candidate-directory acquisition, mode `0700` directories / `0600` files, validation before commit, validation on every cache use, exact OS-build cache partitioning, and corruption quarantine followed by safe reacquisition.
- Public production validates both the selected cache-provider descriptor and the artifact's original provenance descriptor. A development-mirror artifact found in a cache remains development-classified and cannot be laundered into an allowed production cache hit.
- Local-test and production helper binaries now self-report their actual DDI provider classification through `protocol-info`. Artifact inspection and release sidecars derive this value from the built helper. Local test reports `THIRD_PARTY_MIRROR_DEVELOPMENT_PINNED_V030`; the ordinary/production composition reports `UNRESOLVED_PRODUCTION_PROVIDER`.
- The canonical public release gate still requires `APPROVED_PRODUCTION_SOURCE`. Changing desired release configuration without changing the built helper now produces an artifact-identity mismatch.

## Provider and rights policy

The development source is the documented `doronz88/DeveloperDiskImage` GitHub repository. Primary-source inspection on 2026-09-16 found tag `v0.3.0` at the pinned commit and no repository-declared license. Apple asset redistribution/production rights are therefore unresolved.

Consequences:

- downloaded assets are local-test cache data, never bundled in Veya.app or a DMG;
- the provider is explicitly named and classified `thirdPartyMirrorDevelopment`;
- its policy ID states `development-evaluation-only-apple-asset-rights-unresolved-v1`;
- public production cannot construct or select it;
- public zero-Xcode qualification remains blocked until a separately approved production provider and rights/update/revocation policy exist.

This follows the newer V0/user directive that allows a development/local-test provider while production remains closed. It does not reinterpret the mirror as an approved shipping source.

## Acceptance evidence

- Hermetic provider tests start with an empty isolated cache and prove acquisition, validation, provenance, exact build partitioning, cache reuse without network calls, corruption quarantine/reacquisition, wrong hash, malformed/wrong manifest, source-unavailable/404-equivalent, network outage, revision revocation, and production-policy rejection.
- An explicitly opt-in real-network test acquired the three pinned files into `.build/iossim/v6-live-cache-20260916T0355Z` without Xcode or host Python as a runtime dependency. It did not contact Apple TSS or a phone.
- Observed hashes:
  - `Image.dmg`: `05fd807da5e19f030fa4941f24800c965c6c77982ab572dd5d1ef778fb69f9ca` (15,733,248 bytes)
  - `BuildManifest.plist`: `8edd4a2f4f4ef1fbd7bfe49785d8badc673d1395d1d94d85b132ca8ab5ecaf54` (801,505 bytes)
  - `Image.dmg.trustcache`: `36af60889ff5a737874a26daeb8e1a0139ebfebec6ec2e4d8f6a3c1bf1dce35c` (1,895 bytes)
- The downloaded manifest declared `ProductBuildVersion=27A5228h`; all cache files were mode `0600`, and cache directories were mode `0700`.
- Both local-test and production helper compositions compiled. Direct `protocol-info` output reported their distinct actual provider classifications.
- `DeveloperSupportCoordinatorTests`: 15 executed, one opt-in network test skipped in the normal run, zero failures. The separately authorized network invocation executed that test with zero failures.
- Broad safe Swift suite: 311 executed, three opt-in tests skipped, zero failures, zero unexpected.
- No-Xcode runtime/routing checks, five synthetic discovery tests, six artifact identity tests, Python syntax checks, and `git diff --check` passed.

Broad regression log: `.build/iossim/logs/v6-safe-swift-test.log`.

## TSS and physical deferral

- The existing native bridge still performs the live device query, build-identity selection, Apple TSS request when the device lacks a ticket, image/trust-cache upload, and personalized mount. V6 did not replace or emulate that security-sensitive path.
- Hermetic tests distinguish TSS outage, personalization rejection, mount rejection, cache/source/network failure, wrong build, corruption, and service-map failure.
- No phone was contacted. Actual TSS personalization, Developer Mode behavior, personalized mount, cache reuse after a real mount, RSD, RemoteXPC, and AppService on a fresh supported iPhone remain `PHYSICAL_DEVICE` evidence for V19.

## Known limitations

- The local-test provider currently allowlists iOS major versions 17 through 26. A new major requires a reviewed pinned configuration and fresh manifest/device qualification; it never assumes "latest" compatibility.
- Provider-side acquisition receipts are complete, while device/session-bound developer-service receipts are completed by V12.
- The cache is safe to quarantine/reacquire, but cleanup/retention automation is intentionally not destructive and remains a later support-policy concern.
- An approved production source, asset rights decision, signed production metadata authority, and production revocation operations remain unresolved.

## Gate

A fresh isolated Veya-owned cache can acquire and verify the pinned development/local-test asset set without installed Xcode, and production cannot silently select that source or its cached outputs. Automated software gates pass. V6 advances with physical Apple TSS/mount/AppService validation explicitly outstanding and the separate public-production release blocker preserved.
