#!/usr/bin/env bash
# M4 causal matrix: which signing/entitlement configurations can use the Data Protection Keychain?
# Each case is a LaunchServices-launched .app; results and AMFI/securityd log lines are recorded.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
PROBE="${ROOT}/docs/installation-v2/implementation-v2/repro/stable-identity-keychain/Probe.swift"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/veya-m4-matrix.XXXXXX")"
IDENTITY="${VEYA_REPRO_SIGN_IDENTITY:-3AD4C19658941F805AEF81BF11A63305AB333257}"
TEAM="T8SL4SG87F"
BUNDLE="com.veya.m4-matrix"
SERVICE="com.veya.m4-matrix.$(uuidgen | tr '[:upper:]' '[:lower:]')"
swiftc -O -framework Security -framework CryptoKit "${PROBE}" -o "${WORK}/Probe" 2>/dev/null || exit 2

entitlements() { # $1 = none|restricted|sandbox|sandbox+group  (XML written directly: plutil treats dots as key paths)
  local file="${WORK}/$1.entitlements" body=""
  case "$1" in
    restricted) body="<key>com.apple.application-identifier</key><string>${TEAM}.${BUNDLE}</string>
<key>com.apple.developer.team-identifier</key><string>${TEAM}</string>
<key>keychain-access-groups</key><array><string>${TEAM}.${BUNDLE}</string></array>" ;;
    sandbox) body="<key>com.apple.security.app-sandbox</key><true/>" ;;
    sandbox+group) body="<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key><array><string>${TEAM}.${BUNDLE}</string></array>" ;;
  esac
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>%s</dict></plist>\n' "${body}" > "${file}"
  plutil -lint "${file}" >/dev/null || exit 3
  echo "${file}"
}

run_case() { # name signer entitlements access-group
  local name="$1" signer="$2" ents="$3" group="$4" app="${WORK}/$1.app"
  mkdir -p "${app}/Contents/MacOS" && cp "${WORK}/Probe" "${app}/Contents/MacOS/Probe"
  plutil -create xml1 "${app}/Contents/Info.plist"
  for kv in "CFBundleIdentifier:${BUNDLE}" "CFBundleExecutable:Probe" "CFBundlePackageType:APPL"; do
    plutil -insert "${kv%%:*}" -string "${kv#*:}" "${app}/Contents/Info.plist"
  done
  plutil -insert LSUIElement -bool true "${app}/Contents/Info.plist"
  local sign=(--force --sign "${signer}" --options runtime --timestamp=none --identifier "${BUNDLE}")
  [[ "${ents}" != none ]] && sign+=(--entitlements "$(entitlements "${ents}")")
  codesign "${sign[@]}" "${app}" >/dev/null 2>&1 || { echo "case=${name} SIGN_FAILED"; return; }
  echo "case=${name} embedded_entitlements=$(codesign -d --entitlements - --xml "${app}" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)"
  local start; start="$(date '+%Y-%m-%d %H:%M:%S')"
  for op in create read delete; do
    rm -f "${WORK}/${name}.${op}.out"
    perl -e 'alarm 15; exec @ARGV' /usr/bin/open -W -n --stdout "${WORK}/${name}.${op}.out" --stderr "${WORK}/${name}.${op}.out" \
      "${app}" --args "${op}" "${SERVICE}.${name}" acct "${group}" >/dev/null 2>&1
    echo "case=${name} signer=$([[ ${signer} == - ]] && echo adhoc || echo team) ents=${ents} group=${group} op=${op} -> $(tr '\n' ' ' < "${WORK}/${name}.${op}.out" 2>/dev/null)"
  done
  log show --start "${start}" --style compact --predicate '(process == "amfid" OR process == "kernel" OR process == "securityd" OR process == "trustd") AND (eventMessage CONTAINS[c] "m4-matrix" OR eventMessage CONTAINS[c] "entitlement" OR eventMessage CONTAINS[c] "restricted")' 2>/dev/null \
    | grep -v "^Timestamp" | cut -c1-220 | sed "s/^/  log[${name}]: /" | head -6
}

AGENTS_BEFORE="$(pgrep -x SecurityAgent | xargs)"
run_case A_team_none        "${IDENTITY}" none          -
run_case B_team_restricted  "${IDENTITY}" restricted    "${TEAM}.${BUNDLE}"
run_case C_adhoc_restricted -             restricted    "${TEAM}.${BUNDLE}"
run_case D_team_sandbox     "${IDENTITY}" sandbox       -
run_case E_team_sandbox_grp "${IDENTITY}" sandbox+group "${TEAM}.${BUNDLE}"
echo "securityagent_before=[${AGENTS_BEFORE}] after=[$(pgrep -x SecurityAgent | xargs)]"
echo "work=${WORK}"
