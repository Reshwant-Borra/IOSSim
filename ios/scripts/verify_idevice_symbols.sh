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
)

[[ -f "${LIB_PATH}" ]] || { echo "Missing library: ${LIB_PATH}"; exit 2; }

# Prefer Rust's matching llvm-nm. Apple llvm-nm may lag Rust's LLVM object
# format and fail on current Rust archives with "Unknown attribute kind".
if command -v rustup >/dev/null && rustup which llvm-nm >/dev/null 2>&1; then
  NM=("$(rustup which llvm-nm)" -g)
elif command -v rustc >/dev/null && [[ -x "$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | awk '/^host:/{print $2}')/bin/llvm-nm" ]]; then
  NM=("$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | awk '/^host:/{print $2}')/bin/llvm-nm" -g)
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
