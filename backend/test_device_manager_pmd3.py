from __future__ import annotations

import json
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import device_manager
from device_manager import DeviceManager, TunnelInfo
from drive_testing.router import _readiness


def cli_status(available: bool, returncode: int = 0) -> dict:
    return {
        "available": available,
        "python_executable": "python-under-test",
        "package_version": "9.9.9",
        "cli_returncode": returncode,
        "stderr_summary": "" if available else "No module named pymobiledevice3",
        "message": "" if available else "No module named pymobiledevice3",
    }


class DeviceManagerPmd3AvailabilityTests(unittest.TestCase):
    def test_cli_available_optional_python_import_available(self) -> None:
        lockdown = SimpleNamespace(
            udid="PRIVATE-UDID",
            all_values={"ProductVersion": "17.4", "DeviceName": "Test iPhone"},
        )
        with patch.object(device_manager, "create_using_usbmux", MagicMock(return_value=lockdown)), \
             patch.object(device_manager, "_PMD3_PYTHON_API_AVAILABLE", True), \
             patch.object(device_manager, "_check_pmd3_cli", return_value=cli_status(True)):
            status = DeviceManager().status()

        self.assertTrue(status["pmd3_available"])
        self.assertTrue(status["pmd3_cli_available"])
        self.assertTrue(status["pmd3_python_api_available"])
        self.assertTrue(status["device_connected"])
        self.assertEqual(status["device"]["name"], "Test iPhone")

    def test_cli_available_optional_python_import_unavailable(self) -> None:
        devices = [{"SerialNumber": "CLI-UDID", "DeviceName": "CLI iPhone", "ProductVersion": "17.5"}]
        result = SimpleNamespace(returncode=0, stdout=json.dumps(devices), stderr="")
        with patch.object(device_manager, "create_using_usbmux", None), \
             patch.object(device_manager, "_PMD3_PYTHON_API_AVAILABLE", False), \
             patch.object(device_manager, "_check_pmd3_cli", return_value=cli_status(True)), \
             patch("device_manager.subprocess.run", return_value=result):
            status = DeviceManager().status()

        self.assertTrue(status["pmd3_available"])
        self.assertTrue(status["pmd3_cli_available"])
        self.assertFalse(status["pmd3_python_api_available"])
        self.assertTrue(status["device_connected"])
        self.assertEqual(status["device"]["udid"], "CLI-UDID")

    def test_cli_unavailable_reports_diagnostics(self) -> None:
        result = SimpleNamespace(returncode=1, stdout="", stderr="No module named pymobiledevice3")
        with patch.object(device_manager, "create_using_usbmux", None), \
             patch.object(device_manager, "_PMD3_PYTHON_API_AVAILABLE", False), \
             patch.object(device_manager, "_check_pmd3_cli", return_value=cli_status(False, 1)), \
             patch("device_manager.subprocess.run", return_value=result):
            status = DeviceManager().status()

        self.assertFalse(status["pmd3_available"])
        self.assertFalse(status["pmd3_cli_available"])
        self.assertIn("python_executable", status["pmd3_diagnostics"])
        self.assertEqual(status["pmd3_diagnostics"]["cli_returncode"], 1)
        self.assertIn("No module", status["pmd3_diagnostics"]["stderr_summary"])

    def test_device_found_through_cli_fallback_when_python_api_missing(self) -> None:
        devices = [{"UDID": "FALLBACK-UDID", "DeviceName": "Fallback iPhone", "ProductVersion": "16.7"}]
        result = SimpleNamespace(returncode=0, stdout=json.dumps(devices), stderr="")
        with patch.object(device_manager, "create_using_usbmux", None), \
             patch("device_manager.subprocess.run", return_value=result):
            device = DeviceManager().detect()

        self.assertIsNotNone(device)
        assert device is not None
        self.assertEqual(device.udid, "FALLBACK-UDID")
        self.assertEqual(device.ios_major, 16)

    def test_cli_fallback_uses_current_unique_device_id_field(self) -> None:
        devices = [{"UniqueDeviceID": "00008150-00022D581E12401C", "Identifier": "00008150-00022D581E12401C", "DeviceName": "Fallback iPhone", "ProductVersion": "26.6"}]
        result = SimpleNamespace(returncode=0, stdout=json.dumps(devices), stderr="")
        with patch.object(device_manager, "create_using_usbmux", None), \
             patch("device_manager.subprocess.run", return_value=result):
            device = DeviceManager().detect()

        self.assertIsNotNone(device)
        assert device is not None
        self.assertEqual(device.udid, "00008150-00022D581E12401C")

    def test_drive_testing_readiness_passes_required_cli_device_and_tunnel_checks(self) -> None:
        manager = DeviceManager()
        manager._device = device_manager.DeviceInfo("PRIVATE-UDID", "Test iPhone", "17.4", 17)
        manager._tunnel = TunnelInfo("fd00::1", 1234)
        manager._tunnel_proc = None
        with patch.object(manager, "detect", return_value=manager._device), \
             patch.object(manager, "_pmd3_cli_info", return_value=cli_status(True)):
            status = manager.status()

        readiness = _readiness(status, {"state": "idle"}, {"state": "idle"}, True)
        checks = {item["name"]: item for item in readiness["checks"]}
        self.assertEqual(checks["pymobiledevice3 available"]["status"], "PASS")
        self.assertEqual(checks["Device connected"]["status"], "PASS")
        self.assertEqual(checks["Tunnel active when required"]["status"], "PASS")

    def test_drive_testing_readiness_fails_when_cli_does_not_work(self) -> None:
        device = {
            "pmd3_available": False,
            "pmd3_diagnostics": cli_status(False, 1),
            "device_connected": True,
            "device": {"needs_tunnel": True},
            "tunnel_active": True,
        }
        readiness = _readiness(device, {"state": "idle"}, {"state": "idle"}, True)
        checks = {item["name"]: item for item in readiness["checks"]}

        self.assertEqual(checks["pymobiledevice3 available"]["status"], "FAIL")
        self.assertIn("python-under-test", checks["pymobiledevice3 available"]["detail"])
        self.assertEqual(readiness["overall"], "FAIL")


if __name__ == "__main__":
    unittest.main()
