# Installation V2 physical validation handoff

Status: `PHYSICAL_VALIDATION_REQUIRED`

No physical-device, clean-machine, Apple-account, Developer ID, notarization, stapling, or Gatekeeper pass is claimed by this implementation session.

## Artifact under test

The current software-qualified artifact is local-test only:

- `.build/iossim/local-release/Veya-0.1.0-build1-1259da5-local-test.dmg`
- SHA-256: `0bbc112d7ef191190da2afce0067012392e6ec31719330d9e85a8aa7633d4a72`
- Size: `16,139,473` bytes
- Source commit: `1259da507ecded222022cc86bf82863c15640db9`, dirty source
- Signing: ad hoc; not notarized, stapled, Gatekeeper-qualified, or public
- DDI policy: development/local-test mirror only; production source unresolved

Use this artifact only for controlled local qualification. A public qualification run must use a newly built Developer ID signed/notarized/stapled artifact after an approved production DDI provider is selected.

## Safety prerequisites

- Use a dedicated approved Apple test account/Personal Team and a supported test iPhone. Never record its password, 2FA code, session, cookies, private key, raw UDID, pairing record, or PSK.
- Capture only a hashed device alias and safe receipt/error fields in evidence.
- Do not delete unknown certificates, profiles, App IDs, devices, apps, Keychain items, or pairing state.
- Take explicit recovery notes before every destructive Fresh Install test; use only Veya-owned bundle identities and a device dedicated to qualification.
- Preserve every Apple-controlled prompt: Trust, passcode, Developer Mode/reboot, 2FA, developer-profile trust, and VPN approval.

## Qualification sequence

Run in order and stop at the first failed gate.

### 1. Clean Mac and artifact identity

- Use a supported clean Mac or new macOS user with no repository checkout, Xcode, Homebrew, Python, Node, Rust, Cargo, prior Veya state, or developer caches.
- Copy the artifact as a consumer would, recompute SHA-256, mount it read-only, confirm only `Applications` and `Veya.app`, install, and launch.
- Confirm the app displays `Veya (formerly IOSSim)` while retaining bundle ID `com.iossim.mac-provisioner`.
- Verify helper integrity failures are precise by using a disposable tampered copy, never the qualification artifact.

Pass: Veya launches and reaches device selection without repository/developer-tool access. The mounted/downloaded hash and in-app release identity match.

### 2. Native discovery and first Trust

- Connect a never-trusted supported iPhone by USB while locked; verify Veya asks for unlock and does not proceed.
- Unlock, request Trust, deny once, retry, approve Apple's Trust prompt, enter the device passcode only on the iPhone, disconnect/reconnect, and validate a fresh Lockdown session.
- Exercise simultaneous USB and network appearances for the same UDID and verify the exact USB mux/connection identity remains selected.

Pass: no Xcode/devicectl path is invoked; denial/disconnect are recoverable; exact connection identity is stable; no secret pairing bytes appear in logs/support output.

### 3. Developer Mode and developer support

- Begin with Developer Mode disabled; follow Apple's Settings/reboot/confirmation flow and resume Veya.
- For local testing, clear only the Veya-owned developer-support cache and exercise the explicitly classified development provider for the exact iOS build.
- Verify downloaded image, BuildManifest, and trust cache provenance/hash; personalize through Apple TSS; mount; then verify developer-service availability.
- Test offline cache reuse, corrupt-cache quarantine, wrong-build rejection, network outage, TSS rejection, and mount failure where safely reproducible.

Pass: a fresh Veya cache reaches mounted support without installed Xcode and never selects a development mirror in a production-policy build.

### 4. Apple Personal Team and signing

- Authorize the approved test Apple Account, complete legitimate 2FA, select the Personal Team, register the test device/App IDs, create or reuse a Veya-managed certificate, and obtain exact profiles.
- Confirm password and 2FA are transient and session/private key remain Keychain-confined.
- Exercise session expiry, profile near-expiry/expiry, safe renewal, and an injected downstream signing/install failure.

Pass: candidate resources are not promoted until signing, installation, and exact inventory succeed; failure leaves the prior working installation/resources intact; unrelated resources are untouched.

### 5. Native install and developer-profile trust

- Install main app and exact runner through AFC/PublicStaging/InstallationProxy.
- Interrupt transfer/install and reconnect; verify inventory-driven reconciliation rather than blind replay.
- Exercise wrong-team/unknown ownership and confirm it becomes an explicit conflict with no uninstall.
- Complete Apple's developer-profile trust in Settings and resume.

Pass: exact bundle/team/version inventory is proven, only Veya-owned resources are mutated, and no devicectl/xcodebuild consumer route appears.

### 6. Transactional RemotePairing

- Start with a known working active pairing A; stage candidate B; test disconnect after import, bad receipt, replayed receipt, wrong request/device, possession failure, developer-service failure, phone termination, and Mac termination before promotion.
- Resume the matching candidate, complete fresh possession and developer-service proof, promote atomically, and verify delayed cleanup policy.

Pass: every pre-promotion failure leaves A operational; import receipt alone never marks readiness; no raw pairing material appears in logs, journal, or support output.

### 7. LocalDevVPN lifecycle

- Exercise app missing, App Store installation, incompatible version if available, VPN permission denied/pending/approved, configured-but-stopped, running-but-endpoint-unavailable, endpoint ready, foreground/reopen, expired/wrong request, and tunnel restart.

Pass: Veya distinguishes every lifecycle state, resumes on scene activation, and never bypasses Apple's VPN approval.

### 8. Developer services and bounded Rich proof

- Prove the current device/build/support/pairing/release-bound software tunnel, RSD, RemoteXPC, AppService connection, and exact runner launch.
- Run setup's bounded Rich proof: TestManager attach, XCTest control, one harmless Rich `XCUILocation` write, strongest available witness, location clear, and session cleanup.
- Interrupt at each stage and retry. Inspect the iPhone after every success/failure to confirm no simulated location remains.

Pass: DDI/RSD/AppService or stored checkpoints alone never produce READY; only the complete current receipt does; clear and cleanup are mandatory.

### 9. Runtime invariants

- After setup READY, exercise Spoof/static location, Drive, Rich XCUILocation, retained/preinstalled runner behavior, supplied/retained RSD, Rich/default transport, 2 Hz smooth Drive, 1 Hz fallback, Stop & Hold, Resume, Clear, and destination hold.
- Verify one location writer, one route scheduler, no backlog replay, and no Drive route created by setup proof.

Pass: Installation V2 prepares but does not regress or replace the established runtime.

### 10. Recovery, renewal, reboot, and upgrade

- Reboot the Mac and iPhone independently; stop/restart LocalDevVPN; remove only one Veya-owned app/runner at a time; stale pairing; corrupt the Veya-owned DDI cache; expire Apple session/profile in the controlled account; and interrupt each mutating stage.
- Verify the smallest prerequisite repair and preservation of valid domains.
- Upgrade a qualified IOSSim V2 installation to Veya and confirm state, signing identity, pairing generation, phone apps, and runtime mapping are reused.

Pass: normal Repair never performs broad reinstall/reset, branding alone never reprovisions, and Fresh Install remains explicit.

### 11. Diagnostics and secret audit

- Export support data after representative failures and READY.
- Confirm the ZIP contains only the documented allowlist and no passwords, 2FA codes, tokens, cookies, private keys, raw provisioning blobs, raw device IDs, pairing records, or PSKs.
- Confirm stable `VEYA-*` codes, release identity, stage, action, retryability, and safe details.

### 12. Public release qualification (blocked today)

Only after an approved production DDI source/rights/update/revocation policy exists:

- Build from controlled clean source using Developer ID Application signing.
- Verify all nested signatures, notarize, staple app/DMG as required, assess Gatekeeper, create the canonical DMG, mount/audit actual bytes, publish a draft, download it, compare SHA-256, and repeat the mounted audit.
- Repeat the complete clean-Mac/iPhone matrix using that exact downloaded artifact, including rollback and update.

Pass: production provider classification is approved, distribution gates pass, and public zero-Xcode qualification is based on the downloaded immutable artifact.

## Evidence record

For every scenario record timestamp, safe Mac/iPhone OS/build identities, artifact SHA-256, release/setup schemas, test class `PHYSICAL_DEVICE`, expected/actual state transition, stable error code where applicable, and PASS/FAIL. Do not include secret or raw device/account material.

Final physical verdict remains `PHYSICAL_VALIDATION_REQUIRED` until every applicable scenario passes on supported hardware.
