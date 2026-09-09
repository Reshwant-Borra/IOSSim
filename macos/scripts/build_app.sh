#!/usr/bin/env bash
set -euo pipefail

MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "${MAC_DIR}/.." && pwd)"
CONFIGURATION="${IOSSIM_MAC_CONFIGURATION:-debug}"
APP_NAME="${IOSSIM_MAC_APP_NAME:-IOSSim}"
BUNDLE_ID="${IOSSIM_MAC_BUNDLE_IDENTIFIER:-com.iossim.mac-provisioner}"
BUILD_ROOT="${ROOT_DIR}/.build/iossim/mac"
APP_DIR="${BUILD_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

swift build --package-path "${MAC_DIR}" -c "${CONFIGURATION}" --product IOSSimMac
BIN_PATH="$(swift build --package-path "${MAC_DIR}" -c "${CONFIGURATION}" --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}/IOSSimMac" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
printf '%s\n' "${ROOT_DIR}" > "${RESOURCES_DIR}/DevelopmentRepositoryRoot.txt"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>IOSSim</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>IOSSim</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -n "${IOSSIM_MAC_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "${IOSSIM_MAC_CODE_SIGN_IDENTITY}" "${APP_DIR}"
else
  codesign --force --sign - "${APP_DIR}"
fi

echo "${APP_DIR}"
