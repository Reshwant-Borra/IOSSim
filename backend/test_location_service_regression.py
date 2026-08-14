from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from device_manager import DeviceInfo, TunnelInfo
from location_service import LocationService, _build_gpx


class FakeManager:
    def __init__(self, ios_major: int = 17) -> None:
        self.device = DeviceInfo("TEST-UDID", "Test iPhone", f"{ios_major}.0", ios_major)
        self.tunnel = TunnelInfo("fd00::1", 12345) if ios_major >= 17 else None


class LocationServiceRegressionTests(unittest.TestCase):
    @patch("location_service.subprocess.Popen")
    def test_ios17_set_command_still_sends_only_lat_lon(self, popen: MagicMock) -> None:
        process = MagicMock(pid=444)
        process.poll.return_value = None
        popen.return_value = process
        service = LocationService(FakeManager())
        result = service.set_location(28.12345, -82.54321)
        command = popen.call_args.args[0]
        self.assertTrue(result["ok"])
        self.assertEqual(command[-3:], ["--", "28.12345", "-82.54321"])
        self.assertIn("developer", command)
        self.assertIn("dvt", command)
        self.assertNotIn("speed", command)
        self.assertNotIn("course", command)

    def test_legacy_gpx_remains_coordinate_only(self) -> None:
        xml = _build_gpx([{"lat": 1, "lon": 2}, {"lat": 3, "lon": 4}])
        self.assertIn('trkpt lat="1" lon="2"', xml)
        self.assertNotIn("<time>", xml)
        self.assertNotIn("<ele>", xml)
        self.assertNotIn("speed", xml)
        self.assertNotIn("course", xml)


if __name__ == "__main__":
    unittest.main()
