from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SENSITIVE_KEYS = {
    "udid",
    "full_udid",
    "unique_device_id",
    "uniquedeviceid",
    "identifier",
    "serialnumber",
    "serial_number",
    "rsd_address",
    "address",
    "hostname",
    "pair_record",
    "pair_records",
    "private_key",
    "escrow_bag",
    "secrets",
}

UDID_PATTERN = re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16,40}\b|\b[0-9A-Fa-f]{24,40}\b")
IPV6_PATTERN = re.compile(r"\b(?:[0-9A-Fa-f]{1,4}:){2,}[0-9A-Fa-f:]*\b")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def abbreviate_identifier(value: str) -> str:
    if not value:
        return ""
    if len(value) <= 10:
        return "****"
    return f"{value[:4]}...{value[-4:]}"


def _redact_text(value: str) -> str:
    value = UDID_PATTERN.sub(lambda match: abbreviate_identifier(match.group(0)), value)
    value = IPV6_PATTERN.sub("[RSD_ADDRESS_REDACTED]", value)
    return value


def _redact_command(command: list[Any]) -> list[Any]:
    redacted: list[Any] = []
    skip = 0
    for item in command:
        if skip:
            redacted.append("[REDACTED]")
            skip -= 1
            continue
        text = str(item)
        redacted.append(_redact_text(text))
        if text == "--rsd":
            skip = 2
    return redacted


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            lower = key.lower()
            if lower == "command" and isinstance(item, list):
                result[key] = _redact_command(item)
            elif lower in SENSITIVE_KEYS or "credential" in lower or "secret" in lower:
                if isinstance(item, str) and item:
                    result[f"{key}_abbreviated"] = abbreviate_identifier(item)
                result[key] = "[REDACTED]"
            elif lower == "device" and isinstance(item, dict):
                device = redact(item)
                if isinstance(device, dict):
                    raw_udid = item.get("udid") or item.get("UniqueDeviceID") or item.get("Identifier")
                    if raw_udid:
                        device["udid_abbreviated"] = abbreviate_identifier(str(raw_udid))
                result[key] = device
            else:
                result[key] = redact(item)
        return result
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, str):
        return _redact_text(value)
    return value


def repository_commit() -> str:
    try:
        root = Path(__file__).resolve().parents[2]
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, timeout=3).stdout.strip() or "unknown"
    except Exception:
        return "unknown"


class WirelessExperimentStore:
    def __init__(self, root: Path | None = None) -> None:
        configured = os.getenv("IOS_SIM_WIRELESS_TESTING_DATA_DIR")
        self.root = root or (Path(configured) if configured else Path(__file__).resolve().parent.parent / "data" / "wireless_testing" / "experiments")
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()

    def new_experiment_id(self) -> str:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        return f"WIRELESS-{stamp}-{secrets.token_hex(2).upper()}"

    def path_for(self, experiment_id: str) -> Path:
        if not re.fullmatch(r"WIRELESS-[A-Za-z0-9-]+", experiment_id):
            raise ValueError("Invalid wireless experiment ID")
        path = (self.root / experiment_id).resolve()
        if self.root.resolve() not in path.parents:
            raise ValueError("Invalid wireless experiment path")
        return path

    def exists(self, experiment_id: str) -> bool:
        try:
            return self.path_for(experiment_id).is_dir()
        except ValueError:
            return False

    def create(self, test_type: str, session_started_usb_present: bool, metadata: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            experiment_id = self.new_experiment_id()
            path = self.root / experiment_id
            path.mkdir(parents=True, exist_ok=False)
            manifest = {
                "schema_version": "wireless-testing-v1",
                "experiment_id": experiment_id,
                "test_type": test_type,
                "created_at": utc_now(),
                "updated_at": utc_now(),
                "state": "created",
                "repository_commit": repository_commit(),
                "iossim_version": "0.3.0-wireless-testing",
                "session_started_usb_present": bool(session_started_usb_present),
                "metadata": metadata,
                "summary": {},
                "verdict": "INCONCLUSIVE",
                "last_error": None,
            }
            self.write_json(experiment_id, "manifest.json", manifest)
            (path / "events.jsonl").touch()
            self.write_json(experiment_id, "observations.json", {"observations": []})
            return redact(manifest)

    def read_json(self, experiment_id: str, filename: str) -> dict[str, Any]:
        path = self.path_for(experiment_id) / filename
        if not path.exists():
            raise FileNotFoundError(filename)
        return json.loads(path.read_text(encoding="utf-8"))

    def write_json(self, experiment_id: str, filename: str, data: Any) -> None:
        path = self.path_for(experiment_id) / filename
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(redact(data), indent=2, ensure_ascii=True), encoding="utf-8")
        temporary.replace(path)

    def update_manifest(self, experiment_id: str, **changes: Any) -> dict[str, Any]:
        with self._lock:
            manifest = self.read_json(experiment_id, "manifest.json")
            manifest.update(redact(changes))
            manifest["updated_at"] = utc_now()
            self.write_json(experiment_id, "manifest.json", manifest)
            return manifest

    def append_event(self, experiment_id: str, event: dict[str, Any]) -> dict[str, Any]:
        payload = {"schema_version": "wireless-testing-v1", "timestamp": utc_now(), **redact(event)}
        path = self.path_for(experiment_id) / "events.jsonl"
        with self._lock, path.open("a", encoding="utf-8", buffering=1) as handle:
            handle.write(json.dumps(payload, ensure_ascii=True) + "\n")
            handle.flush()
        return payload

    def add_observation(self, experiment_id: str, observation: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            data = self.read_json(experiment_id, "observations.json")
            payload = {"recorded_at": utc_now(), **redact(observation)}
            data.setdefault("observations", []).append(payload)
            self.write_json(experiment_id, "observations.json", data)
            return payload

    def events(self, experiment_id: str) -> list[dict[str, Any]]:
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

    def get(self, experiment_id: str, include_events: bool = False) -> dict[str, Any]:
        result = self.read_json(experiment_id, "manifest.json")
        result["observations"] = self.read_json(experiment_id, "observations.json").get("observations", [])
        if include_events:
            result["events"] = self.events(experiment_id)
        return result

    def list(self) -> list[dict[str, Any]]:
        rows = []
        for path in self.root.glob("WIRELESS-*"):
            try:
                record = self.get(path.name)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
            summary = record.get("summary") or {}
            rows.append({
                "experiment_id": record.get("experiment_id"),
                "created_at": record.get("created_at"),
                "test_type": record.get("test_type"),
                "state": record.get("state"),
                "ios_version": summary.get("ios_version"),
                "pymobiledevice3_version": summary.get("pymobiledevice3_version"),
                "usb_state": summary.get("usb_state"),
                "wireless_discovery": summary.get("wireless_discovery"),
                "wifi_tunnel": summary.get("wifi_tunnel"),
                "rsd": summary.get("rsd"),
                "set_location": summary.get("set_location"),
                "reset_gps": summary.get("reset_gps"),
                "verdict": record.get("verdict"),
                "last_error": record.get("last_error"),
            })
        return sorted(rows, key=lambda row: row.get("created_at") or "", reverse=True)

    def delete(self, experiment_id: str) -> None:
        path = self.path_for(experiment_id)
        if not path.exists():
            raise FileNotFoundError(experiment_id)
        shutil.rmtree(path)

    def export_json(self, experiment_id: str) -> dict[str, Any]:
        return redact(self.get(experiment_id, include_events=True))

