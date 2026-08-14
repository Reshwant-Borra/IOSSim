from __future__ import annotations

import threading
import time
from pathlib import Path
from typing import Any, Callable

from drive_controller import LatLon, haversine_m

from .experiment_store import ExperimentStore, utc_now
from .gpx_generator import coordinate_only_gpx, timestamped_gpx
from .metrics import calculate_metrics
from .models import LOCATION_WRITING_STATES
from .profile_generator import mps_to_mph
from .quality_control import evaluate_quality
from .report_generator import generate_report, qc_markdown
from .route_sampler import validate_route


LocationWriter = Callable[[float, float], dict]
LocationClearer = Callable[[], dict]
Clock = Callable[[], float]
Sleeper = Callable[[float], None]
StatusProvider = Callable[[], dict]
EventLogger = Callable[[str, dict], dict | None]
GpxStarter = Callable[[str, str], dict]
GpxCanceller = Callable[[], dict]


class DriveExperimentController:
    """Owns one experimental location-writing worker at a time."""

    def __init__(
        self,
        location_writer: LocationWriter,
        location_clearer: LocationClearer,
        store: ExperimentStore,
        device_status_provider: StatusProvider,
        stable_drive_status_provider: StatusProvider,
        clock: Clock = time.monotonic,
        sleeper: Sleeper = time.sleep,
        event_logger: EventLogger | None = None,
        gpx_starter: GpxStarter | None = None,
        gpx_canceller: GpxCanceller | None = None,
        operation_lock: threading.RLock | None = None,
    ) -> None:
        self._write_location = location_writer
        self._clear_location = location_clearer
        self.store = store
        self._device_status = device_status_provider
        self._stable_drive_status = stable_drive_status_provider
        self._clock = clock
        self._sleeper = sleeper
        self._event_logger = event_logger or store.append_event
        self._gpx_starter = gpx_starter
        self._gpx_canceller = gpx_canceller
        self._operation_lock = operation_lock or threading.RLock()
        self._lock = threading.RLock()
        self._stop_event = threading.Event()
        self._worker: threading.Thread | None = None
        self._active_id: str | None = None
        self._runtime: dict[str, Any] = self._idle_status()

    def _idle_status(self) -> dict[str, Any]:
        return {
            "ok": True,
            "experiment_id": None,
            "run_id": None,
            "state": "idle",
            "profile_name": None,
            "method": None,
            "repeat_number": 0,
            "total_repeats": 0,
            "elapsed_s": 0.0,
            "estimated_remaining_s": None,
            "current_phase": None,
            "current_coordinate": None,
            "current_sample": 0,
            "total_samples": 0,
            "completed_distance_m": 0.0,
            "remaining_distance_m": 0.0,
            "host_planned_apparent_speed_mph": 0.0,
            "host_calculated_emitted_apparent_speed_mph": 0.0,
            "host_calculated_average_apparent_speed_mph": 0.0,
            "target_update_interval_s": 0.0,
            "actual_latest_update_interval_s": None,
            "latest_timing_drift_s": None,
            "latest_command_latency_s": None,
            "successful_location_writes": 0,
            "failed_location_writes": 0,
            "active_subprocess_pid": None,
            "device_connected": False,
            "tunnel_active": False,
            "pause_supported": True,
            "last_error": None,
            "message": "",
            "chart_points": [],
        }

    def is_location_operation_active(self) -> bool:
        with self._lock:
            return self._runtime.get("state") in LOCATION_WRITING_STATES

    def active_experiment_id(self) -> str | None:
        with self._lock:
            return self._active_id if self.is_location_operation_active() else None

    def create(self, route: list[dict], profile: dict, config: dict) -> dict:
        return self.store.create(route, profile, config)

    def validate(self, experiment_id: str) -> dict:
        with self._lock:
            if self.is_location_operation_active() and self._active_id != experiment_id:
                return self._error("Another Drive Testing experiment is active", "experiment_conflict")
        record = self.store.get(experiment_id)
        profile = record["profile"]
        route_result = validate_route(profile.get("route", []), float(profile.get("requested_distance_m", 0.0)))
        device = self._device_status()
        stable = self._stable_drive_status()
        checks = {
            "route_valid": bool(route_result.get("ok")),
            "profile_valid": bool(profile.get("samples")),
            "device_connected": bool(device.get("device_connected")),
            "pymobiledevice3_available": bool(device.get("pmd3_available")),
            "tunnel_ready": not bool((device.get("device") or {}).get("needs_tunnel")) or bool(device.get("tunnel_active")),
            "stable_drive_inactive": stable.get("state") not in {"starting", "driving", "paused"},
            "experiment_slot_available": not self.is_location_operation_active() or self._active_id == experiment_id,
        }
        ok = all(checks.values())
        state = "ready" if ok else "idle"
        self.store.update_manifest(
            experiment_id,
            state=state,
            validation=checks,
            config={
                **(record.get("config") or {}),
                "device_connected_before_start": checks["device_connected"],
                "tunnel_ready_before_start": checks["tunnel_ready"],
                "feature_flags_enabled": True,
            },
        )
        return {"ok": ok, "state": state, "checks": checks, "message": "Test is ready" if ok else "Validation failed"}

    def start(self, experiment_id: str, confirm_authorized_use: bool = False) -> dict:
        if not confirm_authorized_use:
            return self._error("Confirm that the device and test account are owned or authorized", "authorization_confirmation_required")
        with self._operation_lock:
            with self._lock:
                if self.is_location_operation_active():
                    return self._error("A Drive Testing experiment is already active", "duplicate_start")
                stable = self._stable_drive_status()
                if stable.get("state") in {"starting", "driving", "paused"}:
                    return self._error("Stop stable Drive Mode before starting Drive Testing", "stable_drive_conflict")
            validation = self.validate(experiment_id)
            if not validation.get("ok"):
                return validation

            record = self.store.get(experiment_id)
            profile = record["profile"]
            method = profile.get("method", "timed_static")
            if method in {"legacy_gpx", "timestamped_gpx", "gpx_pacing"} and not self._gpx_starter:
                return self._error("GPX playback is unavailable in this backend", "gpx_unavailable")

            with self._lock:
                self._active_id = experiment_id
                self._stop_event.clear()
                self._runtime = {
                    **self._idle_status(),
                    "experiment_id": experiment_id,
                    "state": "starting",
                    "profile_name": profile.get("name"),
                    "method": method,
                    "total_repeats": int(record.get("total_repeats", 1)),
                    "total_samples": len(profile.get("samples", [])),
                    "remaining_distance_m": float(profile.get("generated_distance_m", 0.0)),
                    "host_planned_apparent_speed_mph": float(profile.get("target_apparent_speed_mph", 0.0)),
                    "target_update_interval_s": float(profile.get("update_interval_s", 1.0)),
                    "pause_supported": method not in {"legacy_gpx", "timestamped_gpx", "gpx_pacing"},
                    "message": "Starting experimental test",
                }
                self.store.update_manifest(experiment_id, state="starting", last_error=None)
                self._worker = threading.Thread(target=self._run, args=(experiment_id,), daemon=True)
                self._worker.start()
                return dict(self._runtime)

    def pause(self, experiment_id: str) -> dict:
        with self._lock:
            if experiment_id != self._active_id or self._runtime.get("state") != "running":
                return self._error("Experiment is not running", "invalid_state")
            if not self._runtime.get("pause_supported", True):
                return self._error("Installed pymobiledevice3 does not provide confirmed GPX pause support", "pause_unsupported")
            self._runtime["state"] = "paused"
            self._runtime["message"] = "Experiment paused"
            self.store.update_manifest(experiment_id, state="paused")
            self._log(experiment_id, {"event_type": "state", "actual_timestamp": utc_now(), "state": "paused", "experiment_id": experiment_id})
            return dict(self._runtime)

    def resume(self, experiment_id: str) -> dict:
        with self._lock:
            if experiment_id != self._active_id or self._runtime.get("state") != "paused":
                return self._error("Experiment is not paused", "invalid_state")
            self._runtime["state"] = "running"
            self._runtime["message"] = "Experiment resumed"
            self.store.update_manifest(experiment_id, state="running")
            self._log(experiment_id, {"event_type": "state", "actual_timestamp": utc_now(), "state": "running", "experiment_id": experiment_id})
            return dict(self._runtime)

    def stop(self, experiment_id: str, reset_gps: bool = False, emergency: bool = False, wait: bool = True) -> dict:
        with self._lock:
            if experiment_id != self._active_id or not self.is_location_operation_active():
                return self._error("Experiment is not active", "invalid_state")
            self._runtime["state"] = "stopping"
            self._runtime["message"] = "Emergency stop requested" if emergency else "Stop requested"
            self._stop_event.set()
            worker = self._worker
        if self._gpx_canceller:
            cancel_result = self._gpx_canceller()
            self._log(experiment_id, {"event_type": "gpx_cancel", "experiment_id": experiment_id, "actual_timestamp": utc_now(), "success": bool(cancel_result.get("ok")), "error_message": cancel_result.get("message")})
        if wait and worker and worker.is_alive() and worker is not threading.current_thread():
            worker.join(timeout=15)
        if reset_gps or emergency:
            result = self._clear_location()
            self._log(experiment_id, {"event_type": "location_reset", "experiment_id": experiment_id, "actual_timestamp": utc_now(), "success": bool(result.get("ok")), "error_message": None if result.get("ok") else result.get("message")})
            with self._lock:
                self._runtime["reset_gps_succeeded"] = bool(result.get("ok"))
                if not result.get("ok"):
                    self._runtime["last_error"] = f"GPS reset failed: {result.get('message', 'unknown error')}"
                    self._runtime["message"] = self._runtime["last_error"]
                    self.store.update_manifest(experiment_id, last_error=self._runtime["last_error"])
        return self.status(experiment_id)

    def emergency_stop(self, experiment_id: str) -> dict:
        return self.stop(experiment_id, reset_gps=True, emergency=True)

    def repeat(self, experiment_id: str, confirm_authorized_use: bool = False) -> dict:
        record = self.store.get(experiment_id)
        duplicate = self.create(
            record["route"].get("coordinates", []),
            record["profile"],
            {**(record.get("config") or {}), "repeated_from": experiment_id},
        )
        return self.start(duplicate["experiment_id"], confirm_authorized_use=confirm_authorized_use)

    def status(self, experiment_id: str | None = None) -> dict:
        with self._lock:
            if self._active_id and (experiment_id is None or experiment_id == self._active_id):
                result = dict(self._runtime)
                try:
                    device = self._device_status()
                    result["device_connected"] = bool(device.get("device_connected"))
                    result["tunnel_active"] = bool(device.get("tunnel_active"))
                except Exception:
                    pass
                return result
        if experiment_id and self.store.exists(experiment_id):
            record = self.store.get(experiment_id)
            profile = record["profile"]
            summary = record.get("summary") or {}
            return {
                **self._idle_status(),
                "experiment_id": experiment_id,
                "run_id": record.get("run_id"),
                "state": record.get("state", "idle"),
                "profile_name": record.get("profile_name"),
                "method": record.get("method"),
                "repeat_number": record.get("repeat_number", 0),
                "total_repeats": record.get("total_repeats", 1),
                "total_samples": len(profile.get("samples", [])),
                "completed_distance_m": summary.get("emitted_distance_m", 0.0),
                "remaining_distance_m": max(0.0, float(profile.get("generated_distance_m", 0.0)) - float(summary.get("emitted_distance_m", 0.0))),
                "successful_location_writes": summary.get("successful_writes", 0),
                "failed_location_writes": summary.get("failed_writes", 0),
                "last_error": record.get("last_error"),
            }
        return self._idle_status()

    def record_observation(self, experiment_id: str, observation: dict) -> dict:
        payload = self.store.add_observation(experiment_id, observation)
        self._refresh_outputs(experiment_id)
        return payload

    def reset(self) -> dict:
        if self.is_location_operation_active() and self._active_id:
            return self.emergency_stop(self._active_id)
        result = self._clear_location()
        return {"ok": bool(result.get("ok")), "message": result.get("message", "GPS reset")}

    def _run(self, experiment_id: str) -> None:
        try:
            record = self.store.get(experiment_id)
            profile = record["profile"]
            if profile.get("method") in {"legacy_gpx", "timestamped_gpx", "gpx_pacing"}:
                self._run_gpx(experiment_id, record, profile)
            else:
                self._run_timed(experiment_id, record, profile)
        except Exception as exc:
            self._finish(experiment_id, "error", str(exc))

    def _run_timed(self, experiment_id: str, record: dict, profile: dict) -> None:
        samples = profile.get("samples", [])
        total_repeats = int(record.get("total_repeats", 1))
        for repeat in range(1, total_repeats + 1):
            if self._stop_event.is_set():
                self._finish(experiment_id, "cancelled", "Experiment stopped")
                return
            run_id = self.store.new_run_id()
            with self._lock:
                self._runtime.update({"run_id": run_id, "repeat_number": repeat, "state": "running", "message": "Experiment running"})
            self.store.update_manifest(experiment_id, run_id=run_id, repeat_number=repeat, state="running")
            self._log(experiment_id, {"event_type": "run_start", "experiment_id": experiment_id, "run_id": run_id, "repeat_number": repeat, "actual_timestamp": utc_now()})
            if not self._emit_samples(experiment_id, run_id, repeat, profile, samples):
                return
        if bool((record.get("config") or {}).get("reset_gps_at_end")):
            result = self._clear_location()
            self._log(experiment_id, {"event_type": "location_reset", "experiment_id": experiment_id, "run_id": self._runtime.get("run_id"), "actual_timestamp": utc_now(), "success": bool(result.get("ok")), "error_message": None if result.get("ok") else result.get("message")})
            if not result.get("ok"):
                self._finish(experiment_id, "error", f"Experiment completed but GPS reset failed: {result.get('message', 'unknown error')}")
                return
        self._finish(experiment_id, "completed", "Experiment completed")

    def _emit_samples(self, experiment_id: str, run_id: str, repeat: int, profile: dict, samples: list[dict]) -> bool:
        started = self._clock()
        paused_total = 0.0
        previous_write_at: float | None = None
        previous_coord: LatLon | None = None
        emitted_distance = 0.0
        for sample in samples:
            if self._stop_event.is_set():
                self._finish(experiment_id, "cancelled", "Experiment stopped")
                return False
            pause_started: float | None = None
            while True:
                with self._lock:
                    paused = self._runtime.get("state") == "paused"
                if not paused:
                    if pause_started is not None:
                        paused_total += max(0.0, self._clock() - pause_started)
                    break
                if pause_started is None:
                    pause_started = self._clock()
                if self._stop_event.is_set():
                    self._finish(experiment_id, "cancelled", "Experiment stopped while paused")
                    return False
                self._sleeper(0.05)

            target_time = started + paused_total + float(sample["planned_elapsed_s"])
            while self._clock() < target_time and not self._stop_event.is_set():
                self._sleeper(min(0.05, max(0.0, target_time - self._clock())))
            if self._stop_event.is_set():
                self._finish(experiment_id, "cancelled", "Experiment stopped")
                return False

            before_status = self._device_status()
            if not before_status.get("device_connected"):
                self._finish(experiment_id, "error", "Device disconnected before location write")
                return False
            needs_tunnel = bool((before_status.get("device") or {}).get("needs_tunnel"))
            if needs_tunnel and not before_status.get("tunnel_active"):
                self._finish(experiment_id, "error", "Required tunnel was lost")
                return False
            if self._stable_drive_status().get("state") in {"starting", "driving", "paused"}:
                self._finish(experiment_id, "error", "Stable Drive Mode became active during the experiment")
                return False

            write_started_at = self._clock()
            actual_elapsed = write_started_at - started - paused_total
            result = self._write_location(float(sample["latitude"]), float(sample["longitude"]))
            write_completed_at = self._clock()
            latency = max(0.0, write_completed_at - write_started_at)
            try:
                after_status = self._device_status()
            except Exception:
                after_status = {"device_connected": False, "tunnel_active": False}
            coord = LatLon(float(sample["latitude"]), float(sample["longitude"]))
            actual_interval = (write_started_at - previous_write_at) if previous_write_at is not None else 0.0
            distance = haversine_m(previous_coord, coord) if previous_coord is not None else 0.0
            speed = distance / actual_interval if actual_interval > 0 else 0.0
            if result.get("ok"):
                emitted_distance += distance
            timing_drift = actual_elapsed - float(sample["planned_elapsed_s"])
            process = result.get("process") or {}
            event = {
                "event_type": "location_write",
                "experiment_id": experiment_id,
                "run_id": run_id,
                "repeat_number": repeat,
                "sequence_number": sample["sequence"],
                "profile_phase": sample["phase"],
                "planned_timestamp": None,
                "actual_timestamp": utc_now(),
                "planned_elapsed_s": sample["planned_elapsed_s"],
                "actual_elapsed_s": actual_elapsed,
                "timing_drift_s": timing_drift,
                "latitude": coord.lat,
                "longitude": coord.lon,
                "distance_from_previous_m": distance,
                "cumulative_distance_m": emitted_distance,
                "target_apparent_speed_mps": sample["target_apparent_speed_mps"],
                "target_apparent_speed_mph": sample["target_apparent_speed_mph"],
                "host_calculated_apparent_speed_mps": speed,
                "host_calculated_apparent_speed_mph": mps_to_mph(speed),
                "planned_interval_s": sample["planned_interval_s"],
                "actual_interval_s": actual_interval,
                "location_write_start_time": write_started_at,
                "location_write_completion_time": write_completed_at,
                "write_latency_s": latency,
                "old_process_termination_started_at": process.get("old_process_termination_started_at"),
                "old_process_terminated_at": process.get("old_process_terminated_at"),
                "old_process_termination_result": process.get("old_process_termination_result"),
                "new_process_started_at": process.get("new_process_started_at"),
                "new_process_pid": result.get("pid"),
                "location_write_success": bool(result.get("ok")),
                "stdout_summary": str(result.get("stdout", ""))[:500],
                "stderr_summary": str(result.get("stderr", ""))[:500],
                "device_connected_before_write": bool(before_status.get("device_connected")),
                "device_connected_after_write": bool(after_status.get("device_connected")),
                "tunnel_active": bool(after_status.get("tunnel_active")),
                "pause_state": False,
                "error_code": None if result.get("ok") else result.get("code", "location_write_failed"),
                "error_message": None if result.get("ok") else result.get("message"),
            }
            self._log(experiment_id, event)
            with self._lock:
                successes = int(self._runtime.get("successful_location_writes", 0)) + (1 if result.get("ok") else 0)
                failures = int(self._runtime.get("failed_location_writes", 0)) + (0 if result.get("ok") else 1)
                average_speed = emitted_distance / actual_elapsed if actual_elapsed > 0 else 0.0
                chart = list(self._runtime.get("chart_points", []))
                chart.append({"elapsed_s": actual_elapsed, "planned_speed_mph": sample["target_apparent_speed_mph"], "emitted_speed_mph": mps_to_mph(speed), "distance_m": emitted_distance, "timing_drift_s": timing_drift, "latency_s": latency})
                self._runtime.update({
                    "elapsed_s": actual_elapsed,
                    "estimated_remaining_s": max(0.0, float(profile.get("planned_duration_s", 0.0)) - float(sample["planned_elapsed_s"])),
                    "current_phase": sample["phase"],
                    "current_coordinate": {"lat": coord.lat, "lon": coord.lon},
                    "current_sample": int(sample["sequence"]) + 1,
                    "completed_distance_m": emitted_distance,
                    "remaining_distance_m": max(0.0, float(profile.get("generated_distance_m", 0.0)) - emitted_distance),
                    "host_planned_apparent_speed_mph": sample["target_apparent_speed_mph"],
                    "host_calculated_emitted_apparent_speed_mph": mps_to_mph(speed),
                    "host_calculated_average_apparent_speed_mph": mps_to_mph(average_speed),
                    "actual_latest_update_interval_s": actual_interval,
                    "latest_timing_drift_s": timing_drift,
                    "latest_command_latency_s": latency,
                    "successful_location_writes": successes,
                    "failed_location_writes": failures,
                    "active_subprocess_pid": result.get("pid"),
                    "device_connected": bool(after_status.get("device_connected")),
                    "tunnel_active": bool(after_status.get("tunnel_active")),
                    "chart_points": chart[-500:],
                })
            if not result.get("ok"):
                self._finish(experiment_id, "error", result.get("message", "Location write failed"))
                return False
            previous_write_at = write_started_at
            previous_coord = coord
        return True

    def _run_gpx(self, experiment_id: str, record: dict, profile: dict) -> None:
        method = profile.get("method")
        content = coordinate_only_gpx(profile["samples"]) if method == "legacy_gpx" else timestamped_gpx(profile["samples"])
        path = self.store.path_for(experiment_id) / ("legacy_route.gpx" if method == "legacy_gpx" else "timestamped_route.gpx")
        path.write_text(content, encoding="utf-8")
        run_id = self.store.new_run_id()
        self.store.update_manifest(experiment_id, state="running", run_id=run_id, repeat_number=1)
        with self._lock:
            self._runtime.update({"state": "running", "run_id": run_id, "repeat_number": 1, "message": "GPX playback running; individual DVT writes are opaque to IOSSim"})
        result = self._gpx_starter(content, method) if self._gpx_starter else {"ok": False, "message": "GPX unavailable"}
        proc = result.get("process")
        with self._lock:
            self._runtime["active_subprocess_pid"] = result.get("pid")
        self._log(experiment_id, {"event_type": "gpx_process_start", "experiment_id": experiment_id, "run_id": run_id, "actual_timestamp": utc_now(), "method": method, "success": bool(result.get("ok")), "pid": result.get("pid"), "note": "GPX timestamps control host pacing only; device receives latitude and longitude"})
        if not result.get("ok"):
            self._finish(experiment_id, "error", result.get("message", "GPX playback failed"))
            return
        started = self._clock()
        duration = float(profile.get("planned_duration_s", 0.0))
        while proc is not None and proc.poll() is None and not self._stop_event.is_set():
            elapsed = self._clock() - started
            index = min(len(profile["samples"]) - 1, next((i for i, sample in enumerate(profile["samples"]) if float(sample["planned_elapsed_s"]) >= elapsed), len(profile["samples"]) - 1))
            sample = profile["samples"][index]
            with self._lock:
                self._runtime.update({"elapsed_s": elapsed, "estimated_remaining_s": max(0.0, duration - elapsed), "current_phase": sample["phase"], "current_coordinate": {"lat": sample["latitude"], "lon": sample["longitude"]}, "current_sample": index + 1, "completed_distance_m": sample["cumulative_distance_m"], "remaining_distance_m": max(0.0, float(profile.get("generated_distance_m", 0.0)) - float(sample["cumulative_distance_m"]))})
            self._sleeper(0.1)
        if self._stop_event.is_set():
            self._finish(experiment_id, "cancelled", "GPX playback cancelled")
            return
        returncode = proc.poll() if proc is not None else result.get("returncode", 1)
        if returncode not in {0, None}:
            self._finish(experiment_id, "error", f"GPX subprocess exited with code {returncode}")
            return
        if bool((record.get("config") or {}).get("reset_gps_at_end")):
            reset = self._clear_location()
            self._log(experiment_id, {"event_type": "location_reset", "experiment_id": experiment_id, "run_id": run_id, "actual_timestamp": utc_now(), "success": bool(reset.get("ok")), "error_message": None if reset.get("ok") else reset.get("message")})
            if not reset.get("ok"):
                self._finish(experiment_id, "error", f"GPX completed but GPS reset failed: {reset.get('message')}")
                return
        self._finish(experiment_id, "completed", "GPX playback completed; per-coordinate write telemetry was not observable")

    def _finish(self, experiment_id: str, state: str, message: str) -> None:
        error = message if state == "error" else None
        self.store.update_manifest(experiment_id, state=state, last_error=error)
        self._log(experiment_id, {"event_type": "run_end", "experiment_id": experiment_id, "run_id": self._runtime.get("run_id"), "actual_timestamp": utc_now(), "state": state, "error_message": error})
        self._refresh_outputs(experiment_id)
        with self._lock:
            self._runtime.update({"state": state, "message": message, "last_error": error, "active_subprocess_pid": None, "estimated_remaining_s": 0.0})
            self._active_id = None
            self._worker = None

    def _refresh_outputs(self, experiment_id: str) -> None:
        record = self.store.get(experiment_id)
        events = self.store.events(experiment_id)
        metrics = calculate_metrics(record["profile"], events, record.get("state", "idle"))
        self.store.write_json(experiment_id, "summary.json", metrics)
        record["summary"] = metrics
        qc = evaluate_quality(record, record["profile"], metrics, events, self.store.path_for(experiment_id), record.get("observations"))
        self.store.write_json(experiment_id, "qc_report.json", qc)
        (self.store.path_for(experiment_id) / "summary.csv").write_text(self.store.export_csv(experiment_id), encoding="utf-8")
        (self.store.path_for(experiment_id) / "qc_report.md").write_text(qc_markdown(qc), encoding="utf-8")
        record["qc"] = qc
        (self.store.path_for(experiment_id) / "report.md").write_text(generate_report(record), encoding="utf-8")

    def _log(self, experiment_id: str, event: dict) -> None:
        self._event_logger(experiment_id, event)

    @staticmethod
    def _error(message: str, code: str) -> dict:
        return {"ok": False, "message": message, "code": code}
