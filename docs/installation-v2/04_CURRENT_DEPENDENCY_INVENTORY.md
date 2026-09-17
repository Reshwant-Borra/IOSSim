# Current dependency inventory

## Runtime and build dependencies

| Dependency | Scope | Current role | V2 decision | Evidence |
| --- | --- | --- | --- | --- |
| SwiftUI/Foundation/Security | Mac runtime | UI, orchestration, Keychain, process execution | Keep | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| `/usr/bin/codesign` | Mac runtime | Re-sign prepared apps; disposable identity proof | Keep with minimum-macOS qualification | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| `libiossim_device_bridge.dylib` | Mac runtime | Stable C ABI into Rust | Keep/refactor ABI | `CONFIRMED_LOCAL_IOSSIM_ARTIFACT` |
| `jkcoxson/idevice` rev `1838db…` | Statically linked Rust | usbmux, Lockdown, AFC, installation, mounter, CoreDevice/RSD/AppService | Keep pinned; add SBOM/notices and initial pairing wrapper | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| BigInt | Swift package/runtime | GrandSlam math | Keep; notice already packaged | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| Apple private AOSKit/AuthKit-derived values | System/private boundary | Machine metadata/anisette support | Isolate and version-gate | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| LocalDevVPN | Separate iPhone app | Phone-local VPN path to developer services | External compatibility dependency | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| XCTest/XCUILocation runner | Installed iPhone payload | Rich runtime writer | Preserve | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| Xcode/xcodebuild | Release build only | Build iPhone apps/test bundle and SDK-linked Mac products | Release infrastructure only | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| Developer support assets | Customer runtime prerequisite | Personalized DDI/trust cache/manifest | Approved-provider blocker | `UNRESOLVED` |
| Apple GrandSlam/Developer Services/TSS | Network services | Auth, provisioning, personalization | Private/version-bound adapter | `CONFIRMED_LOCAL_IOSSIM_CODE` |

`pymobiledevice3`, libimobiledevice, DeveloperDiskImage, isideload, xtool, and apple-private-apis are research references, not linked IOSSim dependencies. See 16.

## Packaged artifacts

The app contains the GUI, `IOSSimProvisioner`, native bridge, prebuilt re-signable main iPhone app, runner/test payload, payload manifest, BuildProvenance, icon, distribution metadata, and direct notices for idevice and BigInt. The release pipeline must generate a full Cargo-lock SBOM and notice set; two top-level notices do not prove transitive compliance. `CONFIRMED_LOCAL_IOSSIM_CODE`, `CONFIRMED_LOCAL_IOSSIM_ARTIFACT`

## Forbidden runtime dependencies

Public Veya must fail its audit if it references a repository path, Python environment, `devicectl`, `xcodebuild`, copied CoreDevice/MobileDevice framework, third-party DDI mirror, development helper selector, or unsigned/unmanifested executable. Build-time Xcode is allowed on controlled release infrastructure and is distinct from customer runtime.
