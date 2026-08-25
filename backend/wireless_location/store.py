from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Any

from .models import SavedWirelessDevice
from .session import normalize_udid, utc_now, validate_udid


DEFAULT_STORE_FILE = Path(__file__).resolve().parents[1] / "data" / "wireless_devices.json"


class WirelessDeviceStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or DEFAULT_STORE_FILE
        self._lock = threading.RLock()

    def list(self) -> list[SavedWirelessDevice]:
        with self._lock:
            return [SavedWirelessDevice.from_dict(item) for item in self._read()]

    def get(self, udid: str) -> SavedWirelessDevice | None:
        target = normalize_udid(validate_udid(udid))
        for device in self.list():
            if normalize_udid(device.udid) == target:
                return device
        return None

    def upsert(self, device: SavedWirelessDevice | dict[str, Any]) -> SavedWirelessDevice:
        item = SavedWirelessDevice.from_dict(device) if isinstance(device, dict) else device
        item.udid = validate_udid(item.udid)
        now = utc_now()
        with self._lock:
            rows = self._read()
            target = normalize_udid(item.udid)
            index = next((i for i, row in enumerate(rows) if normalize_udid(str(row.get("udid") or "")) == target), None)
            if index is None:
                item.created_at = item.created_at or now
                item.updated_at = now
                rows.append(item.to_dict())
            else:
                current = SavedWirelessDevice.from_dict(rows[index])
                created_at = current.created_at or item.created_at or now
                merged = {**current.to_dict(), **item.to_dict(), "created_at": created_at, "updated_at": now}
                rows[index] = merged
                item = SavedWirelessDevice.from_dict(merged)
            self._write(rows)
        return item

    def remove(self, udid: str) -> bool:
        target = normalize_udid(validate_udid(udid))
        with self._lock:
            rows = self._read()
            next_rows = [row for row in rows if normalize_udid(str(row.get("udid") or "")) != target]
            if len(next_rows) == len(rows):
                return False
            self._write(next_rows)
            return True

    def mark_seen(self, udid: str, *, transport: str, device: dict[str, Any] | None = None) -> SavedWirelessDevice:
        current = self.get(udid) or SavedWirelessDevice(udid=validate_udid(udid))
        now = utc_now()
        current.last_seen_at = now
        current.last_transport_state = transport
        if transport == "USB":
            current.last_usb_seen_at = now
        if transport == "WIRELESS":
            current.last_wireless_seen_at = now
        if device:
            current.name = str(device.get("name") or device.get("DeviceName") or current.name or "iPhone")
            current.product_type = device.get("product_type") or device.get("ProductType") or current.product_type
            current.ios_version = device.get("ios_version") or device.get("ProductVersion") or current.ios_version
        return self.upsert(current)

    def mark_wireless_ready(self, udid: str, device: dict[str, Any] | None = None) -> SavedWirelessDevice:
        item = self.mark_seen(udid, transport="WIRELESS", device=device)
        item.wireless_setup_valid = True
        item.setup_state = "WIRELESS_READY"
        item.last_wireless_success_at = utc_now()
        return self.upsert(item)

    def _read(self) -> list[dict[str, Any]]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            return []
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except Exception:
            return []
        if not isinstance(payload, list):
            return []
        return [item for item in payload if isinstance(item, dict)]

    def _write(self, rows: list[dict[str, Any]]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(rows, indent=2, sort_keys=True), encoding="utf-8")
