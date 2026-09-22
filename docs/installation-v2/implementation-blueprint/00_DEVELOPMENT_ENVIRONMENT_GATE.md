# M0 Development Environment Ready

Status: implementation blueprint; no environment was mutated.

## Frozen identity

- This blueprint inherits and preserves the full physical snapshot in [`../architecture-reset/00_PHASE_0_FREEZE_SNAPSHOT.md`](../architecture-reset/00_PHASE_0_FREEZE_SNAPSHOT.md): installed `/Applications/Veya.app` was `0.1.0 (11)`, all Build 1-11 DMGs were present with recorded hashes, and the device was most recently unavailable after an earlier paired observation. No live state was changed for this blueprint.
- Branch: `work/final-no-xcode-setup-v1`
- HEAD: `fd4fbfe364383f83b053ae13e6c96ec3af4fbfd6`
- Release configuration: Veya `0.1.0`, build `11`, `arm64` + `x86_64`.
- The pre-existing dirty worktree is evidence. M0 must not clean, reset, stash, or overwrite it.
- Build 12 and a new DMG are expressly outside this blueprint.

## Observed toolchain

| Tool | Observed | Blueprint decision |
|---|---|---|
| Xcode | 27.0 (27A266a) | Build-only dependency |
| Swift | 6.4; package declares tools 5.9/macOS 13 | Keep package compatibility; validate with pinned Xcode in CI |
| rustup | `/opt/homebrew/bin/rustup` | Supported bootstrap mechanism |
| Rust | stable 1.98.0, aarch64 host | Pin `1.98.0`; do not use floating `stable` |
| Cargo | 1.98.0 under `~/.rustup`; absent from shell PATH | Fix discovery; do not require global PATH |
| targets | `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios` | All required today |
| components | `rustfmt` missing | Install `rustfmt` and `clippy` at M0 |

There is no `rust-toolchain.toml`. The bridge uses Rust edition 2024 and a git-pinned `idevice` revision. Swift links the resulting universal dylib dynamically from `Contents/Resources/NativeDeviceBridge`. iOS Rust cross-compilation is a build concern; Cargo, Xcode, Homebrew, and developer tools must never be consumer dependencies.

## Current dependency and linkage inventory

- Rust manifest: `native/iossim-device-bridge/Cargo.toml`; no Cargo workspace exists yet and no Rust dependencies are vendored.
- Direct Rust dependencies: `idevice` revision `1838db107d38701b4044361163aac049006c2627` with `ring`, usbmuxd/pair/AFC/House Arrest/InstallationProxy/image-mounter/TSS/remote-pairing/RSD/CoreDevice/tunnel features; `serde` 1; `serde_json` 1; `tokio` 1.48 feature set. Lock currently resolves `idevice 0.1.67`, `serde 1.0.229`, `serde_json 1.0.151`, `tokio 1.53.1`.
- The bridge produces `cdylib` and `staticlib`; release uses one codegen unit, thin LTO, abort-on-panic, and stripped symbols.
- Swift package directly pins `BigInt` at revision `63feef7820abb1a8fb08587d7da56bb0b7db8751`; Swift does not link Cargo as a package dependency.
- `scripts/bootstrap/iossim_cli.py` builds Cargo separately for `aarch64-apple-darwin` and `x86_64-apple-darwin`, combines them with `lipo`, and places `target/release/libiossim_device_bridge.dylib` for packaging.
- `macos/scripts/build_app.sh` copies the universal dylib to `Contents/Resources/NativeDeviceBridge`, verifies it, and signs it as a nested macOS bundle component. `NativeDeviceBridge.swift` loads it dynamically and checks ABI/integrity.
- `aarch64-apple-ios` is required by the preserved iOS native dependency build; there is no Intel iOS target. Both Intel and Apple Silicon macOS targets are release requirements.
- Bootstrap also requests `llvm-tools-preview`; M0 records whether it remains necessary. `rustfmt` and `clippy` are explicitly required for repository gates.

## Baselines

- Swift: 384 passed, 14 skipped, 0 failed in the last reset baseline. Skips include precisely the real packaged/Keychain surfaces that the new plan must cover.
- Rust: the earlier `cargo unavailable` result was PATH-related. Running `RUSTC="$(rustup which rustc)" "$(rustup which cargo)" test --locked` passes 11/11 tests.
- Rust formatting cannot currently run because `rustfmt` is not installed.

## Required repository changes in M0

1. Add `rust-toolchain.toml` pinned to `1.98.0`, components `rustfmt`, `clippy`, targets `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios`.
2. Make `discover_tool()` resolve `rustup which cargo|rustc` consistently in doctor, build, test, and package paths.
3. Add one repository command, `./iossim test-installation-baseline`, that invokes exact tools rather than relying on interactive shell PATH.
4. Preserve `Cargo.lock`; every CI/release Cargo invocation uses `--locked`.
5. Record Xcode, Swift, rustc, Cargo, target, and lockfile hashes in qualification output.

## M0 binary exit gate

M0 is complete only when one recorded run proves all of the following:

- `swift test --package-path macos` passes with zero unexpected skips/failures.
- `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo check --workspace --locked`, and `cargo test --workspace --locked` pass.
- Host bridge release builds pass for both macOS targets and `lipo -archs` reports both architectures.
- The required `aarch64-apple-ios` target can compile the preserved iOS bridge path.
- Python repository checks and iOS `POCUnitChecks` pass.
- A clean build environment can restore dependencies from declared manifests; all dependency revisions/checksums are captured in the SBOM.
- No command creates Build 12 or mutates Apple/device/Keychain state.

Failure of any item blocks M1. The rollback is deletion of the toolchain pin and command changes only; production runtime behavior is untouched.
