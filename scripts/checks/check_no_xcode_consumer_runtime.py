#!/usr/bin/env python3
"""Fail-closed audit of the packaged IOSSim consumer composition.

Legacy implementations may remain for explicit developer work. This check
proves the bundled SwiftUI composition selects the native engine/backend and
that consumer packaging requires prebuilt payloads.
"""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(errors="replace")


def require(condition: bool, message: str, failures: list[str]) -> None:
    state = "PASS" if condition else "FAIL"
    print(f"[{state}] {message}")
    if not condition:
        failures.append(message)

def main() -> int:
    failures: list[str] = []
    app = read("macos/Sources/IOSSimMac/IOSSimMacApp.swift")
    store = read("macos/Sources/IOSSimMacCore/SetupStore.swift")
    bundled = read("macos/Sources/IOSSimMacCore/Services/BundledProvisioningEngine.swift")
    helper = read("macos/Sources/IOSSimProvisioner/main.swift")
    runtime = read("macos/Sources/IOSSimMacCore/Services/RuntimeProvisioningSupport.swift")
    selector = read("macos/Sources/IOSSimMacCore/Services/ConsumerProvisioningBackend.swift")
    build_app = read("macos/scripts/build_app.sh")
    artifact_manifest = read("macos/Sources/IOSSimMacCore/Models/ArtifactManifest.swift")
    build_tool = read("scripts/bootstrap/iossim_cli.py")
    brand = read("macos/Sources/IOSSimMacCore/Models/ProductBrand.swift")
    release_config = json.loads(read("config/release.json"))

    require("#if IOSSIM_BUNDLED_ENGINE" in app and "BundledProvisioningEngine.live()" in app,
            "packaged GUI composes BundledProvisioningEngine", failures)
    bundled_branch = app.split("#if IOSSIM_BUNDLED_ENGINE", 1)[1].split("#else", 1)[0]
    require("DevelopmentCLIEngine" not in bundled_branch,
            "DevelopmentCLIEngine is absent from packaged branch", failures)
    require('arguments: ["verify-artifacts", "--json"]' in bundled,
            "bundled engine build action only verifies payloads", failures)
    require(".xcodeFallback" not in store,
            "SetupStore never requests an Xcode provisioning backend", failures)
    require("LEGACY_CONSUMER_BACKEND_FORBIDDEN" in helper,
            "consumer helper rejects legacy provisioning backends", failures)
    require("let deviceBackend = IdeviceProvisioningBackend(applicationService: applicationService)" in helper
            and "deviceBackend: deviceBackend" in helper
            and "deviceBackend: deviceBackend\n            )" in helper,
            "consumer helper explicitly composes one exact-identity native backend for inventory and mutation", failures)
    require("reconcileConsumerSetup" in store and "physicalReconciliationStarted" in helper,
            "setup start and retry route through physical reconciliation", failures)
    provisioner = read("macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift")
    require("let reconciliation = try await reconcileSetup(request)" in provisioner
            and "existingInventory.bundleIdentifiers.contains(prepared.identifiers.main)" in provisioner
            and "existingInventory.bundleIdentifiers.contains(prepared.identifiers.runner)" in provisioner,
            "resume reconciles and repair installs only missing components", failures)
    require('env["DEVELOPER_DIR"]' not in runtime,
            "consumer deterministic environment does not inherit DEVELOPER_DIR", failures)
    automatic = selector.split("case .automatic:", 1)[1].split("case .nativePersonalTeam:", 1)[0]
    require("xcodeInvisible" not in automatic and "xcodeFallback" not in automatic,
            "AUTO has no hidden Xcode fallback", failures)
    require("#if IOSSIM_BUNDLED_ENGINE" in selector
            and "return .nativePersonalTeam" in selector,
            "packaged provisioning backend is compile-time locked to native Personal Team", failures)
    require("#if IOSSIM_BUNDLED_ENGINE" in runtime
            and "return .idevice" in runtime,
            "packaged device backend is compile-time locked to the bundled native bridge", failures)
    require("PAYLOAD_MISSING_FROM_DISTRIBUTION" in build_app
            and 'if [[ -z "${DEVICE_ARTIFACTS_SOURCE}"' in build_app,
            "consumer app packaging requires prebuilt DeviceArtifacts", failures)
    require("PAYLOAD_CAPABILITY_MISMATCH" in build_app
            and "assertCurrentPayloadCapabilities" in artifact_manifest
            and all(name in artifact_manifest and name in build_tool for name in (
                "automaticPairingInbox", "localDevVPNSetupGate", "pairingReceiptSchema", "runtimeMappingSchema"
            )),
            "packaging rejects payloads missing current iPhone capabilities", failures)
    require("assert_iphone_main_binary_capabilities" in build_tool
            and "PAYLOAD_CAPABILITY_BINARY_MISMATCH" in build_tool,
            "payload capability claims require compiled-binary markers", failures)
    require(all(key in build_app and key in build_tool for key in (
                "payloadSourceHead", "payloadSourceDirty", "payloadSourceTreeSHA256",
                "payloadBuildTimestamp", "payloadBuildVariant"
            )),
            "payload provenance distinguishes HEAD, dirty tree, fingerprint, timestamp, and variant", failures)
    require(release_config.get("productName") == "Veya"
            and release_config.get("bundleIdentifier") == "com.iossim.mac-provisioner",
            "Veya changes product branding without changing the Mac bundle identity", failures)
    require(all(value in brand for value in (
                'applicationSupportNamespace = "IOSSim"',
                'preferencesNamespace = "IOSSimMac"',
                'phoneBundleIdentifier = "com.iossim.on-device-dvt-poc"',
                'runnerBundleIdentifier = "com.iossim.location-control-uitests.xctrunner"',
                'pairingKeychainService = "com.iossim.on-device-dvt-poc.rppairing"',
            )),
            "Veya migration explicitly freezes state, payload, runner, and pairing identities", failures)

    legacy_files = {
        "macos/Sources/IOSSimMacCore/Services/DevelopmentCLIEngine.swift": "DEVELOPER_ONLY",
        "macos/Sources/IOSSimMacCore/Services/InstallationInventory.swift": "LEGACY_IMPLEMENTATION_RETAINED",
        "macos/Sources/IOSSimMacCore/Services/RuntimeProvisioningSupport.swift": "LEGACY_IMPLEMENTATION_RETAINED",
        "macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift": "EXPLICIT_LEGACY_SIGNING_BRANCH_RETAINED",
        "scripts/bootstrap/iossim_cli.py": "BUILD_MACHINE_ONLY",
    }
    forbidden = ("devicectl", "xcrun", "xcodebuild", "DEVELOPER_DIR")
    for relative, classification in legacy_files.items():
        text = read(relative)
        hits = sorted({token for token in forbidden if token.lower() in text.lower()})
        print(f"[INFO] {classification} {relative}: {','.join(hits) if hits else 'none'}")

    if failures:
        print(f"FAIL: {len(failures)} consumer routing invariant(s) failed", file=sys.stderr)
        return 1
    print("PASS: packaged consumer composition is native-only and payload-prebuilt")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
