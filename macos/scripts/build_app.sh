#!/usr/bin/env bash
set -euo pipefail

MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "${MAC_DIR}/.." && pwd)"
CONFIGURATION="${IOSSIM_MAC_CONFIGURATION:-debug}"
APP_NAME="${IOSSIM_MAC_APP_NAME:-IOSSim}"
BUNDLE_ID="${IOSSIM_MAC_BUNDLE_IDENTIFIER:-com.iossim.mac-provisioner}"
BUILD_ROOT="${IOSSIM_MAC_BUILD_ROOT:-${ROOT_DIR}/.build/iossim/mac}"
APP_DIR="${BUILD_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BRIDGE_SOURCE="${ROOT_DIR}/native/iossim-device-bridge/target/release/libiossim_device_bridge.dylib"
BRIDGE_DIR="${RESOURCES_DIR}/NativeDeviceBridge"
HELPER_ENTITLEMENTS="${MAC_DIR}/Release/IOSSimProvisionerLocal.entitlements"
APP_ENTITLEMENTS="${MAC_DIR}/Release/IOSSim.entitlements"
SIGN_IDENTITY="${IOSSIM_MAC_CODE_SIGN_IDENTITY:--}"
SOURCE_COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || printf 'unknown')"
SOURCE_DIRTY="false"
if [[ -n "$(git -C "${ROOT_DIR}" status --porcelain 2>/dev/null || true)" ]]; then
  SOURCE_DIRTY="true"
fi
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_VARIANT="${IOSSIM_MAC_BUILD_VARIANT:-LOCAL_NO_XCODE_CONSUMER}"
DEVICE_ARTIFACTS_SOURCE="${IOSSIM_DEVICE_ARTIFACTS_SOURCE:-}"

if [[ -z "${DEVICE_ARTIFACTS_SOURCE}" || ! -f "${DEVICE_ARTIFACTS_SOURCE}/manifest.json" ]]; then
  echo "PAYLOAD_MISSING_FROM_DISTRIBUTION: set IOSSIM_DEVICE_ARTIFACTS_SOURCE to a verified prebuilt DeviceArtifacts directory." >&2
  exit 1
fi
payload_manifest_value() {
  /usr/bin/plutil -extract "$1" raw -o - "${DEVICE_ARTIFACTS_SOURCE}/manifest.json" 2>/dev/null || true
}

PAYLOAD_SOURCE_HEAD="$(payload_manifest_value release.payloadSourceHead)"
PAYLOAD_SOURCE_DIRTY="$(payload_manifest_value release.payloadSourceDirty)"
PAYLOAD_SOURCE_TREE_SHA256="$(payload_manifest_value release.payloadSourceTreeSHA256)"
PAYLOAD_BUILD_TIMESTAMP="$(payload_manifest_value release.payloadBuildTimestamp)"
PAYLOAD_BUILD_VARIANT="$(payload_manifest_value release.payloadBuildVariant)"
PAYLOAD_MANIFEST_VERSION="$(payload_manifest_value schemaVersion)"
PAYLOAD_AUTOMATIC_PAIRING_INBOX="$(payload_manifest_value payloadCapabilities.automaticPairingInbox)"
PAYLOAD_LOCALDEVVPN_SETUP_GATE="$(payload_manifest_value payloadCapabilities.localDevVPNSetupGate)"
PAYLOAD_PAIRING_RECEIPT_SCHEMA="$(payload_manifest_value payloadCapabilities.pairingReceiptSchema)"
PAYLOAD_RICH_RUNTIME_PROOF_INBOX="$(payload_manifest_value payloadCapabilities.richRuntimeProofInbox)"
PAYLOAD_RUNTIME_MAPPING_SCHEMA="$(payload_manifest_value payloadCapabilities.runtimeMappingSchema)"

if [[ ! "${PAYLOAD_SOURCE_HEAD}" =~ ^[0-9a-fA-F]{40}$ || \
      ! "${PAYLOAD_SOURCE_TREE_SHA256}" =~ ^[0-9a-fA-F]{64}$ || \
      ! "${PAYLOAD_SOURCE_DIRTY}" =~ ^(true|false)$ || \
      -z "${PAYLOAD_BUILD_TIMESTAMP}" || \
      -z "${PAYLOAD_BUILD_VARIANT}" ]]; then
  echo "PAYLOAD_PROVENANCE_INCOMPLETE: DeviceArtifacts manifest does not describe the actual payload source tree." >&2
  exit 1
fi
if [[ "${PAYLOAD_AUTOMATIC_PAIRING_INBOX}" -lt 2 || \
      "${PAYLOAD_LOCALDEVVPN_SETUP_GATE}" -lt 2 || \
      "${PAYLOAD_PAIRING_RECEIPT_SCHEMA}" -lt 2 || \
      "${PAYLOAD_RICH_RUNTIME_PROOF_INBOX}" -lt 1 || \
      "${PAYLOAD_RUNTIME_MAPPING_SCHEMA}" -lt 1 ]]; then
  echo "PAYLOAD_CAPABILITY_MISMATCH: DeviceArtifacts lacks automaticPairingInbox2/localDevVPNSetupGate2/pairingReceiptSchema2/richRuntimeProofInbox1/runtimeMappingSchema1." >&2
  exit 1
fi
PAYLOAD_SOURCE_COMMIT="${PAYLOAD_SOURCE_HEAD}"

SWIFT_FLAGS=(
  -Xswiftc -D -Xswiftc IOSSIM_BUNDLED_ENGINE
)

if [[ ! -f "${BRIDGE_SOURCE}" ]]; then
  echo "Native device bridge is missing: ${BRIDGE_SOURCE}" >&2
  echo "Build it first with ./iossim build or cargo build --release in native/iossim-device-bridge." >&2
  exit 1
fi
BRIDGE_SHA256="$(shasum -a 256 "${BRIDGE_SOURCE}" | awk '{print $1}')"
BRIDGE_VERSION="$(strings "${BRIDGE_SOURCE}" | awk '/iossim-device-bridge\/[0-9]/ && !found {print; found=1}')"
if [[ -z "${BRIDGE_VERSION}" ]]; then
  BRIDGE_VERSION="unknown"
fi
IDEVICE_REVISION="$(sed -n 's/.*rev = "\([0-9a-f]*\)".*/\1/p' "${ROOT_DIR}/native/iossim-device-bridge/Cargo.toml" | head -1)"

swift build --package-path "${MAC_DIR}" -c "${CONFIGURATION}" "${SWIFT_FLAGS[@]}" --product IOSSimMac
swift build --package-path "${MAC_DIR}" -c "${CONFIGURATION}" "${SWIFT_FLAGS[@]}" --product IOSSimProvisioner
BIN_PATH="$(swift build --package-path "${MAC_DIR}" -c "${CONFIGURATION}" --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${BRIDGE_DIR}"
cp "${BIN_PATH}/IOSSimMac" "${MACOS_DIR}/${APP_NAME}"
cp "${BIN_PATH}/IOSSimProvisioner" "${MACOS_DIR}/IOSSimProvisioner"
cp "${BRIDGE_SOURCE}" "${BRIDGE_DIR}/libiossim_device_bridge.dylib"
chmod +x "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/IOSSimProvisioner" "${BRIDGE_DIR}/libiossim_device_bridge.dylib"

PROTOCOL_INFO_JSON="$(python3 -B "${ROOT_DIR}/scripts/bootstrap/artifact_identity.py" protocol-info \
  --helper "${MACOS_DIR}/IOSSimProvisioner" \
  --bridge "${BRIDGE_DIR}/libiossim_device_bridge.dylib")"
protocol_value() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" <<<"${PROTOCOL_INFO_JSON}"
}
HELPER_SCHEMA_VERSION="$(protocol_value helperProtocol)"
SETUP_STATE_SCHEMA_VERSION="$(protocol_value setupState)"
ARTIFACT_MANIFEST_SCHEMA_VERSION="$(protocol_value artifactManifest)"
NATIVE_BRIDGE_ABI_VERSION="$(protocol_value nativeBridgeABI)"

cp -R "${DEVICE_ARTIFACTS_SOURCE}" "${RESOURCES_DIR}/DeviceArtifacts"
"${BIN_PATH}/IOSSimProvisioner" --resources "${RESOURCES_DIR}" verify-artifacts --json >/dev/null || {
  echo "PAYLOAD_MISSING_FROM_DISTRIBUTION: bundled payload manifest verification failed." >&2
  exit 1
}

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

cat > "${RESOURCES_DIR}/BuildProvenance.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>guiSourceCommit</key>
  <string>${SOURCE_COMMIT}</string>
  <key>guiSourceHead</key>
  <string>${SOURCE_COMMIT}</string>
  <key>guiSourceDirty</key>
  <${SOURCE_DIRTY}/>
  <key>helperSourceCommit</key>
  <string>${SOURCE_COMMIT}</string>
  <key>helperSourceHead</key>
  <string>${SOURCE_COMMIT}</string>
  <key>helperSourceDirty</key>
  <${SOURCE_DIRTY}/>
  <key>sourceDirty</key>
  <${SOURCE_DIRTY}/>
  <key>bridgeVersion</key>
  <string>${BRIDGE_VERSION}</string>
  <key>ideviceRevision</key>
  <string>${IDEVICE_REVISION}</string>
  <key>buildVariant</key>
  <string>${BUILD_VARIANT}</string>
  <key>setupEngine</key>
  <string>BUNDLED_PROVISIONING_ENGINE</string>
  <key>discoveryBackend</key>
  <string>NATIVE_IDEVICE_USBMUX</string>
  <key>installationBackend</key>
  <string>NATIVE_AFC_INSTALLATION_PROXY</string>
  <key>launchBackend</key>
  <string>NATIVE_APPSERVICE_RSD</string>
  <key>developerServicesBackend</key>
  <string>NATIVE_COREDEVICE_RSD_REMOTEXPC</string>
  <key>developerServicesReceiptSchema</key>
  <integer>2</integer>
  <key>houseArrestBackend</key>
  <string>NATIVE_HOUSE_ARREST_AFC</string>
  <key>pairingBackend</key>
  <string>AUTOMATIC_REMOTE_PAIRING_HOUSE_ARREST</string>
  <key>ddiBackend</key>
  <string>NATIVE_PERSONALIZED_DEVELOPER_SUPPORT</string>
  <key>payloadSource</key>
  <string>BUNDLED_PREBUILT_MANIFEST</string>
  <key>payloadManifestVersion</key>
  <string>${PAYLOAD_MANIFEST_VERSION}</string>
  <key>payloadSourceCommit</key>
  <string>${PAYLOAD_SOURCE_COMMIT}</string>
  <key>payloadSourceHead</key>
  <string>${PAYLOAD_SOURCE_HEAD}</string>
  <key>payloadSourceDirty</key>
  <${PAYLOAD_SOURCE_DIRTY}/>
  <key>payloadSourceTreeSHA256</key>
  <string>${PAYLOAD_SOURCE_TREE_SHA256}</string>
  <key>payloadBuildTimestamp</key>
  <string>${PAYLOAD_BUILD_TIMESTAMP}</string>
  <key>payloadBuildVariant</key>
  <string>${PAYLOAD_BUILD_VARIANT}</string>
  <key>setupStateSchema</key>
  <integer>${SETUP_STATE_SCHEMA_VERSION}</integer>
  <key>helperSchemaVersion</key>
  <integer>${HELPER_SCHEMA_VERSION}</integer>
  <key>artifactManifestSchema</key>
  <integer>${ARTIFACT_MANIFEST_SCHEMA_VERSION}</integer>
  <key>nativeBridgeABI</key>
  <integer>${NATIVE_BRIDGE_ABI_VERSION}</integer>
  <key>legacyFallbackUsed</key>
  <false/>
  <key>consumerBuildAttempted</key>
  <false/>
  <key>buildTimestamp</key>
  <string>${BUILD_TIMESTAMP}</string>
</dict>
</plist>
PLIST

cat > "${RESOURCES_DIR}/DeviceDiscoveryBuild.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>distributionClass</key>
  <string>LOCAL_DEVICE_DISCOVERY_TEST</string>
  <key>sourceCommit</key>
  <string>${SOURCE_COMMIT}</string>
  <key>sourceDirty</key>
  <${SOURCE_DIRTY}/>
  <key>buildTimestamp</key>
  <string>${BUILD_TIMESTAMP}</string>
  <key>bridgeSHA256BeforeSigning</key>
  <string>${BRIDGE_SHA256}</string>
</dict>
</plist>
PLIST

codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp=none "${BRIDGE_DIR}/libiossim_device_bridge.dylib"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
  codesign --force --sign "${SIGN_IDENTITY}" \
    --identifier "${BUNDLE_ID}.provisioner" \
    --options runtime --timestamp=none \
    --entitlements "${HELPER_ENTITLEMENTS}" \
    "${MACOS_DIR}/IOSSimProvisioner"
else
  codesign --force --sign "${SIGN_IDENTITY}" \
    --identifier "${BUNDLE_ID}.provisioner" \
    --options runtime --timestamp=none \
    "${MACOS_DIR}/IOSSimProvisioner"
fi
ENGINE_INTEGRITY="${RESOURCES_DIR}/EngineIntegrity.plist"
HELPER_SHA256="$(shasum -a 256 "${MACOS_DIR}/IOSSimProvisioner" | awk '{print $1}')"
SIGNED_BRIDGE_SHA256="$(shasum -a 256 "${BRIDGE_DIR}/libiossim_device_bridge.dylib" | awk '{print $1}')"
PAYLOAD_MANIFEST_SHA256="$(shasum -a 256 "${RESOURCES_DIR}/DeviceArtifacts/manifest.json" | awk '{print $1}')"
/usr/bin/plutil -create xml1 "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert schemaVersion -integer 1 "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert helperRelativePath -string "Contents/MacOS/IOSSimProvisioner" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert helperSHA256 -string "${HELPER_SHA256}" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert helperSchemaVersion -integer "${HELPER_SCHEMA_VERSION}" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert setupStateSchemaVersion -integer "${SETUP_STATE_SCHEMA_VERSION}" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert artifactManifestSchemaVersion -integer "${ARTIFACT_MANIFEST_SCHEMA_VERSION}" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert nativeBridgeRelativePath -string "NativeDeviceBridge/libiossim_device_bridge.dylib" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert nativeBridgeSHA256 -string "${SIGNED_BRIDGE_SHA256}" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert nativeBridgeABI -integer "${NATIVE_BRIDGE_ABI_VERSION}" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert payloadManifestRelativePath -string "DeviceArtifacts/manifest.json" "${ENGINE_INTEGRITY}"
/usr/bin/plutil -insert payloadManifestSHA256 -string "${PAYLOAD_MANIFEST_SHA256}" "${ENGINE_INTEGRITY}"
codesign --force --sign "${SIGN_IDENTITY}" \
  --options runtime --timestamp=none \
  --entitlements "${APP_ENTITLEMENTS}" \
  "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

python3 -B "${ROOT_DIR}/scripts/bootstrap/artifact_identity.py" \
  inspect-app "${APP_DIR}" \
  --output "${BUILD_ROOT}/artifact-identity.json"

echo "${APP_DIR}"
