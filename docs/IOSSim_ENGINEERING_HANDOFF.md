# IOSSim Engineering Handoff

## Read this first

IOSSim's current setup installs prebuilt iPhone payloads, completes pairing, opens external LocalDevVPN, verifies its existing endpoint probe, and then stops at `SETUP_READY_FOR_RUNTIME`. Retained RSD/TestManager/XCTest/XCUILocation/Spoof/Rich Drive remain frozen.

Repository safety: branch `work/final-no-xcode-setup-v1`, HEAD `1259da507ecded222022cc86bf82863c15640db9`, materially dirty. Never reset, clean, discard, merge, or delete untracked reports/support archives. Read `../CURRENT_WORKTREE_SNAPSHOT.md` before editing overlapping files.

## What is proven

- Current physical no-Xcode discovery and Lockdown: pass on iPhone18,1 / iOS 26.6.2. Raw usbmux currently exposes two endpoints for the same phone; Swift correctly selects one stable identity, though the diagnostic reports a non-blocking count mismatch.
- Saved-session auth, Personal Team, fresh native signing, same-ID force-upgrade through AFC/Installation Proxy, exact inventory, reconciliation, and profile trust: pass.
- Current source: typed developer readiness, conditional DDI, AppService, House Arrest semantic configuration, automatic pairing, phone inbox/receipt, LocalDevVPN setup receipt, schema-4 state, and support/provenance fields compile.
- POC checks: setup envelope/controller cleanup/expiry/receipt and runtime mapping pass.
- Rust bridge: check, 8 library tests, release build, and direct rustfmt check pass.
- Xcode 27.0/iPhoneOS SDK 27.0: exact Release main and payload-runner builds pass; prepared apps are arm64/iOS 17.0 and the main contains every required setup marker.
- Schema-2 artifact verification and the final app deep signature pass. Authoritative app: `.build/iossim/final-setup-payload-retest/IOSSim.app`, tree SHA-256 `8200221baab34c019c857449aabb6ec317586d2b4508c9607372c63bc563c65c` using `sha256_path`.
- The 16:07 schema-4 refresh physically passed external LocalDevVPN AppService launch and the existing `DeveloperRouteProbe` TCP check at `10.7.0.1:49152`, then persisted `SETUP_READY_FOR_RUNTIME`. No TestManager/XCTest/location operation started.

## Current blockers and physical evidence

- There is no blocker through `SETUP_READY_FOR_RUNTIME`; the user confirmed visible automatic foreground launch and the verdict is `FIRST_TIME_NO_XCODE_SETUP_PHYSICAL_PASS`.
- Build-machine configuration blocker is resolved. Xcode remains build-only and is not a consumer dependency.
- The earlier `APPSERVICE_UNAVAILABLE` condition is resolved; the complete typed readiness receipt is green. The device reported a developer image mounted and did not require DDI acquisition.
- Two integration fixes were required: AMFI Developer Mode inspection became advisory when live typed readiness succeeds, and explicit refresh now force-upgrades both same-ID owned payloads. Preserve both fixes.
- Old payload `bc339b3...` is stale/historical and rejected by the guard. Do not test it. No DMG was produced.
- Saved Apple session reuse and authenticated Personal Team provisioning are PHYSICAL_PASS. A completely fresh Apple login from zero state after the SRP fix remains `FINAL_CLEAN_INSTALL_RETEST_REQUIRED`.

## Key source changes in this payload task

- Added `AutomaticPairingInbox.swift` to the real Xcode main target Compile Sources phase.
- Made startup failure bounded and non-hammering.
- Added full controller cleanup/expiry checks and stronger delivered mapping validation.
- Added `IOSSimPayloadRunner` scheme excluding Location Witness.
- Added manifest capability versions, dirty-source fingerprint provenance, binary marker gate, and build-script fail-closed guard.
- Extended BuildProvenance/support schema 7 with separate GUI/helper/payload HEAD/dirty values.
- Made AMFI's Developer Mode status advisory while preserving the typed live readiness failure.
- Made explicit refresh force-upgrade both owned payloads so fresh bytes replace same-ID installed apps; repair remains component-scoped.
- Added a setup-only LocalDevVPN request/receipt gate that reuses the existing route probe and external app's own auto-connect/start behavior; missing/action-required states are typed prerequisites.

## Important references

- Current authoritative docs: this directory's `IOSSim_*` documents and `README.md`.
- Final setup architecture/report: repository root `FINAL_NO_XCODE_SETUP_ARCHITECTURE.md`, `FINAL_NO_XCODE_SETUP_IMPLEMENTATION_REPORT.md`.
- Historical investigations: root `NO_XCODE_*`, `SETUP_*`, `GPT_ASTRA_ARCHITECTURE_COMPLIANCE_AUDIT.md`.
- Final Astra research: `/Users/rishiborra/Desktop/VanishedResearch.mSgdHk/FINAL_PREIMPLEMENTATION/`, especially documents 05–07 and 10–13.
- Ingress graph: `../IPHONE_SETUP_INGRESS_CALL_GRAPH.md`.

## Resume commands

The build and setup are complete through readiness. The exact reproducible build/staging steps remain in `IOSSim_BUILD_AND_PACKAGING.md`; do not rebuild unless payload source changes. The completed focused build command was:

```bash
IOSSIM_MAC_BUILD_ROOT=".build/iossim/final-setup-payload-retest" \
IOSSIM_MAC_BUILD_VARIANT="FINAL_NO_XCODE_SETUP_PAYLOAD_RETEST" \
IOSSIM_DEVICE_ARTIFACTS_SOURCE=".build/iossim/self-contained/IOSSim.app/Contents/Resources/DeviceArtifacts" \
  macos/scripts/build_app.sh
```

For a setup-only recheck, use:

```bash
cd "/Users/rishiborra/Desktop/IOSSim"
./iossim device-debug
./iossim readiness-debug
pkill -x IOSSim 2>/dev/null || true
pkill -x IOSSimProvisioner 2>/dev/null || true
open -n "/Users/rishiborra/Desktop/IOSSim/.build/iossim/final-setup-payload-retest/IOSSim.app"
```

Generation 5 already verified the pairing receipt and recorded readiness. Do not start Spoof/Drive in a setup-only recheck. The next authorized engineering task is runtime startup + Spoof + Rich Drive regression.

## Do not redesign

Preserve discovery, Lockdown, native Apple auth/Personal Team/signing, AFC/Installation Proxy, deterministic IDs, physical reconciliation, LocalDevVPN, RPPairing semantic format, retained RSD/TestManager, runner/XCUILocation, location coordinator/transports, 2 Hz/1 Hz behavior, pause/resume/hold/clear, destination hold, and single-writer/generation semantics.

The next task after a physical setup pass is runtime startup + Spoof + Rich Drive regression, not another setup architecture project.
