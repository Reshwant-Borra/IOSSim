# Veya Installation V2 Final Implementation Specification

Status: **READY_WITH_KNOWN_EXTERNAL_BLOCKERS**. Planning only. This document governs implementation; documents 00-31 provide algorithms, tables, and test detail.

## 1. Architecture

Veya Installation V2 is a reconciliation system, not a step list. The packaged `IOSSimProvisioner` is the sole mutating executor. Veya UI and `VeyaQualify` are typed clients. One actor, `VeyaReconciliationEngine`, observes all domains, derives desired product state, plans the smallest safe transition, executes one transition, proves it independently, re-observes, and repeats.

Swift owns orchestration, Apple policy, Security framework access, persistence, and user-safe errors. Rust owns low-level device protocols and in-process bundle signing behind one universal dylib. iOS owns authenticated inboxes and device-side runtime proof, never Mac setup truth.

## 2. Module boundaries

Required modules are ArtifactRelease, Reconciliation, Journal, AppleAuthorization, PersonalTeam, SigningKeyStore, InProcessSigner, CertificateReconciler, ProvisioningProfile, PayloadBuilder, DeviceTransport, ApplicationInstaller, DeveloperSupport, RemotePairing, LocalDevVPN, RuntimeReadiness, Migration, Diagnostics, and Qualification. Domain services perform bounded observe/mutate/prove operations and cannot advance global stages.

Current Apple parsers/SRP, certificate capacity parsing, native bridge, application management, DDI, pairing, VPN, Rich proof, redaction, and packaging integrity survive behind narrower interfaces. Current parallel coordinators/state stores and legacy signer are replaced.

## 3. State model

Core versioned `Codable & Sendable` values: `InstallationSnapshot`, `DesiredInstallationState`, `ReconciliationPlan`, `PlannedTransition`, `TransitionReceipt`, `Evidence`, `Generation`, `RunID`, `Lease`, `ResourceIdentity`, `ActiveCandidate<T>`, and `VeyaFailure`.

Evidence binds installation, team, device hash, payload/runner artifact, connection generation, and capture/expiry. External Apple/device truth is always re-observed. Cached stage/checkpoint values cannot manufacture capability.

## 4. Reconciliation algorithm

Acquire journal lease -> recover atomic state -> observe domains -> derive desired state -> pure-plan transitions -> persist start -> execute one -> persist receipt -> independently prove -> re-observe -> promote if generation/lease/evidence agree -> repeat. Retry is bounded and typed. Cancellation records candidate state and never promotes. Unknown ownership blocks destructive operations.

## 5. Transaction model

One JSON journal at `Application Support/Veya/installation/journal-v1.json` contains schema, revision, generation, lease, active/candidate resources, transition, evidence references, migration ledger, recovery marker, and last safe checkpoint. The provisioner is the only writer. Writes use locked same-directory temp file, `fsync`, atomic rename, directory `fsync`, reopen/verify. Event JSONL is diagnostic only.

Candidate B is created and validated while active A remains. Promotion atomically makes B active and A retiring; retirement is later/idempotent. Corruption triggers conservative read-only reconstruction, never inferred ownership or revocation.

## 6. Signing key store

Generate RSA-2048 in the packaged provisioner. Encrypt PKCS#8 with AES-256-GCM in a `0600` Veya file; AAD binds installation/key/public hash. Store a random per-installation wrapping key as a non-synchronizing, ThisDeviceOnly data-protection Keychain generic password. Access always sets authentication UI to fail.

The Keychain is only a wrapping-secret store. No SecKey/SecIdentity/certificate, search list, ACL, partition, or external process uses the key. Plaintext exists only briefly inside the provisioner/FFI call and is zeroized. Secure Enclave is incompatible with the RSA/exportable signer path. Packaged upgrade/no-prompt proof is a hard M4 gate.

## 7. In-process signer

Pin `isideload-apple-codesign = "=0.29.11"` (MPL-2.0) under Cargo.lock/checksum. Create `native/veya-signing-core`; export narrow C ABI through the existing universal bridge; call from Swift provisioner. Ship no signer CLI.

The signer inventories the full expected bundle graph, maps profile/allowlisted entitlements per provisioned executable, signs leaves then containers, embeds profiles where required, seals resources, and independently verifies every Mach-O/CMS/profile/entitlement/architecture. Do not use isideload's shallow signing shortcut. Golden nested fixtures and exact Veya payload physical install/launch are mandatory before routing production.

## 8. Certificate lifecycle

Match certificates to local keys by SPKI. Ownership levels progress from unknown through historical receipt to private-key control. Metadata/name never proves ownership. Prefer valid controlled matches; otherwise issue for a candidate key. On 7460, refresh inventory, select at most one controlled obsolete Veya certificate, revoke at most once, refresh, and retry issuance once. Unknown, unrelated, ambiguous, or another Mac's unproven certificate is never revoked.

Ambiguous issue response forces inventory/SPKI recovery before retry. Renew early with active retained. A second Mac uses a distinct installation/key and may receive a safe capacity user action.

## 9. Apple authorization

Authorization is independent of keys/certificates. Password/2FA are ephemeral and zeroized; only validated session material is stored in a separate data-protection Keychain service by the provisioner. Noninteractive lookup never falls back to Keychain UI. Sessions are live-validated and atomically replaced. The old IOSSim service is read-only migration input.

## 10. Provisioning

Profile candidates are accepted only when CMS, validity, team, certificate, device, bundle ID, and entitlements match desired state. Profiles expiring within policy are replaced as candidates. App ID/device registration and profile issue are distinct idempotent operations with Apple request evidence.

## 11. Installation

The coherent transaction is App ID -> profile -> immutable payload candidate -> entitlement derivation -> in-process sign -> independent verify -> stage -> InstallationProxy -> fresh inventory -> launch -> capability proof -> promotion. Install disconnect is ambiguous until inventory. Known-good prior signed payload is retained because iOS same-bundle replacement is not atomically rollbackable.

## 12. Device transport

One `DeviceTransport` facade wraps the pinned Rust `idevice` ABI for discovery, connection identity, Lockdown/Trust, info, inventory/install, AFC/House Arrest, developer image, RSD/RemoteXPC/AppService, and pairing. Stable UDID is identity; usbmux ID is ephemeral; reconnect increments connection generation. Rust owns protocol mechanics; Swift owns policy/evidence.

## 13. Developer support / DDI

Separate development and production providers. Production resolves exact OS build from a signed catalog/bundle/cache, downloads to quarantine, verifies provenance/hash/schema, personalizes via bound TSS evidence, mounts, and proves a developer service. No near-build fallback and no Xcode path in production. The future production source/SLA is a known external blocker; Build 12 may support only enumerated proven builds.

## 14. RemotePairing

Use active/candidate pairing. Encrypt candidate delivery to the exact phone payload; bind device, installation, generation, nonce, expiry, and one-time ID. Require phone receipt, possession challenge, and developer-service proof before promotion. Replay/wrong-device/crash leaves active intact. Pairing bytes never enter journal/logs/support bundles.

## 15. LocalDevVPN

Observe explicit `missing/installed/permissionRequired/configured/starting/running/endpointReady/failed` states. Only a Mac nonce challenge through the expected endpoint proves readiness. Apple's VPN approval is a legitimate user action. Restarts/reboots/network changes invalidate endpoint evidence and trigger re-observation, not destructive reconfiguration.

## 16. Runtime readiness

READY requires fresh proof of VPN endpoint -> software tunnel -> RSD -> RemoteXPC -> AppService -> exact runner -> TestManager -> XCTest -> bounded nonce Rich write -> independent observation -> clear -> cleanup. Evidence is generation/device/artifact/session-bound, expires quickly, and is invalidated on every relevant restart/resource change. Cached setup never yields READY.

## 17. Reinstall

Every reinstall observes external state and reuses valid resources. Missing metadata reconstructs from cryptographic/server evidence; missing key causes candidate replacement; stale profile renews; retained pairing/VPN is re-proven. Interruptions resume from candidates/idempotency. No uninstall/reset/revoke is used as generic repair.

## 18. IOSSim migration

Inventory old Application Support, auth/signing services, Veya/login Keychains, metadata, manifests, and pairing names read-only. Import an old key only if noninteractive export, SPKI/certificate/team agreement, and challenge proof succeed; otherwise create a candidate without ACL repair. Prove new payload/runtime, disable legacy writes permanently, then defer cleanup. Bundle-ID renaming is separated from signer migration.

## 19. Qualification harness

`VeyaQualify` exposes inspect, plan, reconcile, verify, scenario, and full commands with human/JSON output and stable exit classes. It drives the same packaged provisioner/engine. Capability manifests prevent unintended Apple/device mutation. Stage selection restricts the production planner; it is not an alternate engine. Resume re-observes journal state; safe cleanup only removes unreferenced run candidates.

## 20. Failure injection

Inject clocks, IDs, filesystem writer, Keychain, Apple transport, signer, device, DDI/TSS, pairing, VPN, and runtime boundaries. Production and test use the same planner/journal/promotion. Campaign covers auth expiry, 7460, ownership, missing/corrupt state, stale profile, sign/install/disconnect/lock, DDI/TSS, pair/VPN/AppService/Rich, and crashes around proof/promotion/journal writes.

## 21. Observability

Every operation emits stable schema with run/stage/operation/generation/attempt/lifecycle/result/error/retry/user action/subsystem/duration/evidence/time. The first failure is durable. Error namespaces are ART, STATE, AUTH, TEAM, KEY, CERT, PROFILE, SIGN, INSTALL, DEVICE, DDI, PAIR, VPN, RUNTIME, MIG, SEC. Secret-bearing raw errors are never logged.

## 22. Packaging

Before Build 12, prove universal binaries/bridge, internal load paths, resources/schemas/ABI, SBOM/provenance/MPL compliance, artifact identity, secret/static scans, and no release failure injection. Audit mounted bytes. Consumer runtime may not need repository, Python, Xcode/xcrun, Cargo/Rust/rustup, Homebrew, or developer tooling.

## 23. Security

Target removes brittle third-party SecKey authorization but makes private key bytes available briefly to Veya memory. Accept only with encrypted at-rest storage, provisioner-only access, zeroization, artifact/designated-requirement checks, no plaintext IPC, strict file controls, signer audit/fuzzing, and no insecure fallback. Pairing/auth/wrapping secrets are separate. Unknown certificate ownership fails closed.

## 24. Implementation milestones

M0 toolchain; M1 state/event/journal; M2 reconciliation; M3 production harness; M4 key store; M5 signer; M6 auth/team/certificate/profile; M7 profile-sign-install; M8 migration; M9 device/DDI/pair/VPN; M10 runtime proof; M11 packaging/legacy removal; M12 campaign; human gate; M13 Build 12; M14 physical qualification. Detailed binary gates and rollback are in doc 24.

## 25. Build 12 gate

All M0-M12 suites, real packaged no-prompt key store, exact payload signer install/launch, ownership/reinstall/migration/failure campaigns, universal/mounted/SBOM/secret/no-dependency audits, legacy removal, and zero known P0/P1 must pass in one commit-bound report. Required skips fail. A release owner must explicitly authorize Build 12.

## 26. Physical qualification

Qualify development and clean Apple Silicon, clean Intel, fresh/previous/migrated/reinstall states, Mac/iPhone reboot, available/full capacity, owned/unknown certs, second Mac, profile renewal, pairing/VPN recovery, spoof, and drive. Physical evidence remains scoped to tested Mac/iOS/account combinations.

## Final decisions

- Verdict: `READY_WITH_KNOWN_EXTERNAL_BLOCKERS`.
- Signer: Swift provisioner -> universal Rust ABI -> `veya-signing-core` using exact `isideload-apple-codesign 0.29.11`.
- First authorized implementation action: execute M0 only: add the pinned Rust toolchain and make repository tooling resolve rustup-managed Cargo, then produce a complete immutable baseline report. Do not touch production setup behavior in M0.
- External blockers: production DDI source/SLA, Apple private API drift, physically proven clean-Mac/Intel/second-Mac behavior, and M4/M5 proof gates. These do not block M0-M3 foundations.

## Updated design confidence

| Area | Confidence | Evidence still needed |
|---|---:|---|
| Architecture | 92% | implementation/model campaign |
| Signing | 74% | exact nested Veya fixture + physical install on both Mac arches |
| Apple provisioning | 80% | authorized live 2FA/7460/expiry/schema campaign |
| Reinstall | 78% | production-engine scenario campaign + physical clean reinstall |
| Installation | 74% | actual new-signer InstallationProxy/launch/rollback evidence |
| Pairing | 76% | encrypted delivery/reboot physical campaign |
| VPN | 65% | approval/restart/endpoint proof on clean devices |
| AppService | 68% | exact runner across supported iOS builds |
| Rich runtime | 67% | repeated write-observe-clear and drive campaign |
| Packaging | 72% | clean universal mounted artifact audit |
| Clean-Mac behavior | 55% | clean AS + Intel runs with no developer tools/stale state |

## Top implementation risks

1. Signer mishandles nested code/entitlements despite local verification.
2. Data-protection Keychain item changes access across signed app upgrades.
3. Apple auth/provisioning private APIs drift.
4. Production DDI source cannot cover a new exact iOS build.
5. Same-bundle failed install cannot reliably restore prior payload.
6. Legacy machines contain an unmodeled signing identifier/state combination.
7. Second-Mac capacity is safe but blocks automatic progress.
8. Intel-only ABI/dependency behavior escapes Apple Silicon CI.
9. Pairing/VPN receipts claim progress without end-to-end endpoint proof.
10. Test fixtures diverge from actual packaged composition or Apple/device responses.

