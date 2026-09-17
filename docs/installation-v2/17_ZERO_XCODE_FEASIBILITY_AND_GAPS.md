# Zero-Xcode feasibility and gaps

## Verdict

**ZERO_XCODE_CONDITIONALLY_FEASIBLE**

The host/device protocols needed for discovery, initial trust, signing, installation, developer support mount, AppService launch, pairing delivery, LocalDevVPN readiness, and Rich runtime are technically available without invoking Xcode on the customer Mac. Most are already present in the current bridge. `CONFIRMED_LOCAL_IOSSIM_CODE`, `CONFIRMED_OPEN_SOURCE_REFERENCE`

## Conditions

| Boundary | Current status | Condition for ship |
| --- | --- | --- |
| Initial Lockdown trust | ABI missing; upstream `pair_once` and usbmux save exist | Implement narrow ABI and pass clean-device matrix |
| Personalized DDI assets | Existing-cache reader only | Approved Apple-origin acquisition/distribution decision |
| TSS personalization/mount | Implemented in pinned device stack | Validate fresh builds and outage/error handling |
| Personal Team | Substantial private adapter | Compatibility fixtures, kill switch, typed errors, renewal tests |
| App install/launch | Implemented; saved physical evidence | Final-build physical qualification |
| RemotePairing | Import works; proof/rollback unsafe | Staged replacement and possession/operational proofs |
| LocalDevVPN | External app expected | Distribution ownership, activation, version/readiness contract |
| Runtime READY | Stored checkpoint | Fresh Rich runner proof |
| Release | Multiple divergent paths | One artifact-derived, signed/notarized pipeline |

## Developer image blocker

Current iOS 17+ flows require personalized developer-support material selected for exact build/device identity and personalized through Apple TSS. IOSSim can mount it but cannot acquire it on a clean host. The first exact dependency is native `CoreDeviceProxy::connect`: `ImageNotMounted` becomes `DdiRequired` before software tunnel, RSD, RemoteXPC, AppService launch, and the downstream TestManager/XCTest/XCUILocation path.

The inspected Vanish 3.2.1 flow proves it has the same prerequisite. Electron runs bundled `pymobiledevice3 mounter auto-mount` before starting its RSD tunnel. When `~/Xcode_iOS_DDI_Personalized` is empty or stale, bundled `developer_disk_image` downloads `Image.dmg`, `BuildManifest.plist`, and `Image.dmg.trustcache` from `doronz88/DeveloperDiskImage`; PMD then performs Apple TSS personalization and mount. No DDI assets were found bundled in `Vanish.app`. Apple publishes documentation for Xcode component acquisition, not a public third-party DDI distribution API found in this research. `CONFIRMED_LOCAL_IOSSIM_CODE`, `CONFIRMED_VANISH_ARTIFACT`, `CONFIRMED_VANISH_STATIC_CODE`, `CONFIRMED_OPEN_SOURCE_REFERENCE`, `CONFIRMED_APPLE_DOCUMENTATION`

Acceptable resolutions are:

1. Apple documents/authorizes a direct source usable by Veya and the release provider verifies signed metadata and content hashes; or
2. product/legal approves a controlled Veya download origin with documented upstream rights, integrity, revocation, retention, and geographic/service constraints; or
3. the product explicitly requires a user-provided authorized Apple component, accepting that the desired clean zero-Xcode experience is not met.

A public third-party mirror is not the default architecture. Until one resolution is accepted, the overall verdict remains `ARCHITECTURE_NOT_READY`.

Exact updated conclusion: `VEYA_REQUIRES_DDI_AND_VANISH_SOLVES_IT_WITH_BUNDLED_PYMOBILEDEVICE3_AUTO_MOUNT_DOWNLOADING_APPLE_DDI_ASSETS_FROM_THE_DORONZ88_GITHUB_MIRROR_THEN_PERSONALIZING_VIA_APPLE_TSS`.
