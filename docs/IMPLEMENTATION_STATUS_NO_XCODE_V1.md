# IOSSim no-Xcode productization v1 status

Implemented in phase commits on `work/no-xcode-productization-v1`:

1. GrandSlam identity/URL-bag/error classification (`0c6fd78`)
2. Native Rust/C/Swift device bridge (`e48f4c2`)
3. DDI/developer-support/RSD preparation (`3c8b289`)
4. Installation Proxy/House Arrest application management (`e374b5f`)
5. Automatic RemotePairing lifecycle (`c8cd305`)
6. Unified readiness/recovery and setup journal (`1fcd885`)
7. Consumer onboarding coordinator (`2f71e76`)
8. Mac-assisted renewal (`178bdd3`)
9. Native bridge packaging, path sanitization, and signing (`529b573`, `de449e1`, `d7d1795`)

The rich runtime remains feature-frozen. Nonphysical tests and Rust checks are
run before handoff. All real Apple authentication, device discovery, DDI
mount/RSD, install/launch/container, pairing, rich runtime, renewal, and
clean-host checks are explicitly `AWAITING_PHYSICAL_VALIDATION`.

The old CLI/devicectl setup path remains available as a clearly labeled legacy
comparison fallback until physical validation promotes the native coordinator.
