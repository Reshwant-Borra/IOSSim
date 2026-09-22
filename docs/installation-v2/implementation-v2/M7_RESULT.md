# M7 Result — Profile/Sign/Install Transaction

Status: **SOFTWARE_GATE_PASS (engine + scripted boundaries + exact-payload plan/rewrite integration) / PHYSICAL_BLOCKED_HUMAN**.

Continuation (2026-09-21): production integration done — see "Production integration".

## Implemented (`Installation/PayloadTransaction.swift`)

- `.payload` domain: an immutable same-volume copy of the shipped source is taken into `staging/<generation>/source`, signed through `PayloadSigning` (production: `InProcessPayloadSigning` → packaged Rust signer + `withUnlockedPKCS8`) into `staging/<generation>/<App>.app`, and then removed. The candidate digest is the signer's output inventory. Proof is independent re-verification whose inventory must equal that digest. An active payload whose binding (source graph, certificate chain, profiles, entitlements, key, team) changed is `stale` and is re-signed as a candidate.
- `.application` domain: installs the **active** signed payload through the existing `NativeApplicationManager` path and proves it by fresh device inventory, bound to the connection generation. A re-signed payload makes the installed app `stale`. A device that lost the app is `invalid` and is reinstalled from the active payload. The known-good app is never uninstalled.
- Prerequisite failures (for example certificate capacity) block with the stable code and perform no signing or install.

## Defect found and fixed (P1, correctness, affects Build 11 route too)

`NativeApplicationManager.installOrUpgradeReceipt` accepted "inventory shows bundle/version/team" as proof
after a lost install response. For a certificate/profile **renewal** the re-signed payload has the same
version as the app already installed, so a failed install was reported as success and the app was left
signed with the expiring profile. iOS inventory does not expose the signature. Fix: an interrupted response
is reconciled by inventory only when nothing matching was installed before the call. Otherwise the error
stands and the retry reinstalls, which is idempotent. Regression test fails without the fix (verified by revert).

## Tests (`PayloadTransactionTests`, 8/0; existing install-manager tests 11/0)

Happy path with idempotent rerun; signing failure (nothing created, staging clean); verification failure,
install failure, and wrong-version install each preserve the active payload/app; interrupted response on a
fresh device reconciled without reinstall; disconnect between install and proof resumed on a new connection
generation with idempotent reinstall; device lost app → reinstall; renewal lost-response regression;
prerequisite failure blocks without mutation.

Boundaries in these tests are SIMULATED (scripted signer and device). The real signer's positive path is
INTEGRATION_PROVEN in `veya-signing-core` (M5).

## Production integration (continuation)

Seams found between the M5 signer, the M7 transaction and the shipped payload, all fixed:

| ID | Class | Finding | Fix / evidence |
|---|---|---|---|
| M7-C1 | P1 functional | `.payload` signed one bundle; Veya ships two (main app + XCTest runner with nested `.xctest`). `.application` installed one. | `PayloadSigningPlan.Component` per bundle; one record digest over all outputs; both installed in role order and both required by proof. `testMainAndRunnerAreSignedInstalledInOrderAndBothRequiredForProof`. |
| M7-C2 | P1 functional | The per-team bundle-identifier rewrite (main, runner, nested `.xctest`, `IOSSimGate3RunnerBundleIdentifier`) done by the legacy provisioner was missing, so the signed payload could never match the team's profiles. | `infoPlistRewrites` applied to the staged copy only; the rewritten graph must have exactly the pristine signable nodes and the planned root identifier, else `VEYA-SIGN-026` before signing. Tests: rewrite applied to staging only; graph change and unplanned root refused with 0 signs. |
| M7-C3 | P1 functional (M5×M7 seam) | Copying profile grants verbatim would request `keychain-access-groups = TEAM.*`; the Rust signer refuses wildcard requests (`grants_are_exact_or_scoped_wildcards…`), so every real Personal Team signing would fail. | Exact, Xcode-equivalent requests (`TEAM.bundle`), matching the physically validated Xcode build's `Entitlements.plist`; signer re-checks grants. |
| M7-C4 | P3 observability | Every signer error surfaced as bare `VEYA-SIGN-021`. | Signer category code carried in `underlyingSubsystem` (`veya-signing-core/VEYA-SIGN-REQUEST`), never paths or messages. |
| M7-C5 | P3 disk | Discarded/retired `staging/`, `profiles/`, `certificates/` content was never collected. | Lease-held collector removes only entries no active/candidate/retained-retiring record references. `testUnreferencedStagingIsCollected…`. |

`ShippedPayloadPlanProvider` builds the plan from the hash-verified `DeviceArtifacts` manifest (`ShippedPayload`, also
the new `.artifact` domain) and the journal's active key, certificate and profiles — purely local.

`ShippedPayloadIntegrationTests` (exact installed Build 11 payload, real Rust signer, simulated Apple key/cert/profiles):
plan has both bundles with team-derived identifiers and exact entitlements; the rewrite of the real bundles is
approved; the signer then refuses the non-Apple CMS profile at request validation (`VEYA-SIGN-REQUEST`), nothing is
published, staging is empty, and the shipped source still verifies against its manifest. Rust exact-payload sign +
Apple strict verify remains 1/0 on arm64 and x86_64.

Tests: `PayloadTransactionTests` 13/0 (was 8), `ShippedPayloadIntegrationTests` 1/0.

## Not done / blocked

- Launch plus capability proof before promotion is M10.
- Rollback reinstall of the previous signed artifact after a replaced-then-failed launch is not implemented; the spec allows "recovery-required" reporting.
- Physical install: BLOCKED_HUMAN.
