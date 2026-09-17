# Final IOSSim Engineering Decision

## Ready to build?

Yes. The architecture is resolved. Physical qualification remains a set of implementation gates, not a reason to continue static research.

## Decisions

1. Device stack: pinned Rust idevice bridge behind an IOSSim-owned C ABI in the existing signed provisioner. Swift owns UI, Apple auth, Keychain, signing, readiness and recovery.
2. Xcode: removable from consumer runtime. It remains a CI/build/notarization dependency, not a normal-user setup dependency.
3. devicectl: replace discovery with usbmuxd/Lockdown, Developer Mode with AMFI, DDI with Mobile Image Mounter/TSS, install/upgrade/uninstall with AFC plus Installation Proxy, inventory with Installation Proxy/AppService, launch with AppService/DVT over RSD, and containers with House Arrest/AFC.
4. pymobiledevice3: do not embed. Current 11.12.5 is capable but GPL-3.0-or-later with a larger Python/runtime surface; keep as reference or separately reviewed diagnostic helper.
5. Rust idevice: primary host stack, pinned behind ABI because pre-0.2 APIs may break. Never use key-regenerating pairing convenience calls for health checks.
6. libimobiledevice: classic-service fallback/test oracle only; insufficient alone for modern RemotePairing/RSD/DVT.
7. SRP 503: most likely stale or wrongly emitted com.apple.dt.Xcode in X-MMe-Client-Info. Current source contains the AKD correction; verify packaged/fallback output and add URL-bag/final-header normalization. Keep auth, do not replace wholesale.
8. Pairing: native bridge creates/reuses over trusted USB; Mac Keychain protects; app-private House Arrest receives a one-time encrypted envelope; phone receipt plus authenticated RSD/TestManager proof yields READY. Users never handle a plist.
9. Runtime: LocalDevVPN -> RPPairing -> RSD -> TestManager/DVT -> XCTest -> XCUILocation -> Rich Drive remains feature-frozen, including retained sessions, rich metadata, 2 Hz cadence, movement controls, clear and generation protections.
10. First work: baseline tests, auth, native identity/readiness, DDI/RSD, then install/inventory/launch/container operations. Pairing and unified onboarding follow.

## Non-blocking later work

Full cellular qualification, Mac-off retarget, phone-autonomous refresh, seven-day autonomous renewal and replacing rich runtime are later phases. Their retained-session model is structurally compatible with this stack, but needs physical validation.

Baseline: branch work/fix-apple-srp-503; HEAD 0a18e986f40fd877a1aab1e91e4c6a87217c7c81; local origin/main ed233af070f5b751c22f6d8b9f86f4fc01885ce7; tracked tree clean; untracked VanishSetup.dmg and tools/ untouched. IOSSim was not modified.
