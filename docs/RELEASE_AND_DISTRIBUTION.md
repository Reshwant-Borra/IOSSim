# Release and Distribution

IOSSim has two release classes that share the same production Mac UI and bundled
helper architecture but have different distribution guarantees.

## Release Classes

| Command | Distribution class | Signing | Notarized | Gatekeeper qualified | Public use |
| --- | --- | --- | --- | --- | --- |
| `./iossim release` | `PUBLIC_RELEASE` | Developer ID Application + hardened runtime | Yes | Yes | Yes, after qualification |
| `./iossim release-local` | `LOCAL_TEST_ONLY` | Ad-hoc + hardened runtime where applicable | No | No | No |

`./iossim release` must remain strict. It must not silently downgrade to
ad-hoc, unsigned, or not-notarized output when Developer ID or notarization
credentials are missing.

`./iossim release-local` is for local functional and physical testing. It is not
for public distribution and does not qualify Gatekeeper behavior.

## Experimental Local RC

The ignored local candidate is written to:

```text
path: .build/iossim/local-release/IOSSim-0.1.0-local.dmg
classification: LOCAL_TEST_ONLY
```

Run `./iossim release-local` only from a clean experiment HEAD, then use the
adjacent `.release.json` and `.dmg.sha256` files for exact source, timestamp,
size, and checksum provenance. `release-local-audit` rejects a dirty tree or a
HEAD that differs from that metadata.

The release manifest must say:

- `developerID: false`
- `notarized: false`
- `gatekeeperQualified: false`
- `publicDistribution: false`
- `productionUI: true`
- signing type: `Ad Hoc`

## Packaged Mac App

The packaged consumer app contains:

- `Contents/MacOS/IOSSim`
- `Contents/MacOS/IOSSimProvisioner`
- `Contents/Helpers/IOSSimPairingHelper`
- `Contents/Resources/DeviceArtifacts/manifest.json`
- profile-free, re-signable `IOSSim DVT POC.app`
- profile-free, re-signable `IOSSimLocationControlUITests-Runner.app`

It must not contain repository source, `.git`, Python bootstrap, Node modules,
Rust source, Swift source, frontend/backend source, dSYM bundles, pairing
records, private keys, PSKs, `.p12` files, logs, provisioning profile blobs, or
absolute developer-machine paths.

Witness is excluded from the consumer package.

## Consumer Runtime Dependencies

The packaged app should not require:

- repository checkout
- Git
- bash scripts
- Python
- Node/npm
- Rust/cargo/rustup
- Homebrew
- IOSSim source project files

The current product still requires installed Apple developer tooling from Xcode
because setup invokes `/usr/bin/xcrun devicectl` / CoreDevice for physical device
operations.

Current audited uses include:

| Tool | Used for |
| --- | --- |
| `/usr/bin/xcrun devicectl list devices` | Device discovery and exact selected-device resolution |
| `/usr/bin/xcrun devicectl device info lockState` | Lock-state/live-device check |
| `/usr/bin/xcrun devicectl device install app` | Main and runner installation |
| `/usr/bin/xcrun devicectl device info apps` | Authoritative installed-app inventory |
| `/usr/bin/xcrun devicectl device process launch` | Developer-profile trust/runtime mapping launch check |
| `/usr/bin/xcrun devicectl device copy from` | Runtime configuration readback |
| `/usr/bin/xcrun devicectl device copy to` | Pairing candidate transfer into the private iPhone app data container |
| `/usr/bin/codesign` | Consumer-time artifact signing and signature verification |
| `/usr/bin/security` | Profile decoding, Keychain/certificate identity support |
| `/usr/bin/xcodebuild` through `xcrun xcodebuild` | Compatibility Xcode fallback signing shell only; native Personal Team path does not use it for current prepared profiles |

`DEVELOPER_DIR` is now selected per process from the best compatible stable
Xcode. IOSSim does not modify the global `xcode-select` setting.

The packaged Rust pairing helper is built for the configured Mac architectures
from its lockfile at idevice commit
`c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5`. Consumers do not need Rust,
Cargo, Homebrew, or a separate `idevice_pair` download. Release builds remap
developer paths and strip helper symbols before the package secret/path audit.
The release audit also requires the helper to contain the same configured
universal architecture set as the GUI and provisioner.

## Xcode Product Requirement

Current requirement:

| Requirement | Current answer |
| --- | --- |
| Xcode installed | Yes |
| User opens Xcode | Target no, not clean-Mac proven |
| User signs into Xcode | No in current intended native flow |
| User configures Xcode Accounts | No in current intended native flow |
| User manages certificates in Xcode | No |
| User builds manually in Xcode | No |
| User installs manually from Xcode | No |
| User logs into Apple inside IOSSim | Yes |
| IOSSim handles Personal Team provisioning | Yes |
| IOSSim handles signing | Yes |

The product decision has changed from "absolute zero Xcode required" to "Xcode
may be an invisible installed prerequisite if the user does not need to open or
configure it." That assumption must be qualified on a clean Mac.

## Future Device Backend Decision

Path A: keep `devicectl`.

If clean-Mac testing proves that installing Xcode without launching/configuring
it is enough, keeping `devicectl` may be acceptable. Benefits are Apple-supported
device tooling and less custom installation code.

Path B: replace `devicectl`.

If Xcode must be opened/configured, license prompts block the flow, or CoreDevice
dependencies are unacceptable, replace the install/discovery/inventory path with
the pinned idevice stack: usbmuxd, lockdown, AFC/PublicStaging,
InstallationProxy, and authoritative inventory verification.

Do not state that Path B has already been chosen.

## Public Release Work Still Required

Before public release:

- licensed Apple developer-download authentication and consumer bootstrap UI;
- complete third-party notice generation/audit for all statically linked Rust
  transitive dependencies;
- same-Mac/same-iPhone automatic-pairing regression of the experimental RC;
- runtime requalification after setup stabilization;
- clean-Mac Xcode-installed-never-opened qualification;
- decision on `devicectl` versus native idevice/AFC/InstallationProxy;
- profile refresh/expiry proof;
- Developer ID signing;
- notarization and stapling;
- Gatekeeper qualification;
- final support-report and secret-scan audit.

## Source References

- `scripts/bootstrap/iossim_cli.py`
- `macos/Sources/IOSSimMacCore/Services/BundledProvisioningEngine.swift`
- `macos/Sources/IOSSimMacCore/Services/RuntimeProvisioningSupport.swift`
- `docs/mac-host/PRODUCTION_RELEASE.md`
- `docs/mac-host/SELF_CONTAINED_APP.md`
