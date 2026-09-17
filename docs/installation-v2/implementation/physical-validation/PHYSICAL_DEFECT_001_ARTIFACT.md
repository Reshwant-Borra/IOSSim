# PHYSICAL DEFECT 001 — corrected artifact

## OLD ARTIFACT (failed physical validation)

| | |
|---|---|
| Filename | `Veya-0.1.0-build1-1259da5-local-test.dmg` |
| SHA-256 | `0bbc112d7ef191190da2afce0067012392e6ec31719330d9e85a8aa7633d4a72` |
| Source | `1259da5`, dirty |

## NEW ARTIFACT (for retest)

| | |
|---|---|
| Path | `.build/iossim/local-release/Veya-0.1.0-build2-dd259bd-local-test.dmg` |
| Filename | `Veya-0.1.0-build2-dd259bd-local-test.dmg` |
| SHA-256 | `a5cfa59e7355b9a89482280b1c9546ebf5a892c8c19071c0b8895333c19ab2e7` |
| Size | 16,267,883 bytes |
| Mounted app tree SHA-256 | `192a24498716d424343a59f123ade76b5e74467ce518be72251c988ee7a910e1` |
| Architectures | `arm64`, `x86_64` (both `IOSSim` and `IOSSimProvisioner`) |
| `CFBundleExecutable` | `IOSSim` |
| `CFBundleVersion` | `2` |
| Signature classification | ad hoc / hardened runtime — `LOCAL_TEST_ONLY` |
| Source commit | `dd259bd09c32ba1a95d031915d2c393ab2c87149`, **dirty=false** |

The build identity is distinguishable from the failed artifact in every respect
that matters for provenance: build number `1` → `2`, commit `1259da5` →
`dd259bd`, and a clean rather than dirty source tree. Nothing was overwritten.

## Mounted-bytes audit

Verified against the actual mounted DMG, not the build tree:

| check | result |
|---|---|
| Architectures `IOSSim` | `x86_64 arm64` |
| Architectures `IOSSimProvisioner` | `x86_64 arm64` |
| `CFBundleExecutable` | `IOSSim` |
| Helper present | `Contents/MacOS/IOSSimProvisioner` |
| Native bridge | `Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib`, ad hoc / hardened runtime |
| Schemas | `artifactManifest: 2`, `helperProtocol: 2`, `nativeBridgeABI: 2` (expected 2), `provisioningManifest: 4`, `setupState: 5` |
| Payload hashes | `iosMain a95d87e24d70` (`com.iossim.on-device-dvt-poc`), `locationControlRunner c605a3311bdb` (`com.iossim.location-control-uitests.xctrunner`) |
| SBOM | SPDX dependency inventory, 208 packages; idevice + BigInt MIT notices present |
| Signature | `codesign --verify --deep --strict` → valid on disk, satisfies its Designated Requirement |
| Mach-O inventory | 6 executable code items, all ad hoc / hardened runtime |
| Distribution metadata | `LOCAL_TEST_ONLY` |
| DDI provider classification | `THIRD_PARTY_MIRROR_DEVELOPMENT_PINNED_V030` (unchanged from build1) |
| Secret scan | no private keys / pairing / auth material, no developer provisioning profiles, no absolute repository paths, no world-writable files |

`Overall: PASS (LOCAL_TEST_ONLY; public gates not assessed)`

Sidecars written next to the DMG:
`Veya-0.1.0-build2-dd259bd-local-test.release.json` and
`Veya-0.1.0-build2-dd259bd-local-test.dmg.sha256`. A copy of the identity JSON
is kept here as `DEFECT001_MOUNTED_ARTIFACT_IDENTITY.json`.

## Still not publicly distributable

This is an ad-hoc `LOCAL_TEST_ONLY` build. Developer ID signing and notarization
remain a separate, later production-release task, as does the quarantine /
`AppSandbox` execution-policy issue seen when build1 was transferred through
Telegram. No evidence connects that to this defect.
