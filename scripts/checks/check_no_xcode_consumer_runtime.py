#!/usr/bin/env python3
"""Audit production Swift sources for accidental Xcode device-tool use.

Known legacy comparison files are reported as LEGACY rather than hidden. New
consumer bridge/onboarding code is intentionally not allowed to mention these
tools.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "macos" / "Sources"
FORBIDDEN = ("devicectl", "xcrun", "xcodebuild", "xcode-select", "DEVELOPER_DIR", "CoreDevice")
CLASSIFICATIONS = {
    "ConsumerArtifactProvisioner.swift": "LEGACY",
    "RuntimeProvisioningSupport.swift": "LEGACY",
    "InstallationInventory.swift": "LEGACY",
    "SupportBundleExporter.swift": "BUILD_ONLY",
    "ConsumerProvisioning.swift": "LEGACY",
    "DoctorStatus.swift": "LEGACY",
    "ApplePersonalTeamExperimental.swift": "DEV_FALLBACK",
    "ApplePersonalTeamLive.swift": "DEV_FALLBACK",
    "DeveloperSupportCoordinator.swift": "BUILD_ONLY",
    "SetupStore.swift": "LEGACY",
    "main.swift": "BUILD_ONLY",
}

def main() -> int:
    violations = []
    for path in sorted(SOURCE.rglob("*.swift")):
        text = path.read_text(errors="replace")
        for line_no, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            lowered = line.lower()
            hits = [token for token in FORBIDDEN if token.lower() in lowered]
            if not hits:
                continue
            classification = CLASSIFICATIONS.get(path.name, "CONSUMER_RUNTIME")
            print(f"{classification}\t{path.relative_to(ROOT)}:{line_no}\t{','.join(hits)}")
            if classification == "CONSUMER_RUNTIME":
                violations.append((path, line_no))
    if violations:
        print(f"FAIL: {len(violations)} forbidden consumer-runtime occurrence(s)", file=sys.stderr)
        return 1
    print("PASS: no forbidden Xcode device-tool usage outside explicit legacy files")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
