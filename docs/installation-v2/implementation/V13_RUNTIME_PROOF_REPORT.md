# V13 real Rich runtime proof report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Replaced the `consumer-runtime-ready` checkpoint shortcut with a live, cross-process bounded proof. Stored setup state alone now throws `VEYA-RUNTIME-001` and cannot assert READY.
- Added a schema-1 request/receipt protocol over the existing app-private House Arrest setup inbox. It binds device, team, release, artifact set, profile set, pairing generation, developer-support identity, developer-services session, exact runner bundle, request ID, and timestamps.
- Reused the existing retained RSD/TestManager/XCTest implementation and the existing single `LocationCoordinator`; no second writer or runtime architecture was introduced.
- The phone setup controller connects through the current LocalDevVPN/RPPairing path, launches only the dedicated Gate-1 Rich XCTest, and requires observed stages for TestManager control, runner launch, XCTest handshake, test-plan start, and successful finish.
- The Gate-1 XCTest performs one harmless Rich `XCUILocation` write and strongest available witness observation. It now explicitly resets `XCUIDevice.shared.location` in `defer`.
- After the test, the setup controller stops the XCTest handle and calls the authoritative location coordinator with `clearLocation: true`. A receipt cannot be ready unless both location clear and session cleanup succeed.
- READY receipts are persisted owner-only and are revalidated against the current manifest. Release, installed runner/artifact set, or profile-set changes automatically demote stored READY to `NEEDS_ATTENTION`.
- Added `richRuntimeProofInbox: 1` to the required payload capability contract and corrected setup UI copy to describe the bounded proof without implying a Drive route.

## Acceptance evidence

- Focused runtime/state/artifact suite: 13 tests passed, zero failures.
- Dedicated Rich readiness tests cover full bound success, missing stage, cleanup failure, pairing-generation change, exact app activation, wrong/missing receipt, and bounded polling timeout.
- iPhone `POCUnitChecks` passed, including the receipt schema/context/cleanup fixture.
- Unsigned generic iOS-device app build succeeded with the new inbox compiled and linked into the real target.
- Broad safe macOS suite executed 342 tests with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected.
- Six artifact-identity tests, no-Xcode runtime/routing audits, and `git diff --check` passed.

## Preserved runtime invariants

- One `LocationCoordinator` remains the location writer owner.
- The setup proof starts no Drive scheduler and produces no route points.
- Rich/default transport, retained RSD, existing XCTest runner, Stop & Hold, Resume, Clear, destination hold, 2 Hz smooth Drive, 1 Hz fallback, and no-backlog behavior were not redesigned.
- The only Rich test selected in setup mode is `testGate1NoXcodebuildRichLocationWitnessProof`; unrelated UI tests are skipped by the existing environment gate.

## Physical validation deferred

- Full request delivery, scene activation, retained RSD, TestManager control/main sessions, exact installed runner metadata, XCTest handshake, witness callback, location reset, and cleanup on a supported physical iPhone.
- Failure injection for disconnect during test, phone termination, Mac termination, stale RSD recovery, clear failure, and retry after restart.
- Verification that no simulated location remains in the system after success and every failure boundary.

## Known limitations

- The strongest safe observation remains the existing witness XCTest assertion plus a successful XCTest finished callback; Veya does not expose or persist raw witness location data in the setup receipt.
- Physical proof is intentionally not inferred from successful compilation or hermetic callback fixtures.
- Live dependency reconciliation after reboot/upgrade is extended in V14.

## Gate

READY cannot be reached from stored state, DDI, RSD, or AppService alone. It requires a current bound receipt for exact runner/TestManager/XCTest/Rich location execution followed by location clear and session cleanup. Physical end-to-end proof remains required.
