# Personal Team Automatic Refresh

## Current Policy

The production Mac app evaluates the earliest expiration across the main and
runner profiles. The recommended refresh threshold is 48 hours.

- more than 96 hours: current
- 48 to 96 hours: due soon
- 0 to 48 hours: refresh now
- expired: refresh required

The app checks on launch, displays profile status on the dashboard, and provides
**Refresh Now**. Automatic refresh is enabled by default and makes at most one
launch-time attempt when refresh is due. `ConsumerRefreshCoordinator` rejects
concurrent operations. There are no retry loops or automatic uninstalls.

## Refresh Operation

Refresh requires the remembered iPhone to be currently available and the saved
Personal Team to remain discoverable. It resolves the same deterministic IDs,
prepares and signs both artifacts, performs same-ID update installs, verifies the
main app and exactly one derived runner, rewrites the runner mapping, launches
the app, and updates the manifest.

The operation refuses to claim an in-place refresh unless the main app was
present before installation. It preserves app data, RPPairing state, and the
runner mapping by avoiding uninstall. Pairing is not regenerated.

After an update, the existing iPhone runtime may perform its narrow one-shot
session rebuild only for known stale RSD/TestManager failures. It retains the
same runtime architecture and does not alter Drive retry or fallback policy.

## Availability Limits

Automatic refresh is opportunistic, not guaranteed. It can run only while:

- the Mac app is running;
- Xcode and required Apple tooling are available;
- the Xcode-managed Personal Team and signing identity remain usable;
- the selected iPhone is connected/reachable, unlocked as required, paired, and
  in Developer Mode.

This phase intentionally does not install a LaunchAgent or background daemon.
Missed attempts remain visible as dashboard warnings and can be retried manually.

## True Renewal Status

Repeated re-sign/update/install with currently valid 7-day profiles is physically
proven. Xcode reused those profiles during immediate refresh tests. Actual
expiration extension from a newly issued profile is not yet physically proven.

To validate true renewal later:

1. Export or record the old main and runner profile identifiers and expiration
   dates from the IOSSim support bundle.
2. Wait until Xcode issues new profiles, then run **Refresh Now**.
3. Require each observed new expiration to be later than its old expiration.
4. Require the same Team ID, main ID, derived UI-test ID, and derived runner ID.
5. Verify app data, RPPairing state, and runner mapping are preserved.
6. On the iPhone verify Gate 3 reaches `FINISHED`, Rich XCUILocation works,
   normal Spoof works, and Rich Drive reports Rich / 2 Hz without unexpected
   fallback.

Do not mark true renewal validated unless `new expiration > old expiration` is
observed for the required profiles.
