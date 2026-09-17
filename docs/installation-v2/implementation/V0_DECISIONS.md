# V0 decisions and implementation contract

Status: `PASS`; implementation contract frozen; production DDI source remains deliberately unresolved and fail-closed.

## Responsibility owners

| Responsibility | Authoritative owner |
| --- | --- |
| setup presentation and ephemeral user input | `SetupWizardView` / `SetupStore` |
| process protocol, helper path, integrity and cancellation | `BundledProvisioningEngine` |
| all setup mutation serialization | embedded `IOSSimProvisioner` |
| domain check/repair/verify orchestration | `ConsumerArtifactProvisioner` |
| durable keyed state, journal, generation and lease | V2 state store owned by the helper |
| private Apple auth/provisioning protocol | versioned adapter below `ApplePersonalTeamService` |
| native device mechanics and exact connection | `NativeDeviceBridge` and pinned Rust bridge |
| developer-support selection/provenance/cache orchestration | `DeveloperSupportCoordinator` |
| TSS personalization, mount and developer-service verification | native developer-services layer |
| app inventory/install/upgrade | `NativeApplicationManagement` |
| RemotePairing candidate/active lifecycle | `RemotePairingLifecycle` plus phone inbox |
| LocalDevVPN app/VPN implementation | external `com.jkcoxson.LocalDevVPN` and its publisher |
| LocalDevVPN detection/guidance/resume/proof | Veya coordinator and phone inbox |
| READY proof | runtime verification service using retained XCTest/Rich XCUILocation runtime |
| artifact truth and release permission | canonical release auditor/manifest derived from output bytes |

No new production orchestrator is authorized.

## Developer-support provider policy

The code contract classifies every provider as one of:

- validated existing cache (read-only, no fresh acquisition claim);
- explicit development/local-test third-party mirror;
- test fixture;
- approved production source.

The selection context is explicit: development, local test, or public production. Public production rejects development-mirror and fixture providers. A public release additionally requires an approved production provider capable of fresh acquisition; an existing cache does not satisfy that release gate. There is no implicit fallback between policy classes.

The production source is unresolved. Therefore:

- local development and a clearly marked local-test DMG may proceed;
- no mirror is silently treated as production-approved;
- no Apple developer-support assets are authorized for public bundling;
- public zero-Xcode qualification and publication remain blocked;
- the release manifest must report the provider classification and unresolved production policy.

`DeveloperSupportCoordinator` remains the orchestration owner. Provider implementations own acquisition and provenance only. Native services own device query, Apple TSS, mount, and operational proof.

## Dependency and identity decisions

- LocalDevVPN remains external. Veya owns detection, compatibility, guidance, launch/request, resume, endpoint proof, and diagnostics. Apple VPN approval remains user-controlled.
- Existing Mac, phone, runner, Keychain, pairing, provisioning, and signing identifiers remain stable through V17. V18 may change display/product naming; any bundle-ID change requires a separate dual-ID migration decision.
- Customer runtime may depend only on declared bundled components, supported macOS components, explicit Veya setup outputs, iPhone capabilities, Apple/user-authorized security interactions, and declared external LocalDevVPN.
- Repository checkout, developer PATH, Git, Homebrew, host Python/Node/Rust/Cargo, Xcode GUI, DerivedData, manual pairing files, `xcodebuild`, and `devicectl` are not consumer dependencies.

## Runtime invariants

Installation V2 wraps and prepares the current runtime. It does not replace Spoof, Drive, Rich XCUILocation, retained/preinstalled runner behavior, supplied/retained RSD behavior, RemotePairing, saved pairing state, LocalDevVPN, Rich/default transport, compatibility fallback where still required, 2 Hz smooth Drive, 1 Hz fallback, Stop & Hold, Resume, Clear, destination hold, one writer, one scheduler, or no-backlog behavior.

READY will eventually require a bounded Rich set/observe/clear proof. Until that milestone passes, stored configuration must not be represented as a new physical runtime pass.

## Release truth policy

- Desired configuration is an assertion, never evidence.
- Actual final Mach-O slices, plists, schemas/ABIs, payload identities/versions/hashes, component hashes, signatures, source identity/dirty state, channel, and mounted DMG contents are authoritative.
- Any desired-versus-actual mismatch fails the artifact/release gate.
- Dirty/ad hoc output is `LOCAL_TEST_ONLY` and cannot be converted to public status by renaming or sidecar edits.
- Public release requires Developer ID signing, notarization, stapling, Gatekeeper, approved production DDI policy, and artifact-bound physical qualification.

## Production security controls

- Preserve Trust This Computer, passcode, Developer Mode, Apple 2FA, developer-profile trust, VPN approval, and code-signing enforcement.
- Passwords and 2FA stay transient. Sessions and private keys stay in appropriately scoped Keychain items. Pairing records/PSKs never enter logs, support archives, or documentation.
- Production rejects repo/helper/bridge overrides, unapproved provider classes, identity ambiguity, stale generations, incompatible schemas, and destructive ownership guesses.
- Repair is candidate-first and preserves the last verified active resource. Unknown user/account resources are never deleted automatically.
- Support output is allowlisted and negative-scanned before emission.

## Known discrepancy resolution

Older documents said no DDI downloader should be implemented until ADR-003 is resolved. The newer Vanish-informed plan and this implementation directive refine that rule: an explicitly named development/local-test provider may be implemented for local testing, while public production continues to fail closed. This is a policy refinement, not a third architecture.

## V0 gate

The provider-policy types and both coordinator boundaries compile. Nine focused unit tests prove that public-production selection cannot choose a development mirror or test fixture and that a validated cache alone cannot satisfy the fresh-acquisition release gate. Safe no-Xcode and synthetic discovery checks also pass.
