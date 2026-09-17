# Executive verdict

## Direct decisions

| Question | Answer | Basis |
| --- | --- | --- |
| Can Veya follow Vanish's consumer installation model? | **CONDITIONALLY** | The self-contained app, guided Apple actions, automated provisioning/install, typed recovery, and one release identity map cleanly to existing Veya components. |
| Can Veya ship without Xcode installed? | **CONDITIONALLY** | Veya already bundles most required native capabilities. A release-approved personalized DDI source is still unresolved. |
| Does Veya require developer support on a fresh current-iOS device? | **YES for the present native AppService/RSD and Rich runtime architecture** | `CoreDeviceProxy::connect` reports `ImageNotMounted`; the bridge converts that to `DdiRequired` before software tunnel/RSD/AppService. |
| How does Vanish handle it? | Bundled PMD auto-mount downloads DDI inputs from a third-party GitHub mirror, personalizes through Apple TSS, mounts, then opens its RSD tunnel. | `CONFIRMED_VANISH_STATIC_CODE` and bundled package metadata. |
| Is that mechanism approved for Veya? | **NO DECISION** | Technical feasibility is established; provenance, Apple asset rights, availability, integrity policy, and GPL distribution implications need an explicit product/legal decision. |
| Is the architecture ready for unconditional implementation? | **NO** | The DDI provider decision controls the self-contained dependency contract. |

The exact Phase C conclusion is:

> `VEYA_REQUIRES_DDI_AND_VANISH_SOLVES_IT_WITH_BUNDLED_PYMOBILEDEVICE3_AUTO_MOUNT_DOWNLOADING_APPLE_DDI_ASSETS_FROM_THE_DORONZ88_GITHUB_MIRROR_THEN_PERSONALIZING_VIA_APPLE_TSS`

## What Vanish changes in the Veya plan

Vanish resolves the technical mystery: a clean machine does not get the personalized image from macOS, the phone, or a public Apple download API in the inspected flow. Vanish supplies a bundled acquisition client and uses a third-party asset mirror. The earlier Installation V2 blocker was therefore correctly identified, but can now be stated precisely.

Veya should adopt the behavioral pattern: one notarized app owns every installation step it can automate; Apple security prompts remain explicit; state survives interruption; repair is narrower than reinstall; user errors name the failed domain. Veya should keep its native Rust/Swift stack. Bundling Electron, Python, PMD, or Vanish's cloud/entitlement architecture would add distribution and runtime complexity without solving a capability Veya otherwise lacks.

## Current completeness

A rough engineering estimate is **70–80% of the installation capability is present in source**, depending on whether release/qualification work is counted. This is not a readiness percentage. The remaining work includes the highest-risk boundaries: first Lockdown pairing, approved DDI acquisition, process-safe state, staged RemotePairing promotion, LocalDevVPN lifecycle ownership, true Rich runtime proof, renewal, diagnostics, release provenance, and clean-machine qualification.

Independent work can start with artifact truth, hermetic tests, engine integrity, keyed state, initial Lockdown pairing, and pairing staging. The DDI provider milestone must not claim acceptance until the product decision is made.

A read-only `gh release list --repo Reshwant-Borra/IOSSim` check on 2026-09-15 again returned no releases. GitHub Releases remains the proposed future authority, not a current distribution fact.
