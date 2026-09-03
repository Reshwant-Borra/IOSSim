# Device Provisioning Productization

Date: 2026-09-03

## Verdict

GUI correctness: pass for code-level policy/tests and packaged-app launch. Packaged helper validation saw two live connected iPhones and did not collapse them to index 0.

No-devicectl runtime: partial. The Mac code now has an explicit backend boundary and a devicectl-forbidden test mode, but the bundled native idevice library in this repository is an iOS static archive, not a macOS helper library.

Customer provisioning feasibility: partial. Apple-supported distribution paths are documented below; none cleanly supports arbitrary consumer installation of the current main app plus XCTest runner architecture without development-style signing/provisioning or a managed/limited distribution model.

## Devicectl Call Map

| Function | Current command | Input | Output | Used by | Can replace? | Replacement candidate |
| --- | --- | --- | --- | --- | --- | --- |
| Device discovery | `/usr/bin/xcrun devicectl list devices --timeout 8 --json-output <file> --quiet` | none | CoreDevice JSON device list | `DevicectlProvisioningBackend.discoverDevices`, legacy CLI `discover_devices` | Yes, if host idevice FFI is built | usbmux device list + lockdown metadata |
| Live-device validation | `/usr/bin/xcrun devicectl device info lockState --device <id> --timeout 5 --json-output <file> --quiet` | selected/candidate CoreDevice ID | success/failure, lock state JSON | `DevicectlProvisioningBackend.discoverDevices`, install target validation | Probably | lockdown query over exact usbmux provider |
| Raw target resolution | same `list devices` plus exact selected identifier | GUI selection identifier | raw CoreDevice ID | `install` / `repair` | Yes | exact usbmux UDID/provider selection |
| App installation | `/usr/bin/xcrun devicectl device install app --device <id> <app> --timeout 60 --quiet` | selected device and app bundle path | process exit and text | `DevicectlProvisioningBackend.install`, legacy CLI `device` | Research-supported, not implemented | idevice installation proxy / `install_package_with_callback` |
| App lookup | `/usr/bin/xcrun devicectl device info apps --device <id> --bundle-id <bundle id> --timeout 10 --json-output <file> --quiet` | selected device and exact project bundle ID | filtered app list JSON | `DevicectlProvisioningBackend.isAppInstalled`, dashboard installed-state reporting | Yes | idevice installation proxy `get_apps` |
| Process launch | no current packaged helper command found | none | none | not currently used by packaged helper | Optional | DVT process control or CoreDevice app service |

## Idevice Backend Investigation

The pinned `jkcoxson/idevice` source under `ios/.build/idevice-src` contains usbmux enumeration, lockdown metadata, installation proxy lookup/install, DVT process control, CoreDevice app service, and XCTest support. The checked-in `ios/Vendor/idevice/include/idevice_minimal.h` exposes only the on-device RPPairing/RSD/DVT/location/XCTest metadata surface used by the iPhone app. The available `ios/Vendor/idevice/lib/libidevice_ffi.a` is `arm64` for iOS and cannot be linked into the macOS provisioner.

Implemented now:

- `DeviceProvisioningBackend` protocol.
- `DevicectlProvisioningBackend` for the current proven path.
- `IdeviceProvisioningBackend` explicit unavailable implementation, returning `IDEVICE_BACKEND_UNAVAILABLE` instead of falling back.
- `IOSSIM_DEVICE_BACKEND=idevice` explicit backend selection.
- `IOSSIM_FORBID_DEVICETCTL=1` / `IOSSIM_NO_DEVICETCTL=true` structural no-devicectl mode.

Validation:

- `./iossim package-app` passed.
- `./iossim audit-app .build/iossim/self-contained/IOSSim.app` passed.
- A copied app under `/var/folders/.../IOSSim.app` verified its bundled artifacts after normalizing `/private/var` path aliases in the Swift verifier.
- `IOSSIM_FORBID_DEVICETCTL=1 IOSSimProvisioner install --device <id>` exits `78` with `DEVICETCTL_FORBIDDEN` before target resolution.
- `IOSSIM_DEVICE_BACKEND=idevice IOSSimProvisioner doctor --json` selects idevice explicitly and reports no devices because the macOS host FFI is not implemented.

Runtime process audit for packaged provisioning:

- Still invokes `/usr/bin/xcrun devicectl` for discovery, lock-state liveness probing, and app installation when the devicectl backend is selected.
- Also invokes `/usr/bin/xcrun devicectl device info apps` for exact bundle-ID installed-app lookup when the devicectl backend is selected.
- Invokes `/usr/bin/security cms -D -i <embedded.mobileprovision>` for CMS profile decoding.
- Does not invoke `xcodebuild`, `git`, `python`, `node`, `cargo`, or `rustc` in the packaged Swift helper's normal provisioning path.
- `otool -L` shows only macOS system frameworks and Swift runtime libraries; no Xcode private framework dynamic linkage.

Next native milestone:

- Build a separate macOS `libidevice_ffi.a` or helper library.
- Extend the FFI minimally for `iossim_device_list`, `iossim_device_info`, `iossim_install_app`, and `iossim_lookup_app`.
- Prove install/lookup parity against `devicectl` on the same selected device.

## Provisioning Profile Eligibility

The helper now inspects each app bundle's `embedded.mobileprovision` without printing the profile body. It reports:

- profile type: development, ad-hoc, enterprise, app-store, missing, unreadable, or unknown
- team identifier
- expiration date
- provisioned-device count
- selected-device eligible yes/no
- application identifier
- aggregate status: `INSTALLABLE`, `DEVICE_NOT_IN_PROFILE`, `PROFILE_EXPIRED`, `SIGNATURE_INVALID`, `REQUIRES_RESIGNING`, or `UNKNOWN`

Install/repair stops before app installation when the selected device is not eligible.

## Apple-Supported Customer Provisioning Matrix

| Option | Main app | XCTest runner | Random customer iPhone | Xcode | Apple account | Device registration | Expiration | Scale | Policy/technical risk | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Apple Development | Yes | Yes, current natural model | No | Usually yes | Developer/team | Yes | Profile/cert lifecycle | Team/device limited | Low if used for development | Best for internal/dev validation |
| Ad Hoc | Yes | Unknown/high risk for runner behavior | No, only registered devices | Not on customer Mac for install | Developer Program | Yes, up to 100 iPhones per membership year | Distribution profile lifecycle | Poor for public customers | Medium; runner may still need development services | Limited beta only |
| TestFlight | Yes for normal app | Not a supported XCTest-runner distribution model | Yes for invited testers | No customer Xcode | Tester Apple Account/TestFlight | No UDID registration | 90-day beta build | Up to 10,000 external testers | High for current architecture and review | Main app beta only, not current runtime |
| App Store | Yes for normal app | No supported bundled test-runner install/execution model | Yes | No | Customer Apple Account | No | Store lifecycle | Public | High; current DVT/XCTest/developer-services architecture conflicts with review expectations | Not feasible with current architecture |
| Developer ID | Mac app only | No | No | No | Developer Program | No iPhone support | Mac cert lifecycle | Mac distribution | Not applicable | Mac-only |
| Enterprise | Yes for employees | Unknown/high risk for XCTest runner | No, employees/internal only | No customer Xcode | Organization | No UDID registration for in-house | 12-month provisioning profile | Organization internal | High if used for external customers | Not for public customers |
| Custom Apps / ABM | Yes after App Review | No supported XCTest-runner model | Only assigned organizations | No | Organization via ABM/ASM | No | Store-managed | Business/education | High for current runtime | Main app only unless architecture changes |
| Unlisted App | Yes after App Review | No supported XCTest-runner model | Yes with link | No | Customer Apple Account | No | Store-managed | Broad but hidden | High for current runtime | Main app only unless architecture changes |
| Managed deployment / MDM | Yes | Potentially installable as managed app, but XCTest execution still unproven | Organization devices only | No | Organization | Depends on method | Managed/store/enterprise lifecycle | Managed fleets | Medium/high | Enterprise/managed pilots only |
| Free personal team | Yes | Possibly for self-built runner | No, user's own few devices only | Yes | User Apple Account | Xcode-managed | 7 days | Very poor | Credential/security UX risk | Developer-user path only |
| Paid user-owned signing | Yes | Likely yes if user builds/signs full test target | User's own devices | Yes or Apple tooling | User Developer Program | User/team registered | Profile/cert lifecycle | Moderate for technical users | Credential handling must stay in Apple tools | Best legitimate power-user model |
| Local re-signing with user's credentials | Technically possible but delicate | High complexity: runner, test bundle, entitlements, team IDs, provisioning replacement | User's registered devices only | Likely yes or App Store Connect API tooling | User account/team | Yes unless distribution path avoids it | Profile lifecycle | Moderate if fully designed | High if app handles credentials | Future milestone only |

## Source Notes

Apple documents that development provisioning needs an App ID, development certificate, and registered devices; Xcode can manage development profiles automatically. Apple documents Ad Hoc as running on registered devices without Xcode, requiring an App ID, distribution certificate, and selected registered devices. Apple account help says a Personal Team can register up to 10 App IDs, 3 devices, and 3 apps per device, with provisioning profiles expiring after 7 days. Apple TestFlight allows up to 10,000 external testers and 100 internal testers, with builds testable up to 90 days and external review for the first build. Apple Enterprise distribution is restricted to proprietary, in-house employee apps for eligible organizations and profiles expire after 12 months. Apple states App Store apps may only use public APIs and frameworks for intended purposes, and VPN apps have organization and disclosure requirements. Apple unlisted/custom app documentation still requires App Review and App Store-style distribution.

References:

- https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/
- https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/
- https://developer.apple.com/help/account/devices/devices-overview/
- https://developer.apple.com/help/account/basics/about-your-developer-account/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- https://developer.apple.com/programs/enterprise/
- https://support.apple.com/guide/deployment/distribute-proprietary-in-house-apps-depce7cefc4d/web
- https://developer.apple.com/support/unlisted-app-distribution/
- https://developer.apple.com/support/volume-purchase-and-custom-apps/
- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/news/?id=r1sz7dke

## XCTest Runner Conclusion

`com.iossim.location-control-uitests.xctrunner` is the blocking artifact. The current architecture is not just an iOS companion app; it depends on a preinstalled XCTest runner/runtime that developer services can launch and authorize. Apple documents XCTest as Xcode's testing framework, and the current repo's implementation uses DVT/XCTest startup mechanics, RSD, Developer Mode, and developer trust. Standard App Store, unlisted, Custom Apps, and TestFlight flows distribute app binaries to users; they do not provide a supported public product model for shipping and remotely operating a private XCTest runner as part of an end-user runtime.

The legitimate near-term models are:

- registered-device development or ad hoc beta for a small cohort
- user-owned signing for technically capable users
- managed/enterprise pilots for internal organizational devices

Arbitrary consumer iPhone support is not solved with the current XCTest-runner architecture.
