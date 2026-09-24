# Developer Mode pre-install prerequisite gate — 2026-09-24

Replaces the generic first-time Developer Mode failure with an explicit prerequisite in front of the
reconciliation engine. The proven post-Developer-Mode pipeline is unchanged.

## Why

The physical fresh-phone run with Developer Mode OFF produced:

```
failing domain: developerSupport
developerSupport = stale
VEYA-DEVICE-030  The device could not be observed.
```

Root cause: iOS returns the authoritative `"Developer mode is not enabled."` string only on the
install, launch and mount paths. The `developerSupport` domain observes the CoreDevice/RSD chain
first, which fails transport-shaped (`Status::CoreDeviceProxyFailed`), lands in
`DeviceFailureMapping.map`'s `default`, and becomes `DeviceDomainFailure.observationFailed`. The
typed `.developerModeRequired` plumbing added by the fresh-phone work was correct but unreachable on
the path that runs first, so `DevelopmentInstallationStage.resolve` never reached
`.enableDeveloperMode`.

## Flow

```
Select iPhone
  -> Enable Developer Mode      (AMFI action 0, reveal only)
  -> iPhone instructions        (user enables, reboots, unlocks, confirms)
  -> Continue                   (re-list, rebind by stable UDID, verify device state)
  -> Install / Prepare          (existing pipeline, unchanged)
```

The engine never runs for an iPhone whose gate has not passed. `DevelopmentInstallationModel.run`
holds a fail-closed guard in addition to the button routing.

## The trigger

`iossim_bridge_reveal_developer_mode` exports AMFI's reveal action
(`com.apple.amfi.lockdown`, action 0) through the already-linked `AmfiClient`. It creates AMFI's
show-override marker so Settings ▸ Privacy & Security ▸ Developer Mode appears, and does nothing
else: it does not enable Developer Mode, does not reboot, needs no passcode, and is idempotent.

AMFI's enable (action 1) and accept (action 2) are deliberately **not** exposed. Action 1
force-reboots and is rejected outright on any device with a passcode set; enabling belongs to the
user on the device. No Xcode dependency is introduced.

Bridge ABI **2 → 3**. The new symbol joins the fail-closed `allSatisfy` list in
`DynamicNativeDeviceTransport`, so a bridge predating the gate is refused with `.incompatibleABI`
rather than silently skipping the prerequisite.

## Verification — the click is never proof

`Continue` re-lists devices, rebinds by stable UDID through the existing
`DevelopmentDeviceRebinding` (Apple's restart changes the mux identity and connection generation;
the UDID does not, and another attached iPhone is never a substitute), then requires **one** of
three device-side signals:

| Evidence | Why it proves Developer Mode |
|---|---|
| `amfiStatusEnabled` | AMFI status action reported the toggle on. Trustworthy when positive. |
| `personalizedImageMounted` | iOS does not permit a mounted personalized image with Developer Mode off. |
| `developerServicesReady` | The full CoreDevice/RSD/RemoteXPC/AppService chain answered. |

AMFI's status is advisory: iOS 26.6.2 has been physically observed reporting `disabled` while
developer services worked (recorded in `NativeDeveloperServicesCoordinator.prepare`). A
one-signal gate would wedge that device. No signal at all means the gate holds — there is no
bypass, by decision.

`adopt(inspection:)` runs on device selection and can only *raise* the gate, on AMFI's positive
answer. An already-ready iPhone therefore reaches `Install / Prepare` with no extra step and no
extra device I/O. It never lowers the gate, so a later advisory `disabled` cannot un-verify a phone
proven by a mounted image or a live session.

## Recovery when Developer Mode is lost later

`DynamicNativeDeviceTransport.readiness` now re-reads an ambiguous developer-services chain failure
(`coreDeviceProxyFailed`, `softwareTunnelFailed`, `rsdUnavailable`, `remoteXPCFailed`,
`appServiceUnavailable`, `featureUnavailable`, `developerServicesNotReady`, `protocolFailure`) as
`.developerModeRequired` **when the device itself reports Developer Mode off**. The engine's
Developer Mode user action then withdraws the gate's evidence and re-enters the prerequisite.

Validation is re-entered, never weakened:

- transport losses, locks, trust prompts, missing images, application/launch/container failures,
  ABI failures and Veya's own defects keep their accurate meaning;
- a probe that succeeded is never blocked by AMFI's advisory status;
- the reactive recovery stage and every lower-level fail-closed check are retained.

## Removed

`ConsumerOnboardingCoordinator` and its tests. It was a second pre-install Developer Mode gate with
**no production callers** that trusted AMFI's advisory status alone. Its ordering (unlock → trust →
developer mode → install) is preserved by the new gate.

`SetupStore` / `StatusInterpreter.deviceReadiness`'s `.developerModeRequired` path in the legacy
doctor-driven wizard was left alone: it is a separate surface that does not participate in this
pipeline. Flagged, not changed.

## Developer trust

Unchanged and explicitly **not** part of this pre-install gate. `.trustDeveloper` stays post-install
and conditional, reached only from the engine's own `developerTrust` user action after iOS refuses
a launch. It is never requested pre-emptively and never automated. Covered by
`testDeveloperTrustIsNotPartOfThePreInstallGate`.

## Preserved

Signing/certificates/profiles, DDI download and personalization, payload installation, developer
trust handling, LocalDevVPN, automatic pairing, pairing crypto/binding, Run Setup, `sessionProbed`,
zero setup-time location mutation, runtime verification, journal recovery, intentional
spoofing/Rich Drive, DMG packaging, M4 deferral, and existing security/fail-closed behavior.
`InstallationDomain.reconciliationOrder` is unchanged and no second setup engine exists.

## Tests

`DeveloperModeGateTests`: 20/20 PASS — evidence rules; fresh phone starts at reveal and blocks the
engine; reveal succeeds → instructions + Continue; reveal failure does not advance; Continue without
enabling remains gated (repeatedly); unreachable phone stays gated; restart generation change
rebinds by stable UDID; another attached iPhone is never a substitute; verified → Install / Prepare;
advisory AMFI false negative rescued by device-side evidence; already-ready phone not interrupted;
`adopt` never lowers the gate; device change resets it; later unavailability re-enters the
prerequisite; Developer Mode off is no longer a generic observation failure; recovery never relabels
typed failures or healthy devices; outdated/absent native bridge fails closed; developer trust stays
post-install and conditional.

Native: 21/21 PASS, including the ABI-3 assertion and the null-handle reveal guard.

Full macOS suite: 569 tests, 18 skipped, **4 failing assertions in one pre-existing test** —
`SigningKeyStoreTests.testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction`
(`VEYA-KEY-001`, Keychain wrapping store unavailable to an unsigned test binary). Reproduced
identically on the clean tree before these changes; the baseline's own Swift test run passes.

`./iossim installation-baseline --defer-m4`: **Overall PASS**.
Focused DMG tests 3/3 PASS. Artifact identity tests 6/6 PASS.

## Artifact

- Source branch: `work/final-no-xcode-setup-v1`
- Clean source HEAD: `94ed677bffb79a1e6b599326ba3c126c42bccc7a`
- `guiSourceDirty` / `helperSourceDirty` / `sourceDirty`: `false`
- App: `.build/iossim/development-session/Veya Development.app`
- DMG: `.build/iossim/release/Veya-Test-94ed677.dmg`
- Volume: `Veya Test`; exactly `Veya Development.app` + `Applications -> /Applications`
- Size: `33,412,201` bytes
- SHA-256: `af6c5563f848dd978ec5a8627a3a5160aa3071120c88610d91312e3d87b86f02`
- `nativeBridgeABI`: **3** in both `BuildProvenance.plist` and `EngineIntegrity.plist`
- `_iossim_bridge_reveal_developer_mode` exported from the bundled dylib
- Architectures: `x86_64 arm64` for the GUI, helper and bridge
- `hdiutil verify` PASS; `codesign --verify --deep --strict` PASS for the source app and the
  mounted app

The ignored `.build` artifact is not committed. The digest above is the transfer identity.

### iPhone payload

**Unchanged**, still built from clean `073d4a9` (`payloadSourceDirty: false`), reused byte-for-byte
rather than rebuilt. Note: the iPhone-side Run Setup request gating committed in `94ed677`
(`ios/App/SetupView.swift`, `ios/App/Shared/ConnectionStatusModel.swift`,
`ios/Sources/IOSSimOnDeviceDVTPOC/RunSetupInbox.swift`) is **not** in this payload. That is
pre-existing and out of scope here; rebuilding the payload is a separate, separately-verified step.

### Expected development-only audit findings

Unchanged from Target A: development bundle identity (`com.veya.development-session`,
`Veya Development`, build `1`), debug/source path strings in the binaries, and no production
`IOSSim.icns`. No private keys, pairing/auth material, provisioning profiles, forbidden development
material, or world-writable files.

## Physical retest instructions

Do not install Xcode at any point. Stop at the first failure and preserve the exact error text,
failing domain, and failure code before changing anything.

**Setup**

1. `shasum -a 256 Veya-Test-94ed677.dmg` → must equal
   `af6c5563f848dd978ec5a8627a3a5160aa3071120c88610d91312e3d87b86f02`.
2. Open the DMG, drag `Veya Development.app` to Applications, eject `Veya Test`. Do not run it from
   the mounted image.
3. Launch from Applications. If macOS blocks it: System Settings → Privacy & Security → **Open
   Anyway**. Do not disable Gatekeeper or clear quarantine.
4. Start from an iPhone with **Developer Mode OFF** and LocalDevVPN **not installed**. Connect it
   over USB and unlock it.

**A — the gate**

5. Select the iPhone. Expected: header **Enable Developer Mode**, and the primary button reads
   **Enable Developer Mode**, not Install / Prepare.
6. Press **Enable Developer Mode**. Expected: nothing installs, no Apple sign-in, no VPN, no
   pairing. The button becomes **Continue** and the instruction names
   Settings ▸ Privacy & Security ▸ Developer Mode.
7. **Before touching the iPhone**, press **Continue** once. Expected: it stays gated with
   "still reports Developer Mode as unavailable". Record the exact text. *This is the
   click-is-not-proof check.*
8. On the iPhone, confirm the Developer Mode row is now visible in Settings ▸ Privacy & Security.
   Record whether it was already visible before step 6.
9. Turn Developer Mode on, accept the restart, let the iPhone reboot, unlock it, and confirm the
   post-restart **Turn On** prompt (enter the passcode).
10. Back on the Mac, press **Continue**. Expected: the gate verifies and the button becomes
    **Install / Prepare**. Record the header and message.

**B — the existing pipeline (must be unchanged)**

11. Press **Install / Prepare** and run the established flow through to READY: Apple sign-in,
    signing, DDI download/personalization/mount, install, developer-profile trust when iOS asks for
    it, LocalDevVPN install/permission/connect, automatic pairing, Run Setup on the iPhone,
    **Continue / Verify Setup**, READY. Note any step that behaves differently from the last
    physical run.
12. Confirm **Trust Developer** appears only *after* the app is installed and only when iOS actually
    demands it — never before Install / Prepare, and never automatically.
13. Exercise intentional spoofing / Rich Drive and confirm runtime verification still passes.

**C — recovery**

14. With the iPhone at READY, turn Developer Mode **off** on the iPhone (Settings ▸ Privacy &
    Security ▸ Developer Mode) and press the primary button on the Mac. Expected: Veya returns to
    the **Enable Developer Mode** prerequisite. It must **not** report
    `VEYA-DEVICE-030 / The device could not be observed.` Record the exact header, message, domain
    and code.
15. Re-enable Developer Mode on the iPhone, reboot, unlock, press **Continue**, confirm the gate
    verifies again and the pipeline resumes without repeating install/signing work.

**D — regression checks**

16. Select a second iPhone if one is available: the gate must reset for it and must not inherit the
    first phone's verification.
17. Relaunch Veya (M4 deferred): Apple session and signing key are expected to be discarded. Confirm
    the gate re-evaluates against the device rather than assuming the previous session's result.
18. On an iPhone that already has Developer Mode on, confirm selecting it goes straight to
    **Install / Prepare** with no Developer Mode step at all.
