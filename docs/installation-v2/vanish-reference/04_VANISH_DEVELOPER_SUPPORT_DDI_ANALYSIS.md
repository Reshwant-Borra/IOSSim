# Vanish developer-support and DDI analysis

## Proven Vanish mechanism

On macOS, `mountDDI` launches bundled Python as:

```text
python -m pymobiledevice3 mounter auto-mount
```

For iOS 17 and later, bundled PMD selects personalized mounting. Its repository helper reads/writes `~/Xcode_iOS_DDI_Personalized`, expects `Image.dmg`, `BuildManifest.plist`, and `Image.trustcache`, and when required downloads those assets through the GitHub API/raw URLs for `doronz88/DeveloperDiskImage`. PMD queries device identifiers/nonces, obtains or constructs an Apple TSS personalization request, uploads image/trustcache, and mounts image type `Personalized`. Vanish then starts its lockdown/remote tunnel and emits `auto-connect-ready`. `CONFIRMED_VANISH_STATIC_CODE`

The inspected application contains no matching DDI image, trust cache, or build manifest. Vanish therefore downloads rather than bundles these assets. The package metadata describes GitHub acquisition. `CONFIRMED_VANISH_ARTIFACT`

## Veya's exact dependency

Veya can discover, provision, sign, stage, and invoke InstallationProxy without an RSD developer-services session. The first exact DDI-dependent operation in the current setup flow is:

```text
ConsumerArtifactProvisioner.advanceRuntimeConfiguration
  -> prepareDeveloperServices
  -> NativeDeveloperServicesCoordinator.prepare
  -> DynamicNativeDeviceTransport.developerServicesReadiness
  -> iossim_bridge_developer_services_status
  -> CoreDeviceProxy::connect
  -> ImageNotMounted => DdiRequired
```

After a valid image mounts, that same native call creates the software tunnel, performs RSD handshake, verifies `com.apple.coredevice.appservice` and its launch feature, and connects RemoteXPC/AppService. `ConsumerArtifactProvisioner` then launches the installed app. On the phone, `DvtLocationClient` retains an RPPairing tunnel/RSD handle; `xctest_runner_new_from_rsd` and `xctest_runner_start` use it for TestManager/XCTest, after which XCUILocation runs. `CONFIRMED_LOCAL_IOSSIM_CODE`

Thus DDI is a shared prerequisite for both products' current RSD paths, not an accidental API that Veya can ignore. Veya's XCTest runner adds downstream services and proof requirements, but the DDI dependency starts earlier at CoreDeviceProxy.

## Product conclusion

The Vanish mechanism is technically credible and directly observed. It is not automatically suitable for Veya:

- the assets are Apple developer-support binaries mirrored by a third party;
- the availability and update policy are controlled outside Veya;
- wrapper licensing and Apple asset rights are separate questions;
- bundling PMD or its repository helper could introduce GPL obligations;
- the bundled PMD release pins a build identifier, which creates compatibility risk.

Veya's target `DeveloperSupportBuildProviding` interface remains correct. A provider must produce exact-build assets, verified hashes, source/provenance, cache receipts, and a revocation/update policy. Acceptable options are: an Apple-authorized direct source; Veya distribution with confirmed redistribution rights; a separately approved mirror with signed metadata and legal approval; or a documented prerequisite that fails the zero-Xcode product target. No provider should silently scan a developer Mac and call setup self-contained.

**Status:** `PRODUCT_DECISION_REQUIRED`; `ARCHITECTURE_NOT_READY` for the shipping zero-Xcode promise. Physical qualification must prove a cleared cache and a previously unprepared supported iOS build.

Apple authority references used with the local evidence: [Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components) and [Apple Developer Program agreements and guidelines](https://developer.apple.com/support/terms/). Neither page found in this research establishes the doronz88 mirror as an Apple-authorized Veya distribution source.
