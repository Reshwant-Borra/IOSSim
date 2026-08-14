from __future__ import annotations

import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from drive_testing.experiment_controller import DriveExperimentController
from drive_testing.experiment_queue import ExperimentQueueController
from drive_testing.experiment_store import ExperimentStore
from drive_testing.router import build_router


ROUTE = [{"lat": 28.0, "lon": -82.0}, {"lat": 28.0, "lon": -81.98}]


class FakeClock:
    def __init__(self) -> None:
        self.value = 0.0
        self.lock = threading.Lock()

    def now(self) -> float:
        with self.lock:
            return self.value

    def sleep(self, seconds: float) -> None:
        with self.lock:
            self.value += seconds


def device_status() -> dict:
    return {"pmd3_available": True, "device_connected": True, "device": {"udid": "FULL-PRIVATE-UDID", "name": "Test iPhone", "ios_version": "17.4", "ios_major": 17, "needs_tunnel": True}, "tunnel_active": True, "tunnel": {"address": "fd00::1", "port": 1234}}


class DriveTestingApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        store = ExperimentStore(Path(self.temp.name))
        clock = FakeClock()
        controller = DriveExperimentController(lambda lat, lon: {"ok": True, "pid": 1}, lambda: {"ok": True}, store, device_status, lambda: {"state": "idle"}, clock=clock.now, sleeper=clock.sleep)
        queue = ExperimentQueueController(controller, sleeper=clock.sleep)
        app = FastAPI()
        app.include_router(build_router(controller, queue, device_status, lambda: {"state": "idle"}))
        self.client = TestClient(app)
        self.controller = controller

    def tearDown(self) -> None:
        self.temp.cleanup()

    def create(self, name: str = "API test") -> str:
        response = self.client.post("/api/experimental/drive-testing/experiments", json={"route": ROUTE, "profile_settings": {"name": name, "kind": "constant", "method": "timed_static", "target_speed_mph": 20, "distance_m": 20, "update_interval_s": 1}, "reset_gps_at_end": False})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()["experiment"]["experiment_id"]

    def test_403_when_either_flag_is_disabled(self) -> None:
        cases = [({}, 403), ({"IOS_SIM_ENABLE_EXPERIMENTAL": "1"}, 403), ({"IOS_SIM_ENABLE_DRIVE_TESTING": "1"}, 403)]
        for values, expected in cases:
            with patch.dict(os.environ, values, clear=True):
                response = self.client.get("/api/experimental/drive-testing/status")
                self.assertEqual(response.status_code, expected)
                self.assertEqual(response.json()["code"], "drive_testing_disabled")

    @patch.dict(os.environ, {"IOS_SIM_ENABLE_EXPERIMENTAL": "1", "IOS_SIM_ENABLE_DRIVE_TESTING": "1"}, clear=True)
    def test_status_redacts_udid_and_reports_readiness(self) -> None:
        response = self.client.get("/api/experimental/drive-testing/status")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertNotIn("FULL-PRIVATE-UDID", response.text)
        self.assertIn("udid_abbreviated", data["device"])
        self.assertEqual(data["readiness"]["overall"], "WARNING")

    @patch.dict(os.environ, {"IOS_SIM_ENABLE_EXPERIMENTAL": "1", "IOS_SIM_ENABLE_DRIVE_TESTING": "1"}, clear=True)
    def test_profile_generation_validation_creation_run_and_history(self) -> None:
        generated = self.client.post("/api/experimental/drive-testing/profiles/generate", json={"coordinates": ROUTE, "settings": {"kind": "constant", "target_speed_mph": 20, "distance_m": 20, "update_interval_s": 1}})
        self.assertEqual(generated.status_code, 200)
        validated_route = self.client.post("/api/experimental/drive-testing/routes/validate", json={"coordinates": ROUTE, "minimum_distance_m": 20})
        self.assertEqual(validated_route.status_code, 200)
        experiment_id = self.create()
        validation = self.client.post(f"/api/experimental/drive-testing/experiments/{experiment_id}/validate")
        self.assertEqual(validation.status_code, 200, validation.text)
        denied = self.client.post(f"/api/experimental/drive-testing/experiments/{experiment_id}/start", json={"confirm_authorized_use": False})
        self.assertEqual(denied.status_code, 409)
        started = self.client.post(f"/api/experimental/drive-testing/experiments/{experiment_id}/start", json={"confirm_authorized_use": True})
        self.assertEqual(started.status_code, 200, started.text)
        deadline = time.monotonic() + 2
        status = self.client.get(f"/api/experimental/drive-testing/experiments/{experiment_id}/status").json()
        while status["state"] in {"starting", "running"} and time.monotonic() < deadline:
            time.sleep(0.005)
            status = self.client.get(f"/api/experimental/drive-testing/experiments/{experiment_id}/status").json()
        self.assertEqual(status["state"], "completed")
        history = self.client.get("/api/experimental/drive-testing/experiments").json()["experiments"]
        self.assertEqual(history[0]["experiment_id"], experiment_id)
        events = self.client.get(f"/api/experimental/drive-testing/experiments/{experiment_id}/events").json()["events"]
        self.assertTrue(any(event.get("event_type") == "location_write" for event in events))

    @patch.dict(os.environ, {"IOS_SIM_ENABLE_EXPERIMENTAL": "1", "IOS_SIM_ENABLE_DRIVE_TESTING": "1"}, clear=True)
    def test_observation_comparison_exports_and_confirmed_deletion(self) -> None:
        first = self.create("first")
        second = self.create("second")
        observation = self.client.post(f"/api/experimental/drive-testing/experiments/{first}/observation", json={"result": "trip_observed", "phone_state": "stationary", "notes": "manual"})
        self.assertEqual(observation.status_code, 200, observation.text)
        comparison = self.client.post("/api/experimental/drive-testing/compare", json={"experiment_ids": [first, second], "preset": "timed static vs timestamped GPX"})
        self.assertEqual(comparison.status_code, 200)
        self.assertFalse(comparison.json()["show_percentages"])
        self.assertIn("Exploratory observations only", comparison.json()["disclaimer"])
        exported_json = self.client.get(f"/api/experimental/drive-testing/experiments/{first}/export/json")
        exported_csv = self.client.get(f"/api/experimental/drive-testing/experiments/{first}/export/csv")
        self.assertEqual(exported_json.status_code, 200)
        self.assertEqual(exported_csv.status_code, 200)
        self.assertEqual(self.client.delete(f"/api/experimental/drive-testing/experiments/{first}").status_code, 400)
        deleted = self.client.delete(f"/api/experimental/drive-testing/experiments/{first}?confirm=true")
        self.assertEqual(deleted.status_code, 200)
        self.assertIn("not changed", deleted.json()["message"].lower())

    @patch.dict(os.environ, {"IOS_SIM_ENABLE_EXPERIMENTAL": "1", "IOS_SIM_ENABLE_DRIVE_TESTING": "1"}, clear=True)
    def test_queue_and_quick_test_preview(self) -> None:
        experiment_id = self.create()
        configured = self.client.post("/api/experimental/drive-testing/queue", json={"entries": [{"experiment_id": experiment_id, "repeats": 1, "reset_gps_after": False, "delay_after_s": 0}], "stop_on_failure": True})
        self.assertEqual(configured.status_code, 200)
        preview = self.client.post("/api/experimental/drive-testing/quick-test", json={"route": ROUTE, "confirm_authorized_use": False, "reset_gps_at_end": True})
        self.assertEqual(preview.status_code, 200)
        self.assertTrue(preview.json()["requires_confirmation"])
        self.assertGreater(preview.json()["calculated_duration_s"], 0)


if __name__ == "__main__":
    unittest.main()
