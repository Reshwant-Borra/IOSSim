# IOSSim

IOSSim is a private iPhone location-simulation project with a native macOS setup
app, an iPhone runtime app, and a signed XCTest runner used by the proven
XCUILocation runtime path.

Start with [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md). That is the
authoritative handoff for the current branch, physical evidence, release
boundary, and next engineering work.

Current engineer entry points:

- [Current State](docs/CURRENT_STATE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Provisioning and Signing](docs/PROVISIONING_AND_SIGNING.md)
- [Physical Validation](docs/PHYSICAL_VALIDATION.md)
- [Release and Distribution](docs/RELEASE_AND_DISTRIBUTION.md)
- [Next Steps](docs/NEXT_STEPS.md)
- [Engineering History](docs/ENGINEERING_HISTORY.md)
- [Experimental Xcode and RPPairing Bootstrap](docs/XCODE_AND_RPPAIRING_BOOTSTRAP.md)

Developer commands remain:

```bash
./iossim setup
./iossim doctor
./iossim build
./iossim test
./iossim package-app
./iossim release-local
```

The frozen historical desktop frontend/backend implementation is preserved on
the `desktop-legacy` branch. Older root-level and subdirectory documents may
describe that pre-native host architecture; when they conflict with
`docs/CURRENT_STATE.md`, the current-state handoff wins.
