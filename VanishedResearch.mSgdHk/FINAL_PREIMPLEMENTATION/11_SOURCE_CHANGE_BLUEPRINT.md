# Exact Source Change Blueprint

No source changed in this research pass.

## Keep

All iPhone runtime files under ios/Sources/IOSSimOnDeviceDVTPOC implementing LocalDevVPN/RPPairing/RSD/DVT/TestManager/XCTest/XCUILocation, LocationCoordinator, DriveSessionController, DriveScheduler, DriveTiming, DriveLocationTransport, RouteResampler, RichDriveLocation and generation/single-writer behavior. Keep current iOS idevice pin/patch and runtime tests.

## Modify

RuntimeProvisioningSupport.swift: native backend default and expanded typed DeviceBridge. InstallationInventory.swift: native inventory adapter. ConsumerArtifactProvisioner.swift: native install/upgrade/uninstall/launch/House Arrest and remove consumer devicectl/xcodebuild paths. BundledProvisioningEngine.swift, IOSSimSetupEngine.swift, SetupStore.swift: versioned readiness/recovery IPC, no manual READY assertion. ConsumerProvisioningStateStore.swift: per-device journal/migrations/workflow locks. ApplePersonalTeamLive.swift: AKD normalizer, URL-bag endpoint, redirects, 2FA method and transient session classification. ApplePersonalTeamExperimental.swift: single versioned request identity. SupportBundleExporter.swift: remove xcodebuild probe. DoctorStatus.swift and provisioning models: typed health/reasons. PairingStore.swift/RPPairingValidator.swift and iOS setup views: encrypted inbox/receipt and remove normal manual plist import, without runtime algorithm changes.

## Deprecate

DevicectlProvisioningBackend, DevicectlApplicationInventoryReader, direct xcrun devicectl calls, xcodebuild signing-shell fallback, Xcode doctor/support probes from consumer reachability. DevelopmentCLIEngine, scripts/bootstrap and backend Python remain build/research-only.

## New Swift modules

DeviceBridge.swift, DeviceIdentity.swift, DeviceReadiness.swift, DDIManager.swift, InstallationCoordinator.swift, PairingCoordinator.swift, ReadinessEngine.swift, SetupJournal.swift, RenewalCoordinator.swift, AppleAuthenticationDiagnostics.swift. All async typed, timeout/cancellation aware, journal receipt and typed errors.

## New Rust modules

A vendored/pinned bridge target with FFI modules for identity/usbmux/Lockdown, AMFI, DDI/TSS, installation, AFC/House Arrest, RSD/RemotePairing/AppService/DVT and redaction. C handles have explicit free functions and schema version. Rust never accepts arbitrary commands.

## Required Public Contracts

### DeviceProvisioningBackend evolution

Keep the repository’s existing protocol name, but replace string selectors and ProcessResult with typed requests/results. The implementation sequence should be:

| Operation | Input | Output | Stable errors | Persistence |
|---|---|---|---|---|
| discoverDevices | discovery options, timeout | array of DeviceIdentity plus observations | helperUnavailable, transportFailure | none; journal only last selection |
| inspectDevice | DeviceToken | DeviceInspection with model, OS/build, transport, lock/trust, Developer Mode and capabilities | noDevice, identityMismatch, locked | observation timestamp only |
| waitForTrust | DeviceToken, cancellation/deadline | TrustObservation stream/final state | trustRequired, locked, timeout, disconnected | no pair secret in Swift |
| prepareDeveloperSupport | DeviceToken, DDI policy | DeveloperSupportReceipt with mounted build and RSD capabilities | developerModeDisabled, ddiUnavailable, tssRejected, rsdUnavailable | DDI cache receipt |
| listApplications | DeviceToken, optional bundle allowlist | authoritative ApplicationInventory | serviceUnauthorized, transientTransport | journal expected/observed IDs |
| installApplication | DeviceToken, artifact descriptor | InstallReceipt with operation UUID, bundle/team/version | installRejected, signingMismatch | transaction receipt |
| upgradeApplication | same | UpgradeReceipt plus data-preservation probe status | upgradeRejected, teamMismatch | transaction receipt |
| uninstallApplication | DeviceToken, exact bundle ID, explicit destructive token | UninstallReceipt | appNotInstalled, uninstallRejected | destructive audit event |
| launchApplication | DeviceToken, exact bundle ID, launch options | LaunchReceipt/PID if available | developerProfileTrustRequired, serviceUnauthorized | safe receipt |
| readContainerFile | DeviceToken, bundle ID, enum path | bounded bytes/digest | containerUnavailable, pathRejected | never arbitrary downloaded files |
| writeSetupEnvelope | DeviceToken, bundle ID, one-time envelope | transfer digest/receipt | appIdentityMismatch, envelopeExpired | envelope nonce only |
| ensureRemotePairing | DeviceToken, explicit repair policy | PairingHandle metadata/public fingerprint | pairingRequired, pairingRejected, wrongDevice | Keychain secret through Swift coordinator |
| validateRemotePairing | DeviceToken, PairingHandle | RSD peer/capability receipt | pairingStale, peerMismatch, rsdUnavailable | validation date/receipt |

DeviceToken is an opaque workflow token created from a verified physical UDID and connection generation. It is not a display identifier. The bridge refuses an operation if the current usbmux/RSD device no longer matches it.

### PairingCoordinator

Public operations: status(deviceToken), prepare(deviceToken), deliver(deviceToken, appIdentity), awaitImportReceipt(deviceToken, nonce), validateRuntime(deviceToken), repair(deviceToken, classifiedReason), and advancedExport(deviceToken, explicitUserConsent). Inputs never include filesystem paths from UI. Outputs are PairingStatus and PairingReceipt with only public fingerprints. Errors distinguish Lockdown trust, missing host record, semantic corruption, peer mismatch, transfer failure, phone rejection, RSD rejection and runtime-not-ready. Secret persistence is entirely Keychain; journal holds a persistent-reference identifier and fingerprints. Tests use deterministic synthetic records and fake service handshakes.

### ReadinessEngine

Public operations: snapshot(deviceToken), reconcile(deviceToken, mode), nextAction(snapshot), repair(deviceToken, domain, reason), and cancel(workflowID). Reconcile mode is observeOnly or allowSafeRepair; destructive repair always requires a separate user-confirmed token. Output contains domain observations and dependency causes, never raw command text. The engine persists observations/journal transitions, not live service handles. Tests cover every state transition and cross-domain non-interference.

### RenewalCoordinator

Public operations: inspect(deviceToken), plan(deviceToken, now), execute(planID), verify(planID), and cancel(planID). A RenewalPlan names which profiles/artifacts change and which existing key/certificate/session/pairing are reused. Errors distinguish sessionExpired, certificateRevoked, profileExpired, registrationRejected, resignFailed, upgradeFailed, dataReceiptChanged and runtimeVerificationFailed. A failed plan remains resumable; it never deletes the installed app automatically.

### AppleAuthenticationDiagnostics

Public operations: createSRPInitReport(accountInput, requestIdentityProvider), compare(reportA, reportB), and classifyHTTP(responseMetadata). Report fields are endpoint class, HTTP status, sanitized header presence/type/length, request/response field names/types/lengths, retry metadata and correlation ID. This interface must be structurally unable to accept a password for init-only comparison and unable to expose raw sensitive header values. Later proof diagnostics accept only pre-sanitized structural traces.

### Rust FFI ownership

Every returned pointer has one matching free function. Buffers carry pointer, length and capacity; Swift copies then frees. Device and RSD handles are generation-tagged and Sendable only through the owning actor. Cancellation is cooperative and deadlines are enforced on every read/write. Panics are caught at the FFI boundary and returned as helperInternal without process abort where technically possible. The ABI returns a versioned envelope rather than Rust enum ordinals.

## Existing File-Level Changes

| File | Current responsibility | Concrete modification | Dependency change |
|---|---|---|---|
| RuntimeProvisioningSupport.swift | context, backend selection, devicectl and system_profiler implementations | split model/facade from backend; native default; remove shell path and environment-based consumer choice | add DeviceBridge module |
| InstallationInventory.swift | devicectl JSON app lookup/retry | adapt listApplications receipt; preserve bounded retry while separating transport from absence | remove ProcessRunner/xcrun |
| ConsumerArtifactProvisioner.swift | signing, install, launch, mapping readback and fresh uninstall | inject InstallationCoordinator; use upgrade; exact receipt; remove direct command construction | DeviceBridge, journal |
| IOSSimProvisioner/main.swift | command router/doctor | add versioned device/readiness/pairing/renewal commands; reject schema mismatch | linked Rust bridge |
| IOSSimSetupEngine.swift | high-level UI engine protocol | replace confirmRuntimeSetup with reconcile/repair; retain compatibility shim only during migration | ReadinessSnapshot |
| BundledProvisioningEngine.swift | JSON process IPC | validate protocol version/capabilities; stream safe progress; cancel operation | signed provisioner only |
| SetupStore.swift | presentation state and orchestration | render one next action from snapshot; stop parsing error text as domain state | ReadinessEngine result |
| ConsumerProvisioningStateStore.swift | single manifest and JSONL | per-device versioned journal, transaction receipts, migration/backups | Keychain references only |
| ApplePersonalTeamLive.swift | GSA/SRP/2FA/Developer Services | isolate request identity/endpoint/session classifiers and diagnostics; preserve crypto | URL-bag and normalized metadata |
| SupportBundleExporter.swift | broad support collection | allowlist structured records and helper integrity; remove Xcode invocation | no ProcessRunner tool probe |
| PairingStore.swift | phone Keychain RPPairing | add atomic imported-record replacement and receipt, retain runtime API | setup inbox reader |
| RPPairingValidator.swift | shape checks | version/binding/replay validation; no network in parser | CryptoKit hash/verification only |

## Migration Order

Add new interfaces and adapters first, keeping existing test doubles compiling. Migrate inventory, discovery and install consumers one operation at a time. Make the native backend mandatory only after their gates pass. Then delete devicectl implementations and string-error compatibility. Journal migration must precede removal of confirmRuntimeSetup so installed users retain valid signing/profile state.

## Tests

Swift migrations/auth metadata/error classifiers; Rust plist/service/identity/redaction fixtures; fake usbmux/Lockdown/Installation/AFC/RSD servers; interruption/recovery and upgrade-data tests. No live secrets in CI. Physical gates are separate.
