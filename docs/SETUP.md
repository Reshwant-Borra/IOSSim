# IOSSim Setup

For current architecture and evidence, start with
[CURRENT_STATE.md](CURRENT_STATE.md).

## Consumer Mac Setup

The packaged IOSSim Mac app provides the current consumer setup flow:

1. Open IOSSim on the Mac.
2. Connect, unlock, and choose the iPhone.
3. Tap "Trust This Computer?" on the iPhone if iOS asks.
4. Enable Developer Mode if IOSSim asks.
5. Authorize the Apple Account inside IOSSim with normal Apple 2FA.
6. IOSSim discovers the Personal Team and prepares/reuses signing material.
7. IOSSim signs and installs the main app and XCTest runner on the selected
   iPhone.
8. If iOS requires it, trust the developer profile in Settings -> General ->
   VPN & Device Management.
9. Continue in IOSSim so it verifies trust and runtime configuration.
10. Finish iPhone runtime setup and reach Complete.

Current requirement:

| Item | Required now |
| --- | --- |
| Xcode installed | Yes |
| User opens Xcode | Target no, clean-Mac unproven |
| User signs into Xcode | No in current intended native flow |
| User configures Xcode Accounts | No in current intended native flow |
| User builds in Xcode | No |
| User installs from Xcode | No |
| Apple Account login inside IOSSim | Yes |

Xcode remains required because the current physical device backend uses Apple's
`xcrun devicectl` / CoreDevice tooling. The clean-Mac test has not yet proven
that installing Xcode without launching/configuring it is sufficient.

Read the current handoff docs:

- [Provisioning and Signing](PROVISIONING_AND_SIGNING.md)
- [Physical Validation](PHYSICAL_VALIDATION.md)
- [Release and Distribution](RELEASE_AND_DISTRIBUTION.md)
- [Next Steps](NEXT_STEPS.md)

## Developer Setup

This path is for repository development, not for a packaged consumer app.

Requirements:

- macOS 13 or newer.
- Xcode 15 or newer with iPhoneOS SDK and command-line tools available.
- Rust through `rustup`.
- Node.js 20 or newer for the engineering frontend still present in this tree.
- Python 3.11 or newer for backend/development checks still present in this tree.
- Compatible iPhone for physical validation.

Common commands:

```bash
./iossim setup
./iossim doctor
./iossim build
./iossim test
./iossim package-app
./iossim release-local
```

`./iossim setup` creates ignored local state under `.build/iossim/`, configures
developer dependencies, builds/verifies the pinned iOS idevice FFI library, and
performs profile-independent generic iOS builds. It is safe to rerun.

## Device Command

`./iossim device` is an internal developer helper. It still uses Apple
`devicectl` JSON output to detect paired iPhones, build local artifacts, and
install developer artifacts. This is intentionally different from the packaged
consumer flow, which excludes Witness and dynamically signs only the main app and
runner for the selected Personal Team.

## Logs

Command logs are written under:

```text
.build/iossim/logs/
```

Logs are ignored by Git and should remain redacted for common secret-shaped
values.
