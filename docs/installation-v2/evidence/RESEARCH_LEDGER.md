# Research ledger — 2026-09-15

This is an active evidence notebook, not the final architecture verdict. All observations are from the local worktree unless otherwise stated. No device interaction, Apple authentication, Keychain queries, source builds, or production edits were performed.

## Baseline

- Root `/Users/rishiborra/Desktop/IOSSim`; branch `work/final-no-xcode-setup-v1`; HEAD `1259da507ecded222022cc86bf82863c15640db9`; origin `https://github.com/Reshwant-Borra/IOSSim.git`; no tags returned.
- 44 tracked modified files, 4,885 insertions/436 deletions initially. `source-baseline.json` records 412 source/document hashes and initial status/branches. Excludes secret state, archives, app contents and pre-existing reference trees.
- No root AGENTS.md found. A reference-only pymobiledevice3 AGENTS.md was read before inspecting that project. No subagents spawned.
- Vanish mounted read-only at `evidence/vanish-mount` via hdiutil; detach before final handoff. Do not traverse Applications symlink.

## Confirmed observations needing explicit reconciliation

1. Current `build_app.sh` defines IOSSIM_BUNDLED_ENGINE, embeds helper in Contents/MacOS, requires prebuilt DeviceArtifacts. Older development packaging claims are historical. Plain Swift build still selects development GUI by default. Bundled factory never falls back to DevelopmentCLIEngine.
2. `doctor` is a subcommand of IOSSimProvisioner or the development Python CLI, not an executable named doctor. Missing bundled helper creates UnavailableIOSSimSetupEngine then ProcessFailure(commandName: doctor). Generic launch error still mentions development/repository in SetupStore.friendlyError.
3. Consumer helper explicitly constructs shared native service + NativeDeveloperServicesCoordinator + RemotePairingCoordinator + LocalDevVPNSetupCoordinator. Consumer provision/reconcile reject legacy backends. Standalone helper doctor/install still honor environment selectors; bridge override path is not compile-time restricted. GUI sanitizes child environment to system PATH/HOME/locale.
4. Native C ABI 1 implements enumerate/open/inspect, RemotePairing create/validate, personalized-image status/mount, inventory/install/upgrade/uninstall, AppService launch/readiness, House Arrest container read/write. No initial Lockdown pairing ABI. Upstream UsbmuxdProvider only reads existing pair record; LockdownClient has pair/pair_once APIs. Wireless enumeration through usbmux exists; independent Wi-Fi onboarding unproven. Rust selection uses first matching UDID before expected mux check, potential duplicate USB/network ordering defect despite Swift dedup.
5. DDI live provider only reads metadata `iossim-developer-support.json` from existing per-build/per-identity caches. No acquisition writer/downloader. Physical report explicitly says DDI already mounted. This does not prove fresh Mac/phone setup. Open-source DDI downloader uses third-party mirror; rights/provenance unresolved, do not silently adopt.
6. Pairing delivery exists: House Arrest request -> phone bootstrap (32-byte key + nonce) -> Mac AES-GCM envelope -> phone Keychain -> receipt. `ReceiptBoundRemotePairingProof.verify` is a no-op. Receipt proves import, not phone runtime. Forced repair deletes old Mac record before replacement succeeds. Phone bootstrap is reused without binding its requestID, and receipt reuse has no current phone-Keychain challenge. Target needs staged replacement and challenge-based freshness.
7. LocalDevVPN is external `com.jkcoxson.LocalDevVPN`; current setup launches it and verifies TCP 10.7.0.1:49152. It does not install VPN app/configuration. Phone `.task` activation is not guaranteed to restart on mere foregrounding; watcher expires. Target must specify scene activation + pending inbox handling with runtime exclusion.
8. Current setup state is schema 4/provisioner 4, helper schema 1, artifacts schema 2, pairing/mapping wire schemas 1. SETUP_READY_FOR_RUNTIME is not Rich runtime proof. `markRuntimeSetupReady` only checks stored checkpoint.
9. ConsumerProvisioningStateStore and NativeProvisioningArtifactStore are singleton files, while pairing is team/device keyed. UI generation checks and actor refresh lock do not serialize multiple helper processes. Need durable identity-keyed state and cross-process lease/journal.
10. Native Apple auth is already implemented, not merely experimental scaffold: local AOSKit/AuthKit, SRP, 2FA, Xcode token, listTeams, managed Keychain RSA key/CSR/cert, read-before-create device/App IDs/profiles. Private adapter version `research-2026-09-akd`. Version-bound constants and private frameworks remain unsupported public interfaces. Password/2FA transient, session Keychain; no remote anisette default. Fresh account flow not physically proved in latest docs.
11. Keychain signing ACL explicitly includes GUI/helper and /usr/bin/codesign; key created in default traditional user Keychain. NativeSigningIdentityResolver and integration tests require separate scrutiny; do not run those tests against user's current Keychain.
12. `.build/iossim/local-release/IOSSim-0.1.0-final-setup-payload-retest.dmg` EXISTS, SHA256 `1b25cd7c41ec2fcb597f24f94184f38bfa29392e638baa06490ea477a92cf14a`, 10,072,395 bytes. Sidecar timestamp 2026-09-15T16:25:23.118518Z, LOCAL_TEST_ONLY, ad hoc, not notarized, dirty source. Contradicts older no-DMG docs. Need mount and compare app.
13. Retest app GUI/helper/bridge are arm64 only. Sidecar claims arm64+x86_64 from config. BuildProvenance timestamp 16:17:56Z, setupStateSchema=3, despite source schema 4. Payload manifest hash `ecdf74fafe767b024fe9712b14512f9b572ba7f627ebf806b4c84867f0a9dd66` matches report; source fingerprint `5668a29add1a3966c4514115523b1a21e69ff6585bdbc76c3e89dcb0aae64a5a`.
14. Saved log `.build/iossim/logs/20260915T182122Z-mac-swift-test.log`: 279 tests, 7 skipped, 36 failures (1 unexpected). Newer than handoff's 271/6/37. Failures include stale backend expectations, SetupStore real-service/default-store leakage, pairing mock operationalProofFailed, support export fixture, skipped-install fault expectations. Do not wave all failures away as stale without diagnosis.

## Tests actually run in this research

- `python3 -B scripts/checks/check_no_xcode_consumer_runtime.py`: PASS (source string assertions only).
- `python3 -B scripts/checks/check_no_xcode_install_routing.py`: PASS (source string assertions only).
- `python3 -B scripts/checks/test_device_discovery_cli.py`: 5 PASS (synthetic parsing/structure).
- `git diff --check`: PASS at initial inspection.
- No Swift/Rust build or physical tests run. Some Swift tests access real Keychain/session by default; do not run full suite here.

## Vanish direct artifact facts

DMG 147,766,400 bytes, SHA256 `fef10cf9e2dcca54773f059fcbc865ad402f43637f9260c7f1391ac541c96ed0`; app `com.vanish.app`, 3.2.1/build 3.2.1, arm64, plist minimum macOS 10.15 (helper actual minimum may be higher), Developer ID Bhavya Khunt / 6343MY26K5, runtime flag, stapled ticket reported by codesign. Fresh inventory: 4,386 regular files, 339,823,032 bytes; ASAR 161 entries, matches old inventory. Electron, Squirrel/Mantle/ReactiveObjC, bundled Python 3.13, pymobiledevice3 9.12.0 GPL-3.0-or-later, Rust VanishSideloader. No execution.

Vanish.ipa SHA256 `7959eba32164c8de29cec2d723df7381f63b8b292fbb76f137c9b40d0e935dbc`, main com.vanish.stikdebug, 3.2.0/build1, iOS17.4, LiveActivity extension. Legacy StikDebug-2.3.7.ipa hash `9e697a42d1630ce9d6b3478597b4daccf331ef7536e2deaccffc0dc0f9104fef`. No profiles/frameworks/XCTest observed in ZIP listing. URL schemes vanish/locsim/sidestore; queries localdevvpn/shortcuts. Prior research's IOSSim comparison is stale (pre-native install). Revalidate JS paths and binary symbols directly, without saving proprietary code.

## External sources opened

Apple current docs: developer account overview (Personal Team limits), notarizing macOS software, packaging Mac software, Developer Mode, Sign in with Apple authentication, ASC API keys/profiles/overview, generating cryptographic keys, TN2206/2339/3126/3127. Use URLs from tool results in final documents. Public Sign in with Apple is app identity, not Developer Services authorization; ASC team-key provisioning is not free Personal Team password auth. Apple packaging says only outermost container needs notarization; two-stage app+DMG submission is a product choice, not requirement.

Existing pinned references available under `VanishedResearch.mSgdHk/FINAL_PREIMPLEMENTATION/references/`; source register has exact commits. Direct idevice inspection confirms USB provider reads existing pairing; RemotePairing awaitingUserConsent branch uses protocol PIN 000000 only after service consent, no trust bypass. Need read license and current remote metadata for projects actually used; no dependencies to add.

## Continuation status — 2026-09-15

Recovery revalidated branch `work/final-no-xcode-setup-v1`, HEAD `1259da507ecded222022cc86bf82863c15640db9`, and all 412 baseline source/document hashes. The baseline comparison reported no changed or missing source files. Both research mounts remain active: Vanish on `/dev/disk44s1` at `evidence/vanish-mount`, and the final payload retest DMG on `/dev/disk46s1` at `evidence/iossim-mount`.

| Major research area | Status | Remaining boundary |
|---|---|---|
| Worktree/source baseline and Git history | COMPLETE | Final comparison and status capture at handoff. |
| Existing reports and stale-claim reconciliation | PARTIAL | Finish named report/diff reconciliation and record superseded claims. |
| Packaged engine, helper, doctor, and setup call graph | PARTIAL | Freeze authoritative reachable-path graph and error translation. |
| Native device bridge and application management | PARTIAL | Confirm final ABI behavior, duplicate transport selection, and proof levels. |
| Initial USB Lockdown trust/pairing | NEEDS REVALIDATION | Audit upstream pair/pair_once and define required ABI/state machine. |
| Fresh developer-image acquisition | NOT STARTED | Resolve Apple source, personalization, cache ownership, licensing, and version scope. |
| RemotePairing delivery/security | PARTIAL | Freeze wire/state model, staged replacement, possession proof, and rollback. |
| LocalDevVPN delivery/configuration/runtime | PARTIAL | Resolve ownership/distribution and define permission, activation, readiness states. |
| AppService/developer-services/runner launch | PARTIAL | Separate implementation/test evidence from missing physical proof. |
| Setup state, ownership, concurrency, and recovery | PARTIAL | Specify identity-keyed stores, lease, journal, generations, and migrations. |
| Apple Personal Team adapter | PARTIAL | Finish retry/idempotency/version-bound data and failure taxonomy. |
| Keychain/signing identity lifecycle | NEEDS REVALIDATION | Complete static audit without touching the real Keychain. |
| Build/release/provenance pipeline | PARTIAL | Map all build paths and explain architecture/schema divergence. |
| Current assembled app vs mounted DMG | PARTIAL | Complete exact content/hash/signature comparison. |
| Vanish architecture edges | PARTIAL | Finish bounded sideload, pairing, update, DDI, and LocalDevVPN analysis. |
| Apple public documentation | PARTIAL | Finish current DDI/codesign/distribution claims with primary sources. |
| Open-source reference/license audit | PARTIAL | Record exact commits, licenses, adoption status, and obligations. |
| Saved Swift test failure classification | NOT STARTED | Classify all 36 failures by cause and milestone. |
| Support bundle/diagnostic redaction | NEEDS REVALIDATION | Audit current exporter and define V2 allowlist schema. |
| Installation V2 documents 00–40 | NOT STARTED | Author after evidence closure, reread 01–33, then write Phase 9. |
| Clean-machine, iPhone, Apple service, VPN, and release qualification | PHYSICAL_VALIDATION_REQUIRED | Specification only in this session; no lab execution authorized. |

## Remaining research before final docs

Read all named reports/modified diffs, NativeSigningIdentityResolver, support exporter, runtime controllers, reconcile/install/signing details, remaining release scripts/artifact manifests; inspect Vanish ASAR edges with bounded snippets, Mach-O/IPA entitlements and static signature status. Verify current DMG mounted contents. Audit upstream DDI sources, usb pairing implementation and licenses, Apple codesign/no-Xcode system availability, GitHub releases read-only. Then author meaningful 00–40 docs with state contracts, file matrix and deterministic milestones; reread 00–33 before phase 9. Do not mark full architecture READY if approved fresh-DDI supply or required security/product decision remains unresolved.

## Completion status — 2026-09-15

The queue above is retained as the continuation checkpoint. The continuation completed it as follows:

| Major research area | Final status | Result |
|---|---|---|
| Worktree/source baseline and history | COMPLETE | Original 412 paths unchanged at pre-document comparison; final comparison is part of handoff audit. |
| Reports, modified source, packaged call graph | COMPLETE | Current code supersedes the stale backend/packaging/readiness claims recorded in documents 02–07. |
| Native device/AppService path | COMPLETE / PHYSICAL_VALIDATION_REQUIRED | Implemented through RSD/AppService; saved physical record exists, final clean-build proof remains. |
| Initial USB Lockdown pairing | COMPLETE / PHYSICAL_VALIDATION_REQUIRED | Pinned idevice `pair_once` plus usbmux save/session validation define the required ABI; clean Trust flow remains a lab gate. |
| Fresh developer support acquisition | PRODUCT_DECISION_REQUIRED | Cache/mount/TSS mechanics understood; no approved Apple-origin acquisition/distribution source was established. |
| RemotePairing security | COMPLETE design / PHYSICAL_VALIDATION_REQUIRED | Staged candidate, request binding, possession proof, operational proof, and two-sided promotion are specified. |
| LocalDevVPN | COMPLETE design / PHYSICAL_VALIDATION_REQUIRED | External App Store ownership, scene activation, version contract, approval states, and endpoint proof are specified. |
| State/concurrency/recovery | COMPLETE design | Keyed schema, OS lease, journal, CAS, migration, recovery, and invalidation model frozen. |
| Apple Personal Team and signing | COMPLETE static audit / PHYSICAL_VALIDATION_REQUIRED | Versioned private adapter and Keychain/renewal lifecycle specified without real Keychain mutation. |
| Build/release/provenance | COMPLETE | Direct script hardcodes schema 3; retest output is arm64 despite universal sidecar. One mounted-output-derived pipeline specified. |
| Assembled app vs mounted DMG | COMPLETE | Identical tree hash `42fe6b9a861c88ff902b8926ab2972aa8dfb885c87b2202400315391479862c2`; `diff -qr` empty; component hashes equal. |
| Vanish/open-source/Apple research | COMPLETE within static scope | Findings and limitations recorded in 09–17; no proprietary code adopted. |
| Swift failure classification | COMPLETE | 36 assertions classified into stale expectation, broken fixture/mock, and test-isolation groups; harness isolation is a real defect. |
| Support diagnostics | COMPLETE design | Current broad schema reviewed; allowlist schema 8 and negative scanner specified. |
| Documentation 00–40 and README | COMPLETE | 01–33 were reread before 34–40; indexed set verified present and non-placeholder. |
| Physical qualification | PHYSICAL_VALIDATION_REQUIRED | No lab work was executed; complete future matrix is document 33. |

Read-only GitHub query returned no releases. The selected future authority is GitHub Releases plus a Veya-signed artifact-derived manifest. The architecture verdict is `ARCHITECTURE_NOT_READY`, specifically because developer-support asset acquisition and distribution remain unresolved.

## Vanish-reference continuation — 2026-09-15

- Revalidated branch/HEAD and all 412 production/source baseline hashes before writing the follow-on documents; no production path changed.
- Remounted the official Vanish DMG read-only on `/dev/disk44s1` for bounded static inspection; no vendor code was executed and no credentials/user state were accessed.
- Confirmed Vanish calls bundled Python with `-m pymobiledevice3 mounter auto-mount` before its RSD tunnel. Bundled PMD 9.12.0 selects personalized images for iOS 17+, caches at `~/Xcode_iOS_DDI_Personalized`, and delegates missing assets to bundled `developer_disk_image` 0.2.0.
- Confirmed that downloader addresses `api.github.com/repos/doronz88/DeveloperDiskImage` and raw `PersonalizedImages/Xcode_iOS_DDI_Personalized/{Image.dmg,BuildManifest.plist,Image.dmg.trustcache}`. No equivalent DDI assets were present in the Vanish app inventory. PMD then queries device personalization data, uses Apple TSS when needed, and mounts `Personalized`.
- Confirmed Vanish DDI failure is setup-blocking and separately maps locked, Trust, personalization/developer setup, and generic preparation errors. DDI success precedes `lockdown start-tunnel`/remote fallback and `auto-connect-ready`.
- Confirmed the exact Veya dependency boundary: native install does not itself require DDI; `NativeDeveloperServicesCoordinator.prepare` first requires it when `iossim_bridge_developer_services_status` attempts `CoreDeviceProxy::connect`. DDI gates software tunnel, RSD, RemoteXPC, AppService launch, and downstream retained-RSD TestManager/XCTest/XCUILocation.
- Exact conclusion: `VEYA_REQUIRES_DDI_AND_VANISH_SOLVES_IT_WITH_BUNDLED_PYMOBILEDEVICE3_AUTO_MOUNT_DOWNLOADING_APPLE_DDI_ASSETS_FROM_THE_DORONZ88_GITHUB_MIRROR_THEN_PERSONALIZING_VIA_APPLE_TSS`.
- The mechanism is technically demonstrated but does not resolve Veya's source authority, Apple asset rights, integrity/update policy, availability, or GPL packaging decision. Architecture remains `ARCHITECTURE_NOT_READY`.
- Added the complete `docs/installation-v2/vanish-reference/` behavioral map and implementation plan. No production implementation was modified.
- Re-ran the safe no-Xcode consumer composition/routing checks and synthetic discovery tests: all passed (5 discovery tests). `git diff --check` passed. Final baseline comparison again reported 412 baseline files, no changed/missing production/source paths, same branch, and same HEAD.
- A read-only `gh release list --repo Reshwant-Borra/IOSSim` query again returned no releases.
- Detached only the research-created Vanish image `/dev/disk44`; unrelated user/system/local-build mounts were left untouched.
