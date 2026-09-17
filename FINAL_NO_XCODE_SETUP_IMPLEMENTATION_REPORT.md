# Final No-Xcode Setup Implementation Report

Date: 2026-09-15  
Branch: `work/final-no-xcode-setup-v1`  
Baseline HEAD: `1259da507ecded222022cc86bf82863c15640db9`

## Result

The three remaining systems are integrated in the existing bundled provisioning/reconciliation architecture at source level. No runtime, spoof, or drive path was started or redesigned. This pass is not a physical pass: no iPhone was connected, the exact-build DDI requirement is not yet known, no approved DDI asset/provider exists on this Mac, and the available prebuilt iPhone payload predates the automatic-pairing startup ingress.

## What existed and was reused

- Physically proven native usbmux discovery, Lockdown inspection, AFC staging, Installation Proxy install/inventory, Personal Team provisioning/signing, deterministic bundle identities, and component-scoped repair.
- Pinned idevice revision `1838db107d38701b4044361163aac049006c2627` and static C ABI.
- Rust AppService launch, MobileImageMounter/TSS calls, House Arrest read/write, and RemotePairing create/validate exports.
- Astra scaffolds for developer support, native application management, Mac Keychain pairing, AES-GCM envelope, and phone Keychain import.
- The existing phone runtime pairing plist and Keychain contract.

## What was missing

- AppService collapsed service/application “not found” into physical `deviceNotFound`.
- No production developer-service coordinator or typed proxy/tunnel/RSD/RemoteXPC/AppService probe preceded launch.
- DDI code was not composed and its production source was undefined.
- The native JSON runtime mapping writer was unused; setup relied on an older preferences readback.
- RemotePairing was test scaffolding: no phone bootstrap lifecycle/startup hook, production composition, receipt polling, or targeted repair.
- Schema 2 ended setup after runtime mapping and could show completion before pairing.
- Support provenance and diagnostics lacked final setup domains.

## Implemented

- Stage-specific native status codes and a developer-services readiness receipt; `ServiceNotFound` is distinct from physical device resolution.
- A single `NativeDeveloperServicesCoordinator` composed with the shared transport and AppService/container service.
- Conditional exact-build DDI selection, mandatory hashes/trust cache, IOSSim Application Support cache root, in-bridge TSS/mount, and fail-closed no-approved-source behavior.
- Exact current team-derived AppService bundle launch after readiness.
- Idempotent schema-1 runtime mapping and semantic native House Arrest/AFC readback; the phone resolver consumes it with compatibility fallback.
- Device/team-scoped Mac Keychain pairing, strict runtime-plist validation, native reuse validation, targeted rotation, encrypted House Arrest delivery, phone bootstrap/import/receipt, and delivery-only repair.
- Schema 3 checkpoints `REMOTE_PAIRING_VERIFIED` and `SETUP_READY_FOR_RUNTIME`; restart/reconnect rederive final state only after live developer-service and receipt checks.
- Consumer-facing stage names, safe per-domain support fields, backend/provenance values, and regression/unit checks.
- Rust House Arrest errors now carry `house_arrest_write`/`house_arrest_read` context and distinguish an unavailable container service.
- One ad-hoc signed retest app was packaged at `.build/iossim/final-setup-retest/IOSSim.app` with tree SHA-256 `1ccf5d0ae9fcce9e53968b32817f5768c6c933677eef1a09347d45c7a9745b0f`. Its provenance truthfully records `SOURCE_DIRTY=true` and payload source `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`.

## Intentionally unchanged

The discovery and installation backends, Apple authentication, Personal Team signing, prebuilt-payload model, deterministic identifiers, and all LocalDevVPN/TestManager/XCTest/XCUILocation/location/drive components were not redesigned. Manual pairing tooling may remain as diagnostic recovery but is not the production onboarding composition.

## Evidence and validation

- macOS `swift build`: pass.
- iOS package `swift build`: pass.
- `swift run POCUnitChecks`: pass, including automatic pairing envelope/receipt and delivered runtime mapping.
- Rust `cargo test --lib`: 8 passed, including ABI statuses and `ServiceNotFound` regression.
- Rust release bridge build: pass.
- no-Xcode consumer static routing check: pass.
- native install routing check: pass.
- device discovery CLI tests: 5 passed.
- `./iossim device-debug`: bridge loads and every discovery layer executes, but returns zero devices because no phone is connected.
- App bundle deep code-signature verification: pass; bundled prebuilt main/runner manifest hashes: pass.
- Full production `audit-app`: not a pass for this ad-hoc retest package because the focused build script does not add the production icon/license packaging or sanitize debug source paths. This is not a public-release artifact.
- macOS XCTest suite: not runnable with Command Line Tools alone (`no such module XCTest`); production targets still compile. This is a build-machine test item, not a consumer dependency.

## Remaining blockers/unvalidated items

1. Run the new staged probe with the iPhone connected to identify the first actual CoreDevice/AppService layer and determine whether DDI is required on iOS 26.6.2.
2. If DDI is required, release operations must provide an approved exact-build asset/manifest (or approved signed provider configuration). None exists in the repository or current cache.
3. Rebuild the prebuilt iPhone payload on the build machine from this source. The available payload is from `bc339b3e13a62b7ac1eafb3d2598a2d65174b107`; it contains the envelope processor but not the automatic setup-inbox startup controller.
4. Perform physical AppService visible-launch, House Arrest semantic readback, automatic pairing receipt, restart, reconnect, and main-deletion recovery tests. Only those results may promote the gates to `PHYSICAL_PASS`.

Accordingly, no artifact may currently claim `FIRST_TIME_NO_XCODE_SETUP=PHYSICAL_PASS` or `SETUP_READY_FOR_RUNTIME=true`.
