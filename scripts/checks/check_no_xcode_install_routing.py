#!/usr/bin/env python3
"""Regression audit for the bundled consumer application's device-operation routing."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
PROVISIONER = ROOT / "macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift"
HELPER = ROOT / "macos/Sources/IOSSimProvisioner/main.swift"
POLICY = ROOT / "macos/Sources/IOSSimMacCore/Services/ConsumerProvisioningBackend.swift"
NATIVE_BRIDGE = ROOT / "macos/Sources/IOSSimMacCore/Services/NativeDeviceBridge.swift"
NATIVE_APPS = ROOT / "macos/Sources/IOSSimMacCore/Services/NativeApplicationManagement.swift"


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    failures: list[str] = []
    provisioner = PROVISIONER.read_text()
    helper = HELPER.read_text()
    policy = POLICY.read_text()
    native_bridge = NATIVE_BRIDGE.read_text()
    native_apps = NATIVE_APPS.read_text()

    require(
        "inventoryReader: any DeviceApplicationInventoryReading = NativeApplicationInventoryReader()" in provisioner,
        "consumer provisioner does not default to native Installation Proxy inventory",
        failures,
    )
    require(
        "deviceBackend: any DeviceProvisioningBackend = IdeviceProvisioningBackend()" in provisioner,
        "consumer provisioner does not default to the native idevice backend",
        failures,
    )
    for operation in (
        '"devicectl", "device", "install", "app"',
        '"devicectl", "device", "uninstall", "app"',
        '"devicectl", "device", "info", "apps"',
        '"devicectl", "device", "process", "launch"',
        '"devicectl", "device", "copy", "from"',
    ):
        require(operation not in provisioner, f"active consumer provisioner contains {operation}", failures)
    require(
        re.search(r"else\s*\{\s*backend = \.nativePersonalTeam\s*\}", helper) is not None,
        "consumer-provision without an explicit signing backend does not fail closed to native",
        failures,
    )
    require(
        len(re.findall(r"nativeConsumerProvisioner\s*\(", helper)) >= 4
        and "stateStore: ConsumerProvisioningStateStore" in helper
        and "let deviceBackend = IdeviceProvisioningBackend(applicationService: applicationService)" in helper
        and re.search(
            r"inventoryReader:\s*NativeApplicationInventoryReader\(\s*service:\s*applicationService,\s*deviceBackend:\s*deviceBackend\s*\)",
            helper,
        ) is not None
        and "deviceBackend: deviceBackend" in helper,
        "bundled consumer helper is not explicitly composed from keyed state and one shared exact-identity native inventory/install backend",
        failures,
    )
    require(
        re.search(r"livePersonalTeamExperimentEnabled: Bool\s*\{\s*true\s*\}", policy) is not None,
        "bundled production setup does not enable the selected no-Xcode provisioning architecture",
        failures,
    )
    require(
        "NativeDeviceBridge" in policy and "libiossim_device_bridge.dylib" in policy,
        "native capability policy does not inspect the actual bundled bridge",
        failures,
    )
    require(
        'Self.symbol("iossim_bridge_launch_app", in: loaded)' in native_bridge
        and "transport.launchApplication(on: device, bundleIdentifier: bundleIdentifier)" in native_apps,
        "native AppService launch is not wired through the Swift/C bridge",
        failures,
    )

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("PASS: consumer install/inventory/uninstall/container routing is native and has no devicectl fallback")
    print("PASS: native AppService launch is wired through the Swift/C bridge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
