# V12 developer-services and AppService proof report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Split native transport readiness from operational setup readiness. CoreDeviceProxy, software tunnel, RSD, RemoteXPC, AppService connection, and advertised launch capability are now `transportReady`; they cannot by themselves produce an operational receipt.
- Added schema-2 developer-services receipts that bind the exact device UDID hash, usbmux ID, connection type and generation, developer-support identity, pairing generation when available, release identity, fresh session/attempt UUID, observation timestamp, exact target bundle identifier, and AppService launch result.
- Required a real `launchapplication` call for the exact installed runner bundle before the coordinator returns ready. The Rust bridge launch payload now identifies the requested bundle and confirms AppService connection in addition to process identifiers.
- Added five-minute freshness enforcement and future-clock tolerance. Receipts from a different release, pairing generation, connection generation, device, or target bundle fail `isCurrent`.
- Bound the pre-pair setup probe to the current release and exact runner. Bound the RemotePairing operational proof to the candidate pairing generation/release and the team-derived exact runner bundle.
- Kept mounted-DDI state as one field rather than treating it as final readiness. Exact iOS build plus artifact identity/hash is recorded after acquisition; an already-operational device is classified against its current build/service map.
- Added `developerServicesReceiptSchema = 2` to generated and direct-build provenance.

## Acceptance evidence

- Focused Swift native-device and pairing suites: 28 tests passed, zero failures.
- New tests prove that transport/service-map success alone is not operational readiness, exact target launch is required, stale connection/release receipts fail, wrong-app receipts fail, and receipt age is bounded.
- Rust native bridge suite: 11 tests passed, including exact AppService target serialization and unchanged ABI/status-layout assertions.
- Broad safe macOS suite executed 338 tests with 9 explicit opt-in/local-system/physical skips, zero failures, zero unexpected.
- Optimized native bridge rebuilt successfully from current Rust source.
- no-Xcode consumer runtime/routing audits and `git diff --check` passed.

## Readiness semantics

`DDI mounted` is not READY. `RSD connected` is not READY. `AppService listed` is not READY. V12 readiness requires a fresh exact-context AppService connection and successful launch receipt for the expected runner. V13 remains responsible for attaching TestManager/XCTest and executing the bounded Rich XCUILocation probe.

## Physical validation deferred

- Personalized developer support, software tunnel, RSD/RemoteXPC, AppService connection, and exact runner launch on a supported physical iPhone.
- Process identifier semantics across supported iOS builds.
- Rejection of stale receipts after real USB/network reconnection, pairing rotation, iOS update, and release upgrade.
- Real profile-trust and Developer Mode error mapping from the exact runner launch.

## Known limitations

- The session identifier binds one bounded coordinator attempt; live native socket objects are intentionally not persisted across the FFI boundary.
- An already-operational service map identifies developer support by current iOS build plus active service-map classification because no distributable Apple asset identity is exposed by that path. Fresh acquisition receipts include the selected build identity and image hash.
- TestManager/XCTest control and a harmless location write/clear are deliberately not claimed here; they are the V13 gate.

## Gate

AppService launch is independently represented and testable, and no transport-only state can satisfy operational readiness. Physical device launch remains required.
