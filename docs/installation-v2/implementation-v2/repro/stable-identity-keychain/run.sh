#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
REPRO="${ROOT}/docs/installation-v2/implementation-v2/repro/stable-identity-keychain"
BUILD_PARENT="${ROOT}/.build/iossim"
mkdir -p "${BUILD_PARENT}"
WORK="$(mktemp -d "${BUILD_PARENT}/stable-identity-keychain.XXXXXX")"
IDENTITY="${VEYA_REPRO_SIGN_IDENTITY:-3AD4C19658941F805AEF81BF11A63305AB333257}"
TEAM_ID="T8SL4SG87F"
ACCESS_GROUP="${VEYA_REPRO_ACCESS_GROUP:-${TEAM_ID}.com.veya.local-keychain}"
VEYA_ENTITLEMENTS="${VEYA_REPRO_ENTITLEMENTS:-${REPRO}/Veya.entitlements}"
UNRELATED_ENTITLEMENTS="${VEYA_REPRO_UNRELATED_ENTITLEMENTS:-${REPRO}/Unrelated.entitlements}"
SERVICE="com.veya.keychain-repro.$(uuidgen | tr '[:upper:]' '[:lower:]')"
ACCOUNT="cross-build"

cleanup() {
  if [[ -x "${WORK}/VeyaA.app/Contents/MacOS/Probe" ]]; then
    "${WORK}/VeyaA.app/Contents/MacOS/Probe" delete "${SERVICE}" "${ACCOUNT}" "${ACCESS_GROUP}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! security find-identity -v -p codesigning | grep -Fq "${IDENTITY}"; then
  echo "required signing identity is unavailable: ${IDENTITY}" >&2
  exit 1
fi

make_app() {
  local name="$1"
  local bundle_id="$2"
  local define="$3"
  local entitlements="$4"
  local app="${WORK}/${name}.app"
  local executable="${app}/Contents/MacOS/Probe"
  mkdir -p "${app}/Contents/MacOS"
  swiftc -O -D "${define}" -framework Security -framework CryptoKit "${REPRO}/Probe.swift" -o "${executable}"
  plutil -create xml1 "${app}/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "${bundle_id}" "${app}/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string Probe "${app}/Contents/Info.plist"
  plutil -insert CFBundlePackageType -string APPL "${app}/Contents/Info.plist"
  plutil -insert CFBundleVersion -string "${define}" "${app}/Contents/Info.plist"
  plutil -insert LSUIElement -bool true "${app}/Contents/Info.plist"
  codesign --force --sign "${IDENTITY}" --identifier "${bundle_id}" --options runtime --timestamp=none --generate-entitlement-der --entitlements "${entitlements}" "${app}"
  codesign --verify --strict "${app}"
}

make_app VeyaA com.veya.keychain-identity-repro VERSION_A "${VEYA_ENTITLEMENTS}"
make_app VeyaB com.veya.keychain-identity-repro VERSION_B "${VEYA_ENTITLEMENTS}"
make_app Unrelated com.veya.keychain-identity-unrelated UNRELATED "${UNRELATED_ENTITLEMENTS}"

echo "work=${WORK}"
for app in VeyaA VeyaB Unrelated; do
  echo "artifact=${app}"
  codesign -dvvv --entitlements - --requirements - "${WORK}/${app}.app" 2>&1
done

CDHASH_A="$(codesign -dvvv "${WORK}/VeyaA.app" 2>&1 | sed -n 's/^CDHash=//p')"
CDHASH_B="$(codesign -dvvv "${WORK}/VeyaB.app" 2>&1 | sed -n 's/^CDHash=//p')"
if [[ ! "${CDHASH_A}" =~ ^[0-9a-f]{40}$ || ! "${CDHASH_B}" =~ ^[0-9a-f]{40}$ || "${CDHASH_A}" == "${CDHASH_B}" ]]; then
  echo "cross-build cdhash precondition failed: A=${CDHASH_A} B=${CDHASH_B}" >&2
  exit 1
fi
echo "cdhash_a=${CDHASH_A}"
echo "cdhash_b=${CDHASH_B}"

AGENTS_BEFORE="$(pgrep -x SecurityAgent | tr '\n' ',' || true)"
SAMPLES="${WORK}/securityagent.samples"
(
  for _ in $(jot 600); do
    pgrep -x SecurityAgent || true
    sleep 0.02
  done
) > "${SAMPLES}" &
MONITOR_PID=$!

launch_packaged() {
  local app="$1"
  local operation="$2"
  local output="$3"
  /usr/bin/open -W -n --stdout "${output}" --stderr "${output}.err" "${app}" --args "${operation}" "${SERVICE}" "${ACCOUNT}" "${ACCESS_GROUP}"
  cat "${output}" "${output}.err" 2>/dev/null || true
}

CREATE_OUTPUT="$(launch_packaged "${WORK}/VeyaA.app" create "${WORK}/create.out")"
READ_A_OUTPUT="$(launch_packaged "${WORK}/VeyaA.app" read "${WORK}/read-a.out")"
READ_B_OUTPUT="$(launch_packaged "${WORK}/VeyaB.app" read "${WORK}/read-b.out")"
READ_B_RELAUNCH_OUTPUT="$(launch_packaged "${WORK}/VeyaB.app" read "${WORK}/read-b-relaunch.out")"

if [[ "${VEYA_REPRO_SKIP_NEGATIVE:-0}" == "1" ]]; then
  UNRELATED_OUTPUT="skipped"
  UNRELATED_STATUS=99
else
  set +e
  UNRELATED_OUTPUT="$(perl -e 'alarm 10; exec @ARGV' /usr/bin/open -W -n --stdout "${WORK}/unrelated.out" --stderr "${WORK}/unrelated.err" "${WORK}/Unrelated.app" --args read "${SERVICE}" "${ACCOUNT}" "${ACCESS_GROUP}" 2>&1; cat "${WORK}/unrelated.out" "${WORK}/unrelated.err" 2>/dev/null || true)"
  UNRELATED_STATUS=$?
  set -e
fi

wait "${MONITOR_PID}"
AGENTS_AFTER="$(pgrep -x SecurityAgent | tr '\n' ',' || true)"
SAMPLED_AGENTS="$(sort -u "${SAMPLES}" | tr '\n' ',' || true)"

CREATE_DIGEST="${CREATE_OUTPUT##*digest=}"
READ_A_DIGEST="${READ_A_OUTPUT##*digest=}"
READ_B_DIGEST="${READ_B_OUTPUT##*digest=}"
READ_B_RELAUNCH_DIGEST="${READ_B_RELAUNCH_OUTPUT##*digest=}"
if [[ "${CREATE_DIGEST}" != "${READ_A_DIGEST}" || "${CREATE_DIGEST}" != "${READ_B_DIGEST}" || "${CREATE_DIGEST}" != "${READ_B_RELAUNCH_DIGEST}" ]]; then
  echo "digest mismatch across create/read/rebuild/relaunch" >&2
  exit 1
fi
if [[ "${UNRELATED_STATUS}" -eq 0 ]]; then
  echo "unrelated application unexpectedly retrieved the item" >&2
  exit 1
fi
if [[ -n "${AGENTS_BEFORE}${AGENTS_AFTER}${SAMPLED_AGENTS}" && "${VEYA_REPRO_ALLOW_NEGATIVE_SECURITYAGENT:-0}" != "1" ]]; then
  echo "SecurityAgent observed: before=${AGENTS_BEFORE} after=${AGENTS_AFTER} sampled=${SAMPLED_AGENTS}" >&2
  exit 1
fi

echo "create=${CREATE_OUTPUT}"
echo "same_build_read=${READ_A_OUTPUT}"
echo "cross_build_read=${READ_B_OUTPUT}"
echo "relaunch_read=${READ_B_RELAUNCH_OUTPUT}"
echo "unrelated_exit=${UNRELATED_STATUS}"
echo "unrelated_result=${UNRELATED_OUTPUT}"
echo "securityagent_before=<none>"
echo "securityagent_sampled=<none>"
echo "securityagent_after=<none>"
echo "RESULT=PASS"
