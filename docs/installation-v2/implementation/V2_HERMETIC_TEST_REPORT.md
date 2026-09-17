# V2 hermetic installer test report

Verdict: `PASS`

## Implemented

- Added a repository-contained hermetic installation harness with isolated roots for Application Support, provisioning state, artifact state, developer-support cache, pairing metadata, logs, support export, temporary signed artifacts, and the operation journal.
- Added in-memory/fake boundaries for device inspection, Apple provisioning, signing, developer support, installation, pairing, LocalDevVPN, runtime proof, and Keychain-like secret storage. The harness makes no phone, Apple service, production Keychain, or external filesystem access.
- Covered 26 named scenarios, including all V2-required fault cases and explicit crash/restart recovery. Two harnesses also run concurrently with independent state and secret stores.
- Made `SetupStore` state roots injectable: preferences and temporary workspace no longer require process-global `UserDefaults.standard` or the host temporary directory in tests.
- Converted all 34 `SetupStoreTests` to unique preference suites and repository-contained temporary roots.
- Repaired the consumer sequence fixture to implement the physical-reconciliation contract, including exact device/team/runner inventory. Runtime confirmation now remains fail-closed unless the reconciled install and runner mapping are valid.
- Corrected the route priority for the explicit developer-profile-trust checkpoint so it is not hidden by the generic incomplete-checkpoint route.

## Failure classification and cleanup

The safe package regression initially exposed 10 assertions across seven test cases. They were classified and resolved as follows:

- `BROKEN_FIXTURE`: the SetupStore consumer fake lacked `reconcileConsumerSetup`; the native pipeline fake claimed both apps were installed before an install; the pairing repair fake failed every validation rather than only the stale record.
- `TEST_ISOLATION_DEFECT`: two Apple authorization tests relied on the live default backend; one attempted a real request with synthetic credentials. Both now inject an explicit fake/unavailable backend.
- `SUPERSEDED_EXPECTATION`: tests expected AUTO/Xcode fallback even though the authoritative consumer default is native Personal Team and AUTO must not select headless Xcode; the support-note assertion expected older wording.
- `REAL_PRODUCT_DEFECT`: runtime confirmation accepted a manifest without requiring the physically reconciled exact runner mapping, and developer-profile trust routing occurred after a generic checkpoint route. Both were fixed in `SetupStore`.

No failing test was deleted, and no production behavior was weakened to satisfy a stale expectation.

## Evidence

- `HERMETIC_INTEGRATION`: `HermeticInstallationHarnessTests` — 3/3 passed.
- `UNIT` / `HERMETIC_INTEGRATION`: `SetupStoreTests` — 34/34 passed.
- Focused formerly failing set — 22/22 passed.
- Broad safe Swift package suite — 279 tests executed, 1 opt-in local-system probe skipped, 0 failures, 0 unexpected failures.
- Excluded by command-line filter: the six `NativeSigningIdentityIntegrationTests` and the one real-Keychain persistence test. Running them merely for V2 would mutate the user's Keychain and is prohibited by the test policy.
- `git diff --check` — passed.

All temporary roots used for this milestone were under `.build/iossim/` in the IOSSim workspace. No physical device, Apple account, provisioning account, phone installation, or real pairing state was touched.

## Acceptance gate

The setup state machine and required fault matrix can be exercised repeatedly in isolated state without a real phone, Apple account, production Keychain, or hidden configured-Mac state. The gate passes.

## Deferred

- The V2 harness supplies the service boundaries and scenario matrix; V4 will replace the deliberately small test journal with the production keyed state/lease implementation.
- Physical behavior remains unclaimed and belongs to V5–V13/V19.
