# IOSSim Clean-Room Opportunities

This document records independent implementation opportunities motivated by Vanish evidence. It is not an implementation plan authorization and no IOSSim files were changed in this documentation phase.

## Guiding Principle

Keep IOSSim's proven phone-side runtime unless a future experiment disproves it for a specific requirement. Focus engineering on the friction around setup, pairing, recovery, no-Xcode operation, cellular readiness, and renewal.

## 1. Complete Mac Device Bridge

### Motivation from Vanish

Vanish ships working user-facing replacements for many Xcode/devicectl operations through:

- Python/pymobiledevice3.
- Rust idevice/isideload-style functionality.
- prebuilt IPA.
- AFC/installation_proxy evidence.
- RSD/DVT service use.

Evidence: E04-E09, E12.

### IOSSim Current State

`CONFIRMED`: IOSSim still relies on devicectl and has an incomplete native backend. Evidence: E25-E26.

### Independent Architecture

Build one macOS-native device bridge responsible for:

- USB discovery via usbmux/lockdown.
- stable identity registry.
- trust/readiness checks.
- Developer Mode status where supported.
- developer-image preparation/mounting.
- app inventory.
- install/upgrade/uninstall.
- app launch.
- app-scoped transfer/readback.
- RemotePairing preparation.
- RSD/tunnel readiness.

Keep Apple auth/provisioning separate. Keep iPhone runtime separate.

### Complexity

`HARD`.

### Key Exit Criteria

- Full consumer setup on a clean no-Xcode host.
- No hidden devicectl calls in install/recovery/doctor paths.
- Two-device identity correctness.
- Locked/untrusted/missing Developer Mode cases classified correctly.
- No proprietary Vanish code copied.

## 2. Automatic Pairing

### Motivation from Vanish

Vanish manages RemotePairing internally, checks per-device state, places pairing into the app, repairs pairing, and retains manual export as fallback. Evidence: E11.

### Independent Architecture

IOSSim flow:

1. Bind selected physical device to a stable ID.
2. Check normal USB trust.
3. Create or validate RemotePairing using legitimate Apple-approved flow.
4. Store host pairing material in protected per-device storage.
5. Deliver only selected-device material through authorized channel.
6. Have phone runtime import/acknowledge.
7. Verify authenticated RSD/TestManager service before marking ready.
8. Offer scoped repair/export only on failure.

### Complexity

`MODERATE` after Mac device bridge exists.

### Safety Constraints

- Do not suppress Trust prompts.
- Do not copy records between phones.
- Do not expose private keys in logs.
- Do not treat file existence as proof of validity.
- Do not re-provision unless pairing diagnosis actually requires it.

## 3. Unified Readiness and Recovery

### Motivation from Vanish

Vanish has helper progress, watchdog/replay, lock/reboot retry, pairing repair, cellular readiness, and diagnostic UX. Evidence: E09, E11, E14-E17, E19.

### IOSSim Opportunity

Create one health model covering:

- Apple auth.
- selected team.
- signing certificate.
- provisioning profile.
- device registration.
- installation.
- Developer Mode.
- developer-profile trust.
- pairing.
- VPN helper.
- RSD service.
- TestManager.
- runner.
- location transport.
- active writer generation.
- pending clear/revert.

### Recovery Rules

- Verify before acting.
- Retry transient transport failures with bounded backoff.
- Preserve valid provisioning state.
- Do not recreate certificates because Wi-Fi changed.
- Do not replay movement if the last user intent was clear.
- Persist a no-secrets setup journal.
- Resume setup by reconciling actual state, not by replaying every step.

### Complexity

`MODERATE`.

## 4. Cellular Improvements

### Motivation from Vanish

Vanish mobile evidence supports a retained phone-local session and a cellular-off bootstrap. Evidence: E14-E15.

### Independent Architectures Ranked

| Rank | Architecture | Recommendation |
| --- | --- | --- |
| 1 | Guided bootstrap using existing IOSSim phone runtime | Best first experiment |
| 2 | Harden local tunnel/interface selection and reconnect | Likely needed if bootstrap is flaky |
| 3 | USB/Mac-hosted fallback writer | Useful support fallback, not mobile parity |
| 4 | IOSSim-owned VPN helper | Hard; entitlement/distribution unknown |
| 5 | Cloud command relay | Not recommended without a separate product need |

### Complexity

`RESEARCH_REQUIRED`, then `MODERATE` to `HARD` depending on outcome.

### Acceptance Criteria

- Fresh retarget after Mac-off where applicable.
- Clear after Mac-off.
- Warm and cold cellular cases separated.
- Wi-Fi to cellular and cellular to Wi-Fi tested.
- Session health measured, not inferred from VPN icon.

## 5. Renewal

### Motivation from Vanish

Vanish includes phone-side self-refresh/re-sign/in-place upgrade machinery and copy acknowledging seven-day expiry. Evidence: E16.

### IOSSim Path

Start simpler:

- Display installed profile expiration.
- Warn before expiry.
- Provide Mac-assisted in-place renewal.
- Preserve app data.
- Reuse Apple session/certificate/profile when valid.
- Handle account/team mismatch clearly.

Then evaluate phone-side refresh:

- legality and distribution.
- where Apple auth/session is stored.
- whether expired app can recover.
- background limits.
- Wi-Fi requirement.
- app data preservation.

### Complexity

- Mac-assisted renewal: `MODERATE`.
- On-phone signing refresh: `HARD`.

## 6. Onboarding Simplification

### Vanish Motivation

Vanish appears to remove Xcode selection, manual pairing file handling, Apple Developer Portal operations, app compilation, and low-level setup interpretation. Evidence: E04-E19.

### IOSSim Target Journey

1. Open IOSSim.
2. Connect iPhone.
3. Unlock and Trust if needed.
4. Enable Developer Mode if needed.
5. Apple Account login and legitimate 2FA.
6. IOSSim performs provisioning/signing/install.
7. IOSSim creates/delivers pairing internally.
8. User approves developer trust/VPN where Apple requires.
9. IOSSim verifies runtime readiness.
10. User searches destination and spoofs.

### What Cannot Legitimately Disappear

- Apple trust.
- Apple 2FA when challenged.
- Developer Mode confirmation/restart.
- VPN consent.
- developer-profile trust if required.

## 7. Privacy and Cloud Boundaries

### Vanish Lesson

Vanish has optional saved Apple password, backend entitlement/auth/session/event endpoints, and map/routing providers that may receive queries/coordinates. Evidence: E10, E18, E20.

### IOSSim Recommendation

- Prefer local Keychain sessions over saved Apple password by default.
- Keep diagnostics redacted.
- Avoid adding cloud coordinate relay unless clearly needed.
- Separate map-provider disclosure from product telemetry.
- Never log pairing secrets or Apple tokens.

## 8. Useful Components to Evaluate

| Component | Use | License note |
| --- | --- | --- |
| idevice | Native host device bridge candidate | MIT upstream |
| isideload | Apple auth/signing architecture reference | MIT upstream |
| pymobiledevice3 | Research/reference tool | GPL-3.0-or-later, careful distribution implications |
| libimobiledevice | C alternative for USB/lockdown/install | LGPL family |
| Xcodes/XcodesKit | Apple auth/session UX reference | MIT |
| StikDebug | Architecture reference only | current upstream AGPL-3.0; exact fork provenance unknown |

Do not reuse Vanish assets or proprietary code.

## Recommended Engineering Order

1. Evidence review and missing discriminating tests.
2. Mac device bridge contract and devicectl inventory.
3. Native bridge implementation and clean-host qualification.
4. Automatic pairing.
5. Unified readiness/recovery.
6. Cellular bootstrap/session hardening.
7. Mac-assisted renewal.
8. Optional phone-side refresh.
9. UX polish: Live Activity, diagnostics, updater, route planning.
10. Dependency, privacy, and release matrix qualification.

No calendar estimates are provided; complexity depends on protocol coverage and testing results.
