# DDI and Developer Services

iOS before 17 uses classic DeveloperDiskImage plus signature. iOS 17+ uses personalized image material, BuildManifest, trust cache and a device-specific TSS ticket. Rust idevice and current pmd3 implement the query/personalize/mount flow. The public [DeveloperDiskImage repository](https://github.com/doronz88/DeveloperDiskImage) confirms split assets but does not grant Apple redistribution rights.

## Modern Personalized Flow

1. Read ProductVersion, BuildVersion, UniqueChipID/ECID and device personalization identifiers through the trusted device session.
2. Select an exact compatible BuildIdentity from BuildManifest by BoardId/ChipID and security mode; do not select by marketing iOS version alone.
3. Hash the image with SHA-384 and ask Mobile Image Mounter for an existing personalization manifest. A failed query may close the service socket, so reconnect before continuing.
4. If no cached/device manifest exists, query nonce for DeveloperDiskImage and construct TSS request with board/chip/ECID, production/security/img4 flags, BuildIdentity manifest entries and LoadableTrustCache RestoreRequestRules.
5. Send to Apple TSS with ordinary TLS validation and bounded response size. Extract the signed image ticket/manifest; never fabricate one.
6. Upload the image as Personalized using the ticket as signature, then MountImage with ticket, trust cache and optional image-info plist.
7. Re-query mount status and then RSD/DVT/TestManager capability. A successful upload without a mount/service proof is not READY.

This matches the audited idevice mounter methods query_personalization_manifest, query_personalization_identifiers, query_nonce, get_manifest_from_tss, upload_image and mount_image. libimobiledevice’s current CLI accepts a directory containing image, BuildManifest and firmware/trust material for iOS 17+, but that alone does not supply modern RSD.

## DDIManager

Take product version/build; query device requirements; resolve exact build cache; verify signed manifest and hashes; request TSS personalization; upload/mount through Mobile Image Mounter; record mount/trust-cache receipt. Cache under 0700 Application Support, digest indexed. One request per device, bounded retries and long failure backoff. Reject stale build, wrong board/chip, trust-cache mismatch, Developer Mode off and TSS failure as separate errors.

Asset policy: prefer user-authorized Xcode/CoreDevice cache when present; otherwise use only a release-approved runtime provider with signature/hash manifest and legal asset review; if unavailable report unsupported/action. Never hard-code a public mirror as a redistribution guarantee.

The current pmd3 downloader uses the doronz88 GitHub repository and a current-build constant, caching personalized assets under its home data folder. That is operational evidence for file layout, not an acceptable IOSSim supply-chain policy by itself. Apple documents Xcode component acquisition through Xcode/xcodebuild, but no audited official public API directly grants a third-party app a redistributable DDI. Therefore DDIProvider implementations are:

- ExistingAppleCacheProvider: read-only discovery of an authorized local CoreDevice/Xcode DDI; no Xcode process invocation.
- IOSSimApprovedDownloadProvider: HTTPS-only signed manifest controlled by IOSSim release operations, whose upstream asset rights have been reviewed; content-addressed downloads, resumable, size-capped.
- DevelopmentFixtureProvider: non-production test payloads/fake manifests.

Provider output includes asset provenance ID, build ID, image/trustcache/manifest SHA-256 and size, fetched/validated timestamps and minimum bridge version. It never includes Apple session tokens in the cache key.

## Services

After Developer Mode and mount, CoreDeviceProxy software tunnel -> RSD handshake -> RemoteXPC service map -> DVT/TestManager capability. The host bridge establishes setup capability; the existing iPhone retained RSD/TestManager/XCTest/rich location path remains frozen. DDI failure never triggers signing or pairing regeneration.

Useful service split:

| Need | Transport/service | Owner |
|---|---|---|
| Developer Mode status | com.apple.amfi.lockdown or mounter status query | host bridge |
| Image query/upload/mount | com.apple.mobile.mobile_image_mounter or RSD equivalent | DDIManager/Rust |
| Userspace tunnel | com.apple.internal.devicecompute.CoreDeviceProxy | Rust bridge |
| Service discovery | RSD handshake/RemoteXPC root dictionary | Rust bridge |
| App launch | CoreDevice AppService or DVT ProcessControl | InstallationCoordinator |
| Test runner capability | TestManager/DVT endpoints | readiness probe; phone runtime owns live session |

Do not copy or link Apple CoreDevice/MobileDevice private frameworks from Xcode. macOS’s existing usbmux/device support and Security/Keychain APIs may be used in place; availability is observed at runtime. Command Line Tools do not include devicectl and are not a substitute.

First target qualification cells are iOS 17.4+, 18.x and 26.x; 17.0-17.3 is UNKNOWN. Gate requires clean host, exact matching, TSS personalization, mount, AMFI/developer services, remount/update cache behavior and no image bytes in diagnostics.

Cache invalidation occurs when BuildVersion/BuildIdentity/asset digest or bridge compatibility changes, not simply after an iOS marketing-version bump. An iOS update first tries the still-matching mounted/cached asset, then acquires a new one if required. Keep the previous verified asset until the new one mounts, subject to quota. Errors distinguish noApprovedSource, wrongBuildIdentity, corruptAsset, developerModeDisabled, personalizationRejected, tssUnavailable, uploadFailed, mountRejected and serviceMapUnavailable.
