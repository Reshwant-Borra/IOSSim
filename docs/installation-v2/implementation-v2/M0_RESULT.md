# M0 Result

Status: **PASS**

## Implemented

- Added repository `rust-toolchain.toml` pinning Rust `1.98.0`, `rustfmt`, `clippy`, `llvm-tools-preview`, and the three required Apple targets.
- Updated bootstrap discovery/setup so rustup-managed tools are deterministic even when bare `cargo` is absent from shell PATH.
- Added `./iossim installation-baseline`, covering repository checks, Rust format/check/clippy/test, Swift/iOS checks, and both macOS Rust release targets.
- Added explicit safety contracts to every unsafe public Rust FFI and resolved strict clippy findings.
- Kept all SwiftPM/module caches under the repository for this qualification flow.

## Exit evidence

- Bundle identifier, no-Xcode runtime/routing, artifact identity, and device-discovery checks: PASS.
- Rust fmt/check/clippy (`-D warnings`): PASS.
- Rust tests: 11 passed, 0 failed.
- macOS Swift: 384 executed, 14 skipped, 0 failed.
- iOS shared `POCUnitChecks`: PASS.
- Rust release build `aarch64-apple-darwin`: PASS.
- Rust release build `x86_64-apple-darwin`: PASS.
- Release configuration remains Build 11.

## Failures corrected

1. Strict clippy exposed missing public FFI safety documentation and reducible conditional branches. The bridge now documents caller obligations and passes with warnings denied.
2. The command sandbox initially blocked SwiftPM external caches. Repository-local module caches and the authorized unsandboxed build environment resolved this without changing source behavior.
3. An initial baseline implementation redirected `HOME`, which introduced an artificial fifteenth Keychain skip. The override was removed; the true 14-skip baseline is preserved.

## Remaining risks

The 14 skips are classified in `00_IMPLEMENTATION_BASELINE.md`; required packaged/Keychain/signing coverage remains gated in M3-M5 and cannot remain unexplained at M12.

