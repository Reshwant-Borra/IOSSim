# IOSSim Build and Packaging

Authoritative build instructions as of 2026-09-15.

## Development/build machine versus consumer Mac

Full Xcode and an iPhoneOS SDK are required to compile the iPhone payload. They are build-machine inputs only. A normal IOSSim consumer Mac receives those payloads inside `IOSSim.app` and must not invoke Xcode, `xcodebuild`, `xcrun devicectl`, Xcode Accounts, or a source build.

Current build-machine audit:

| Item | Observed |
|---|---|
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` |
| `xcodebuild -version` | Xcode 27.0, build 27A266a |
| iPhoneOS SDK | 27.0 at `.../SDKs/iPhoneOS27.0.sdk` |
| Swift | Apple Swift 6.4 |
| Host | Apple Silicon, macOS 26.6.2 |
| Apple Development identities | 2 available |
| Rust iOS target | installed |

The former build-machine configuration blocker is **RESOLVED**. The canonical payload and authoritative Mac app builds passed. This does not introduce any consumer dependency on Xcode.

## Required targets and artifacts

| Artifact | Source target | Scheme | Product type | Canonical source ID | Bundled path | Required | Rebuild |
|---|---|---|---|---|---|---|---|
| Main app | `IOSSimOnDevicePOC` | `IOSSimOnDevicePOC` | iOS application | `com.iossim.on-device-dvt-poc` | `DeviceArtifacts/IOSSim DVT POC.app` | Yes; setup ingress and frozen runtime owner | Yes |
| UI test bundle | `IOSSimLocationControlUITests` | `IOSSimPayloadRunner` | UI-testing bundle embedded in runner | `com.iossim.location-control-uitests` | `...Runner.app/PlugIns/IOSSimLocationControlUITests.xctest` | Yes; runner payload content | Yes, with runner |
| XCTest runner app | Xcode-generated host for `IOSSimLocationControlUITests` | `IOSSimPayloadRunner` | UI-test runner application | `com.iossim.location-control-uitests.xctrunner` | `DeviceArtifacts/IOSSimLocationControlUITests-Runner.app` | Yes; frozen TestManager/XCUILocation runtime | Yes |
| Location Witness | `IOSSimLocationWitness` | excluded from `IOSSimPayloadRunner` | iOS application | `com.iossim.location-witness` | none | No | No |
| Unit-test bundle | `IOSSimLocationControlTests` | `AppleLocationControl` | unit-test bundle | `com.iossim.location-control-tests` | none | No | No |

`IOSSimPayloadRunner.xcscheme` exists specifically to avoid building the unrelated witness while still producing the required UI test runner.

## Exact payload build commands

After installing full Xcode, use its real developer directory. These are build-machine commands and deliberately use the generic physical-iOS destination:

```bash
cd "/Users/rishiborra/Desktop/IOSSim"

DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild \
  -project ios/IOSSimOnDevicePOC.xcodeproj \
  -scheme IOSSimOnDevicePOC \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ios/.build/DerivedData \
  clean build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  DEBUG_INFORMATION_FORMAT= GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
  SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO COPY_PHASE_STRIP=YES \
  STRIP_INSTALLED_PRODUCT=YES DEPLOYMENT_POSTPROCESSING=YES

DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild \
  -project ios/IOSSimOnDevicePOC.xcodeproj \
  -scheme IOSSimPayloadRunner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ios/.build/DerivedData \
  clean build-for-testing \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  DEBUG_INFORMATION_FORMAT= GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
  SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO COPY_PHASE_STRIP=YES \
  STRIP_INSTALLED_PRODUCT=YES DEPLOYMENT_POSTPROCESSING=YES
```

The repository's `build_ios` function uses these two schemes. The successful canonical invocation was `./iossim package-app`; it produced both Release device products, ran the capability guards, and staged `.build/iossim/self-contained/IOSSim.app`. `./iossim build` remains intentionally unsuitable as the focused payload-rebuild instruction because it mixes unrelated developer builds.

## Target membership and compiled-code gates

Before staging, `assert_iphone_payload_capability_sources` verifies the inbox file is a member of the main target, startup calls it, the Keychain/receipt path exists, the mapping consumer exists, and the runner scheme excludes the witness. `assert_iphone_main_binary_capabilities` then scans the actual main Mach-O for the setup controller, bootstrap, receipt, Keychain service, and runtime-mapping markers. Manifest capabilities are emitted only after both gates pass.

The old Release product fails with:

```text
PAYLOAD_CAPABILITY_BINARY_MISMATCH: AutomaticPairingInboxController,
remote-pairing.bootstrap, remote-pairing.receipt, runtime-mapping.json
```

## Signing model

Build products are produced without a distribution profile. Canonical packaging copies both apps, removes `embedded.mobileprovision` and dSYM content, sanitizes build paths, then signs nested frameworks/test bundles and apps ad hoc while preserving identifier/entitlement/flag metadata. Consumer setup later rewrites source IDs to deterministic Personal Team IDs, embeds IOSSim-created profiles, and signs with the IOSSim-managed Personal Team identity.

Source targets declare no custom entitlement file. The final fresh main, runner, nested test bundle, frameworks, profiles, and entitlements must be inspected after Xcode build and after profile-free preparation. The stale prepared apps are arm64 and contain no embedded provisioning profile; that is historical evidence only.

## Canonical staging and manifest

The current canonical staging implementation is `assemble_self_contained_app` in `scripts/bootstrap/iossim_cli.py`. It selects exactly the main and runner, prepares them for Personal Team re-signing, and writes a schema-2 `DeviceArtifacts/manifest.json` containing:

- component role, source bundle ID, version, relative path, deterministic tree SHA-256, and `personalTeamResign` mode;
- payload source HEAD, dirty flag, deterministic source-tree SHA-256, build timestamp, and `DEVICE_PAYLOAD_RELEASE` variant;
- explicit capabilities `automaticPairingInbox=1`, `pairingReceiptSchema=1`, `runtimeMappingSchema=1`, and `localDevVPNSetupGate=1`.

When Xcode is available, `./iossim package-app` exercises the canonical full staging path. Use the resulting `.build/iossim/self-contained/IOSSim.app/Contents/Resources/DeviceArtifacts` as the verified input to the one authoritative focused retest app:

```bash
IOSSIM_MAC_BUILD_ROOT=".build/iossim/final-setup-payload-retest" \
IOSSIM_MAC_BUILD_VARIANT="FINAL_NO_XCODE_SETUP_PAYLOAD_RETEST" \
IOSSIM_DEVICE_ARTIFACTS_SOURCE=".build/iossim/self-contained/IOSSim.app/Contents/Resources/DeviceArtifacts" \
  macos/scripts/build_app.sh
```

The focused build refuses missing artifacts, incomplete payload provenance, absent capability versions, hash mismatches, and bundle-ID mismatches. It never falls back to building iPhone source.

## Verification checklist

1. `file`, `lipo -archs`, and `vtool -show-build` on main, runner, and nested test executable: physical iOS arm64; project deployment target 17.0; compatible with iOS 26.6.2.
2. Inspect each Info.plist ID/executable/version and nested bundle/framework layout.
3. `codesign -d --entitlements :-` and `codesign --verify --deep --strict` on prepared payloads.
4. Current helper `verify-artifacts --json`: all hashes and IDs pass, and current payload capabilities pass.
5. Compare old/new tree hashes and provenance; new values must differ.
6. Build focused app; inspect its embedded manifest and payload hashes rather than trusting build output.
7. `codesign --verify --deep --strict` the Mac app; run static no-Xcode and native routing checks.
8. Compute deterministic Mac app tree hash with the same sorted-relative-path/null-delimited SHA-256 convention used by `sha256_path`.

Successful current values:

- payload HEAD `1259da507ecded222022cc86bf82863c15640db9`, dirty `true`, source-tree SHA-256 `5668a29add1a3966c4514115523b1a21e69ff6585bdbc76c3e89dcb0aae64a5a`;
- main tree SHA-256 `8c60fe20198307ba57550f7230c33b9361ab1ca57bcd1880db0ddb9f639b0081`;
- runner tree SHA-256 `c1e42038a763889b6dd23d175058a6c1d077b962caa61e50f456f8c4d7b5fb9c`;
- manifest SHA-256 `ecdf74fafe767b024fe9712b14512f9b572ba7f627ebf806b4c84867f0a9dd66`;
- authoritative app tree SHA-256 `8200221baab34c019c857449aabb6ec317586d2b4508c9607372c63bc563c65c` using `sha256_path`.

Physical integration established one packaging-sensitive rule: a user-requested `refresh` must install/upgrade both freshly signed owned payloads even when the same derived bundle IDs are already present. Merely comparing IDs leaves an older phone binary installed. `repair` remains component-scoped; only `refresh` force-upgrades both payloads.

No DMG was produced; it is optional and did not block physical setup. If later produced, the requested local path is `.build/iossim/local-release/IOSSim-0.1.0-final-setup-payload-retest.dmg` and its SHA-256 must be recorded.
