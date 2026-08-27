from __future__ import annotations

import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import main


class LocationClearApiTests(unittest.TestCase):
    def test_clear_is_idempotent_when_no_device_or_simulation_is_active(self) -> None:
        with (
            patch.object(main.drive_testing, "active_experiment_id", return_value=None),
            patch.object(main.drive, "stop", return_value={"ok": True}),
            patch.object(main.wireless_location, "session_status", return_value={"simulation_enabled": False}),
            patch.object(main.svc, "clear_location", return_value={"ok": False, "message": "No device connected"}),
        ):
            response = TestClient(main.app).post("/api/location/clear")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertTrue(response.json()["ok"])
        self.assertEqual(response.json()["message"], "GPS is already using the real location.")

    def test_clear_still_uses_wireless_when_wireless_simulation_is_active(self) -> None:
        with (
            patch.object(main.drive_testing, "active_experiment_id", return_value=None),
            patch.object(main.drive, "stop", return_value={"ok": True}),
            patch.object(main.wireless_location, "session_status", return_value={"simulation_enabled": True}),
            patch.object(main.wireless_location, "clear_location", return_value={"ok": True, "message": "GPS reset wirelessly."}) as clear_wireless,
            patch.object(main.svc, "clear_location") as clear_wired,
        ):
            response = TestClient(main.app).post("/api/location/clear")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["message"], "GPS reset wirelessly.")
        clear_wireless.assert_called_once()
        clear_wired.assert_not_called()


if __name__ == "__main__":
    unittest.main()
