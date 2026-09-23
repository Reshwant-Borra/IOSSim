# Setup completion by the user's Run Setup tap — 2026-09-22

Development qualification only. M4 stays **DEFERRED**, distribution/notarization stays deferred.
Physically proven end to end on 2026-09-22 (see "Physical test").

## What changed

Setup completion used to be proved by a Mac-requested on-device run that drove the DVT path *and*
the Rich Drive XCTest runner. It is now the result of the **user's own Run Setup tap** in the
installed app, recorded as a receipt Veya reads.

```
INSTALL → VPN → AUTOMATIC PAIRING DELIVERY
   → Veya writes run-setup.request, proves developer services (DDI), waits
   → "ACTION REQUIRED: Open Veya on your iPhone and tap Run Setup."
   → user taps Run Setup (the existing button, the real product path)
   → phone writes run-setup.receipt
   → Veya validates it → runtime satisfied → READY
   → a failed run reports the phone's own error and never satisfies setup
```

Veya never presses Run Setup. It writes a request file and reads a receipt file; the coordinator
has no launch call at all (`RunSetupReadinessTests.testVeyaAsksAndWaitsWithoutEverStartingTheRunItself`).

## Traced before changing (unchanged behaviour)

- **Automatic pairing delivery** (physically proven, preserved): `ProductionDeviceDomains.pairing.prepare`
  → `RemotePairingCoordinator.prepareAutomatically` → House Arrest/AFC writes into
  `Library/Application Support/IOSSim/SetupInbox/` (request → bootstrap → AES-GCM envelope →
  candidate receipt → HMAC possession challenge → developer-services proof → promote → operational
  receipt). The phone stores the record in the Keychain (`com.iossim.on-device-dvt-poc.rppairing`,
  account `primary`, `AfterFirstUnlockThisDeviceOnly`). Not modified by this change.
- **Run Setup** (`SetupView` → `ConnectionStatusModel.runSetup` → `OnDeviceDVTExperimentRunner`):
  pairing summary → `DeveloperRouteProbe` (TCP `10.7.0.1:49152`) → `connect()` →
  `tunnel_create_rppairing` (TLS-PSK over LocalDevVPN) → `remote_server_connect_rsd`
  (`com.apple.instruments.dtservicehub`) → DeviceInfo round-trip → `location_simulation_new`.
- **DDI**: required by Run Setup itself, not only by verification — `dtservicehub` exists over RSD
  only while a personalized DDI is mounted. The DDI dependency is preserved: the prover still runs
  `developerServices.prepare` before asking the user to tap.
- **XCTest**: `XCTestRichDriveLocationTransport` (default Drive mode) still launches the runner
  through `com.apple.dt.testmanagerd.remote`. Product XCTest is untouched; only the READY-time
  XCTest run is no longer requested.

## Why the tap alone was not enough

Run Setup reports PASS once the LocationSimulation channel opens. It never delivered a coordinate,
and `ensureConnected` returns early on a cached session state, so a repeat tap could pass without
touching the device. When (and only when) it answers a Veya request, the run now also does
`setTestLocationAndVerify()` (Core Location must observe the coordinate with
`isSimulatedBySoftware == true`) and `clear()`. Product paths (`ensureReady`) are unchanged.

## Files

| File | Change |
|---|---|
| `ios/Sources/IOSSimOnDeviceDVTPOC/RunSetupInbox.swift` | new: request/receipt/outcome, pairing identity, sanitised error, receipt written `completeFileProtectionUntilFirstUserAuthentication` |
| `ios/App/Shared/ConnectionStatusModel.swift` | `runSetup(answeringVeyaRequest:)`, verify/clear, receipt, request watcher |
| `ios/App/SetupView.swift` | waiting banner; button answers the request; pairing copy now says Veya delivers it |
| `ios/App/RootTabView.swift` | presents Setup when a request is pending (shows the button, never taps it) |
| `ios/App/IOSSimOnDeviceDVTPOCApp.swift` | watcher task; legacy Rich proof task kept, now inert |
| `ios/IOSSimOnDevicePOC.xcodeproj/project.pbxproj` | new source in the app target |
| `macos/.../Services/RunSetupReadiness.swift` | new: request/receipt, binding, `RunSetupFailure`, `RunSetupProgress`, coordinator |
| `macos/.../Installation/DeviceProductionAdapters.swift` | `JournalRuntimeProver` asks, proves developer services, waits |
| `macos/.../Installation/RuntimeReadiness.swift` | `runSetupRequired` (VEYA-RUNTIME-011), `runSetupFailed` (VEYA-RUNTIME-012) |
| `macos/.../Installation/ProductionComposition.swift`, `DevelopmentInstallationSession.swift`, `IOSSimMac/Views/DevelopmentInstallationView.swift` | progress callback so the instruction shows while Veya waits |
| `scripts/bootstrap/iossim_cli.py` | payload capability guards for the new receipt path; newly packaged payloads declare `runSetupInbox: 1` |

Kept deliberately: `RichRuntimeReadinessCoordinator`, `RichRuntimeProofInbox`, the provisioner's
diagnostic command, and manual pairing import.

## Receipt binding (what can never satisfy setup)

Request ID, device UDID hash, team, release identity, installed main bundle ID, and the pairing
identifier + `SHA256(public_key)` of the record Veya delivered; `completedAt` must not precede the
request. Every stage must be true: pairing, LocalDevVPN, endpoint, session, **location verified**,
**location cleared**, and no error code.

## Tests

- macOS `RunSetupReadinessTests` (4): waits without launching; the tap satisfies; a failed run keeps
  the real error and never satisfies; only a fully bound receipt satisfies (stale request, another
  device, another app, foreign pairing, unverified/uncleared location, VPN down).
- macOS `RuntimeReadinessTests.testUntappedRunSetupIsAUserActionAndTheTapReachesReady`.
- iOS `POCUnitChecks`: request binding/expiry; success retires the request and reports the pairing
  identity; failure keeps the request, preserves the code, sanitises the message, and an unverified
  location is never success.
- `./iossim installation-baseline --defer-m4`: **Overall PASS** (macOS Swift tests, iOS shared unit
  checks, Rust, secret scan, legacy guard; M4 DEFERRED).
- Pre-existing and unrelated: `swift test` alone fails 4 `SigningKeyStoreTests` cases on a clean
  tree too (Keychain wrapping unavailable, M4).

## Follow-up (deliberately out of scope)

1. **Runtime TTL vs setup completion.** The runtime evidence still expires after 600 s and is bound
   to `connectionGeneration`, so a later Install / Resume can ask for another tap. `connectionGeneration`
   is an in-memory counter bumped by every `listDevices()` and reset when Veya relaunches, so the TTL
   is currently what stops a stale proof reading as current. Splitting durable "setup complete" from
   ephemeral runtime health needs both changed together.
2. **First Rich Drive after setup** now carries the iOS automation approval. On refusal the existing
   per-session fallback reports "Rich Drive unavailable. Using DVT Compatibility."
3. **Require `runSetupInbox` in the payload manifest.** New payloads declare it, but
   `ArtifactManifest.currentPayloadCapabilities` does not require it yet: raising the bar now rejects
   every payload built before this change (observed physically — the installed `/Applications/Veya.app`
   made `ProductionWiringTests` fail until the requirement was withdrawn). Raise it with the first
   rebuilt-and-installed payload, so an old payload that can never answer the request fails fast
   instead of leaving the user tapping.
4. **Production helper path** has no progress callback, so the instruction appears there only after
   the wait ends. The development app (used for physical runs) shows it live.

## Artifacts built for the physical run (2026-09-22, commit `272201b`, clean tree)

- iPhone payload: `.build/iossim/self-contained/IOSSim.app/Contents/Resources/DeviceArtifacts`
  (`payloadSourceHead 272201bcfbe9`, `payloadSourceDirty false`; `payloadCapabilities.runSetupInbox = 1`;
  main binary carries `RunSetupInbox`, `run-setup.request`, `run-setup.receipt`, `locationVerified`,
  and still `AutomaticPairingInboxController`). Components: `IOSSim DVT POC.app` (`dd8609d732f6`),
  `IOSSimLocationControlUITests-Runner.app` (`233341ded42b`).
- Development Mac app: `.build/iossim/development-session/Veya Development.app`
  (`com.veya.development-session`, debug, ad-hoc signed, universal bridge arm64 + x86_64; carries the
  `run-setup.request`/`receipt` paths and the waiting instruction string).

`./iossim package-app` reports one unrelated FAIL on this Mac: `ARTIFACT_IDENTITY_MISMATCH:
architectures macApp/provisioner expected [arm64, x86_64], actual [arm64]`. It is structural, not
caused by this change — `build_self_contained_macos_products` builds host-arch products while
`audit_app` expects the universal ones that only `release`/`release-local` produce. The iPhone
payload passed every capability, bundle-identity and hygiene check in that same run.

## Physical test — PASSED

Performed 2026-09-22 22:17–22:20 on the physical iPhone. Install / Prepare → VPN prerequisite →
install → automatic pairing → READY FOR SETUP → the user's own Run Setup tap → Continue / Verify
Setup → READY, with no further automation and no manual pairing import.

Two changes were needed first and are recorded in
[`PHYSICAL_E2E_CHECKPOINT_2026-09-22.md`](PHYSICAL_E2E_CHECKPOINT_2026-09-22.md): the journal
candidate deadlock that made the first attempt fail with `VEYA-SEC-003`, and the shift from the
five-minute in-run wait to Prepare → tap → Continue (pending-request reuse, single-read verification,
and a freshness guard that accepts a tap which legitimately precedes Continue). Follow-up 1 below is
unchanged; follow-ups 3 and 4 still stand.
