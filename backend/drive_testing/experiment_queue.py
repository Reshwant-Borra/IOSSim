from __future__ import annotations

import threading
import time
from typing import Any, Callable

from .experiment_controller import DriveExperimentController


class ExperimentQueueController:
    def __init__(self, controller: DriveExperimentController, sleeper: Callable[[float], None] = time.sleep) -> None:
        self.controller = controller
        self._sleeper = sleeper
        self._lock = threading.RLock()
        self._stop_event = threading.Event()
        self._worker: threading.Thread | None = None
        self._entries: list[dict[str, Any]] = []
        self._status: dict[str, Any] = {"ok": True, "state": "idle", "current_index": None, "entries": [], "estimated_total_duration_s": 0.0, "last_error": None, "requires_confirmation": False}

    def configure(self, entries: list[dict[str, Any]], stop_on_failure: bool = True) -> dict:
        if self._status["state"] in {"running", "paused"}:
            return {"ok": False, "message": "Stop the queue before replacing it", "code": "queue_active"}
        estimate = 0.0
        validated = []
        for entry in entries:
            if not self.controller.store.exists(entry["experiment_id"]):
                return {"ok": False, "message": f"Experiment {entry['experiment_id']} does not exist", "code": "not_found"}
            record = self.controller.store.get(entry["experiment_id"])
            duration = float(record["profile"].get("planned_duration_s", 0.0))
            estimate += (duration + float(entry.get("delay_after_s", 0.0))) * int(entry.get("repeats", 1))
            validated.append(dict(entry))
        with self._lock:
            self._entries = validated
            self._status = {"ok": True, "state": "ready", "current_index": None, "entries": validated, "estimated_total_duration_s": estimate, "last_error": None, "requires_confirmation": False, "stop_on_failure": stop_on_failure}
        return self.status()

    def start(self, confirm_authorized_use: bool = False) -> dict:
        if not confirm_authorized_use:
            return {"ok": False, "message": "Queue start requires authorized-use confirmation", "code": "authorization_confirmation_required"}
        with self._lock:
            if self._status["state"] not in {"ready", "stopped", "completed"}:
                return {"ok": False, "message": "Queue is not ready", "code": "invalid_state"}
            self._stop_event.clear()
            self._status.update({"state": "running", "last_error": None, "requires_confirmation": False})
            self._worker = threading.Thread(target=self._run, daemon=True)
            self._worker.start()
        return self.status()

    def pause(self) -> dict:
        with self._lock:
            if self._status["state"] != "running":
                return {"ok": False, "message": "Queue is not running", "code": "invalid_state"}
            current = self._status.get("current_experiment_id")
        if current:
            result = self.controller.pause(current)
            if not result.get("ok"):
                return result
        with self._lock:
            self._status["state"] = "paused"
        return self.status()

    def resume(self) -> dict:
        with self._lock:
            if self._status["state"] != "paused":
                return {"ok": False, "message": "Queue is not paused", "code": "invalid_state"}
            current = self._status.get("current_experiment_id")
        if current:
            result = self.controller.resume(current)
            if not result.get("ok"):
                return result
        with self._lock:
            self._status["state"] = "running"
        return self.status()

    def stop(self) -> dict:
        self._stop_event.set()
        current = self._status.get("current_experiment_id")
        if current and self.controller.is_location_operation_active():
            self.controller.stop(current, reset_gps=False)
        with self._lock:
            self._status["state"] = "stopped"
        return self.status()

    def status(self) -> dict:
        with self._lock:
            return dict(self._status)

    def _run(self) -> None:
        for index, entry in enumerate(self._entries):
            for repeat in range(int(entry.get("repeats", 1))):
                if self._stop_event.is_set():
                    return
                experiment_id = entry["experiment_id"]
                with self._lock:
                    self._status.update({"current_index": index, "current_repeat": repeat + 1, "current_experiment_id": experiment_id})
                result = self.controller.start(experiment_id, confirm_authorized_use=True)
                if not result.get("ok"):
                    self._fail(result.get("message", "Queue entry failed to start"))
                    return
                while self.controller.is_location_operation_active() and not self._stop_event.is_set():
                    self._sleeper(0.1)
                final = self.controller.status(experiment_id)
                if final.get("state") != "completed":
                    self._fail(final.get("last_error") or f"Queue entry ended as {final.get('state')}")
                    return
                if entry.get("reset_gps_after"):
                    reset = self.controller.reset()
                    if not reset.get("ok"):
                        self._fail(f"Reset GPS failed: {reset.get('message')}")
                        return
                delay = float(entry.get("delay_after_s", 0.0))
                waited = 0.0
                while waited < delay and not self._stop_event.is_set():
                    step = min(0.1, delay - waited)
                    self._sleeper(step)
                    waited += step
        with self._lock:
            self._status.update({"state": "completed", "current_experiment_id": None, "current_index": None})

    def _fail(self, message: str) -> None:
        with self._lock:
            self._status.update({"state": "failed", "last_error": message, "requires_confirmation": True})
