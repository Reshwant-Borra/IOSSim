# Executive summary

## Verdict

**ARCHITECTURE_NOT_READY**

The current worktree already implements most of the native no-Xcode device stack: bundled production engine selection, native usbmux discovery, inspection, personalized image mount, Installation Proxy/AFC installation, AppService launch over CoreDevice/RSD, House Arrest transfer, a substantial private Personal Team adapter, and automatic RemotePairing delivery. Older statements that native installation is absent or that packaged consumers normally use the repository Python CLI are stale. `CONFIRMED_LOCAL_IOSSIM_CODE`

The blocking product question is fresh developer-support image supply. IOSSim only reads existing Apple/CoreDevice caches. Follow-on static analysis proves the official Vanish 3.2.1 app also requires DDI: before opening its RSD tunnel it runs bundled `pymobiledevice3 mounter auto-mount`; on an empty personalized-image cache, the bundled `developer_disk_image` client downloads `Image.dmg`, `BuildManifest.plist`, and the trust cache from the doronz88 GitHub mirror, then PMD personalizes through Apple TSS and mounts the image. This resolves the technical mechanism but not redistribution rights, source authority, integrity/update policy, or GPL packaging implications for Veya. Until Veya has an approved source and written distribution/use decision, clean-machine zero-Xcode cannot be shipped honestly. `CONFIRMED_LOCAL_IOSSIM_CODE`, `CONFIRMED_VANISH_STATIC_CODE`, `CONFIRMED_OPEN_SOURCE_REFERENCE`, `CONFIRMED_APPLE_DOCUMENTATION`, `PRODUCT_DECISION_REQUIRED`

## Direct decisions

| Area | Decision | Evidence/status |
| --- | --- | --- |
| Zero-Xcode | `ZERO_XCODE_CONDITIONALLY_FEASIBLE`; do not market as complete yet | First pairing is implementable; DDI supply blocks release |
| Setup engine | Keep `IOSSimSetupEngine`, `SetupStore`, `BundledProvisioningEngine`, `IOSSimProvisioner`, and `ConsumerArtifactProvisioner`; consolidate ownership | `CONFIRMED_LOCAL_IOSSIM_CODE` |
| Initial trust | Add a narrow native Lockdown `pair_once` ABI and preserve Apple’s Trust/passcode UI | `CONFIRMED_OPEN_SOURCE_REFERENCE`; physical validation required |
| Developer support | Keep cache discovery/mount; add a policy-gated provider only after product/legal approval | Architecture blocker |
| Pairing | Refactor to staged replacement and fresh possession proof; import receipt is insufficient | Current proof is a no-op and repair deletes first |
| LocalDevVPN | Keep the separately distributed App Store app; Veya detects, guides install, launches, and verifies endpoint | Redistribution/entitlement risk avoids absorption |
| Runtime readiness | READY requires a fresh end-to-end Rich runtime probe, not a stored checkpoint | Current `markRuntimeSetupReady` is configuration-only |
| Apple provisioning | Keep behind a versioned private adapter; expose typed service outcomes to setup | Current implementation is substantial but undocumented/private |
| State | Replace singleton files with release/team/device/artifact-scoped snapshots, journal, and OS file lock | Current actors do not serialize helper processes |
| Release | One builder and one release identity; derive manifest from mounted output | Current DMG is arm64 while sidecar says universal; embedded schema is stale |
| Branding | Rename IOSSim to Veya only after functional qualification; migrate state and support old bundle IDs deliberately | Bundle/signing IDs unchanged in this research |

## Current proof boundary

The saved physical records contain typed `APPSERVICE_READY`, `MAIN_NATIVE_LAUNCH_SUCCEEDED`, and LocalDevVPN readiness events on an iPhone18,1 running iOS 26.6.2. Those records support prior physical success, but they are not a new clean-machine test or proof for a final signed build. `PHYSICAL_EVIDENCE_FROM_EXISTING_RECORD`

The newest Swift log reports 279 tests, 7 skipped, 36 assertion failures, and 1 unexpected failure. The failures group into stale backend/state expectations, fixtures that skip the intended injected fault, pairing mocks that cannot satisfy the new proof path, and SetupStore tests leaking persisted/live defaults. The last category is a real test-isolation defect even where product code is not disproven. `CONFIRMED_LOCAL_IOSSIM_TEST`

## Required blocker resolution

Architecture becomes ready only after all of these are true:

- A developer-support asset decision names the upstream authority, permitted use/distribution, integrity metadata, outage behavior, and supported iOS build range.
- The decision is compatible with “no full Xcode for the customer.”
- First-time Lockdown pairing and staged RemotePairing proof have frozen wire/state contracts.
- LocalDevVPN compatibility ownership and minimum supported version are accepted.
- A canonical release authority is selected; GitHub currently has no releases.

The remaining physical work is explicitly deferred to 33. No document here turns a static or saved result into a physical pass.
