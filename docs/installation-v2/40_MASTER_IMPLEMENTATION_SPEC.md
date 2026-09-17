# Master implementation specification

## Status and gate

This specification is the implementation authority after acceptance of ADRs in 37. It does not authorize production release while ADR-003 is unresolved. Overall status: **ARCHITECTURE_NOT_READY**. Work through M1–M5 and other non-DDI foundations may proceed after review; a public zero-Xcode candidate may not.

The execution-focused follow-on plan is [vanish-reference/20_VANISH_INFORMED_MASTER_IMPLEMENTATION_PLAN.md](vanish-reference/20_VANISH_INFORMED_MASTER_IMPLEMENTATION_PLAN.md). It preserves this document's invariants and updates the DDI evidence: Vanish requires DDI and uses a bundled PMD client plus the doronz88 GitHub asset mirror and Apple TSS. That is a proven mechanism, not an approved Veya dependency.

## Required product behavior

A user installs one signed/notarized Veya DMG, selects an iPhone, and lets Veya reconcile owned prerequisites. The user performs only legitimate Apple-required actions: unlock/passcode/Trust, Developer Mode/reboot, Apple Account/2FA where needed, developer-profile trust, LocalDevVPN App Store install, and VPN approval. Veya provisions a Personal Team identity/profile, re-signs and installs the bundled main/runner, establishes developer services, securely transfers and proves RemotePairing, verifies LocalDevVPN, launches/attaches the runner, performs a Rich runtime proof, and then displays READY.

Customer runtime must not require a repository, Python environment, full Xcode, `xcodebuild`, `devicectl`, or selectable legacy backend. Controlled release infrastructure may use Xcode to build Apple SDK payloads.

## Frozen component architecture

Retain the current chain:

```text
SwiftUI / SetupStore
 -> IOSSimSetupEngine V2
 -> BundledProvisioningEngine
 -> signed embedded VeyaProvisioner
 -> ConsumerArtifactProvisioner/domain reconciler
 -> versioned Apple service + native device/domain services
 -> pinned Rust idevice bridge
```

SetupStore owns presentation and ephemeral user interaction. The helper owns one serialized mutation under a per-SetupKey OS lease. Domain services implement check/repair/verify and return receipts. Stores implement keyed atomic state. The bridge implements typed protocol operations only. No second production engine is created.

## Persistent identity and transaction contract

`SetupKey = releaseCompatibilityID/teamID/deviceHash/artifactSetID`. Every request has operation ID and expected generation. Mutation follows journal `INTENT -> OBSERVED -> COMMITTED`, with fsync, atomic snapshot, generation CAS, and a PID/start/boot-bound lease. Secret bytes live in Keychain or private artifact records; setup state stores references and public/salted metadata.

Schema-4 singleton state and native profile artifact files are imported once as unverified candidates and reconciled against Keychain/device inventory before promotion. Ambiguous state is quarantined. No migration deletes old state until the new snapshot is committed and qualified.

## Ordered setup domains

1. Verify app/helper/bridge/payload manifest, signatures, hashes, and schemas.
2. Enumerate and bind the exact device hash plus mux connection ID/type.
3. Reuse a valid Lockdown record or run USB `pair_once`, persisting and validating after the user trusts.
4. Restore/obtain Apple session through the versioned private adapter; select the explicit team.
5. Reconcile managed key/certificate/device/App IDs/profiles with read-before-create.
6. Sign staging payloads and verify profile, entitlements, key/cert, and strict codesign.
7. Install/upgrade main and runner and verify exact inventory; suspend for developer-profile trust when explicitly proven.
8. Resolve exact developer-support assets from an approved provider, personalize/mount, and prove RSD service map.
9. Prove AppService and launch exact main bundle.
10. Deliver RemotePairing candidate with request-bound AEAD; prove phone possession and developer-service operation; promote without deleting the prior active record early.
11. Reconcile external LocalDevVPN presence/version/approval/run state; prove request-bound endpoint and developer service.
12. Launch runner, attach TestManager, and perform bounded Rich set/observe/clear proof under one writer generation.
13. Commit READY only while every receipt identity and TTL is current.

The authoritative state/error semantics are 19–22. Repair always begins with check and targets the earliest invalid owning domain. Later failure preserves earlier valid resources.

## Critical protocol additions

### Native bridge ABI v2

Add exact connection selection and Lockdown pairing begin/poll/save/validate. Every result carries ABI/schema, selected device hash/connection identity, stable error, bounded detail, and an explicitly freed receipt buffer. Production rejects dylib overrides. Fix Rust selection so it filters by UDID and expected mux ID/type before choosing.

### Pairing wire schema 2

Bind request ID, device, team, app/artifact, expiry, bootstrap, nonce, and candidate fingerprint as AEAD context. Use phone Keychain active/candidate slots. Import receipt is an intermediate state. A fresh challenge proves candidate possession; an authenticated RSD/developer-service operation proves usability. Both sides promote, then retire old state. Journal recovery handles one-sided promotion.

### LocalDevVPN wire schema 2

Persist request ID/expiry and reconcile on every phone scene activation. Receipts bind the selected identity and request. A compatible app version and Apple-approved configuration precede run state. READY requires the intended endpoint plus developer-service proof, not receipt or TCP acceptance alone.

### Helper protocol V2

Provide `protocol-info`, `reconcile`, `action`, `status`, and `cancel`; keep support export. Envelopes are length-bounded JSON over inherited pipes and include release/operation/setup/generation identity. The helper sanitizes environment and emits stable `VEYA-*` errors. Legacy commands move to a developer-only target and are deleted after parity.

## Apple provisioning and signing

Expose `ApplePersonalTeamService`; place current behavior in an adapter named/versioned for its compatibility set. Password/2FA/SRP are ephemeral. Session tokens/cookies use Keychain. Signing keys are Veya-tagged, exact-team scoped, and never broadly deleted. Certificate/profile renewal creates candidates, signs and verifies both apps, upgrades and launches them, then promotes. Ambiguous server mutations reconcile by listing exact resources before retry.

Protocol incompatibility or unapproved terms disables mutation and preserves installed apps. SetupStore sees typed auth/2FA/session/limit/outage/compatibility states only.

## Developer-support blocker contract

`DeveloperSupportProvider` returns exact build identity, provenance ID, image/manifest/trust-cache digests/sizes, and rights/policy identifier. Existing Apple caches remain a provider. A production network provider may be implemented only after ADR-003 names an approved authority and verification/revocation policy. No hardcoded public mirror, implicit PMD downloader, or bundled Apple bytes enter the consumer by default.

Mount logic selects by device/product build and personalization identifiers, uses Apple TSS with ordinary TLS validation, uploads/mounts through the native bridge, and re-queries mount/RSD. Upload success is not operational proof.

## Runtime preservation

Do not redesign Spoof/Drive or replace Rich XCUILocation with Vanish-style coordinate-only DVT. Preserve retained runner, supplied RSD, saved pairing, LocalDevVPN, Rich default/DVT fallback, 2 Hz/1 Hz behavior, Stop/Hold/Resume/Clear/destination hold, one writer/scheduler, and no backlog. New readiness uses a safe proof hook and always clears; a disconnected clear remains journaled as pending.

## Diagnostics and privacy

Every domain emits structured safe events with release/operation/state/code/timing and noncorrelatable aliases. Support schema 8 is an explicit DTO; it never serializes persistence structs. A negative content scanner aborts on credentials, tokens, cookies, SRP/anisette, private keys, pair/profile/TSS/VPN material, raw identifiers, home paths, or coordinates. About/support include exact release identity and component/schema hashes.

## Release contract

One orchestrator builds configured architectures, payloads, app, and DMG. The public target is one universal arm64/x86_64 artifact while Intel macOS 13 is supported. The final name is `Veya-<semver>-build<build>-<shortsha>.dmg`. The signed manifest is generated from the read-only mounted DMG and records actual component slices, plists, schemas, hashes, signatures, payloads, source/dependency/toolchain provenance, SBOM/notices, and qualification IDs.

Any mismatch in architecture, schema, helper/bridge, payload hash/capability, Info.plist, source state, signing, notarization, stapling, Gatekeeper, mounted contents, or license policy fails the release. GitHub Releases is the initial immutable authority; signed Veya metadata remains the update trust anchor. Upload is followed by independent download and hash/manifest verification before publish.

## Implementation order and gates

Execute M0–M15 from 36. M1 release truth and M2 hermetic tests precede behavior changes. M3 state safety precedes new mutations. M5 trust precedes fresh device work. M6 cannot pass until the DDI decision. M8 pairing and M9 VPN precede M11 READY. M13 produces the canonical candidate; M14 branding follows functional qualification; M15 binds all physical evidence to the final artifact.

Each milestone must preserve files listed as untouched, pass automated acceptance, record migration/rollback, and stop on its failure gate. Do not batch branding, bundle-ID changes, private adapter changes, pairing crypto, state migration, and release rewrite into one review.

## Definition of implementation complete

Implementation is complete only when:

- all required files in 35 have their target roles and legacy public routes are absent;
- automated tests are hermetic and pass, including fault/crash/concurrency/secret/mismatch suites;
- ADR-003 and all shipment decisions are accepted;
- one final signed/notarized mounted artifact passes Release V2 audit;
- every applicable physical matrix cell in 33 passes against that exact DMG hash;
- support output proves release identity and contains no forbidden material;
- current IOSSim users migrate/rollback without losing working resources;
- READY can be reproduced by an end-to-end Rich proof on each supported device/OS cell.

Until then, use precise intermediate labels such as `CONFIGURED`, `ACTION_REQUIRED`, `PAIRING_OPERATIONAL`, or `RUNNER_OPERATIONAL`; do not show or market READY/zero-Xcode.

## Future implementation-agent handoff

Start with M0 decisions, then implement M1 and M2 only. Preserve the dirty user worktree and runtime invariants. Use 35 for file scope, 19–22 for state/errors/recovery, 23–27 for ownership/security, and 29–31 for release gates. Do not implement a DDI downloader until ADR-003 is resolved. Do not rename IOSSim, bundle IDs, or signing identifiers before M14. Do not delete active pairing/signing/installed resources during repair. Bind every claimed pass to the actual final artifact.
