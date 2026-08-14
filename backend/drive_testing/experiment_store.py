from __future__ import annotations

import csv
import io
import json
import os
import re
import secrets
import shutil
import subprocess
import threading
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import SCHEMA_VERSION


SENSITIVE_KEYS = {
    "udid",
    "full_udid",
    "rsd_address",
    "rsd_credentials",
    "command",
    "command_details",
    "start_address",
    "destination_address",
    "exact_address",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            lower = key.lower()
            if lower in SENSITIVE_KEYS or "credential" in lower:
                result[key] = "[REDACTED]"
            elif lower == "device" and isinstance(item, dict):
                device = redact(item)
                if isinstance(device, dict) and item.get("udid"):
                    device["udid_abbreviated"] = abbreviate_udid(str(item["udid"]))
                result[key] = device
            else:
                result[key] = redact(item)
        return result
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def abbreviate_udid(udid: str) -> str:
    if len(udid) <= 8:
        return "****"
    return f"{udid[:4]}...{udid[-4:]}"


class ExperimentStore:
    def __init__(self, root: Path | None = None) -> None:
        configured = os.getenv("IOS_SIM_DRIVE_TESTING_DATA_DIR")
        self.root = root or (Path(configured) if configured else Path(__file__).resolve().parent.parent / "data" / "drive_testing" / "experiments")
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()

    def new_experiment_id(self) -> str:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        return f"EXP-{stamp}-{secrets.token_hex(2).upper()}"

    def new_run_id(self) -> str:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        return f"RUN-{stamp}-{secrets.token_hex(2).upper()}"

    def create(self, route: list[dict], profile: dict, config: dict) -> dict:
        with self._lock:
            experiment_id = self.new_experiment_id()
            path = self.root / experiment_id
            path.mkdir(parents=True, exist_ok=False)
            manifest = {
                "schema_version": SCHEMA_VERSION,
                "experiment_id": experiment_id,
                "created_at": utc_now(),
                "updated_at": utc_now(),
                "state": "idle",
                "run_id": None,
                "repeat_number": 0,
                "total_repeats": int(config.get("repeats", 1)),
                "repository_commit": repository_commit(),
                "iossim_version": "0.2.0-drive-testing",
                "config": redact(config),
                "profile_name": profile.get("name", "Unnamed profile"),
                "method": profile.get("method", "timed_static"),
                "requested_distance_m": profile.get("requested_distance_m", 0.0),
                "output_directory": str(path),
                "last_error": None,
            }
            self.write_json(experiment_id, "manifest.json", manifest)
            self.write_json(experiment_id, "route.json", {"coordinates": route})
            self.write_json(experiment_id, "planned_profile.json", profile)
            self.write_json(experiment_id, "observations.json", {"observations": []})
            (path / "events.jsonl").touch()
            return manifest

    def path_for(self, experiment_id: str) -> Path:
        if not re.fullmatch(r"EXP-[A-Za-z0-9-]+", experiment_id):
            raise ValueError("Invalid experiment ID")
        path = (self.root / experiment_id).resolve()
        if self.root.resolve() not in path.parents:
            raise ValueError("Invalid experiment path")
        return path

    def exists(self, experiment_id: str) -> bool:
        return self.path_for(experiment_id).is_dir()

    def read_json(self, experiment_id: str, filename: str) -> dict:
        path = self.path_for(experiment_id) / filename
        if not path.exists():
            raise FileNotFoundError(filename)
        return json.loads(path.read_text(encoding="utf-8"))

    def write_json(self, experiment_id: str, filename: str, data: Any) -> None:
        path = self.path_for(experiment_id) / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(redact(data), indent=2, ensure_ascii=True), encoding="utf-8")
        temporary.replace(path)

    def update_manifest(self, experiment_id: str, **changes: Any) -> dict:
        with self._lock:
            manifest = self.read_json(experiment_id, "manifest.json")
            manifest.update(redact(changes))
            manifest["updated_at"] = utc_now()
            self.write_json(experiment_id, "manifest.json", manifest)
            return manifest

    def append_event(self, experiment_id: str, event: dict) -> dict:
        payload = {"schema_version": SCHEMA_VERSION, **redact(event)}
        path = self.path_for(experiment_id) / "events.jsonl"
        with self._lock, path.open("a", encoding="utf-8", buffering=1) as handle:
            handle.write(json.dumps(payload, ensure_ascii=True) + "\n")
            handle.flush()
        return payload

    def events(self, experiment_id: str) -> list[dict]:
        path = self.path_for(experiment_id) / "events.jsonl"
        if not path.exists():
            return []
        result = []
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return result

    def add_observation(self, experiment_id: str, observation: dict) -> dict:
        with self._lock:
            data = self.read_json(experiment_id, "observations.json")
            payload = {"recorded_at": utc_now(), **redact(observation)}
            data.setdefault("observations", []).append(payload)
            self.write_json(experiment_id, "observations.json", data)
            return payload

    def get(self, experiment_id: str, include_events: bool = False) -> dict:
        manifest = self.read_json(experiment_id, "manifest.json")
        result = {
            **manifest,
            "route": self.read_json(experiment_id, "route.json"),
            "profile": self.read_json(experiment_id, "planned_profile.json"),
            "observations": self.read_json(experiment_id, "observations.json").get("observations", []),
        }
        for filename, key in (("summary.json", "summary"), ("qc_report.json", "qc")):
            try:
                result[key] = self.read_json(experiment_id, filename)
            except FileNotFoundError:
                result[key] = None
        if include_events:
            result["events"] = self.events(experiment_id)
        return result

    def list(self) -> list[dict]:
        records = []
        for path in self.root.glob("EXP-*"):
            try:
                record = self.get(path.name)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
            observations = record.get("observations", [])
            summary = record.get("summary") or {}
            qc = record.get("qc") or {}
            records.append({
                **{key: record.get(key) for key in ("experiment_id", "created_at", "state", "profile_name", "method", "requested_distance_m", "repeat_number", "last_error")},
                "emitted_distance_m": summary.get("emitted_distance_m"),
                "calculated_average_apparent_speed_mph": summary.get("host_calculated_average_apparent_speed_mph"),
                "actual_duration_s": summary.get("actual_duration_s"),
                "write_failures": summary.get("failed_writes", 0),
                "observed_result": observations[-1].get("result") if observations else None,
                "notes": observations[-1].get("notes", "") if observations else "",
                "qc_status": qc.get("status"),
            })
        return sorted(records, key=lambda item: item.get("created_at") or "", reverse=True)

    def delete(self, experiment_id: str) -> None:
        path = self.path_for(experiment_id)
        if not path.exists():
            raise FileNotFoundError(experiment_id)
        shutil.rmtree(path)

    def export_json(self, experiment_id: str) -> dict:
        return redact(self.get(experiment_id, include_events=True))

    def export_csv(self, experiment_id: str) -> str:
        events = self.events(experiment_id)
        fields = [
            "experiment_id", "run_id", "repeat_number", "sequence_number", "profile_phase",
            "planned_elapsed_s", "actual_elapsed_s", "timing_drift_s", "latitude", "longitude",
            "distance_from_previous_m", "cumulative_distance_m", "target_apparent_speed_mph",
            "host_calculated_apparent_speed_mph", "planned_interval_s", "actual_interval_s",
            "write_latency_s", "location_write_success", "error_code", "error_message",
        ]
        buffer = io.StringIO()
        writer = csv.DictWriter(buffer, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        for event in events:
            if event.get("event_type") == "location_write":
                writer.writerow(event)
        return buffer.getvalue()


def repository_commit() -> str:
    try:
        root = Path(__file__).resolve().parents[2]
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, timeout=3).stdout.strip() or "unknown"
    except Exception:
        return "unknown"
