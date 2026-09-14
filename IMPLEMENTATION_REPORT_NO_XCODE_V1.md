# IOSSim no-Xcode productization v1 implementation report

## 1. Verdict

`IMPLEMENTATION_COMPLETE_READY_FOR_PHYSICAL_TEST`

The eight requested implementation areas are present, tested with deterministic
fakes/fixtures, and packaged. Real Apple/device behavior remains explicitly
`AWAITING_PHYSICAL_VALIDATION`; no physical success is claimed.

## 2. Base Repository State

- Starting branch: `work/fix-apple-srp-503`
- Starting commit: `0a18e986f40fd877a1aab1e91e4c6a87217c7c81`
- `main`: `ed233af070f5b751c22f6d8b9f86f4fc01885ce7`
- `origin/main`: `ed233af070f5b751c22f6d8b9f86f4fc01885ce7`
- Pre-existing untracked content preserved: `VanishSetup.dmg`, `tools/`.

## 3. Final Branch and Commit

Branch: `work/no-xcode-productization-v1`  
HEAD: `d7d1795d8effc157bd8e44be92196be65ae572f3`

## 4. Eight Requested Features

| Feature | Status | Main Components | Tests | Physical Validation |
|---|---|---|---|---|
| SRP fix | Implemented | `AppleAuthenticationDiagnostics`, URL-bag resolver, AKD identity | 44 live/auth tests | `AWAITING_PHYSICAL_VALIDATION` (`AUTH_PHYSICAL`) |
| Device bridge | Implemented | Rust `idevice` 0.1.67 pin, C ABI, `IOSSimDeviceBridge` | 8 bridge tests, cargo tests | `AWAITING_PHYSICAL_VALIDATION` (`DEVICE_PHYSICAL`) |
| DDI/RSD | Implemented | `DeveloperSupportCoordinator`, TSS/mounter FFI | 6 DDI tests | `AWAITING_PHYSICAL_VALIDATION` (`DDI_PHYSICAL`, `RSD_PHYSICAL`) |
| Native app management | Implemented | Installation Proxy, House Arrest/AFC, signed preflight | 6 application tests | `AWAITING_PHYSICAL_VALIDATION` (`INSTALL_PHYSICAL`, `LAUNCH_PHYSICAL`, `CONTAINER_PHYSICAL`) |
| Automatic pairing | Implemented | Keychain store, Rust create/validate, encrypted inbox/receipt/repair | 4 pairing tests plus iPhone validator | `AWAITING_PHYSICAL_VALIDATION` (`PAIRING_PHYSICAL`) |
| Readiness/recovery | Implemented | domain state engine, bounded plans, setup journal | 5 state/journal tests | `AWAITING_PHYSICAL_VALIDATION` for service proofs |
| Onboarding | Implemented | high-level coordinator and user-action states | 3 coordinator tests | `AWAITING_PHYSICAL_VALIDATION` (`CLEAN_HOST_PHYSICAL`) |
| Renewal | Implemented | profile/certificate/session decision engine, in-place upgrade contract | 4 renewal tests | `AWAITING_PHYSICAL_VALIDATION` (`RENEWAL_PHYSICAL`) |

## 5. Apple Authentication Changes

The SRP-init 503 path now normalizes outbound GrandSlam client identity to the
researched AKD form, removes stale rejected `com.apple.dt.Xcode` identity
tokens, uses the researched User-Agent, derives endpoints from the Apple URL
bag with bounded cache/invalidation, and sends trusted-device validation as a
GET with a validated six-digit `security-code` header. HTTP 503 is classified as
an HTTP service response (with retryability and safe metadata), not as generic
network failure. Passwords, 2FA, SRP secrets, cookies, and tokens are redacted.
Real account/2FA/team discovery: `AWAITING_PHYSICAL_VALIDATION`.

## 6. Device Bridge

Pinned repository: `jkcoxson/idevice`, commit
`1838db107d38701b4044361163aac049006c2627` (release 0.1.67, MIT). The Rust
crate is built as a signed `libiossim_device_bridge.dylib` and bundled under
`Contents/Resources/NativeDeviceBridge`. Swift sees only typed identities,
inspection, application, DDI, container, and pairing abstractions. FFI uses
opaque handles, explicit free functions, bounded UTF-8/data buffers, typed
status codes, cancellation, and panic trapping.

## 7. Xcode Dependency Audit

`scripts/checks/check_no_xcode_consumer_runtime.py` passes. Remaining matches
are classified as:

- `LEGACY`: `ConsumerArtifactProvisioner`, `RuntimeProvisioningSupport`,
  `InstallationInventory`, compatibility status/error parsing.
- `DEV_FALLBACK`: experimental Apple provisioning and historical CoreDevice
  evidence parsing.
- `BUILD_ONLY`: `IOSSimProvisioner`, support export, developer-support cache
  inspection, release/build scripts.

The native bridge, pairing, application manager, readiness, renewal, and new
onboarding coordinator do not invoke Xcode, `xcrun`, or `devicectl`. The old
technical CLI backend remains an explicit migration fallback pending physical
promotion; consumer production can use the bundled native bridge without
requiring Xcode installation.

## 8. DDI

Typed version/build/board/chip/ECID state, exact cache matching, integrity
checks, TSS structural request handling, personalization, mount transitions,
disconnect/incompatible cases, and post-mount RSD probing are implemented.
Only read-only Apple developer-support caches and explicit development fixtures
are accepted; no Vanish or proprietary assets are copied.

## 9. Application Management

Installation Proxy handles inventory, fresh install, upgrade, and scoped
uninstall. House Arrest/AFC handles validated app-container paths and verified
readback of runtime mapping. Signed app preflight checks bundle ID, profile,
CodeResources, and Team ID. Launch is an authenticated RSD/AppService hook and
fails closed until that physical service is proven.

## 10. Pairing

RemotePairing is created/reused over trusted USB lockdown, persisted per
device/team in Keychain, encrypted for one-time app-private inbox delivery,
validated by the iPhone receipt processor, and then subjected to an actual
operational-proof hook. Repair is targeted and never deletes signing/app data.
Manual plist handling remains Advanced Diagnostics only.

## 11. Readiness and Recovery

Ten domains use structured states rather than booleans. Plans distinguish user
actions, finite transport retries, pairing repair, signing renewal, and DDI
preparation. Setup journal fields are non-secret, permissioned 0700/0600, and
resume is designed to reconcile real state rather than replay blindly.

## 12. Onboarding

Intended flow: connect/select iPhone; unlock/trust; enable Developer Mode;
authenticate Apple Account/2FA; prepare IOSSim and signing; install main/runner;
pair automatically; approve profile/VPN prompts; verify RSD/TestManager; Ready.
The coordinator exposes concise phases and explicit user actions, while raw
protocol errors stay in diagnostics.

## 13. Renewal

Expiry tracking separates profiles, certificates, Apple session, pairing, and
installed app. Valid certificates are reused; profiles refresh; revoked/expired
certificates are recreated; expired sessions request legitimate reauthentication;
Installation Proxy performs in-place upgrade and post-upgrade verification.
Pairing and app data are not deleted as renewal side effects.

## 14. Frozen Runtime Audit

LocalDevVPN, phone-side RPPairing consumer, RSD/DVT/TestManager sessions,
XCTest runner, PID authorization, XCTest handshake, XCUILocation, rich metadata,
speed/course/heading, 2 Hz Drive, fallback, resampling, pause/resume/hold/
clear, generation protection, and reconnect semantics were not redesigned.
Only minimal phone inbox receipt code and native setup adapters were added.

## 15. Security Audit

Credential and diagnostic redaction tests pass. Passwords, 2FA, cookies, tokens,
SRP private values, signing private keys, and pairing private material are not
written to logs/journal/support bundles. Keychain is used for signing and
pairing secrets. FFI validates pointers, sizes, UTF-8, ownership, and path
traversal; container paths are scoped to IOSSim-owned app containers.

## 16. License/Dependency Audit

The host `idevice` pin is MIT and its notice is included in the package. BigInt
remains pinned and its MIT notice is included. No GPL pymobiledevice3 code or
Vanish binaries/assets/records are shipped.

## 17. Tests Added

GrandSlam identity/URL-bag/error tests; native bridge fake transport tests; DDI
cache/TSS/mount tests; Installation Proxy/container tests; pairing envelope,
receipt, reuse/repair tests; readiness/journal tests; onboarding interruption/
selection tests; renewal decision/in-place tests; and a static no-Xcode audit.

## 18. Tests Run

- `./iossim test` — PASS (including Mac 256 tests, Rust cargo fmt/check/test,
  POCUnitChecks, frontend, backend, and build checks).
- `swift test --package-path macos` — PASS, 256 executed, 6 skipped, 0 failed.
- `swift test --package-path ios` — package compiles; no Swift test target is
  defined (`no tests found` is expected for this package layout).
- `cargo fmt --manifest-path native/iossim-device-bridge/Cargo.toml` — PASS.
- `cargo check --manifest-path native/iossim-device-bridge/Cargo.toml` — PASS.
- `cargo test --manifest-path native/iossim-device-bridge/Cargo.toml --lib` —
  PASS, 3 tests.
- `python3 scripts/checks/check_no_xcode_consumer_runtime.py` — PASS.

## 19. Build Results

`./iossim build` — PASS. Native host bridge and existing iPhone FFI build and
the Mac/iOS products compile successfully.

## 20. Test DMG

- Path: `.build/iossim/local-release/IOSSim-0.1.0-local.dmg`
- Size: 17,929,062 bytes
- SHA-256: `2ee25ebde5bb177b2f6190e2fb9515dbbe395a25bee8ed46dea51eddcb4effad`
- Source commit: `d7d1795d8effc157bd8e44be92196be65ae572f3`
- Build date: 2026-09-14 (EDT)
- Status: `LOCAL_TEST_ONLY`, ad-hoc hardened runtime, not notarized/stapled.

## 21. Remaining Physical Validation

1. On a clean Mac, launch the DMG and discover one/two USB and wireless phones.
2. Run Apple login, 2FA, team discovery, and confirm no old SRP 503.
3. Verify Trust, lock, Developer Mode, DDI personalization/mount, and RSD.
4. Install/upgrade/launch main app and runner; verify container mapping readback.
5. Exercise automatic RemotePairing creation, receipt, RSD proof, and repair.
6. Run retained RSD → TestManager → XCTest gates and Rich Spoof/Drive behavior.
7. Disconnect/reboot/reconnect and verify journal reconciliation and intent hold/
   clear protection.
8. Exercise Mac-assisted renewal and data/pairing preservation.
9. Repeat the full flow on a Mac without Xcode installed.

Every item above is `AWAITING_PHYSICAL_VALIDATION`.

## 22. Known Issues

- AppService launch and authenticated RSD proof require the physical device
  session and fail closed in test fixtures.
- Apple developer-support acquisition is intentionally limited to approved
  local cache/fixture inputs; future Apple-distributed acquisition policy must
  be finalized before broad shipping.
- Legacy CLI/devicectl setup code remains for migration/comparison and must be
  retired or hidden from normal consumer setup after physical native promotion.
- The bundled host bridge is currently arm64; universal host-bridge packaging
  for x86_64 Macs remains a release-engineering follow-up.

## 23. Rollback Points

`b1c9990` baseline protection; `0c6fd78` SRP; `e48f4c2` bridge;
`3c8b289` DDI; `e374b5f` app management; `c8cd305` pairing;
`1fcd885` readiness; `2f71e76` onboarding; `178bdd3` renewal;
`e27a8c5` docs/audit; `529b573` bridge packaging; `de449e1` path sanitization;
`d7d1795` bridge signing.

## 24. Final Recommendation

Start with `AUTH_PHYSICAL` on the clean Mac/iPhone pair, then immediately run
the ordered device/DDI/RSD/install/pairing sequence in section 21. Do not call
the release public-ready until the physical gates pass.
