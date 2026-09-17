# Current build and release map

## Paths

| Entry | Mac build | iPhone payload | Signing/distribution | Risk |
| --- | --- | --- | --- | --- |
| `macos/scripts/build_app.sh` | host-only `swift build`, bundled flag | copies prebuilt DeviceArtifacts | local app assembly/ad hoc workflow | hardcodes schema 3 and host architecture |
| `./iossim build` | calls broad development build including `build_app.sh` | may build project products | development | can produce a different app from release path |
| `./iossim package-app` | self-contained assembler | builds/copies payload and manifest | local signing/audit | canonical-ish but separate from direct script |
| `./iossim release-local` | per configured arch + `lipo` | Release payload | ad hoc DMG, local audit | requires clean tree; sidecar initially copies desired architecture |
| `./iossim release` | per configured arch + `lipo` | Release payload | Developer ID, app+DMG notarization/stapling/audit | strongest current path |
| direct SwiftPM | current host arch | none | no proper bundle | developer only |

`release-local` and `release` have actual `lipo -archs` checks during final mounted-DMG audit. The inspected retest artifact was assembled through the divergent host-only path and received a manually named/copied release sidecar without passing that canonical audit: both GUI/helper are arm64, the sidecar lists arm64 and x86_64, and embedded schema is 3. `CONFIRMED_LOCAL_IOSSIM_CODE`, `CONFIRMED_LOCAL_IOSSIM_ARTIFACT`

The direct script writes schema 3 at `macos/scripts/build_app.sh`; the Python assembler writes schema 4. This directly explains the artifact/source contradiction. The mounted DMG app and `.build/iossim/final-setup-payload-retest/IOSSim.app` are byte-tree equivalent, so the DMG did not introduce the mismatch.

## Current authority

The remote repository had zero GitHub Releases when queried read-only on 2026-09-15. Local DMGs and sidecars are therefore evidence artifacts, not a canonical public channel. `EXPERIMENTALLY_VERIFIED_LOCAL`

## Required consolidation

One release orchestrator owns compilation, assembly, audit, sidecars, signing/notarization, and publication. `build_app.sh` becomes an internal thin call into the same assembler or is deleted. Development builds are visibly nonrelease and cannot create release-shaped filenames/metadata.
