# Veya Installation Architecture (checkpoint `8155901`)

Status: frozen engineering reference for the installation system at commit
`8155901446d573e26e1601f6c05344ad4487bc15` (branch `work/final-no-xcode-setup-v1`). Every statement
below was traced from source at that commit. Physical evidence and its limits are in
[`../installation-v2/implementation-v2/PHYSICAL_INSTALLATION_VALIDATION_2026-09-24.md`](../installation-v2/implementation-v2/PHYSICAL_INSTALLATION_VALIDATION_2026-09-24.md).

Companion documents:

- [NATIVE_DEVICE_BRIDGE.md](NATIVE_DEVICE_BRIDGE.md): Rust bridge, C ABI, device selection, the USB/Wi-Fi fix.
- [SIGNING_AND_IDENTITY.md](SIGNING_AND_IDENTITY.md): Apple account, key, certificate, profile, signing, and the guarantees behind Developer Trust classification.
- [INSTALLATION_FAILURE_MODEL.md](INSTALLATION_FAILURE_MODEL.md): failure taxonomy and flattening points.
- [PERSISTENCE_AND_EVIDENCE.md](PERSISTENCE_AND_EVIDENCE.md): every persisted record, its scope, and what matters for `VEYA-TEAM-032`.

---

## A. macOS application architecture

### What actually runs in the physically validated artifact

The validated artifact is the **development session** build, `Veya Development.app`
(`com.veya.development-session`), produced by `tools/qualification/package_development.py`. It is a
SwiftPM **debug** build (`IOSSIM_MAC_CONFIGURATION=debug`), which defines `VEYA_QUALIFICATION`
(`macos/Package.swift:6`) and, through `macos/scripts/build_app.sh:74`, `IOSSIM_BUNDLED_ENGINE`.

| Layer | Type / file | Role |
|---|---|---|
| Entry point | `IOSSimMacApp` — `macos/Sources/IOSSimMac/IOSSimMacApp.swift:5` | Builds the legacy `SetupStore` engine (`BundledProvisioningEngine.live()`), then chooses the scene. With `VEYA_QUALIFICATION` and Info.plist `VeyaDevelopmentSession = true` (or env `VEYA_DEVELOPMENT_SESSION=1`) it shows `DevelopmentInstallationView`. Otherwise it shows the legacy `RootView`/`SetupStore` flow. |
| UI | `DevelopmentInstallationView` — `macos/Sources/IOSSimMac/Views/DevelopmentInstallationView.swift` (whole file is `#if VEYA_QUALIFICATION`) | Device picker, **Trust / Pair**, Apple **Sign In** / **Verify**, **Inspect**, and one primary button. The button belongs to the Developer Mode gate until it is `.verified`, and after that to the engine. |
| View model | `DevelopmentInstallationModel` (same file, line 6) | `refresh()`, `authorize(...)`, `pair()`, `revealDeveloperMode()`, `continueDeveloperModeGate()`, `run(_ command:)` (line 134). Holds `DeveloperModeGateProgress gate`. |
| Session | `DevelopmentInstallationSession` — `macos/Sources/IOSSimMacCore/Installation/DevelopmentInstallationSession.swift:33` | Owns one `LiveApplePersonalTeamBackend` (Apple session, in-process), a `DevelopmentMemoryWrappingStore` (line 7; signing-key wrapping secret held **only in memory**), and an `InMemoryRemotePairingStore`. It composes the engine with `ThirdPartyMirrorDevelopmentProvider` (`.localTest`) for developer disk images. |
| Composition | `ProductionComposition.compose(...)` — `macos/Sources/IOSSimMacCore/Installation/ProductionComposition.swift:29` | The single composition of all 13 domains (list in §B). The development session passes overrides for wrapping, pairing store and DDI provider. The domain set does not change. |
| Engine host | `EngineHost.handle(_:composition:)` — `macos/Sources/IOSSimMacCore/Installation/ProvisionerProtocol.swift:330` | Maps an `EngineRequest` (`inspect`/`plan`/`verify`/`reconcile`/`resume`) to the engine and returns a `QualificationResult`. **In the development session this runs in-process in the GUI**; the packaged `IOSSimProvisioner` binary is present but the dev UI does not spawn it. |
| Engine | `VeyaReconciliationEngine` (actor) — `macos/Sources/IOSSimMacCore/Installation/VeyaReconciliationEngine.swift` | observe → plan → execute one transition → prove → promote, under a journal lease. |
| Planner | `ReconciliationPlanner.plan(...)` — `ReconciliationPlanner.swift:6` | Pure function. Walks desired requirements in order and stops at the first unsatisfied domain. |
| Observation / transition protocols | `InstallationObserver`, `InstallationTransition` — `ReconciliationProtocols.swift` | Each domain implements `observe(scope:journal:)`, `execute(_:)`, `prove(_:in:)`. |
| Journal | `InstallationJournalRepository` (actor) — `InstallationJournalRepository.swift`; model `InstallationJournal` — `InstallationJournal.swift` | Flock-protected, digest-enveloped, atomically written JSON with a `.previous` copy. |
| Presentation | `DevelopmentInstallationStage.resolve(...)` / `DevelopmentInstallationPrimaryAction.resolve(...)` — `DevelopmentInstallationPresentation.swift:13,32` | Maps engine result (first failure code, failure domain, user action, status, "Run Setup request issued") to a UI stage. Presentation only: **every primary action is `.reconcile`**. |
| Error presentation | `DevelopmentInstallationFailureContext` (same file) and the "Last action failed" `GroupBox` | Shows domain, `VEYA-*` code, safe message, and user action. |

The legacy `SetupStore`/`RootView` path (consumer onboarding wizard) is still compiled. It is **not**
what was physically validated in this checkpoint.

### Request lifecycle for one button press

`DevelopmentInstallationModel.run(.reconcile)` (`DevelopmentInstallationView.swift:134`):

1. Refuses to run unless `gate.allowsEnginePipeline` is true (Developer Mode verified). If not, it calls `continueDeveloperModeGate()` instead.
2. Builds `EngineDeviceSelection(udid:name:transportIdentity:)` from the selected `NativeDeviceInspection`. The transport identity carries the exact `usbmuxIdentifier`, `connection` and `connectionGeneration`.
3. `session.composition(...)`, then `EngineRequest(command: .reconcile, capabilities: CapabilityManifest(allowedDomains: reconciliationOrder, maximumPermission: .destructiveOwned, maximumTransitions: 64), connectionGeneration:, device:)`.
4. `EngineHost.handle` → `DesiredStateDeriver.ready()` (all 13 domains required) → `VeyaReconciliationEngine.reconcile`.
5. If the response has no observations (a transition threw), it re-runs `.inspect` so the list is current.
6. `DevelopmentInstallationStage.resolve(...)` picks the stage. If the engine's user action is the Developer Mode action, the gate is **invalidated** (`developerModeGate.invalidate`) and the prerequisite is re-entered.

---

## B. Installation domains

`InstallationDomain` (`InstallationDomainModels.swift`): `artifact, authorization, team, signingKey,
certificate, profile, payload, application, developerSupport, pairing, vpn, runtime, migration`.

Reconciliation order (`ProvisionerProtocol.swift:21`):
`artifact → migration → authorization → team → signingKey → certificate → profile → payload →
application → developerSupport → vpn → pairing → runtime`.
VPN is placed before pairing on purpose. Pairing-first hid the LocalDevVPN prompt behind pairing.

Direct prerequisites (`ProvisionerProtocol.swift:29`): `signingKey←migration`, `authorization←artifact`,
`team←authorization`, `certificate←team,signingKey`, `profile←certificate`,
`payload←artifact,profile`, `application←payload`, `developerSupport←artifact`,
`pairing←application`, `vpn←application`, `runtime←application,developerSupport,pairing,vpn`.

### Observation states (`DomainObservationState`, `ReconciliationModels.swift`)

`satisfied, missing, stale, invalid, candidateUnproved, candidateProved, waitingForUser,
retryableFailure, terminalFailure`. Construction enforces two rules: `waitingForUser` requires a
`userAction`, and `retryable/terminalFailure` require a `VeyaFailure`.

### Journal-backed vs. live-only domains

`artifact`, `authorization` and `team` are **observation-only**: `execute`/`prove` throw
`transitionUnavailable`, and they never write journal records. The final journal
(`~/Library/Application Support/Veya/development-session/installation/journal-v1.json`, revision 1895)
has active records for the other 10 domains only.

### Per-domain reference

| Domain | Implementation | Observed by | `satisfied` means | `missing` | `stale` | `invalid` | Transition (create/replace) | Proof evidence (kind / provenance) | Identity binding | Failure codes / user action |
|---|---|---|---|---|---|---|---|---|---|---|
| **artifact** | `ArtifactDomain` `ShippedPayload.swift:70` | Loads `Resources/DeviceArtifacts/manifest.json`, verifies every component hash (`ArtifactManifestLoader.assertArtifactsVerified`). Cached once per process. | Shipped payload matches its manifest; resource `shipped-payload@sha256(role=sha…)`. | — | — | — | None (cannot repair in place). | None | Payload digest | `VEYA-ART-030` damaged, `031` unexpected shape (terminal); action "Reinstall Veya from its original download…" |
| **migration** | `MigrationDomain` `LegacyMigration.swift:92` | Journal only | `migration.phase != notStarted` and an active record exists | No record | — | — | Read-only inventory of legacy files → migration ledger `inventoried`, candidate `legacy-snapshot` | `legacyInventorySnapshot` / `veya-migration-reader` | Digest of the ledger items | — |
| **authorization** | `AppleAccountDomain(.authorization)` `AppleDomains.swift:100` | `AppleAccountContext.team()` → `currentPersonalTeam()` (resumes the stored session). Cached per composition, i.e. per button press. | Session usable; resource `apple-session` | — | — | — | None. **Veya never signs in on the user's behalf.** | None | — | `waitingForUser` "Sign in to your Apple Account in Veya…" for sessionExpired/badPassword/authenticationRejected/verificationExpired/srpAuthFailed/verificationRejected/xcodeScopedTokenFailed. `VEYA-AUTH-031` unreachable (retryable), `032` protocol changed, `033` rate limited (retryable). |
| **team** | `AppleAccountDomain(.team)` | Same call | Exactly one Personal Team; resource = team ID | — | — | — | None | None | Team ID (not persisted) | `VEYA-TEAM-030` no Personal Team, `031` ambiguous, `032` "The signed-in Apple Account is not the one Veya's certificate belongs to." (from backend `.invalidTeam`) |
| **signingKey** | `SigningKeyDomain` `SigningKeyDomain.swift:5` + `VeyaSigningKeyStore` | Decrypt envelope, compare public-key SHA-256, sign/verify probe | Key usable | No active record | — | Wrapper/ciphertext missing, GCM failure, corrupt, unsafe file, mismatch → replaced | `store.createCandidate(installationID:)`: RSA-2048, AES-256-GCM PKCS#8 at `secrets/signing-keys/<keyID>.vkey` (0600) | `signingKeySignVerifyProbe` / `veya-signing-key-store` | `resourceID = keyID`, `digest = SPKI SHA-256` | `VEYA-KEY-001` wrapping store unavailable, `002` interaction required (**terminal**), `010` Keychain error (retryable), `003…012` (invalid → replace) |
| **certificate** | `CertificateDomain` `AppleDomains.swift:233` | Reads `certificates/<derSHA>.cer` (digest-checked) and parses RSA-2048 | SPKI == current signing key SPKI **and** ≥ 72 h validity left (`CertificatePlanner.minimumRemainingValidity`). Also fresh: `validUntil` = proof `validUntil`. | No active record | New key, or inside the 72 h window | Unreadable / unparsable DER | `CertificateReconciler.reconcile`: reuse by SPKI → issue CSR (≤ 2) → on capacity, revoke an **owned retired-key** certificate (≤ 1, needs `destructiveOwned`) → issue | `appleInventorySPKIMatch` / `apple-developer-services`, `validUntil = min(now+24h, expiry−72h)` | `resourceID = serial`, `digest = DER SHA-256`, metadata `teamIdentifier`, `spkiSHA256` | `VEYA-CERT-040…047`; `046` capacity needs the user (message tells them to revoke an unused certificate) |
| **profile** | `ProfileDomain` `AppleDomains.swift:384` | Offline validation of both stored profiles (main, runner) against the active certificate DER, team, selected device, and derived bundle IDs | Both valid and ≥ 48 h left | No active record | Different certificate or device, or inside the 48 h window | Candidate fails validation | Requires `account.team() == certificate.team` (else **`VEYA-TEAM-032`**, `AppleDomains.swift:505`), ensure device registered, ensure App IDs, download + validate + store `profiles/<gen>/{main,runner}.mobileprovision` | `profileCMSBindingValidation` / `cms-offline-validation`, `validUntil = expiry−48h` | Digest of `bundle=sha` parts. Metadata: `teamIdentifier`, `certificate` (DER digest), `device` (`sha256("device|<udid>")`), per-role bundle and sha | `VEYA-PROFILE-030…036`; no certificate/device → `waitingForUser` "Connect your iPhone, unlock it, and select it…" |
| **payload** | `PayloadDomain` `PayloadTransaction.swift:123` | Re-derives the signing plan (`ShippedPayloadPlanProvider`) and re-verifies staged bundles with the in-process verifier | Staged signature verifies **and** `metadata.binding == plan.binding` | No active record | Binding changed (key/cert/profile/source/IDs/entitlements) | Verification fails | Copy to `staging/<gen>/source`, apply planned Info.plist rewrites, require identical signable-graph shape, sign in process with `veya-signing-core`, write `staging/<gen>/<App>.app` | `payloadIndependentVerification` / `veya-signing-core` (`machOCount`) | `resourceID = main bundle id`, `digest = sha(role=inventorySha)` | `VEYA-SIGN-020…026` (`021` carries `veya-signing-core/<VEYA-SIGN-category>`) |
| **application** | `ApplicationDomain` `PayloadTransaction.swift:353` | installation_proxy inventory on the selected device | Every role's bundle/version/team installed and active identity == active payload identity | No active record | Payload re-signed (new digest) | Device lost or changed an app (`VEYA-INSTALL-025`) | `NativeApplicationManager.installOrUpgradeReceipt` per role (install, then inventory verification) | `deviceInventoryAfterInstall` / `installation-proxy-inventory`, **connection-bound** | Same identity as payload | Inventory unreadable → `retryableFailure` **`VEYA-INSTALL-024`** (the USB/Wi-Fi defect surfaced here) |
| **developerSupport** | `ProductionDeviceDomains.developerSupport` `DeviceProductionAdapters.swift:313` over `CoordinatedDeviceDomain` `DeviceDomains.swift:124` | `DynamicNativeDeviceTransport.readiness`: inspect + CoreDevice/RSD/RemoteXPC/AppService probe. Read-only, never mounts, never launches. | Transport ready **and** active record identity == current identity | No active record | Connection generation, device, or installed application changed | Not ready (incomplete) | `NativeDeveloperServicesCoordinator.prepare`: probe → on `ddiRequired` acquire + verify + personalize + mount DDI → probe → **launch installed main app** (AppService) | `developerSupportFreshObservation` / `device-coordinator`, connection-bound (proof is a fresh read-only observation) | `sha(domain|deviceHash|connGen|application=id@digest)` | `VEYA-DDI-030` incompatible, `031` unavailable, `032` launch rejected (retryable, carries Apple chain constants); user actions Developer Mode / Developer Trust / unlock / trust computer; `VEYA-DEVICE-030` generic |
| **vpn** | `ProductionDeviceDomains.vpn` `DeviceProductionAdapters.swift:400` | Reads phone receipt `Library/Application Support/IOSSim/SetupInbox/localdevvpn.receipt` from the app container (House Arrest/AFC) | Receipt bound to UDID/team/release, ≤ 60 s old, state `RUNTIME_ENDPOINT_REACHABLE` with `endpointReachable` | Receipt absent or bound to something else | Receipt older than 60 s | Incomplete state; phone-reported user action is downgraded to `invalid` so the transition re-probes | `LocalDevVPNSetupCoordinator.prepare` (§I) | `vpnFreshObservation` / `device-coordinator` | As developerSupport, depends on `application` | `VEYA-VPN-030…037` (§I) |
| **pairing** | `ProductionDeviceDomains.pairing` `DeviceProductionAdapters.swift:355` | `store.load(deviceUDID:, teamIdentifier:)` then native RemotePairing validation against the device | Stored record validates on this device | No stored record for `(team, udid)` | As above | Mid-lifecycle | `RemotePairingCoordinator.reconcileAutomatically`: create RPPairing over trusted USB lockdown, deliver to app container, receipt, possession + developer-services proof, promote | `pairingFreshObservation` / `device-coordinator` | As above | `VEYA-PAIR-030` (retryable), `031` secure storage unavailable |
| **runtime** | `RuntimeReadinessDomain` `RuntimeReadiness.swift:23` + `JournalRuntimeProver` `DeviceProductionAdapters.swift:520` | Journal binding of the four upstream records + device + connection | Active identity == current binding **and** proof not expired (TTL 600 s) | Any upstream record missing | Binding changed or proof missing | Candidate for another binding | Candidate only; the proof runs in `prove` (§J) | `runtimeFullChainProof` / `rich-runtime-inbox`, attribute `receipt` digest, connection-bound, `validUntil = completedAt+600s` | `sha(application,developerSupport,pairing,vpn identities, device, connection)` | `VEYA-RUNTIME-010` runtime action, `011` Run Setup not tapped (retryable + action), `012` phone reported failure |

Retryable vs terminal: an observation's `retryableFailure`/`terminalFailure` follows
`VeyaFailure.retryable`. Transitions for `authorization, team, certificate, profile` are "remote" and
retry up to `remoteRetryLimit` (4) with 1, 2, 4, 8 s backoff. The others retry up to
`localRetryLimit` (2) immediately (`VeyaReconciliationEngine.executeWithRetry`).

Irreversible effects (`TransitionRecovery.required`, `ReconciliationModels.swift:236`): certificate
issue/revoke, profile issue, application replace, DDI mount, pairing delivery, VPN configuration.
These are never rolled back; after interruption they are reconciled by re-observing Apple or device
inventory. Veya-local candidates (`artifact, authorization, team, signingKey, payload, runtime,
migration`) roll back by discarding the candidate.

---

## C. Planner / state machine

```
observe(all scope domains)  →  plan (first unsatisfied)  →  execute ONE transition
      ▲                                                          │
      │                                                  putCandidate (generation+1)
      │                                                          │
      │                                             prove (independent evidence)
      │                                                          │
      │                                 evidence.generation == candidate.generation
      │                                 evidence.subject == candidate.identity
      │                                 evidence.connectionGeneration == scope's
      │                                                          │
      │                                attachEvidence → re-observe the domain:
      │                                must be candidateProved or satisfied
      │                                                          │
      └──────────────── promote (old active → retiring) ◄────────┘
```

`ReconciliationPlanner.plan` (`ReconciliationPlanner.swift:6`), per required domain in order:

| Observation | Plan |
|---|---|
| none | `blocked`, `VEYA-STATE-017` "could not be observed" |
| `satisfied`, but expired (`validUntil`) or from another connection generation | `replaceCandidate` |
| `satisfied` but not the desired target | `replaceCandidate` |
| `missing` | `createCandidate` |
| `stale` / `invalid` | `replaceCandidate` |
| `candidateUnproved` | `proveCandidate` (same generation) |
| `candidateProved` | `promoteCandidate`, or `proveCandidate` if the connection changed |
| `waitingForUser` | `userActionRequired` (stop) |
| `retryableFailure` | `retryableWait` (stop) |
| `terminalFailure` | `blocked` (stop) |
| all satisfied | `ready` |

Mutation is permitted only if `.safeRepair ≤ policy.maximumPermission` and the domain is allowed;
otherwise `VEYA-STATE-012`.

### Why a transition is never proof

`VeyaReconciliationEngine.execute` (`VeyaReconciliationEngine.swift:164`):

1. `service.execute` returns only a **candidate** record. Nothing is active yet.
2. `service.prove` must produce **separate** evidence. The engine rejects it unless
   `evidence.generation == candidate.generation`, `evidence.subject == candidate.identity`, and a
   connection-bound proof matches the scope's `connectionGeneration`.
3. The domain is then **observed again**, and promotion requires `candidateProved` or `satisfied`
   with the same resource.
4. `InstallationJournalRepository.promote` (`:164`) independently requires an evidence ID on the
   candidate at the same generation and domain.

Device domains prove with a fresh read-only observation (`CoordinatedDeviceDomain.prove`: "Proof is a
fresh read-only observation, never the prepare call's own return value"). Examples: `application`
proves with a new installation_proxy inventory, `certificate` with Apple's live inventory, `payload`
with an independent verify, `runtime` with the phone's own Run Setup receipt.

### Reconcile, Continue, Verify Setup, retry, recovery

- **reconcile**: loops `observe → plan → execute` for at most `maximumTransitions` (64 in the dev UI), holding a 30 s lease renewed every 10 s (`whileHoldingLease`). It stops at the first non-transition disposition.
- **Continue** and **Continue / Verify Setup** are presentation labels (`DevelopmentInstallationPrimaryAction`). Each sends the same `.reconcile`. Because every run re-observes from scratch, the user's action (trust, VPN connect, Run Setup tap) is picked up only through device-side observation.
- **Verify Setup** as an `EngineCommand.verify` (inspect-only plan on one stage) exists for qualification. The dev UI's "Verify Setup" label is still `.reconcile`.
- **Retry**: transient `VeyaFailure.retryable` errors inside one transition are retried by `executeWithRetry`. At the plan level, `retryableWait` ends the run and the user presses the button again.
- **Recovery**: `recoverAbandonedTransition(runID:)` at run start. `executeBlockingCandidateRecovery` (`InstallationJournalRepository.swift:130`) discards only Veya-local candidates left from an earlier generation and records the discard in `journal.recovery`. The current journal shows `blockingCandidateDiscarded:runtime`, recovered from revision 1400. Irreversible candidates are never discarded silently.
- **Stale evidence**: the planner treats expired `validUntil` or a different connection generation as `replaceCandidate`. Certificate proof expires after 24 h, profile proof 48 h before expiry, runtime proof 600 s after Run Setup completion, and the VPN receipt after 60 s.
- **Journal generation**: every candidate takes `generation + 1` (`putCandidate`). Generations are monotonic and never reused. Record IDs embed them (`certificate-148`, `profile-149`, …).
- **Device rebinding**: the device identity is `(UDID, usbmux id, connection kind, connectionGeneration)`. `IOSSimDeviceBridge.listDevices` increments `connectionGeneration` on every listing. Connection-bound observations and evidence are void on another generation, so a reconnect or reboot forces device-domain re-proof.
- **Failure propagation**: a thrown `VeyaFailure` is re-tagged `originating(in: activeDomain)`. `EngineHost.failureResult` classifies user-action failures as `userActionRequired` (not product failures) and maps the rest to `failed`.

---

## D. Developer Mode

### Components

| Piece | Location |
|---|---|
| Reveal FFI (AMFI action 0) | `iossim_bridge_reveal_developer_mode` — `native/iossim-device-bridge/src/lib.rs` (`AmfiClient::reveal_developer_mode_option_in_ui`) |
| Status in inspection | `iossim_bridge_inspect_device`: inside the paired lockdown session reads `DeveloperModeStatus` in domain `com.apple.security.mac.amfi`. Only if that yields nothing does it fall back to AMFI action 3. `resolve_developer_mode` (`lib.rs:877`): `Some(true)→enabled`, `Some(false)→disabled`, `None→unknown`. **A failed or unanswered query is `unknown`, never `disabled`.** |
| ABI | 3. The reveal symbol is in the Swift fail-closed required-symbol list (`DynamicNativeDeviceTransport.init`). A bridge without it is refused as `incompatibleABI`. |
| Swift bridge | `DynamicNativeDeviceTransport.revealDeveloperMode(on:)` |
| Gate | `DeveloperModeGate` / `DeveloperModeGateCoordinator` — `macos/Sources/IOSSimMacCore/Services/DeveloperModeGate.swift` (`#if VEYA_QUALIFICATION`) |
| Recovery re-mapping | `DeviceFailureMapping.developerModeRecovery` — `DeviceProductionAdapters.swift:146` |

AMFI enable (action 1), accept (action 2) and `trust_app_signer` (action 4) exist in the pinned
`idevice` crate (`idevice/src/services/amfi.rs`, revision `1838db1`) and are **deliberately not
exported**. Enable force-reboots and is rejected on any device with a passcode. Enabling belongs
to the user on the device.

### Gate phases (`DeveloperModeGatePhase`)

| Phase | Meaning | Button |
|---|---|---|
| `reveal` | Toggle may be hidden | **Enable Developer Mode** → AMFI action 0 only |
| `enable` | Toggle revealed; user must enable, restart, confirm, unlock | **Continue** |
| `undetermined` | iPhone did not answer | **Continue** (check again) |
| `verified` | Device-side evidence accepted | Engine button (**Install / Prepare** …) |

### Transitions

- `adopt(inspection:)` (`DeveloperModeGate.swift:164`) runs on selection/refresh. It can only **raise** the gate to `verified`, on `inspection.developerMode == .enabled`. It never lowers a verified gate. Before verification it only separates "no answer" (`undetermined`) from an authoritative `disabled`.
- `reveal(on:)` (`:188`): on success → `enable`; on failure → stays `reveal`, so the user is never sent to look for a toggle that was not revealed.
- `verify(stableUDID:)` (`:210`) is the **Continue** handler. It **rebinds** through `bridge.listDevices()` and `DevelopmentDeviceRebinding.descriptor(forStableUDID:)`. The UDID is stable across Apple's restart; mux id and connection generation are not; another attached iPhone is never a substitute. It then requires one of three device-side proofs (`DeveloperModeGate.evidence`, `:25`):
  `amfiStatusEnabled`, `personalizedImageMounted`, or `developerServicesReady`.
  With none, it goes to `enable`/`reveal` if the device authoritatively said disabled, and to `undetermined` if the device did not answer.
- `invalidate(detail:)` (`:257`): the engine reported the Developer Mode user action after verification (`DevelopmentInstallationView.swift`, `run`). Evidence is withdrawn and the phase returns to `enable`.
- `reset()`: a different iPhone was selected.

**"Reveal Developer Mode option" is never proof of "Developer Mode is enabled."** Reveal moves the
gate to `enable`, never to `verified`. Pressing **Continue** is not proof either: `verify` accepts
only an answer read back from the phone.

### Engine-side Developer Mode

Once the gate passes, the engine can still meet Developer Mode off. On the CoreDevice/RSD chain iOS
answers with transport-shaped errors. `DeviceFailureMapping.developerModeRecovery` re-reads
`coreDeviceProxyFailed / softwareTunnelFailed / rsdUnavailable / remoteXPCFailed /
appServiceUnavailable / featureUnavailable / developerServicesNotReady / protocolFailure` as
`.developerModeRequired` **only** when the inspection reported `disabled`. Locks, disconnects, trust,
missing images and Veya defects keep their meaning. The domain then reports the Developer Mode user
action, and the UI invalidates the gate.

Fail-closed properties: unknown is never disabled; disabled is never ignored; the engine never runs
before `verified`; AMFI advisory `disabled` cannot un-verify a phone proven by a mounted image or a
live developer-services session.

---

## E. Developer Trust ("Untrusted Developer")

### Why it can only be observed after installation

iOS evaluates developer trust when it **launches** an app signed by a Personal Team developer the
user has not trusted. Settings > General > VPN & Device Management only lists that developer once an
app from it is installed. Installation itself succeeds. The distinguishing operation is therefore
the **launch**.

### Where the launch happens

`developerSupport` depends on `application` (`dependsOn: [.application]`), so every install or
reinstall makes `developerSupport` stale. Its transition (`NativeDeveloperServicesCoordinator.prepare`
→ `operationalReceipt`, `NativeDeveloperServicesCoordinator.swift:170`) first proves the
CoreDevice/RSD/RemoteXPC/AppService chain on this connection, then calls
`transport.launchApplication(bundleIdentifier: main)` → `iossim_bridge_launch_app` → AppService
`launch_application`.

### Structured rejection payload (native)

In `iossim_bridge_launch_app`, a launch error that is `IdeviceError::CoreDevice(v)` with
`v.sub_code() == 1` is a **typed** discriminant: the device answered the launch feature with an error
envelope. It is recorded as `LaunchRejectionEnvelope::CoreDeviceErrorEnvelope`. A substring match
("security", "denied", "signature", "trusted") is recorded only as `Heuristic`. The NSError chain is
recovered by a brace-aware parser (`extract_error_chain`, `lib.rs:364`) **before** the 512-character
diagnostic truncation (`clean_diagnostic`, `lib.rs:426`). It is sent as JSON in the result payload:
`{schemaVersion:1, kind:"launchRejection", envelope, chain:[{domain, code, bsDescription}], chainComplete}`.
Free text, paths, identifiers and localized reasons are never included (`sanitized_domain`,
`sanitized_bs_description`).

Swift (`DynamicNativeDeviceTransport.error(status:)`, `NativeDeviceBridge.swift:1162`): status 22
with a decodable schema-1 payload becomes `.launchRejectedStructured(NativeLaunchRejection)`. An
absent, undecodable or unknown-schema payload becomes `.launchRejected(String)`.

### The exact classification rule

`DeviceFailureMapping.map(_:trustPrerequisites:)` (`DeviceProductionAdapters.swift:165`) returns the
Developer Trust user action when **either**:

1. **Structured path** (`isDeveloperTrustRejection(given:)`, `:264`): the error is
   `.launchRejectedStructured(detail)`, **and**
   - `detail.isStructurallyUsable`: schema 1, envelope `coreDeviceErrorEnvelope`, `chainComplete`, non-empty chain; **and**
   - `detail.isOpenApplicationSecurityDenial` (`:239`): terminal node `FBSOpenApplicationErrorDomain`, code `3`, `BSErrorCodeDescription == "Security"`; **and**
   - `DeveloperTrustPrerequisites.allProven` (`:61`), all five of:
     - `developerServicesProven`: supplied by the call site. It is `true` only in the developerSupport transition, which launches after its own readiness probe succeeded. In the VPN/pairing transitions it is `true` only if developerSupport has an active record.
     - `applicationInstalled`: active `application` record carries unexpired `deviceInventoryAfterInstall` evidence at its generation.
     - `payloadSignatureVerified`: `payloadIndependentVerification` on the active payload.
     - `profileBindingValidated`: `profileCMSBindingValidation` on the active profile, unexpired.
     - `certificateInventoryMatched`: `appleInventorySPKIMatch` on the active certificate, unexpired.
2. **Legacy text path** (`isDeveloperTrustRejection`, `:254`): the error is `.launchRejected(String)`
   and `ConsumerProvisioningErrorClassifier.isDeveloperProfileTrustRejection` matches the text
   (`ConsumerProvisioning.swift:956`). This serves the retained `devicectl` path. From the current
   bridge it is reachable only if a status-22 payload fails to decode. **This path does not check
   the prerequisites** (see the failure-model document).

Otherwise a launch rejection maps to `VEYA-DDI-032` ("The installed Veya app could not be launched on
the iPhone. iOS reported: <domain code desc > …>"), which is retryable.

### Negative cases: Veya must NOT classify Developer Trust when

- the envelope is `heuristic` (substring only), the schema is unknown, the payload is absent (except
  via the legacy text path), or the chain is incomplete or empty;
- the terminal node is anything other than `FBSOpenApplicationErrorDomain / 3 / Security`
  (e.g. `BadExecutable` code 5 stays `VEYA-DDI-032`);
- any prerequisite is unproven or its evidence expired;
- the error comes from an **observation**: `developerSupport.observe` never launches, and
  `DeviceFailureMapping.map(error)` there uses `.unproven` prerequisites;
- the launch failed for `ApplicationNotFound`, `DeviceLocked`, `DeveloperModeNotEnabled`, a
  transport stage, or a timeout. Those keep their typed meanings.

Why the structured denial alone is not enough: iOS folds invalid code signature, inadequate
entitlements and untrusted profile into the same `FBSOpenApplicationErrorDomain 3 Security` denial.
Veya removes the first two in advance from its own evidence (see
[SIGNING_AND_IDENTITY.md §Guarantees](SIGNING_AND_IDENTITY.md#guarantees-that-let-developer-trust-exclude-signature-and-entitlement-causes)).

### Presentation and Continue

- User action string `DeviceFailureMapping.developerTrust`: "On the iPhone open Settings > General >
  VPN & Device Management, select the Apple Development entry for your Apple Account, tap Trust, then
  continue in Veya."
- `DevelopmentInstallationStage.resolve` → `.trustDeveloper`: title "Trust Developer", with the same
  Settings path in its instruction. The primary action is **Continue** (= `.reconcile`).
- On **Continue**, the next run re-observes: `application` still satisfied, `developerSupport` still
  not active → transition → **launch again**. Only a successful launch (AppService returns a pid for
  the requested bundle) lets developerSupport become satisfied. The user's tap is never recorded as
  proof.

### Why Veya never trusts the developer itself

AMFI action 4, `trust_app_signer(input_profile_uuid)`, would mark the signer trusted without the user.
The bridge does not export it and no Swift path can reach it. Trusting a developer is an explicit
iOS security consent that belongs to the phone's owner. Automating it would bypass Apple's control
and would turn the classification above into a way around the consent instead of a way to route the
user to it. This is an intentional product rule, not a missing feature.

---

## I. LocalDevVPN

| Aspect | Implementation |
|---|---|
| iPhone side | App Store app `com.jkcoxson.LocalDevVPN` (App Store id `6755608044`), minimum `1.0.0`, supported major 1 (`LocalDevVPNCompatibilityPolicy`). Veya's iPhone app runs `LocalDevVPNSetupInbox` (payload capability `localDevVPNSetupGate: 2`). It checks functional readiness as TCP reachability to `10.7.0.1:49152` and writes the receipt. |
| Mac side | `LocalDevVPNSetupCoordinator` — `macos/Sources/IOSSimMacCore/Services/LocalDevVPNSetupCoordinator.swift`; trace file `localdevvpn-transition-trace.jsonl` in the state root |
| Domain | `.vpn` (`ProductionDeviceDomains.vpn`, `DeviceProductionAdapters.swift:400`), depends on `application` |
| Request | `LocalDevVPNSetupRequestPayload {requestID, appBundleIdentifier, endpoint 10.7.0.1:49152, createdAt, deviceUDID, teamIdentifier, releaseIdentity}` → `…/SetupInbox/localdevvpn.request` in Veya's container |
| Transition (`prepare`, `:212`) | write request → launch Veya (AppService) → poll receipt 4×0.5 s → if not ready: inventory check for LocalDevVPN (missing → `appMissing`; version → `unsupportedVersion`) → launch LocalDevVPN → poll 48×0.5 s, stopping on an actionable state |
| Receipt acceptance | schema 1, same `requestID`, same endpoint, same UDID/team/release, state `RUNTIME_ENDPOINT_REACHABLE` **and** `endpointReachable == true` (otherwise `receiptInvalid`) |
| Observation | Receipt read-only, ≤ 60 s old. Older → `stale` (physically observed: a 600 s window reported satisfied minutes after LocalDevVPN was turned off). |
| User actions | `VEYA-VPN-031` install LocalDevVPN, `032` allow the VPN configuration, `033` open LocalDevVPN and tap Connect, `034` endpoint unreachable (retryable), `035` no receipt, `036` invalid receipt, `037` transport; `030` unsupported version (terminal) |
| Stage | `DevelopmentInstallationStage.connectLocalDevVPN` when the failure domain is `.vpn`, the code has the `VEYA-VPN` prefix, or the action mentions LocalDevVPN |
| Relationship to runtime | Runtime binding includes the active VPN record. Run Setup needs the VPN route. VPN proof older than 60 s makes the next run re-probe. |
| Recovery | Every **Continue** re-runs `prepare`, which re-writes the request and re-polls. The phone's last reported state is only a hint. |

---

## J. Runtime / Run Setup and READY

1. `RuntimeReadinessDomain.execute` creates a candidate whose identity is the **binding**: the SHA-256 of
   the active `application`, `developerSupport`, `pairing` and `vpn` identities, plus device hash and
   connection generation.
2. `prove` → `JournalRuntimeProver.proveRuntime` (`DeviceProductionAdapters.swift:520`):
   - requires `InstalledPayloadIdentity` and a pairing record with `pairingGeneration > 0`;
   - reuses a pending `run-setup.request` the phone can still answer, or writes a new one via
     `RunSetupReadinessCoordinator.requestSetup` (request lifetime 15 min);
   - proves developer services fresh (`developerServices.prepare`, which launches the app again);
   - `awaitRunSetup` reads `…/SetupInbox/run-setup.receipt`. The receipt must be bound to the request,
     pairing identifier and public-key fingerprint, and report `sessionEstablished && sessionProbed`
     (a live, read-only session probe on the phone; Run Setup never changes location).
3. **Veya never starts setup on the phone.** The user's own **Run Setup** tap is the proof. No
   receipt → `RunSetupFailure.notTapped` → `VEYA-RUNTIME-011` (retryable, action "Tap Run Setup on
   your iPhone, then continue in Veya."). The UI shows **READY FOR SETUP** when the request was just
   issued.
4. The receipt's `completedAt` must be within the 600 s TTL before this call and at most 5 s in
   the future.
5. Evidence `runtimeFullChainProof` (connection-bound, `validUntil = completedAt + 600 s`) → promotion.

**READY** = the planner returns `.ready`: all 13 domains are observed `satisfied`, fresh and on the
current connection. The UI maps `status == "ready"` to stage `.ready` ("Setup is complete and the
iPhone is ready.").

Runtime goes stale when any upstream identity changes (reinstall, new pairing, new VPN proof record),
the connection generation changes, or 600 s pass. It is re-proven by the same transition, which may
need a fresh Run Setup tap.

---

## K. iPhone payload (bundled `DeviceArtifacts`)

| Field | Value |
|---|---|
| Manifest | `Contents/Resources/DeviceArtifacts/manifest.json`, SHA-256 `56ef35c080458b2745e9cd9cbafea2afd714ec1f314a9f2764e66c8f52aeee0a`, schema 2 |
| Source | commit `073d4a976b18a6ec863de0a5f1d216cc3be7c0b6`, `payloadSourceDirty: false`, tree SHA-256 `da3b57a4a332eef944828f64d318c45c70c8b57e0d45535879727e1f717947b3` |
| Build | `DEVICE_PAYLOAD_RELEASE`, variant `PRODUCTION`, buildNumber 11, `2026-09-23T03:20:49.500896Z` |
| `iosMain` | `IOSSim DVT POC.app`, `com.iossim.on-device-dvt-poc` 0.1 (build 1), arm64, iOS ≥ 17.0, SHA-256 `a249ca5b02abe80947bf78e7e945677ca332c89159ce42bd3adf3cb0ce879a80` |
| `locationControlRunner` | `IOSSimLocationControlUITests-Runner.app`, `com.iossim.location-control-uitests.xctrunner` 1.0 (build 1), arm64, contains `PlugIns/IOSSimLocationControlUITests.xctest`, SHA-256 `233341ded42baae97e03394f348d10b2760c0ff83ff30c080e7616bdf339b82a` |
| Capabilities | `automaticPairingInbox 2, localDevVPNSetupGate 2, pairingReceiptSchema 2, richRuntimeProofInbox 1, runSetupInbox 2, runtimeMappingSchema 1` |
| Re-signing | Per team: main → `com.personalteam.iossim.t<hash>.on-device-dvt-poc`, runner → `….location-control-uitests.xctrunner`, xctest → `….location-control-uitests` (`ShippedPayloadPlanProvider`) |
| Identity check | Whole `DeviceArtifacts` tree hash `0c3910d4bc97fb794f10beab79e2e5cca535d7a1bf43eab636357fded7a23868` is **byte-identical** in `Veya-Test-6a0c7e8.dmg`, `Veya-Test-94ed677.dmg`, `Veya-Test-1f2a398.dmg`, the physically validated `Veya Development.app` and `Veya-Test-8155901.dmg`. |

Known source drift: `git diff 073d4a9 8155901 -- ios/` changes `ios/App/SetupView.swift`,
`ios/App/Shared/ConnectionStatusModel.swift`, `RunSetupInbox.swift` and `POCUnitChecks` (iPhone-side
Run Setup request gating, added in `94ed677`). **Those iPhone changes are not in the bundled payload.**
The payload was deliberately not rebuilt.
