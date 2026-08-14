from __future__ import annotations

import tempfile
import threading
import time
import unittest
from pathlib import Path

from drive_testing.experiment_controller import DriveExperimentController
from drive_testing.experiment_queue import ExperimentQueueController
from drive_testing.experiment_store import ExperimentStore
from drive_testing.profile_generator import generate_profile


ROUTE = [{"lat": 28.0, "lon": -82.0}, {"lat": 28.0, "lon": -81.99}]


class FakeClock:
    def __init__(self) -> None:
        self.value = 0.0
        self.lock = threading.Lock()

    def now(self) -> float:
        with self.lock:
            return self.value

    def sleep(self, seconds: float) -> None:
        with self.lock:
            self.value += max(0.0, seconds)


def ready_device() -> dict:
    return {
        "pmd3_available": True,
        "device_connected": True,
        "device": {"name": "Test", "ios_version": "17.4", "ios_major": 17, "needs_tunnel": True},
        "tunnel_active": True,
        "tunnel": {"address": "redacted", "port": 1234},
    }


def idle_drive() -> dict:
    return {"state": "idle"}


class DriveExperimentControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.store = ExperimentStore(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_controller(self, writer=None, clearer=None, device=ready_device, stable=idle_drive, sleeper=None):
        clock = FakeClock()
        controller = DriveExperimentController(
            writer or (lambda lat, lon: {"ok": True, "pid": 10}),
            clearer or (lambda: {"ok": True}),
            self.store,
            device,
            stable,
            clock=clock.now,
            sleeper=sleeper or clock.sleep,
        )
        return controller, clock

    def create(self, controller: DriveExperimentController, repeats: int = 1) -> str:
        profile = generate_profile(ROUTE, {"name": "short", "kind": "constant", "target_speed_mph": 20, "distance_m": 20, "update_interval_s": 1, "random_seed": 1})
        return controller.create(ROUTE, profile, {"repeats": repeats, "reset_gps_at_end": False})["experiment_id"]

    def wait_done(self, controller: DriveExperimentController, experiment_id: str) -> dict:
        deadline = time.monotonic() + 10
        status = controller.status(experiment_id)
        while status["state"] in {"starting", "running", "paused", "stopping"} and time.monotonic() < deadline:
            time.sleep(0.005)
            status = controller.status(experiment_id)
        return status

    def test_successful_run_and_repeat_execution(self) -> None:
        writes = []
        controller, _ = self.make_controller(writer=lambda lat, lon: writes.append((lat, lon)) or {"ok": True, "pid": 99})
        experiment_id = self.create(controller, repeats=2)
        result = controller.start(experiment_id, confirm_authorized_use=True)
        self.assertTrue(result["ok"])
        final = self.wait_done(controller, experiment_id)
        self.assertEqual(final["state"], "completed")
        record = self.store.get(experiment_id, include_events=True)
        self.assertEqual(record["repeat_number"], 2)
        self.assertGreater(len(writes), 2)
        self.assertTrue((self.store.path_for(experiment_id) / "events.jsonl").exists())
        self.assertTrue((self.store.path_for(experiment_id) / "report.md").exists())

    def test_writer_failure_preserves_partial_log(self) -> None:
        calls = 0

        def writer(lat, lon):
            nonlocal calls
            calls += 1
            return {"ok": calls < 2, "message": "writer failed"}

        controller, _ = self.make_controller(writer=writer)
        experiment_id = self.create(controller)
        controller.start(experiment_id, True)
        final = self.wait_done(controller, experiment_id)
        self.assertEqual(final["state"], "error")
        events = self.store.events(experiment_id)
        self.assertTrue(any(event.get("location_write_success") is False for event in events))
        self.assertTrue((self.store.path_for(experiment_id) / "summary.json").exists())

    def test_device_disconnect_and_tunnel_loss_stop_safely(self) -> None:
        for failure in ("device", "tunnel"):
            calls = 0

            def status_provider():
                nonlocal calls
                calls += 1
                status = ready_device()
                if calls > 3:
                    if failure == "device":
                        status["device_connected"] = False
                    else:
                        status["tunnel_active"] = False
                return status

            controller, _ = self.make_controller(device=status_provider)
            experiment_id = self.create(controller)
            controller.start(experiment_id, True)
            final = self.wait_done(controller, experiment_id)
            self.assertEqual(final["state"], "error")

    def test_stable_drive_conflict_and_authorization_confirmation(self) -> None:
        controller, _ = self.make_controller(stable=lambda: {"state": "driving"})
        experiment_id = self.create(controller)
        self.assertEqual(controller.start(experiment_id, True)["code"], "stable_drive_conflict")
        controller, _ = self.make_controller()
        experiment_id = self.create(controller)
        self.assertEqual(controller.start(experiment_id, False)["code"], "authorization_confirmation_required")

    def test_pause_resume_stop_and_duplicate_start(self) -> None:
        release = threading.Event()
        clock = FakeClock()

        def blocking_sleep(seconds: float) -> None:
            release.wait(timeout=0.5)
            clock.sleep(seconds)

        controller = DriveExperimentController(
            lambda lat, lon: {"ok": True},
            lambda: {"ok": True},
            self.store,
            ready_device,
            idle_drive,
            clock=clock.now,
            sleeper=blocking_sleep,
        )
        first = self.create(controller)
        second = self.create(controller)
        controller.start(first, True)
        deadline = time.monotonic() + 1
        while controller.status(first)["state"] != "running" and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertEqual(controller.start(second, True)["code"], "duplicate_start")
        paused = controller.pause(first)
        self.assertEqual(paused["state"], "paused")
        resumed = controller.resume(first)
        self.assertEqual(resumed["state"], "running")
        controller.stop(first, wait=False)
        release.set()
        final = self.wait_done(controller, first)
        self.assertEqual(final["state"], "cancelled")

    def test_emergency_stop_records_reset_failure(self) -> None:
        release = threading.Event()
        clock = FakeClock()

        def blocking_sleep(seconds: float) -> None:
            release.wait(timeout=0.5)
            clock.sleep(seconds)

        controller = DriveExperimentController(
            lambda lat, lon: {"ok": True},
            lambda: {"ok": False, "message": "clear failed"},
            self.store,
            ready_device,
            idle_drive,
            clock=clock.now,
            sleeper=blocking_sleep,
        )
        experiment_id = self.create(controller)
        controller.start(experiment_id, True)
        result_holder = {}

        def stop():
            result_holder.update(controller.emergency_stop(experiment_id))

        thread = threading.Thread(target=stop)
        thread.start()
        release.set()
        thread.join(timeout=2)
        self.assertIn("GPS reset failed", result_holder.get("last_error") or "")
        self.assertTrue(any(event.get("event_type") == "location_reset" and not event.get("success") for event in self.store.events(experiment_id)))

    def test_queue_completes_and_stops_on_failure(self) -> None:
        controller, _ = self.make_controller()
        experiment_id = self.create(controller)
        queue = ExperimentQueueController(controller, sleeper=lambda _: None)
        configured = queue.configure([{"experiment_id": experiment_id, "repeats": 1, "reset_gps_after": False, "delay_after_s": 0}], True)
        self.assertEqual(configured["state"], "ready")
        queue.start(True)
        deadline = time.monotonic() + 10
        while queue.status()["state"] == "running" and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertEqual(queue.status()["state"], "completed")

        failing, _ = self.make_controller(writer=lambda lat, lon: {"ok": False, "message": "failure"})
        failed_id = self.create(failing)
        failed_queue = ExperimentQueueController(failing, sleeper=lambda _: None)
        failed_queue.configure([{"experiment_id": failed_id, "repeats": 1, "reset_gps_after": False, "delay_after_s": 0}], True)
        failed_queue.start(True)
        deadline = time.monotonic() + 10
        while failed_queue.status()["state"] == "running" and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertEqual(failed_queue.status()["state"], "failed")
        self.assertTrue(failed_queue.status()["requires_confirmation"])


if __name__ == "__main__":
    unittest.main()
