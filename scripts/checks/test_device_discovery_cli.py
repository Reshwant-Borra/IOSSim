#!/usr/bin/env python3
import importlib.util
import inspect
import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "bootstrap" / "iossim_cli.py"
SPEC = importlib.util.spec_from_file_location("iossim_cli", MODULE_PATH)
assert SPEC and SPEC.loader
iossim_cli = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = iossim_cli
SPEC.loader.exec_module(iossim_cli)


class DeviceDiscoveryCLITests(unittest.TestCase):
    def test_transport_failure_is_not_an_empty_success(self) -> None:
        payload = json.dumps({
            "ok": False,
            "data": {
                "rawDeviceCount": 0,
                "returnedDeviceCount": 0,
                "devices": [],
                "diagnostics": [{"code": "USBMUX_UNAVAILABLE", "detail": "socket unavailable"}],
            },
        })
        result = iossim_cli.parse_native_discovery_payload(payload, Path("helper"), Path("bridge"))
        self.assertFalse(result.available)
        self.assertEqual(result.error_code, "USBMUX_UNAVAILABLE")
        self.assertEqual(result.devices, [])

    def test_future_product_and_os_are_retained(self) -> None:
        payload = json.dumps({
            "ok": True,
            "data": {
                "rawDeviceCount": 1,
                "returnedDeviceCount": 1,
                "devices": [{
                    "name": "Future iPhone",
                    "identifier": "PHONE...0001",
                    "selectionIdentifier": "PHONE-0001",
                    "udidRedacted": "PHONE...0001",
                    "model": "iPhone99,1",
                    "osVersion": "99.0",
                    "developerModeStatus": "unknown",
                    "pairingState": "unknown",
                    "tunnelState": "not-checked",
                }],
                "diagnostics": [{"code": "DEVICE_DISCOVERED", "detail": "one device"}],
            },
        })
        result = iossim_cli.parse_native_discovery_payload(payload, Path("helper"), Path("bridge"))
        self.assertTrue(result.available)
        self.assertEqual(result.returned_count, 1)
        self.assertEqual(result.devices[0]["model"], "iPhone99,1")
        self.assertEqual(result.devices[0]["osVersion"], "99.0")

    def test_count_comparison_identifies_exact_boundary(self) -> None:
        self.assertEqual(iossim_cli.discovery_count_mismatches(1, 1, 1, 1), [])
        self.assertEqual(
            iossim_cli.discovery_count_mismatches(1, 0, 0, 0),
            ["Rust parsed=0", "C ABI=0", "Swift=0"],
        )

    def test_development_doctor_discovery_contains_no_devicectl(self) -> None:
        source = inspect.getsource(iossim_cli.discover_native_devices)
        source += inspect.getsource(iossim_cli.check_devices)
        self.assertNotIn("devicectl", source.lower())
        self.assertNotIn("xcrun", source.lower())

    def test_local_mac_build_embeds_the_consumer_discovery_stack(self) -> None:
        source = (ROOT / "macos" / "scripts" / "build_app.sh").read_text(encoding="utf-8")
        self.assertIn("IOSSIM_BUNDLED_ENGINE", source)
        self.assertIn("IOSSimProvisioner", source)
        self.assertIn("libiossim_device_bridge.dylib", source)
        self.assertNotIn("DevelopmentRepositoryRoot.txt", source)


if __name__ == "__main__":
    unittest.main()
