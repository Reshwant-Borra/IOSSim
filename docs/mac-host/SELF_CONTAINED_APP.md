# Self-Contained IOSSim.app Packaging

This milestone separates developer build dependencies from consumer runtime dependencies.

Current note: the live native Personal Team path no longer relies on a user
signing into Xcode Accounts. The packaged app still uses installed Xcode
developer tooling, especially `/usr/bin/xcrun devicectl`, but the intended
consumer authorization flow happens inside IOSSim. See
[../PROVISIONING_AND_SIGNING.md](../PROVISIONING_AND_SIGNING.md) and
[../RELEASE_AND_DISTRIBUTION.md](../RELEASE_AND_DISTRIBUTION.md).

## Runtime Architecture

Development app builds still use:

`SwiftUI GUI -> DevelopmentCLIEngine -> /bin/bash -> repository ./iossim -> Python bootstrap`

Self-contained app builds use:

`SwiftUI GUI -> BundledProvisioningEngine -> Contents/MacOS/IOSSimProvisioner -> bundled DeviceArtifacts`

`BundledProvisioningEngine` is selected at compile time with `IOSSIM_BUNDLED_ENGINE`. In bundled mode `DevelopmentCLIEngine` is not compiled into the app target, `DevelopmentRepositoryRoot.txt` is not packaged, and the app does not search for a repository.

## Canonical Commands

- `./iossim package-app`
- `./iossim audit-app .build/iossim/self-contained/IOSSim.app`

`package-app` is a build-time command. It may use Python, Git, Xcode, Swift, Rust, cargo, Node, npm, and repository source to create the final app bundle. Those tools are not normal runtime dependencies of the packaged app except where listed below.

## Packaged Runtime Contents

The self-contained app includes:

- `Contents/MacOS/IOSSim`
- `Contents/MacOS/IOSSimProvisioner`
- `Contents/Resources/DeviceArtifacts/manifest.json`
- `Contents/Resources/DeviceArtifacts/IOSSim DVT POC.app`
- `Contents/Resources/DeviceArtifacts/IOSSimLocationControlUITests-Runner.app`

It must not include repository source, `.git`, the Python bootstrap, Node modules, Rust source, Swift source, frontend/backend source, dSYM bundles, pairing records, private keys, PSKs, `.p12` files, logs, or absolute developer-machine paths.

## Dependency Classification

| Dependency | Currently Used For | Build-Time | Packaged Runtime | Can Remove | Can Prebuild | Must Bundle | Apple System Provided | User Action | Security Impact |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Git | clone/check pinned idevice source and commit metadata | Yes | No | Yes from runtime | N/A | No | Usually with Apple tools | No for packaged app | Avoids repository leakage |
| bash | repository launcher/development scripts | Yes | No | Yes from runtime | N/A | No | Yes | No | Removes script injection surface |
| Python | developer bootstrap, backend tests, packaging command | Yes | No | Yes from runtime | N/A | No | Not guaranteed | No for packaged app | Avoids shipping source bootstrap |
| Python packages | backend tests/dev API | Yes | No | Yes from runtime | N/A | No | No | No for packaged app | Avoids dependency/vendor exposure |
| Node/npm | frontend engineering UI/tests | Yes | No | Yes from runtime | N/A | No | No | No for packaged app | Avoids frontend source/runtime exposure |
| Rust/cargo/rustup | build idevice FFI static archive | Yes | No | Yes from runtime | Yes | No | No | No for packaged app | Rust paths are remapped before packaging |
| Swift compiler | build Mac/helper/iOS apps | Yes | No | Yes from runtime | Yes | No | Xcode-provided | No for packaged app | No source shipped |
| Xcode/xcodebuild | build profile-free artifacts at package time; compatibility signing-shell fallback | Yes | Compatibility only in current native flow | No in current proven device path | Yes | No | Full Xcode | Install Xcode; clean-Mac first-launch requirements unproven | Current native path authorizes Apple Account inside IOSSim |
| xcrun/devicectl | discover devices and install bundled apps | Yes | Yes | Not yet | No | No | Xcode/Apple developer tools | Install/select Apple developer tools | Current proven install path |
| codesign/security | prepare profile-free artifacts; sign and inspect selected-team artifacts | Yes | Yes during provisioning | No | N/A | No | macOS/Xcode | IOSSim-managed native identity or compatibility Xcode identity | No private key material packaged |
| DeveloperDiskImage/developer services | CoreDevice install/XCTest support | Yes via Xcode | Yes indirectly through devicectl/XCTest runner | Not yet proven | No | No | Xcode/private Apple stack | Apple tools required | Apple-controlled boundary |
| IOSSim iPhone app | owned runtime app | Yes | Installed from bundle | No | Yes | Yes | No | Device must accept profile | Development profile limits devices |
| Witness app | developer validation only | Yes | No | Yes from consumer package | Yes | No | No | None for consumers | Retained in source and development workflows |
| XCTest runner app | rich XCUILocation runtime path | Yes | Installed from bundle | No | Yes | Yes | Includes copied XCTest frameworks | Device must accept profile | Preserves long-lived runner architecture |
| LocalDevVPN | Apple-approved local VPN path on iPhone | No | Required externally | No | Not project-owned here | No | No | Install/approve on iPhone | User approval required |
| RPPairing | pairing material stored/imported on iPhone | No | Required on iPhone | No | No | Never | No | Import in iPhone app | Must never be bundled or logged |
| Apple Development identity/profiles | sign iPhone artifacts | Yes | Not needed to run prebuilt artifacts on already provisioned devices | Not for arbitrary users | Yes for registered devices | Embedded profiles inside iPhone apps | Apple account/Xcode | Build/signing machine | Profiles are device-limited; no private keys shipped |

## Xcode Boundary

Xcode remains required on the consumer Mac because the current physical device
path uses Apple's installed CoreDevice tooling through `/usr/bin/xcrun
devicectl`. The native Personal Team path obtains Apple authorization inside
IOSSim and reuses IOSSim-managed signing material. The packaged helper still
uses `codesign`, `security`, and `devicectl` to prepare, verify, and install the
two artifacts. It does not call Git, Python, Node, npm, cargo, rustup,
repository scripts, or an IOSSim source project at runtime.

Removing `xcrun devicectl` should be handled as a later focused milestone behind an Apple tooling adapter or a direct compiled idevice/CoreDevice integration.

## Signing Model

The bundled iPhone artifacts are profile-free and re-signable. At installation,
the helper derives stable Personal Team runner identities, asks Xcode to create
or reuse matching profiles, signs the nested runner graph and main app, verifies
the selected device is included, and installs both. Developer-machine profiles
are not shipped.

No private keys, developer account credentials, pairing records, or RPPairing material are packaged.
