# Physical Installation Validation and Checkpoint — 2026-09-24

Verdict: **checkpoint `8155901` is frozen and physically validated end-to-end to READY on one iPhone.**
The READY that proves `8155901` is the run completing at **13:45:48 EDT**. The **13:43:00** READY
(the "1:43 PM" run) was produced by the earlier build `1f2a398`. Evidence for both is below.

Architecture references: [`docs/architecture/`](../../architecture/INSTALLATION_ARCHITECTURE.md).

## 1. Source state (frozen)

| Item | Value |
|---|---|
| Branch | `work/final-no-xcode-setup-v1` (upstream `origin/work/final-no-xcode-setup-v1`) |
| HEAD | `8155901446d573e26e1601f6c05344ad4487bc15` "Resolve per-operation device by UDID and mux id, not first UDID match" (2026-09-24 13:15:27 −0400) |
| Tree | clean: no staged, unstaged or untracked-relevant changes (`git status --porcelain` empty) |
| Commits ahead of upstream (unpushed at audit time) | `94ed677`, `838caca`, `f8d9b5a`, `1f2a398`, `8155901` |
| Relation to `origin/main` | HEAD is 20 commits ahead of `origin/main` (not merged) |

Dependency chain of the validated architecture (oldest → newest; all on this branch):

| Commit | Time | Content |
|---|---|---|
| `073d4a9` | 09-22 23:20 | VPN continuation UX; **source of the bundled iPhone payload** |
| `6a0c7e8` | 09-23 00:04 | Continuation UX polish |
| `5f167f8` | 09-23 10:31 | Target-A private test DMG path (`create_release_dmg` volume/app naming) |
| `94ed677` | 09-23 23:31 | Developer Mode pre-install gate, ABI 2→3 (`reveal_developer_mode`), typed Developer Mode/trust plumbing, LocalDevVPN actionable failures |
| `838caca` | 09-23 23:34 | Gate record (docs) |
| `f8d9b5a` | 09-24 09:49 | Structured launch-rejection chain + conditional Developer Trust classification |
| `1f2a398` | 09-24 12:46 | Developer Mode from lockdown (unknown ≠ disabled), DDI `UniqueChipID` in session, launch probe after every install (`developerSupport` depends on `application`), `VEYA-DDI-032` |
| `8155901` | 09-24 13:15 | Per-operation device selection by UDID + mux id (Rust only, `lib.rs`) |

`git diff 1f2a398 8155901` touches only `native/iossim-device-bridge/src/lib.rs`
(`find_selected_device` / `selected_device` and one test). All Swift, including Developer Mode,
Developer Trust, presentation and domains, is identical between the two builds.

## 2. Artifact provenance

`.build/iossim/development-session/Veya Development.app`, built 2026-09-24 13:16:17 (build logs
`.build/iossim/logs/20260924T1715*Z`/`T1716*Z`):

| Field | Value |
|---|---|
| `guiSourceCommit` / `helperSourceCommit` | `8155901446d573e26e1601f6c05344ad4487bc15` |
| `guiSourceDirty` / `helperSourceDirty` / `sourceDirty` | `false` / `false` / `false` |
| Build variant | `VEYA_DEVELOPMENT_SESSION` (SwiftPM debug; `VEYA_QUALIFICATION`) |
| `Contents/MacOS/Veya Development` | `f5c210ac46f3f7f06de4d2301657fd1f1648a481d83b2f09cb89cea16d041f68`, arm64 + x86_64 |
| `Contents/MacOS/IOSSimProvisioner` | `256ac023c7dc293fee754d10c1343dc4db536f4925b05c0bb77811df62ffa5c4`, arm64 + x86_64 |
| Native bridge | `e66dce4eb37bc1e415219ae9097e9228a4d04455bb36f35db4f3937419459a4f`, arm64 + x86_64, ABI 3, `iossim-device-bridge/0.1.0+idevice-1838db1` |
| Payload manifest | `56ef35c080458b2745e9cd9cbafea2afd714ec1f314a9f2764e66c8f52aeee0a` (source `073d4a9`, clean) |
| Signing | ad-hoc, no Team ID; `codesign --verify --deep --strict` PASS |
| `EngineIntegrity.plist` | helper, bridge and payload-manifest hashes above; ABI 3; setup-state schema 5 |

On-disk hashes were re-computed during this audit and match `artifact-identity.json`.
Bridge-to-source link: the packaged bridge's arm64/x86_64 slices, with signatures removed, match
`native/target/{aarch64,x86_64}-apple-darwin/release/libiossim_device_bridge.dylib` in size and
differ only in 1 byte (arm64) and 2 bytes (x86_64) inside the Mach-O load-command header
(offsets 1642–1651), which is consistent with the sign/unsign round trip. During this audit,
`cargo build --release --locked` at HEAD treated those artifacts as up to date.

## 3. Which process produced which READY (discrepancy with the task statement)

From the macOS unified log (`launchd` spawns, `loginwindow` appDeath) and the build logs:

| Process | Spawned | Exited | Binary | Evidence |
|---|---|---|---|---|
| PID 9569 | **13:04:57** | 13:43:45 | Build of 12:47:20 = **`1f2a398`** (clean; the same bundle `Veya-Test-1f2a398.dmg` was packaged from at 12:49; bridge `83ec7c1b…`, i.e. **before the selector fix**) | Launch-job identity identical to the 12:54 launch; the only dev-app builds today are 12:47 and 13:16 |
| PID 17951 | **13:43:56** | 13:46:25 | Build of 13:16:17 = **`8155901`** | New launch-job identity; bundle bytes unchanged since 13:16:18 and hash-identified above |

The journal (`~/Library/Application Support/Veya/development-session/installation/journal-v1.json`,
revision 1895) records two full chains:

**Run A — PID 9569 (`1f2a398`)**

| Time | Generation | Evidence |
|---|---|---|
| 13:41:57–13:42:02 | — | Apple sign-in, team, device already registered, App IDs ready (reused signing key gen 133 and its certificate; wrapping key still in memory) |
| 13:42:03 | 140 / 141 | `profileCMSBindingValidation`, `payloadIndependentVerification` |
| 13:42:06 | 142 | `deviceInventoryAfterInstall` |
| 13:42:36 | 143 | `developerSupportFreshObservation` (launch probe succeeded) |
| 13:42:41 | 144 | `vpnFreshObservation` |
| 13:42:54 | 145 | `pairingFreshObservation` |
| **13:43:00** | 146 | `runtimeFullChainProof` → READY |

**Run B — PID 17951 (`8155901`), the checkpoint's physical proof**

| Time | Generation | Evidence |
|---|---|---|
| 13:44:28–13:44:30 | — | Apple SRP sign-in, `APPLE_SESSION_READY` (new process, so a new session) |
| 13:44:34 | 147 | `signingKeySignVerifyProbe`: **new key**, because the relaunch lost the in-memory wrapping secret, as designed |
| 13:44:35–36 | 148 | `submitDevelopmentCSR` → `CERTIFICATE_LIMIT_REACHED`, reconciled; `appleInventorySPKIMatch` |
| 13:44:37–38 | 149 / 150 | Device already registered, App IDs ready, profiles validated; payload re-signed and verified |
| 13:44:41 | 151 | `deviceInventoryAfterInstall` (reinstalled with the new signature) |
| 13:45:01 | 152 | `developerSupportFreshObservation`: AppService launch of the reinstalled app succeeded |
| 13:45:28–29 | 153 | `vpnFreshObservation` (LocalDevVPN receipt `satisfied`) |
| 13:45:42 | 154 | `pairingFreshObservation`: new RPPairing (the in-memory pairing store was empty after the relaunch) |
| **13:45:48** | 155 | `runtimeFullChainProof` → **READY** |

All 13 domains satisfied: `application, artifact, authorization, certificate, developerSupport,
migration, pairing, payload, profile, runtime, signingKey, team, vpn`. `artifact`, `authorization` and
`team` are observation-only and have no journal records. The UI's final text ("READY" / "Setup is
complete and the iPhone is ready.") is from the user's report and was not captured by this audit.

Target device: an iPhone with UDID prefix `00008150-0002…` (its `sha256("device|udid")` equals the
profile record's `device` metadata `62770554…`). Team `T8SL4SG87F`.

## 4. What is proven, and how

| Claim | Status | Basis |
|---|---|---|
| 8155901 build reaches READY from a fresh process (sign-in, key, certificate with capacity reclaim, profile, re-sign, reinstall, launch probe, VPN, new pairing, Run Setup, runtime) | **Physically proven** | Run B journal evidence + process provenance |
| Developer Mode gate (reveal → user enables → Continue verifies from device) | **Physically proven on `1f2a398`/earlier** (user report; gate code identical in `8155901`) | Not re-exercised in Run B (Developer Mode was already on) |
| Developer Trust stage → Settings trust → Continue → launch succeeds | **Physically proven on `1f2a398`/earlier** (user report; journal: app installed 13:05:16, developer support first satisfied 13:42:36 after the user's trust). Trust code is identical in `8155901`. | Not re-exercised in Run B (the developer was already trusted) |
| USB/Wi-Fi duplicate-entry fix | **Unit-tested** (`per_operation_selector_uses_udid_and_mux_not_input_order`); **statically proven** (diff); physically, Run B succeeded while the target's network entry churned (detached 13:43:59). The Wi-Fi-first ordering was **not** deliberately reproduced during a Run B operation. | Unified log `usbmuxd` |
| Structured trust chain matches real iOS output | **Not proven from captured output**: Rust fixtures are reconstructed from documented shape (commit `f8d9b5a` says so). A trust-blocked launch was physically routed to the Trust Developer stage per the user report, but the payload bytes were not captured. | — |
| LocalDevVPN, Run Setup, runtime proof | **Physically proven** (Runs A and B) | Journal + VPN trace (`receiptValidation satisfied` at 13:45:52/58) |
| Friend DMG on another Mac/iPhone/Apple Account | **Not proven** | Not yet run |
| Multi-account signing (`VEYA-TEAM-032`) | **Known failing, not fixed** | See §8 |

## 5. Tests (run on the clean checkpoint during this audit)

| Suite | Command | Result |
|---|---|---|
| Rust bridge unit tests | `cargo test --workspace --locked` (in baseline) | **35 passed**, 0 failed |
| Rust `veya-signing-core` | same | **12 passed**, 1 ignored, 0 failed; doc-tests 0 |
| macOS Swift (`IOSSimMacCoreTests`, 49 test classes) | `swift test` with `--skip SigningKeyStoreTests.testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction` (baseline `--defer-m4`) | **588 executed, 15 skipped, 0 failures** |
| M4 packaged-helper test (the deferred one) | `swift test --filter SigningKeyStoreTests` | 11 executed, **4 assertion failures, all in `testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction`**: `VEYA-KEY-001` "The Keychain wrapping store is unavailable to this build." Reproduced on this checkpoint. Cause is structural: `WrappingSecretBackendKind.select` requires a Team ID + access group, and ad-hoc test builds have neither. This is the documented M4 pre-release blocker, not a regression. |
| iOS shared unit checks | `swift run --package-path ios POCUnitChecks` | PASS |
| Artifact identity | `scripts/checks/test_artifact_identity.py` | **6/6** OK |
| Release DMG | `scripts/checks/test_release_dmg.py` | **3/3** OK |
| Device discovery CLI | `scripts/checks/test_device_discovery_cli.py` | **5/5** OK |

The 15 Swift skips are opt-in physical, Keychain or network tests (`IOSSIM_RUN_KEYCHAIN_INTEGRATION`,
opt-in physical device boundaries, real-network DDI provider, packaged-app integrity when not provided).

Relevant categories: Developer Mode `DeveloperModeGateTests` (23); Developer Trust
`DeveloperTrustClassificationTests` (10), `TrustDeveloperFlowTests` (7); presentation
`DevelopmentInstallationPresentationTests` (11); planner `ReconciliationPlannerTests` (19);
domains `DeviceDomainsTests` (13), `AppleDomainsTests` (11); journal
`InstallationJournalRepositoryTests` (17); signing/profile `PayloadTransactionTests` (13),
`CertificateReconciliationTests` (11), `CertificateCapacityRecoveryTests` (18), `InProcessSignerTests`
(3), Rust `qualification_tests` (9); LocalDevVPN `LocalDevVPNSetupCoordinatorTests` (9); runtime
`RuntimeReadinessTests` (8), `RunSetupReadinessTests` (6); bridge `NativeDeviceBridgeTests` (25),
Rust selector tests (3); wiring `ProductionWiringTests` (17); packaging/identity Python checks above.
Counts are `func test…` declarations per file.

## 6. Baseline

`./iossim installation-baseline --defer-m4` → **Overall: PASS** (exit 0). Steps: bundle identifier
inventory, no-Xcode consumer runtime policy, no-Xcode install routing, artifact identity checks,
device discovery CLI checks, Installation V2 secret scan, legacy-signing guard, `cargo fmt --check`,
`cargo check`, `cargo clippy -D warnings`, `cargo test`, debug bridge, macOS Swift tests, iOS unit
checks, and Rust release builds for `aarch64-apple-darwin` and `x86_64-apple-darwin`. M4 was reported
as `DEFERRED` ("DEVELOPMENT ONLY; secure persistence remains a pre-release blocker").

`./iossim audit-app ".build/iossim/development-session/Veya Development.app"` → **FAIL on 5
production-consumer checks** that this development artifact class knowingly does not meet: executable
name `IOSSim`, production Info.plist/identity, production icon, absolute build-machine paths in debug
binaries, and production artifact-derived identity. These are the same "expected Development-only
findings" accepted for Target-A. Every security check passed: no private keys, pairing or auth
material, no provisioning profiles, no forbidden development material, no source-like or
world-writable files, and payload hashes and bundle IDs match. `release-local` / `release-local-audit`
target the production identity and were not used for this artifact class.

## 7. Private friend-test DMG

Built from the **exact physically validated app bytes** (no rebuild or re-sign) via the official
`create_release_dmg(runner, app, out, volume_name="Veya Test", app_bundle_name="Veya Development.app")`.

| Field | Value |
|---|---|
| Path | `/Users/rishiborra/Desktop/IOSSim/.build/iossim/release/Veya-Test-8155901.dmg` |
| SHA-256 | `9dde51d5dbc806a079875e9a54edcaede0c18a0c53bcaa2a177aa4b5728bc54f` (sidecar `Veya-Test-8155901.dmg.sha256`) |
| Size | 33,645,575 bytes, UDZO |
| Volume / contents | `Veya Test`: exactly `Veya Development.app` + `Applications -> /Applications` |
| `hdiutil verify` | VALID |
| Mounted app vs. validated app | every file byte-identical (per-file SHA-256 manifest) |
| Copied-back app vs. validated app | byte-identical |
| `codesign --verify --deep --strict` | PASS (mounted and copied back); ad-hoc, `TeamIdentifier=not set` |
| Architectures | GUI, helper, bridge: `x86_64 arm64` |
| Bridge ABI (runtime `dlopen`) | 3, `iossim-device-bridge/0.1.0+idevice-1838db1`; 21 `iossim_bridge_*` + 8 `veya_signing_*` exports incl. `iossim_bridge_reveal_developer_mode` |
| Source app unchanged by packaging | yes (per-file manifest before and after identical; `git status` clean before and after) |
| Quarantine attribute | none locally (a real download may add one → **Open Anyway**) |

This is a private qualification artifact: ad-hoc signed, not notarized, M4 deferred. It is **not**
production-ready.

## 8. Known issue — `VEYA-TEAM-032` (intentionally unresolved)

Observed: after using one Apple Account and team, the tester intentionally signed in with another Apple
Account on another device. Veya reported `VEYA-TEAM-032`: "The signed-in Apple Account is not the one
Veya's certificate belongs to."

Status: **unresolved, not worked around.** The next task is to determine the intended multi-account
signing lifecycle: which persisted state is scoped by Apple Account, Team ID, certificate identity or
device, and which is rotated, invalidated or safely reused on an intentional account switch.
Certificate matching, profile matching, Team ID validation and entitlement validation must not be
weakened. Starting points (facts, not a diagnosis):
[`docs/architecture/PERSISTENCE_AND_EVIDENCE.md` §Relevant to VEYA-TEAM-032](../../architecture/PERSISTENCE_AND_EVIDENCE.md#relevant-to-veya-team-032-flagged-not-investigated).

## 9. Remaining uncertainties

- Developer Mode and Developer Trust were physically exercised on `1f2a398`/earlier, not re-exercised
  by the `8155901` process. The Swift code is identical. The native change only affects device
  resolution.
- The exact Wi-Fi-listed-first ordering was not captured during a Run B operation.
- The structured launch-rejection payload has not been captured byte-for-byte from a real device.
- Development-session integrity: the dev UI loads the bridge without checking `EngineIntegrity.plist`'s
  SHA-256 (code signature and ABI/symbol checks still apply).
- The bundled iPhone payload (`073d4a9`) predates the iPhone-side Run Setup gating changes in `94ed677`.
- Debug binaries contain the build machine's absolute home path, so the build user's short name
  appears in the DMG.
- Clean-Mac behavior (Gatekeeper approval, no prior state, Intel) is unverified for this DMG.
