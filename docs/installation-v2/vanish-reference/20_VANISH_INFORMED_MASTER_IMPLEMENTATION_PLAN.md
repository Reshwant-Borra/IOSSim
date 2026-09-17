# Vanish-informed master implementation plan

## Outcome and constraint

Build a single signed Veya application that guides a consumer from a fresh Mac and iPhone through legitimate Apple Trust, Developer Mode, Apple account/2FA, Personal Team provisioning, sign/install, profile trust, secure pairing, LocalDevVPN, and an actual Rich XCTest/XCUILocation proof. The implementation keeps IOSSim's Swift/Rust architecture. Production runtime must not require Xcode, a repository, developer tools, or externally installed language runtimes.

The plan is executable except for one deliberately unresolved input: the shipping DDI provider. Vanish confirms the technical sequence but obtains Apple developer-support inputs from the doronz88 GitHub mirror. Implementation of that provider must wait for the V0 product/legal/security decision.

## Fixed interfaces

```swift
protocol InstallationEngineV2 {
    func protocolInfo() async throws -> EngineProtocolInfo
    func reconcile(_ key: SetupKey, trigger: ReconcileTrigger) async throws -> SetupSnapshot
    func perform(_ action: SetupAction, for key: SetupKey) async throws -> SetupSnapshot
    func status(_ key: SetupKey) async throws -> SetupSnapshot
    func cancel(_ operationID: UUID) async throws
}

protocol SetupDomainReconciler {
    associatedtype Receipt: Codable & Sendable
    func check(_ context: SetupContext) async throws -> DomainObservation
    func repair(_ observation: DomainObservation, context: SetupContext) async throws
    func verify(_ context: SetupContext) async throws -> Receipt
}

protocol DeveloperSupportBuildProvider {
    var providerID: String { get }
    func artifact(for device: DeviceBuildIdentity) async throws -> ProvenancedDeveloperSupportArtifact
}
```

Equivalent concrete types may use existing names, but ownership cannot move across these boundaries without a new ADR. The setup engine owns orchestration; the Apple adapter owns private protocol; the native bridge owns device protocols; the provider owns asset acquisition/provenance; pairing owns its secrets; runtime verification owns READY proof.

## Persistence authority

`SetupKey = SHA256(releaseIdentity || teamID || canonicalDeviceUDID || artifactSetID)` with raw values retained only in protected domain stores. The directory contains `snapshot-v5.json`, `journal-v1.jsonl`, `lease.json`, and candidate subdirectories. Snapshot holds safe domain state and references, never credentials, pairing material, private keys, raw profiles, or raw UDIDs. Keychain holds Apple sessions, signing private keys, and sensitive references. Pair records remain in their native protected store; snapshot contains opaque record IDs/hashes.

Every mutation follows `lock -> observe -> journal intent -> mutate -> observe -> journal result -> CAS snapshot -> fsync -> unlock`. Recovery treats unfinished intent as unknown and inspects the real resource. Candidate promotion is atomic. Active signing, profile, installed app where possible, and pairing resources remain until replacement verification succeeds.

## Exact implementation order

1. **V0 decisions:** approve DDI source and distribution obligations; fix supported matrix and release authority.
2. **V1 artifact truth:** create manifest V2 and mounted-DMG auditor. Make the observed architecture/schema contradictions impossible.
3. **V2 harness:** isolate tests and freeze current native/provisioning behavior with explicit fakes.
4. **V3 engine:** add protocol/integrity envelope and production-only composition. Convert doctor/helper errors to `VEYA-INTEGRITY`.
5. **V4 state:** land key/lease/journal/schema migration before any new mutating workflow.
6. **V5 Trust:** extend ABI with exact connection selection and Lockdown `pair_once`; prove first trust physically.
7. Develop **V6 DDI**, **V8 Apple adapter**, and **V9 signing lifecycle** behind their fixed interfaces. V6 cannot pass without the approved provider.
8. **V7 install parity:** fix mux ordering, bind operations to device/artifact, and verify inventory.
9. **V10 pairing:** change destructive replacement to candidate/import/challenge/operational-proof/promotion.
10. **V11 VPN:** make the external dependency and Apple approval an explicit resumable domain.
11. **V12 developer services:** bind DDI/tunnel/RSD/AppService receipts and exact native launch.
12. **V13 runtime:** introduce end-to-end Rich proof and redefine READY.
13. **V14 recovery/renewal** and **V15 diagnostics:** complete lifecycle, stable errors, allowlist support bundle.
14. **V16 legacy removal:** only after replacement gates pass.
15. **V17 canonical distribution**, **V18 naming migration**, then **V19 physical qualification**.

## Domain state and invalidation

The canonical phases and transition contracts are in [14_TARGET_SETUP_STATE_MACHINE.md](14_TARGET_SETUP_STATE_MACHINE.md). Stored state is domain-based: integrity, deviceTrust, developerMode, developerSupport, appleSession, team, signingIdentity, profiles, artifacts, installation, profileTrust, remotePairing, vpn, developerServices, runner, richRuntime. `READY` is derived only when all required receipts are current.

Receipt minimum fields are domain schema, outcome, observed-at/expiry, release/artifact IDs, hashed device/team scope where applicable, operation ID, verifier version, and safe evidence summary. Receipt TTL/invalidation is defined in code and tested with a fake clock. A downstream failure never rewrites an upstream receipt unless its inputs changed.

## Error contract

The stable namespaces are `VEYA-INTEGRITY`, `DEVICE`, `TRUST`, `APPLE`, `SIGNING`, `PROFILE`, `INSTALL`, `PAIRING`, `VPN`, `DEVSERVICE`, `RUNNER`, `RUNTIME`, `STATE`, and `UPDATE`. Each error envelope contains code, user summary, action enum, retryability, last verified phase, safe detail, correlation ID, and internal cause chain stored only in redacted logs. Passwords, 2FA, cookies, tokens, keys, profiles, pair records, PSKs, DDI personalization secrets, and raw device IDs are forbidden.

## Initial Trust implementation

Add ABI v2 functions to inspect pair state, invoke the pinned idevice `LockdownClient::pair_once`, poll, and validate a new Lockdown session. Select the device using the captured mux connection identity before pairing. Surface `WAITING_FOR_USER_TRUST` without manufacturing consent. Persist only through the upstream provider's protected mechanism. Timeouts/disconnects preserve all unrelated state; denial is terminal until explicit retry.

## Developer-support implementation

Call live developer-services readiness first. Only `DdiRequired` invokes a provider. The provider returns exact image/build manifest/trust cache plus source identity, source URL/service, signed metadata if available, hashes, license/rights policy ID, acquisition time, and supported build identity. Validate before cache commit and again before mount. The native bridge performs device query, Apple TSS, upload/mount, then proves CoreDeviceProxy, software tunnel, RSD, RemoteXPC, AppService, and launch feature.

Do not implement a doronz88 fallback. If V0 approves a mirror, encode it as a named provider with signed release metadata, pinned policy, outage/revocation behavior, and packaged notices; if rights/provenance cannot be approved, the product cannot make the zero-Xcode fresh-machine promise.

## Apple/sign/install implementation

Expose `ApplePersonalTeamService` methods for authorize/challenge/teams, reconcile identity, reconcile device/App IDs, and acquire profiles. Put GrandSlam/AuthKit/Developer Services request details in a versioned adapter with protocol-incompatibility detection. Read before create; reconcile after ambiguous network failure. Candidate keys/certificates/profiles are promoted only after a disposable codesign probe and signed-artifact validation.

Copy immutable release payloads to a protected workspace. Apply deterministic team App IDs, embed exact profiles, sign nested code from inside out, and validate code signatures, entitlements, team, UDID, dates, and bundle graph. Native InstallationProxy installs/upgrades the selected device; inventory proves exact versions/identities after the operation. Profile-trust pending is a user-action state, not an installation failure.

## Pairing implementation

Replace destructive repair with two slots. Generate unique request ID, bootstrap key, and nonce for every candidate. Bind envelope associated data and receipt to request ID, device, release/artifact, pair-record hash, and expiry. Phone writes candidate to a distinct Keychain label and returns an authenticated import receipt. Mac issues a fresh nonce challenge; phone proves possession of the candidate without revealing it. Then attempt the developer-service/RPPairing operation. Only after both proofs do both sides journal and atomically promote; old active state remains through a grace window. Abort deletes only candidate state.

## LocalDevVPN implementation

Keep `com.jkcoxson.LocalDevVPN` external unless V0 changes policy. Inventory bundle/version, emit an App Store/manual-install action when absent, launch by native AppService, write a request-bound phone inbox message, and resume it whenever the scene becomes active. Treat the Apple VPN prompt as explicit user consent. Require a cryptographically/request-bound application handshake at the expected endpoint plus a developer-service check; a listening socket alone is insufficient.

## Runtime READY implementation

After AppService launches the correct installed payload and pairing/VPN are operational, start the exact runner through retained RSD/TestManager. Require defined runner stages. Execute a bounded Rich location write with a test coordinate, obtain the strongest available acknowledgement/effect observation, clear location, and terminate/return the runner to the documented retained state. Any cleanup failure prevents READY. The receipt is scoped to device, release, runner/profile, pairing generation, and developer-service session and expires on disconnect/change.

The existing DriveScheduler, one location writer, 2 Hz smooth mode, 1 Hz fallback, Stop & Hold, Resume, Clear, destination hold, and no-backlog rules are invariants. The setup proof calls them through a narrow test hook; it does not redesign them.

## Release, migration, and legacy removal

The canonical assembler produces `Veya-<semver>-build<build>-<shortsha>.dmg` containing `Veya.app` and Applications alias. It inspects actual binaries, plists, schemas, payloads, signatures, source state, notarization, and mounted contents. It creates a draft release, downloads the artifact, repeats hash/audit, then promotes one immutable release. Universal binaries are claimed only if every required executable/library contains both slices; otherwise publish architecture-specific artifacts under an explicit ADR.

Remove `DevelopmentCLIEngine`, repo lookup, Xcode/devicectl/xcodebuild consumer routes, backend environment selectors, old release builder, and ambiguous helper fallback only at V16 after replacement gates. Keep schema-4 migration readers for the supported upgrade window. Rename IOSSim to Veya at V18 after state/Keychain/device-install migration is proven; bundle/signing ID changes require a separate explicit ADR.

## Testing and go/no-go

Unit tests cover pure state, cryptography, parsing, adapters, receipt invalidation, and failure classification. Integration tests use fake processes/device/Apple/Security/filesystems. Artifact tests mutate assembled apps/DMGs. Opt-in service tests use controlled accounts. Physical tests use the exact final signed/notarized download and are never replaced by source checks.

The complete gates are in [19_VANISH_INFORMED_ACCEPTANCE_GATES.md](19_VANISH_INFORMED_ACCEPTANCE_GATES.md). A future implementation agent starts with V0/V1, can implement V2–V5 while the DDI decision is pending, and must stop V6 at the provider interface if no approved source exists.

## Architecture verdict

`ARCHITECTURE_NOT_READY`

The design and file order are implementable, but the shipping zero-Xcode architecture lacks an approved developer-support asset source. Vanish demonstrates a third-party-mirror solution; it does not resolve Veya's provenance, licensing, and distribution decision.
