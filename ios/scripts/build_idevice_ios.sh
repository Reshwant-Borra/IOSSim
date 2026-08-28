#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${ROOT_DIR}/.build/idevice-src"
OUT_DIR="${ROOT_DIR}/Vendor/idevice/lib"
PINNED_COMMIT="c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5"
FEATURES="rustcrypto remote_pairing rsd dvt device_info location_simulation tunnel_tcp_stack core_device_proxy obfuscate"

command -v xcrun >/dev/null || { echo "xcrun is required. Install/select full Xcode."; exit 2; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null || { echo "iphoneos SDK unavailable. Open Xcode and accept the license first."; exit 2; }
command -v git >/dev/null || { echo "git is required."; exit 2; }
git --version >/dev/null || { echo "git is unavailable. Open Xcode and accept the license first."; exit 2; }
command -v rustup >/dev/null || { echo "rustup is required. Install Rust first."; exit 2; }
command -v cargo >/dev/null || { echo "cargo is required. Install Rust first."; exit 2; }

mkdir -p "${ROOT_DIR}/.build" "${OUT_DIR}"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  git clone https://github.com/jkcoxson/idevice.git "${REPO_DIR}"
fi

git -C "${REPO_DIR}" fetch --tags origin
git -C "${REPO_DIR}" checkout "${PINNED_COMMIT}"

rustup target add aarch64-apple-ios
rustup component add llvm-tools-preview || true

cd "${REPO_DIR}/ffi"
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)" \
IPHONEOS_DEPLOYMENT_TARGET=17.0 \
cargo build --release --target aarch64-apple-ios --no-default-features --features "${FEATURES}"

cp "${REPO_DIR}/target/aarch64-apple-ios/release/libidevice_ffi.a" "${OUT_DIR}/libidevice_ffi.a"

echo "Built ${OUT_DIR}/libidevice_ffi.a"
file "${OUT_DIR}/libidevice_ffi.a" || true
ls -lh "${OUT_DIR}/libidevice_ffi.a"
