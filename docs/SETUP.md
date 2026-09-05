# IOSSim Setup

## Consumer Mac Setup

The packaged IOSSim Mac app provides the consumer Personal Team flow:

1. open IOSSim on the Mac;
2. connect, unlock, and choose an iPhone;
3. enable Developer Mode if requested;
4. choose a Personal Team already signed in through Xcode;
5. install IOSSim;
6. enable LocalDevVPN and complete **Set Up IOSSim** on the iPhone;
7. return to the Mac and confirm setup completion.

The Mac app never requests an Apple ID password or verification code. Xcode and
its developer tooling remain prerequisites for the current proven signing and
installation path. The consumer package does not require this repository and
installs only IOSSim plus its deterministic XCTest runner; Witness is excluded.

See [Consumer Setup Flow](mac-host/CONSUMER_SETUP_FLOW.md) and
[Consumer Provisioning Architecture](mac-host/CONSUMER_PROVISIONING_ARCHITECTURE.md).

Release engineers should use the signed/notarized DMG workflow and physical
qualification checklist in [Production Release](mac-host/PRODUCTION_RELEASE.md).
For local packaged-product testing before Developer ID credentials are available,
use the separately labeled `./iossim release-local` workflow documented there.
That artifact keeps the production UI but is ad-hoc signed, not notarized, not
Gatekeeper-qualified, and not for public distribution.

## Developer Setup

This setup path is for the current iPhone/on-device IOSSim architecture on
`main`. It does not package or run the frozen `desktop-legacy` frontend/backend
branch.

## Requirements

- Compatible Mac running macOS 13 or newer.
- Xcode 15 or newer with the iPhoneOS SDK installed.
- Apple Development signing capability in Xcode.
- Rust through `rustup`.
- Node.js 20 or newer for the engineering frontend still present on `main`.
- Python 3.11 or newer for the engineering backend still present on `main`.
- Compatible iPhone for device provisioning.

## Setup

```bash
./iossim setup
```

## Check Environment

```bash
./iossim doctor
./iossim doctor --json
```

## Build

```bash
./iossim build
```

## Test

```bash
./iossim test
```

## Set Up iPhone

```bash
./iossim device
```

## What Setup Automates

`./iossim setup` creates ignored local state under `.build/iossim/`, configures
the backend virtual environment, installs backend developer test requirements,
installs frontend dependencies with `npm ci`, installs the Rust iOS target,
builds the pinned `jkcoxson/idevice` FFI library, verifies required FFI symbols,
and performs profile-independent generic builds of the iOS app plus the internal
Witness/XCUILocation runner. `./iossim device` remains the developer command that
requests signed device products.

The command is safe to rerun. It uses hash markers for dependency installs and
does not rewrite shell profiles, reset Git history, remove user data, or create
pairing material.

## Apple Actions That Remain Manual

Apple requires several steps that IOSSim should not bypass:

- Install Xcode from Apple and launch it once.
- Accept any Xcode license or first-run prompts.
- Sign in to Xcode and make an Apple Development signing identity available.
- Connect, unlock, and trust the iPhone.
- Enable Developer Mode on the iPhone.
- Install and approve LocalDevVPN on the iPhone.
- Import RPPairing inside the IOSSim iPhone app.

The CLI may report that pairing material is required, but it must never print or
copy pairing contents, private keys, PSKs, auth blobs, provisioning material, or
sensitive signing material.

## Local Signing Override

The Xcode project currently has an automatic-signing development team from the
validated development machine. Other authorized Macs can override it without
editing the project:

```bash
printf 'IOSSIM_DEVELOPMENT_TEAM=YOURTEAMID\n' > .iossim.local.env
./iossim build
```

`.iossim.local.env` is ignored by Git. Do not put secrets in it.

## Device Command

`./iossim device` uses Apple `devicectl` JSON output to detect paired iPhones,
builds the required local artifacts, and installs:

- `IOSSim DVT POC.app`
- `IOSSimLocationWitness.app`
- `IOSSimLocationControlUITests-Runner.app`

The command is an internal developer provisioning helper. It does not generate,
read, or export RPPairing files. It still reports LocalDevVPN and in-app pairing
import as manual actions because those are runtime requirements on the iPhone.

This three-artifact developer command is intentionally different from the
production consumer flow. Production excludes Witness and dynamically signs the
main app and deterministic derived runner for the selected Personal Team.

## Logs

Concise terminal output is the default. Detailed command logs are written under:

```text
.build/iossim/logs/
```

Logs are ignored by Git and redacted for common secret-shaped values.

## Troubleshooting

If Xcode is missing, install Xcode from Apple, open it once, and rerun:

```bash
./iossim setup
```

If signing fails, open Xcode Settings, add your Apple ID, and either select a
team in Xcode or set `IOSSIM_DEVELOPMENT_TEAM` in `.iossim.local.env`.

If Rust is installed but `cargo` or `rustc` is not on `PATH`, rerun
`./iossim setup`. The CLI and idevice scripts locate the rustup toolchain
directly and do not require editing shell startup files.

If `./iossim doctor` reports no iPhone, connect the phone by USB, unlock it, and
approve the trust prompt on the device.
