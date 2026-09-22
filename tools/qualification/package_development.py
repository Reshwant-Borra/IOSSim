#!/usr/bin/env python3
"""Build a separate, universal debug app. Never a release or M4 qualification artifact."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/bootstrap"))
import iossim_cli as cli


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", type=Path, required=True, help="verified DeviceArtifacts directory")
    args = parser.parse_args()
    runner = cli.Runner()
    if not cli.build_host_device_bridge(runner):
        return 1
    products = cli.build_universal_macos_products(runner, configuration="debug")
    environment = os.environ.copy()
    environment.update({
        "IOSSIM_MAC_CONFIGURATION": "debug",
        "IOSSIM_MAC_APP_NAME": "Veya Development",
        "IOSSIM_MAC_BUNDLE_IDENTIFIER": "com.veya.development-session",
        "IOSSIM_MAC_BUILD_ROOT": str(ROOT / ".build/iossim/development-session"),
        "IOSSIM_MAC_BUILD_VARIANT": "VEYA_DEVELOPMENT_SESSION",
        "IOSSIM_MAC_PRODUCTS_PATH": str(products),
        "IOSSIM_DEVICE_ARTIFACTS_SOURCE": str(args.payload.resolve()),
        "IOSSIM_MAC_CODE_SIGN_IDENTITY": "-",
    })
    return subprocess.run([str(ROOT / "macos/scripts/build_app.sh")], cwd=ROOT, env=environment).returncode


if __name__ == "__main__":
    raise SystemExit(main())
