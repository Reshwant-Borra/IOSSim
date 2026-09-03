#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${ROOT_DIR}/.build/idevice-src"
OUT_DIR="${ROOT_DIR}/Vendor/idevice/lib"
PATCH_DIR="${ROOT_DIR}/Vendor/idevice/patches"
PINNED_COMMIT="c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5"
FEATURES="rustcrypto remote_pairing rsd dvt device_info location_simulation tunnel_tcp_stack core_device_proxy obfuscate xctest"

find_rust_tool() {
  local tool="$1"
  if command -v "${tool}" >/dev/null; then
    command -v "${tool}"
    return 0
  fi

  local rustup_home="${RUSTUP_HOME:-${HOME}/.rustup}"
  local candidate
  for candidate in "${rustup_home}"/toolchains/*/bin/"${tool}"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  return 1
}

command -v xcrun >/dev/null || { echo "xcrun is required. Install/select full Xcode."; exit 2; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null || { echo "iphoneos SDK unavailable. Open Xcode and accept the license first."; exit 2; }
command -v git >/dev/null || { echo "git is required."; exit 2; }
git --version >/dev/null || { echo "git is unavailable. Open Xcode and accept the license first."; exit 2; }
RUSTUP_BIN="$(command -v rustup || true)"
CARGO_BIN="$(find_rust_tool cargo || true)"
[[ -n "${CARGO_BIN}" ]] || { echo "cargo is required. Install Rust first."; exit 2; }
RUST_TOOLCHAIN_BIN="$(dirname "${CARGO_BIN}")"
case ":${PATH}:" in
  *":${RUST_TOOLCHAIN_BIN}:"*) ;;
  *) export PATH="${RUST_TOOLCHAIN_BIN}:${PATH}" ;;
esac

mkdir -p "${ROOT_DIR}/.build" "${OUT_DIR}"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  git clone https://github.com/jkcoxson/idevice.git "${REPO_DIR}"
fi

git -C "${REPO_DIR}" fetch --tags origin
git -C "${REPO_DIR}" checkout "${PINNED_COMMIT}"

if [[ -d "${PATCH_DIR}" ]]; then
  for patch in "${PATCH_DIR}"/*.patch; do
    [[ -e "${patch}" ]] || continue
    if git -C "${REPO_DIR}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
      echo "Patch already applied: $(basename "${patch}")"
    else
      echo "Applying idevice patch: $(basename "${patch}")"
      git -C "${REPO_DIR}" apply --check "${patch}"
      git -C "${REPO_DIR}" apply "${patch}"
    fi
  done
fi

if [[ -n "${RUSTUP_BIN}" ]]; then
  "${RUSTUP_BIN}" target add aarch64-apple-ios
  "${RUSTUP_BIN}" component add llvm-tools-preview || true
else
  echo "rustup not found on PATH; using discovered cargo and assuming aarch64-apple-ios target is installed."
fi

cd "${REPO_DIR}/ffi"
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)" \
IPHONEOS_DEPLOYMENT_TARGET=17.0 \
"${CARGO_BIN}" build --release --target aarch64-apple-ios --no-default-features --features "${FEATURES}"

cp "${REPO_DIR}/target/aarch64-apple-ios/release/libidevice_ffi.a" "${OUT_DIR}/libidevice_ffi.a"

echo "Built ${OUT_DIR}/libidevice_ffi.a"
file "${OUT_DIR}/libidevice_ffi.a" || true
ls -lh "${OUT_DIR}/libidevice_ffi.a"
