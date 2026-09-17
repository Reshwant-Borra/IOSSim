# Release Pipeline V2

## Pipeline

```text
clean pinned source + version/build/channel
 -> resolve exact Swift/Rust/Xcode dependencies
 -> build each declared architecture
 -> build prebuilt iPhone main/runner payloads
 -> assemble once
 -> derive manifest from output bytes
 -> sign nested code, helper, bridge, app
 -> audit unmounted app
 -> notarize/staple app archive
 -> create canonical DMG
 -> sign/notarize/staple DMG
 -> mount read-only
 -> independently re-inventory mounted app
 -> compare manifest/sidecar/source policy
 -> publish immutable artifact + checksum + manifest + SBOM
```

Public filename is `Veya-<semver>-build<build>-<shortsha>.dmg`, for example `Veya-0.5.0-build41-a81c21f.dmg`. A channel may be metadata but never produces ambiguous `final`, `fixed`, or `new` names.

## Fail-closed gates

1. Source is clean, exact commit exists in the intended remote, subdependency pins resolve, and build inputs are recorded.
2. Actual Mach-O slices of GUI, helper, bridge, and nested native payload code match declared policy.
3. Actual Info.plist identifiers/version/build/minimum OS equal release input.
4. Helper/bridge/setup/artifact/wire schemas are read from built components through a protocol-info command or generated shared source, never duplicated literals.
5. Every DeviceArtifacts component’s actual tree hash/bundle ID/version/capability/signing mode equals its manifest.
6. Consumer binary/string/import scans reject repository paths, Xcode/devicectl runtime routes, unsafe environment overrides, secrets, and unexpected dynamic libraries.
7. Nested signatures, entitlements, designated requirements, hardened runtime, timestamps, app/DMG notarization tickets, stapling, and Gatekeeper assessments pass.
8. Mounted DMG contains only expected app, Applications link, and declared presentation files. Its app tree equals the pre-DMG signed app under a documented normalization method.
9. Release sidecar is regenerated from the mounted artifact and signed; any desired-versus-actual mismatch aborts.
10. SPDX/CycloneDX SBOM, license policy/notices, vulnerability report, and Apple-asset provenance decision pass.

## Publication and rollback

Use GitHub Releases as the initial canonical authority because the code remote already lives on GitHub and no alternate signed backend is established. Publication creates a draft, uploads exact immutable artifacts, independently downloads/verifies them, then publishes. Update metadata references artifact hash and signed manifest. The application never installs an update solely because GitHub/TLS served it.

Rollback publishes a new build/version pointing to audited older source; it never replaces bytes under an existing release identity. Revocation metadata can block a bad build while preserving forensic identity.
