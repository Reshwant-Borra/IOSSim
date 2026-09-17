# V16 legacy removal report

Verdict: `PASS`

## Removed from the packaged consumer path

- `IOSSIM_PROVISIONING_BACKEND` can no longer select Xcode, invisible Xcode, or any other backend when `IOSSIM_BUNDLED_ENGINE` is compiled. Packaged selection is unconditionally native Personal Team.
- `IOSSIM_DEVICE_BACKEND` can no longer select devicectl in a packaged build. Packaged device discovery and mutation are unconditionally routed through the bundled native idevice bridge.
- `DevelopmentCLIEngine` remains compiled out under `IOSSIM_BUNDLED_ENGINE` and is absent from the packaged GUI composition.
- SetupStore and the bundled consumer helper continue to reject legacy signing backends and never route a failed native operation into devicectl, xcodebuild, repository lookup, or a Python CLI.

## Intentionally retained

- `DevelopmentCLIEngine` in non-bundled developer builds for explicit repository development and diagnostics.
- Devicectl discovery/install implementations for developer-only parity comparison and physical rollback evidence; compile-time packaged selection cannot reach them.
- Explicit Xcode provisioning/signing branches for development/recovery comparison until physical native renewal parity and a rollback release are qualified.
- Xcode/xcodebuild in payload and release build tooling; this is a build-machine dependency, not a consumer dependency.
- Schema 1–4 readers and digest migration for upgrade continuity.
- Legacy singleton-to-keyed state importer, guarded by exact device/team identity.

## Acceptance evidence

- A dedicated `IOSSIM_BUNDLED_ENGINE` compilation/test proved that `XCODE_FALLBACK` and `devicectl` environment requests still resolve to native Personal Team and idevice.
- The development CLI test target is excluded in packaged compilation, matching the production source guard.
- No-Xcode consumer audit passed every invariant, including the new compile-time backend locks.
- Native install-routing audit passed and found no consumer devicectl fallback.
- Broad safe macOS suite: 353 tests executed, 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected. Full output is retained in `v16-swift-test.log`.
- `git diff --check` passed.

## Gate

The packaged consumer has one authoritative setup/device route. Retained legacy implementations are unreachable in that compile mode and remain only where deletion would precede physical parity, migration-window expiry, or build-tool replacement evidence.
