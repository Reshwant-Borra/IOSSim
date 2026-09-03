#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_PATH="${1:-${ROOT_DIR}/Vendor/idevice/lib/libidevice_ffi.a}"
REQUIRED_SYMBOLS=(
  "rp_pairing_file_read"
  "tunnel_create_rppairing"
  "remote_server_connect_rsd"
  "device_info_directory_listing"
  "location_simulation_new"
  "location_simulation_set"
  "location_simulation_clear"
  "xctest_runner_new_from_rsd"
  "xctest_runner_copy_metadata_from_rsd"
  "xctest_runner_start"
  "xctest_runner_stop"
  "xctest_runner_get_status"
  "xctest_runner_copy_error_message"
  "xctest_runner_string_free"
  "xctest_runner_metadata_free"
  "xctest_runner_free"
)

[[ -f "${LIB_PATH}" ]] || { echo "Missing library: ${LIB_PATH}"; exit 2; }

find_rust_llvm_nm() {
  local rustup_bin
  rustup_bin="$(command -v rustup || true)"
  if [[ -z "${rustup_bin}" ]]; then
    for candidate in /opt/homebrew/bin/rustup /usr/local/bin/rustup; do
      if [[ -x "${candidate}" ]]; then
        rustup_bin="${candidate}"
        break
      fi
    done
  fi

  if [[ -n "${rustup_bin}" ]] && "${rustup_bin}" which llvm-nm >/dev/null 2>&1; then
    "${rustup_bin}" which llvm-nm
    return 0
  fi

  if command -v rustc >/dev/null; then
    local sysroot host candidate
    sysroot="$(rustc --print sysroot)"
    host="$(rustc -vV | awk '/^host:/{print $2}')"
    candidate="${sysroot}/lib/rustlib/${host}/bin/llvm-nm"
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  fi

  local rustup_home="${RUSTUP_HOME:-${HOME}/.rustup}"
  local candidate
  for candidate in "${rustup_home}"/toolchains/*/lib/rustlib/*/bin/llvm-nm; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  return 1
}

# Prefer Rust's matching llvm-nm. Apple llvm-nm may lag Rust's LLVM object
# format and fail on current Rust archives with "Unknown attribute kind".
if RUST_LLVM_NM="$(find_rust_llvm_nm)"; then
  NM=("${RUST_LLVM_NM}" -g)
elif command -v llvm-nm >/dev/null; then
  NM=(llvm-nm -g)
else
  NM=(nm -gU)
fi

EXPORTS="$("${NM[@]}" "${LIB_PATH}" 2>/dev/null)"
missing=0
for symbol in "${REQUIRED_SYMBOLS[@]}"; do
  if grep -Eq "(_| )${symbol}$" <<<"${EXPORTS}"; then
    echo "FOUND ${symbol}"
  else
    echo "MISSING ${symbol}"
    missing=1
  fi
done

exit "${missing}"
