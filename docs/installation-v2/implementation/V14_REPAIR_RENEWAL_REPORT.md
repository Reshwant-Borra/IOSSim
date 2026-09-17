# V14 repair, resume, and renewal report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Added an ordered, typed smallest-repair policy spanning device access, Apple authorization, signing renewal, owned-app install/upgrade, developer support, pairing, LocalDevVPN, and bounded Rich runtime proof.
- Recovery selects only the earliest invalid prerequisite. It does not replay later setup domains until their dependencies are current.
- Physical reconciliation now derives the current payload version from the bundled app's actual `Info.plist`, compares the current provisioner schema/version, evaluates the 48-hour profile refresh window, and checks exact main/runner inventory.
- Near-expiry or expired signing state routes through `.refresh`; a release identity change also routes through refresh/upgrade. A missing main or runner continues to use `.repair` and installs only that missing owned component.
- Every setup-start, retry, or reconnect reconciliation demotes stored runtime READY to `NEEDS_ATTENTION`. The prior receipt remains evidence but cannot survive a potentially new CoreDevice/RSD session as current readiness.
- Persisted pairing/final checkpoints remain hints: exact inventory and House Arrest mapping are rechecked, then pairing, LocalDevVPN, developer services, and Rich runtime readiness are re-established in dependency order.
- Corrected the V13 setup boundary so completion of pairing/VPN marks runtime setup `USER_ACTION_REQUIRED`, never READY before the bounded Rich proof.
- Existing candidate signing lifecycle, transactional pairing promotion, keyed state lease/journal, and explicit destructive Fresh Install operation remain unchanged.

## Acceptance evidence

- Focused repair-policy suite: 10/10 passed.
- Focused reconciliation regressions: pending developer trust never reinstalls; manual main deletion repairs only main; both passed.
- New integration fixtures prove near-expiry profiles select `RENEW_SIGNING` and stale actual release identity selects `REINSTALL_OWNED_ARTIFACTS`.
- Broad safe macOS suite: 349 tests executed, 9 explicit opt-in/local-system/physical skips, 0 failures, 0 unexpected. Full output is retained in `v14-swift-test.log`.
- No-Xcode consumer runtime and install-routing audits passed.
- Six artifact-identity tests passed.
- `git diff --check` passed.

## Scenario coverage

- Profile expiry/near-expiry: refresh candidate path.
- Certificate/profile invalidity or revocation surfaced by the adapter/artifact store: typed refresh failure without deleting the active candidate predecessor.
- Missing main, runner, or both: exact owned-component repair scope.
- Pairing stale, LocalDevVPN stopped/approval pending, developer support stale, and runtime proof stale: independent ordered recovery domains.
- Release upgrade, app restart, Mac/iPhone reconnect, and crash journal recovery: persisted hints are reconciled against live state.
- Apple session expiry: typed user reauthorization precedes downstream mutation.

## Physical validation deferred

- Renewal against a live Personal Team, including Apple-session expiry and certificate revocation.
- Mac reboot and iPhone reboot with fresh CoreDevice/RSD sessions.
- Real missing-app reinstall, release upgrade, stale DDI cache recovery, stopped LocalDevVPN, stale pairing, and interrupted install on a supported phone.
- Confirmation that a failed smallest repair leaves every unrelated valid physical resource operational.

## Gate

Automated reconciliation is prerequisite-based and non-destructive, current state is derived from actual payload and live inventory evidence, and stored READY is invalidated across live-session boundaries. Physical renewal and reboot behavior remains required.
