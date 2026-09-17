# Vanished Research Package Index

Documentation phase date: 2026-09-14  
Original research date: 2026-09-13  
Research directory: `/Users/rishiborra/Desktop/VanishedResearch.mSgdHk/`

## START HERE

Read this file first, then read:

1. `01_VANISHED_ARCHITECTURE.md` for the reconstructed system model.
2. `04_DEVICE_PAIRING_AND_NO_XCODE.md` for the two highest-priority architectural findings.
3. `05_MOBILE_CELLULAR_RUNTIME.md` for cellular and phone-local runtime evidence.
4. `07_IOSSIM_COMPARISON.md` and `08_IOSSIM_CLEAN_ROOM_OPPORTUNITIES.md` before planning IOSSim work.
5. `09_EVIDENCE_REGISTER.md` when checking the evidence behind any claim.

This package preserves the current investigation state. It does not add new Vanished research, perform physical experiments, modify IOSSim, modify Vanished, or implement any IOSSim changes.

## Purpose

The investigation was a clean-room interoperability and architecture study of the supplied Vanished/GetVanished artifact. The goal was to understand observable architecture, Apple-device mechanisms, provisioning, pairing, networking, runtime location simulation, UX automation, and IOSSim implementation opportunities without copying proprietary code or bypassing security controls.

The practical question was:

> Which Vanished capabilities are real architecture, which are automation around normal Apple mechanisms, and which can IOSSim independently implement without replacing its proven rich location runtime?

## Artifact Analyzed

Target DMG: `VanishSetup.dmg`

SHA-256:

```text
fef10cf9e2dcca54773f059fcbc865ad402f43637f9260c7f1391ac541c96ed0
```

The local DMG size and SHA-256 matched the public v3.2.1 release asset. The app bundle inside identified as `com.vanish.app` version 3.2.1. The enclosed app was signed and notarized; the outer DMG was not a signed code object with a usable signature. Evidence: E01, E02, E29.

IOSSim source context used during the investigation:

```text
HEAD 0a18e986f40fd877a1aab1e91e4c6a87217c7c81
branch work/fix-apple-srp-503
```

Evidence: E24.

## Methodology

The completed research was static and public-source heavy:

- Read-only DMG metadata and SHA-256 verification.
- Read-only app bundle inventory.
- Mach-O metadata, imports, symbols, entitlements, signatures, and linked-library inspection.
- ASAR metadata and bounded readable-text inspection.
- IPA ZIP and Info.plist inventory.
- Targeted strings and symbol searches for Apple-device, authentication, signing, pairing, DVT, RSD, XCTest, LocalDevVPN, cellular, renewal, recovery, and cloud indicators.
- Public-source comparison against idevice, isideload, pymobiledevice3, libimobiledevice, StikDebug, Xcodes, Apple Developer documentation, GitHub release metadata, and getvanish.app public material.
- IOSSim source audit for current device, provisioning, pairing, and runtime architecture.

No Vanish runtime session was executed. No Apple account login, provisioning, phone installation, network transition, physical-device, battery, expiration, or failure-recovery experiment was performed. All physical-transition rows in `EXPERIMENTS.tsv` remain `NOT_RUN`.

## Clean-Room Boundary

Allowed work performed:

- Inspect binaries, metadata, symbols, strings, resources, plist metadata, signatures, entitlements, and public documentation.
- Document protocols and architecture from observable evidence.
- Compare observable behavior with public/open-source implementations.
- Recommend independent IOSSim implementation paths.

Explicitly not performed:

- No credential, token, session-cookie, private-key, Apple ID, 2FA, or real pairing-record extraction.
- No DRM/licensing bypass.
- No tampering with Vanished servers.
- No copying proprietary source code into IOSSim.
- No Vanish execution in a user account.
- No IOSSim implementation edits.

## Confidence Terminology

- `CONFIRMED`: Directly observed metadata, package inventory, signature, code path, or explicit shipped behavior.
- `STRONG_EVIDENCE`: Multiple corroborating facts support the conclusion, but runtime confirmation is missing.
- `PLAUSIBLE`: Reasonable explanation supported by some evidence, but alternatives remain live.
- `UNKNOWN`: Insufficient evidence.
- `DISPROVEN`: The proposition conflicts with direct evidence.

Confidence attaches to the exact claim. A compiled string or library capability alone is never treated as proof that the feature runs.

## Top Findings

1. `CONFIRMED`: Vanish bundles a device stack: Python 3.13, `pymobiledevice3` 9.12.0, and an arm64 Rust `VanishSideloader`. Evidence: E04-E09.
2. `STRONG_EVIDENCE`: Vanish avoids user-facing full-Xcode dependency through bundled protocol clients and prebuilt mobile payloads, not through bundled Apple CoreDevice frameworks. Evidence: E04-E09, E12.
3. `DISPROVEN`: Vanish does not eliminate pairing. It creates, stores, places, repairs, and can export pairing material. Evidence: E11.
4. `STRONG_EVIDENCE`: Apple Account automation is local-helper driven through GrandSlam/SRP, 2FA, Developer Services, certificates, profiles, signing, and installation. Evidence: E08-E10.
5. `CONFIRMED`: Optional saved Apple password storage exists using Electron `safeStorage`; this is not proof of durable Apple session reuse. Evidence: E10.
6. `STRONG_EVIDENCE`: Mobile/cellular mode is phone-local and uses LocalDevVPN plus retained developer-service sessions. Evidence: E13-E15.
7. `STRONG_EVIDENCE`: The cellular workflow appears to bootstrap by temporarily disabling cellular, establishing a local session, then restoring cellular. Evidence: E14-E15.
8. `STRONG_EVIDENCE`: Developer Mode is required in the intended flow. Evidence: E05, E19, Apple Developer Mode documentation.
9. `STRONG_EVIDENCE`: Seven-day Personal Team expiration is handled by refresh/re-sign/install flows rather than bypassed. Evidence: E16.
10. `STRONG_EVIDENCE`: IOSSim likely does not need to replace its proven rich iPhone runtime to match most Vanish UX advantages. Evidence: E25-E28.

## Documentation Map

- `01_VANISHED_ARCHITECTURE.md`: End-to-end architecture, lifecycle, diagrams, confidence separation.
- `02_DMG_STATIC_ANALYSIS.md`: Static package inventory, signatures, entitlements, frameworks, Python/Rust/IPA findings, hostnames and strings.
- `03_APPLE_AUTH_PROVISIONING_SIGNING.md`: Apple auth, 2FA, Developer Services, certificates, profiles, signing, expiration, renewal.
- `04_DEVICE_PAIRING_AND_NO_XCODE.md`: Pairing automation evidence, no-Xcode architecture, IOSSim replacement matrix.
- `05_MOBILE_CELLULAR_RUNTIME.md`: LocalDevVPN, retained sessions, cellular bootstrap, Mac dependency, location simulation.
- `06_UX_AUTOMATION_AND_RECOVERY.md`: User-friction improvements, diagnostics, recovery, maps, updates, classification by advantage type.
- `07_IOSSIM_COMPARISON.md`: Definitive IOSSim versus Vanish matrix and source-level IOSSim findings.
- `08_IOSSIM_CLEAN_ROOM_OPPORTUNITIES.md`: Independent implementation opportunities, not implementation work.
- `09_EVIDENCE_REGISTER.md`: Durable major-claim register with evidence, alternatives, and limitations.
- `10_UNKNOWNS_AND_FUTURE_RESEARCH.md`: Unknowns split by static, runtime, long-duration, and unsafe/not currently determinable categories.

## Raw Evidence Locations

Original files preserved in the research directory:

- `REPORT.md`: Original 40-section comprehensive report.
- `EVIDENCE.md`: Evidence IDs E01-E31.
- `EXPERIMENTS.tsv`: Unrun transition/physical experiment matrix.
- `bundle-inventory.json`: Complete outer bundle metadata, 4,386 regular non-symlink files.
- `asar-inventory.json`: ASAR entry metadata, 161 entries.
- `inspect_archive.py`: Read-only inspection utility used for bounded metadata/text extraction.

Raw artifact file hashes recorded during this documentation phase:

```text
REPORT.md              ac8a32d607892351dfe789597554f4e9dc3e4247e0424d42ee6f8255bbd30077
EVIDENCE.md            d45a0dfc4c56831d15e1f75c7b704162aca5b9453de417b52a0590e0b1b4dffe
EXPERIMENTS.tsv        393d3879e970cb6dbef58cdebf40ca2a690bd6ef9db35f0d14913354e1c48810
bundle-inventory.json  193994012db9437d53ebe31cfb8428619ab906057957b0e5ea1a18991d290100
asar-inventory.json    3f755460ea2e1e9ce7154638a91e6701a19815b180cade2fa7ebe43d4f86680b
inspect_archive.py     f2c3a5c126143f3631a6b323f57c91207ad6599c7a25f12d389f199d0fb57785
```

## Remaining Unknowns

The largest unknowns all require controlled runtime observation or long-duration testing:

- Clean no-Xcode host success.
- Actual device delta after setup.
- Fresh Developer Mode disabled behavior.
- Wi-Fi to cellular, cellular to Wi-Fi, and Mac-off fresh retarget behavior.
- Whether mobile entitlement/cloud access is needed only for license/accounting or also runtime control.
- Apple session lifetime and exact saved-session behavior.
- Installed profile dates, expiration rollover, and fully expired-app recovery.
- Battery, CPU, and network overhead.
- Actual injected location metadata beyond latitude/longitude.

Do not treat these as negative findings. They remain unresolved because the documentation phase intentionally did not run physical experiments.
