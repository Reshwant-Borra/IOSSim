# Open questions

## Architecture blocker

1. **What approved source may Veya use for current personalized developer-support assets on a clean Mac?** Vanish no longer leaves the technical mechanism unknown: it downloads the assets from the doronz88 GitHub mirror through bundled PMD and personalizes through Apple TSS. The remaining question is whether Veya may and should use any mirror/bundled/direct source. Required answer: upstream authority, rights/terms decision, wrapper license obligations, asset signature/hash/provenance, update/revocation/outage behavior, cache policy, supported iOS builds, and accountable owner. `PRODUCT_DECISION_REQUIRED`. This is the reason for `ARCHITECTURE_NOT_READY`.

## Shipment product/legal decisions

2. Will the product/security/legal owners approve the private GrandSlam/Developer Services adapter for consumer distribution, with a kill switch and compatibility maintenance commitment?
3. Is there a support/commercial compatibility agreement with the LocalDevVPN publisher, and what is the user experience if the App Store app is unavailable or becomes incompatible?
4. Is macOS 13 on Intel a supported Veya target? ADR-015 assumes yes and requires a universal DMG; a different answer must update the release policy before M1.
5. Will bundle identifiers remain stable during the IOSSim-to-Veya display rename? A bundle-ID change requires the separate dual-ID plan in 32.
6. Who controls GitHub release permissions, Developer ID/notarization credentials, signed update-manifest keys, incident revocation, and release approval separation?

## Implementation questions resolved by milestones

7. Which exact idevice protocol operation best proves phone possession of the newly imported RemotePairing candidate? M8 must select and threat-review it before wire schema 2 freezes.
8. What safe Rich probe demonstrates XCUILocation semantics without leaving user-visible movement? M11 must define the observable and guaranteed Clear behavior.
9. What TTLs/renewal margins are appropriate for readiness receipts, profiles, pairing requests, VPN requests, and operation leases? Use capability events rather than arbitrary long caches; tune through tests.
10. Can current release dependencies build and operate on x86_64? M1 answers by actual build/audit; if not, return to decision 4 rather than relabeling output.

## Physical questions, not architecture blockers

Clean Trust prompt transitions, AppService launch on every supported iOS build, Keychain ACL behavior, LocalDevVPN permission/foreground behavior, pairing crash recovery, profile renewal/limits, reboot/update/reinstall, Rich cadence/clear, and final notarized DMG behavior require 33/M15. Their absence prevents shipment but does not require more static architecture invention.

## Explicitly closed questions

- The packaged production engine is `BundledProvisioningEngine`, not repository CLI.
- Native installation/AppService/House Arrest support exists.
- `doctor` is a helper subcommand.
- Current READY is not runtime proof.
- The current retest DMG equals its assembled app but its architecture/schema metadata is wrong.
- GitHub currently has no releases; GitHub Releases is the selected future authority.
- Vanish is evidence, not an implementation source or default architecture.
