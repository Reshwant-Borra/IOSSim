#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "config" / "bundle-identifiers.json"
PBXPROJ = ROOT / "ios" / "IOSSimOnDevicePOC.xcodeproj" / "project.pbxproj"
DVT_CLIENT = ROOT / "ios" / "Sources" / "IOSSimOnDeviceDVTPOC" / "DvtLocationClient.swift"
XCUI_TEST = ROOT / "ios" / "Tests" / "LocationControl" / "AppleXCUILocationControlUITests.swift"
MAC_BUILD_SCRIPT = ROOT / "macos" / "scripts" / "build_app.sh"


def fail(message: str) -> int:
    print(f"[FAIL] Bundle identifier inventory: {message}")
    return 1


def main() -> int:
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    entries = {entry["logicalRole"]: entry for entry in data["identifiers"]}
    required_roles = {
        "iosMain",
        "locationWitness",
        "locationControlTests",
        "locationControlUITests",
        "locationControlRunner",
        "macProvisioner",
    }
    missing = sorted(required_roles.difference(entries))
    if missing:
        return fail(f"missing roles: {', '.join(missing)}")

    pbx = PBXPROJ.read_text(encoding="utf-8", errors="ignore")
    for role in ["iosMain", "locationWitness", "locationControlTests", "locationControlUITests"]:
        bundle_id = entries[role]["bundleIdentifier"]
        if bundle_id not in pbx:
            return fail(f"{role} identifier is not present in project.pbxproj")

    runner_id = entries["locationControlRunner"]["bundleIdentifier"]
    if runner_id not in DVT_CLIENT.read_text(encoding="utf-8", errors="ignore"):
        return fail("generated XCTest runner identifier is not referenced by DvtLocationClient")

    witness_id = entries["locationWitness"]["bundleIdentifier"]
    if witness_id not in XCUI_TEST.read_text(encoding="utf-8", errors="ignore"):
        return fail("witness identifier is not referenced by XCUILocation tests")

    mac_id = entries["macProvisioner"]["bundleIdentifier"]
    if mac_id not in MAC_BUILD_SCRIPT.read_text(encoding="utf-8", errors="ignore"):
        return fail("Mac bundle identifier is not the build-script default")

    print("[PASS] Bundle identifier inventory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
