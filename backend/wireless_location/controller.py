from __future__ import annotations

import threading
from pathlib import Path
from typing import Any, Callable

from wireless_testing.command_runner import Runner

from .discovery import WirelessDeviceDiscovery, WirelessSetupBootstrap, device_metadata, identifier_for
from .models import SavedWirelessDevice, SetupState, WirelessSessionState
from .session import AsyncWorker, WirelessUserspaceLocationSession, normalize_udid, utc_now, validate_udid
from .store import WirelessDeviceStore


StatusProvider = Callable[[], dict[str, Any]]


class WirelessLocationController:
    def __init__(
        self,
        *,
        stable_status_provider: StatusProvider,
        store: WirelessDeviceStore | None = None,
        discovery: WirelessDeviceDiscovery | None = None,
        bootstrap: WirelessSetupBootstrap | None = None,
        runner: Runner | None = None,
        worker: AsyncWorker | None = None,
        session_factory: Callable[..., WirelessUserspaceLocationSession] = WirelessUserspaceLocationSession,
        operation_lock: threading.RLock | None = None,
    ) -> None:
        self._stable_status = stable_status_provider
        self.store = store or WirelessDeviceStore()
        self.discovery = discovery or WirelessDeviceDiscovery(runner)
        self.bootstrap = bootstrap or WirelessSetupBootstrap(runner)
        self.worker = worker or AsyncWorker()
        self.session_factory = session_factory
        self._operation_lock = operation_lock or threading.RLock()
        self._lock = threading.RLock()
        self._session: WirelessUserspaceLocationSession | None = None
        self._selected_udid: str | None = None
        self._connection_mode = "automatic"
        self._last_error: str | None = None
        self._last_recovery_status: str | None = None

    def list_devices(self, *, refresh: bool = True) -> dict[str, Any]:
        if refresh:
            self.refresh_saved_devices()
        return {
            "ok": True,
            "devices": [self._device_status(device) for device in self.store.list()],
            "selected_udid": self._selected_udid,
            "connection_mode": self._connection_mode,
            "session": self.session_status(),
            "message": self._status_message(),
        }

    def status(self, *, refresh: bool = True) -> dict[str, Any]:
        return self.list_devices(refresh=refresh)

    def set_connection_mode(self, mode: str, udid: str | None = None) -> dict[str, Any]:
        if mode not in {"automatic", "usb", "wireless"}:
            return self._error("Unknown connection mode.", "invalid_connection_mode")
        with self._lock:
            self._connection_mode = mode
            if udid:
                self._selected_udid = validate_udid(udid)
        return self.status(refresh=True)

    def begin_setup(self) -> dict[str, Any]:
        usb_device, error = self.discovery.single_usb_device()
        if error:
            self._last_error = error
            return self._error(error, "usb_setup_required")
        assert usb_device is not None
        udid = validate_udid(identifier_for(usb_device) or "")
        metadata = device_metadata(usb_device)
        now = utc_now()
        saved = self.store.upsert(SavedWirelessDevice(
            udid=udid,
            name=str(metadata.get("name") or "iPhone"),
            product_type=metadata.get("product_type"),
            ios_version=metadata.get("ios_version"),
            wireless_setup_valid=False,
            setup_state=SetupState.PREPARING.value,
            last_seen_at=now,
            last_usb_seen_at=now,
            last_transport_state="USB",
        ))
        with self._lock:
            self._selected_udid = udid
        prepared = self.bootstrap.prepare(udid)
        saved.setup_state = SetupState.READY_TO_UNPLUG.value if prepared.get("ok") else SetupState.FAILED.value
        saved.wireless_setup_valid = bool(prepared.get("ok"))
        saved.last_seen_at = utc_now()
        saved.last_usb_seen_at = saved.last_seen_at
        saved.last_transport_state = "USB"
        self.store.upsert(saved)
        if not prepared.get("ok"):
            self._last_error = prepared.get("message") or "Wireless setup failed."
            return self._error(self._last_error, "wireless_setup_failed", extra={"device": saved.to_dict(), "setup": prepared})
        self._last_error = None
        return {
            "ok": True,
            "device": self._device_status(saved),
            "setup_state": SetupState.READY_TO_UNPLUG.value,
            "steps": [
                {"label": "Device detected", "status": "complete"},
                {"label": "Wireless access prepared", "status": "complete"},
                {"label": "Device saved", "status": "complete"},
                {"label": "Unplug your iPhone", "status": "current"},
            ],
            "message": "You can unplug your iPhone now.",
        }

    def verify_setup_unplugged(self, udid: str) -> dict[str, Any]:
        real_udid = validate_udid(udid)
        saved = self.store.get(real_udid)
        if not saved:
            return self._error("This iPhone has not been saved yet.", "device_not_saved")
        visibility = self.discovery.visibility(real_udid)
        if visibility.errors:
            return self._error("Wrong or ambiguous iPhone detected. Keep only the selected iPhone reachable.", "ambiguous_device", extra={"visibility": visibility.to_public_dict()})
        if visibility.usb_present:
            saved.setup_state = SetupState.READY_TO_UNPLUG.value
            self.store.upsert(saved)
            return self._error("Unplug your iPhone to finish wireless verification.", "usb_still_connected", extra={"visibility": visibility.to_public_dict()})
        if not visibility.network_present:
            saved.setup_state = SetupState.VERIFYING_WIRELESS.value
            self.store.upsert(saved)
            return self._error("Your iPhone isn't reachable. Make sure it is unlocked and on the same Wi-Fi.", "wireless_not_found", extra={"visibility": visibility.to_public_dict()})
        result = self.connect_wireless(real_udid)
        if result.get("ok"):
            saved = self.store.mark_wireless_ready(real_udid, device_metadata(visibility.selected_network or {}))
            return {
                "ok": True,
                "device": self._device_status(saved),
                "setup_state": SetupState.WIRELESS_READY.value,
                "session": self.session_status(),
                "steps": [
                    {"label": "Device detected", "status": "complete"},
                    {"label": "Wireless access prepared", "status": "complete"},
                    {"label": "Connected wirelessly", "status": "complete"},
                ],
                "message": "Your iPhone is ready.",
            }
        return result

    def connect_wireless(self, udid: str | None = None) -> dict[str, Any]:
        selected = validate_udid(udid or self._selected_or_first_wireless_udid())
        saved = self.store.get(selected)
        if not saved:
            return self._error("Connect your iPhone once to enable wireless mode.", "device_not_saved")
        if not saved.wireless_setup_valid:
            return self._error("Connect your iPhone with USB once to refresh wireless setup.", "wireless_setup_required")
        visibility = self.discovery.visibility(selected)
        if visibility.errors:
            return self._error("Wrong or ambiguous iPhone detected. Keep only the selected iPhone reachable.", "ambiguous_device", extra={"visibility": visibility.to_public_dict()})
        if not visibility.network_present:
            saved.last_transport_state = "OFFLINE"
            self.store.upsert(saved)
            return self._error("Your iPhone isn't reachable. Make sure it is unlocked and on the same Wi-Fi.", "wireless_not_found", extra={"visibility": visibility.to_public_dict()})
        with self._operation_lock:
            with self._lock:
                if self._session and normalize_udid(self._session.device_udid) != normalize_udid(selected):
                    self.worker.run(self._session.disconnect(), timeout=20)
                    self._session = None
                if self._session is None:
                    self._session = self.session_factory(selected, device_metadata=SavedWirelessDevice.from_dict(saved.to_dict()).to_dict())
                session = self._session
                self._selected_udid = selected
            try:
                self.worker.run(session.connect(), timeout=45)
            except Exception as exc:
                self._last_error = _message(exc)
                return self._error("Wireless connection could not be restored. Connect USB to refresh setup.", "wireless_connect_failed", extra={"error": self._last_error})
        self.store.mark_wireless_ready(selected, device_metadata(visibility.selected_network or {}))
        self._last_error = None
        return {"ok": True, "session": self.session_status(), "message": "Wireless Ready"}

    def disconnect_wireless(self, udid: str | None = None) -> dict[str, Any]:
        with self._operation_lock:
            with self._lock:
                session = self._session
                if udid and session and normalize_udid(session.device_udid) != normalize_udid(validate_udid(udid)):
                    return self._error("Selected iPhone is not the active wireless session.", "wrong_device")
                self._session = None
            if session:
                self.worker.run(session.disconnect(), timeout=20)
        return {"ok": True, "session": self.session_status(), "message": "Wireless disconnected"}

    def should_use_wireless(self, mode: str | None = None, udid: str | None = None) -> bool:
        selected_mode = (mode or self._connection_mode or "automatic").lower()
        if selected_mode == "usb":
            return False
        if selected_mode == "wireless":
            return True
        with self._lock:
            if self._session and self._session.simulation_enabled:
                return True
        selected = udid or self._selected_or_first_wireless_udid(raise_if_missing=False)
        if not selected:
            return False
        saved = self.store.get(selected)
        if not saved or not saved.wireless_setup_valid:
            return False
        visibility = self.discovery.visibility(selected)
        return not visibility.errors and visibility.network_present

    def set_location(self, lat: float, lon: float, *, udid: str | None = None) -> dict[str, Any]:
        selected = validate_udid(udid or self._selected_or_first_wireless_udid())
        connect = self.connect_wireless(selected)
        if not connect.get("ok"):
            return connect
        assert self._session is not None
        with self._operation_lock:
            try:
                self.worker.run(self._session.set_location(lat, lon), timeout=45)
            except Exception as exc:
                self._last_error = _message(exc)
                recovery = self._recover_if_same_device_visible()
                if not recovery.get("ok"):
                    return recovery
        self.store.mark_wireless_ready(selected)
        return {"ok": True, "message": "Location set wirelessly.", "session": self.session_status()}

    def clear_location(self, *, udid: str | None = None) -> dict[str, Any]:
        with self._operation_lock:
            with self._lock:
                session = self._session
            if not session:
                return self._error("No active wireless location session.", "wireless_session_missing")
            if udid and normalize_udid(session.device_udid) != normalize_udid(validate_udid(udid)):
                return self._error("Selected iPhone is not the active wireless session.", "wrong_device")
            try:
                self.worker.run(session.clear_location(), timeout=45)
            except Exception as exc:
                self._last_error = _message(exc)
                return self._error("Reset GPS failed. Wireless connection could not send Clear.", "wireless_clear_failed", extra={"error": self._last_error, "session": session.status()})
            finally:
                with self._lock:
                    if self._session is session:
                        self._session = None
                self.worker.run(session.disconnect(), timeout=20)
        self._last_error = None
        return {"ok": True, "message": "GPS reset wirelessly.", "session": self.session_status()}

    def remove_device(self, udid: str) -> dict[str, Any]:
        real_udid = validate_udid(udid)
        with self._lock:
            active_same = self._session and normalize_udid(self._session.device_udid) == normalize_udid(real_udid)
        if active_same:
            self.disconnect_wireless(real_udid)
        removed = self.store.remove(real_udid)
        if not removed:
            return self._error("Saved iPhone was not found.", "device_not_found")
        with self._lock:
            if self._selected_udid and normalize_udid(self._selected_udid) == normalize_udid(real_udid):
                self._selected_udid = None
        return {"ok": True, "message": "Saved iPhone removed.", "devices": self.list_devices(refresh=False)["devices"]}

    def refresh_saved_devices(self) -> None:
        devices = self.store.list()
        for device in devices:
            try:
                visibility = self.discovery.visibility(device.udid)
            except Exception:
                continue
            if visibility.usb_present:
                self.store.mark_seen(device.udid, transport="USB", device=device_metadata(visibility.selected_usb or {}))
            elif visibility.network_present:
                self.store.mark_seen(device.udid, transport="WIRELESS", device=device_metadata(visibility.selected_network or {}))
            else:
                device.last_transport_state = "OFFLINE"
                self.store.upsert(device)
        with self._lock:
            if self._selected_udid is None:
                ready = next((item for item in self.store.list() if item.wireless_setup_valid and item.last_transport_state == "WIRELESS"), None)
                if ready:
                    self._selected_udid = ready.udid

    def session_status(self) -> dict[str, Any]:
        with self._lock:
            session = self._session
        if not session:
            return {
                "device_udid": self._selected_udid,
                "device_name": None,
                "connection": "none",
                "wireless_ready": False,
                "session_state": WirelessSessionState.DISCONNECTED.value,
                "simulation_enabled": False,
                "latitude": None,
                "longitude": None,
                "last_set_at": None,
                "last_clear_at": None,
                "last_error": self._last_error,
                "recovery": self._last_recovery_status,
            }
        status = session.status()
        status["recovery"] = self._last_recovery_status
        return status

    def diagnostics(self) -> dict[str, Any]:
        selected = self._selected_udid
        visibility = None
        if selected:
            try:
                visibility = self.discovery.visibility(selected).to_public_dict()
            except Exception as exc:
                visibility = {"error": _message(exc)}
        return {
            "ok": True,
            "selected_udid": selected,
            "usb_visible": visibility.get("usb_present") if visibility else None,
            "wifi_visible": visibility.get("network_present") if visibility else None,
            "visibility": visibility,
            "userspace_session": self.session_status(),
            "last_error": self._last_error,
        }

    def _recover_if_same_device_visible(self) -> dict[str, Any]:
        session = self._session
        if not session:
            return self._error("Wireless connection was interrupted.", "wireless_session_missing")
        visibility = self.discovery.visibility(session.device_udid)
        if visibility.errors or not visibility.network_present:
            self._last_recovery_status = "offline"
            return self._error("Wireless connection was interrupted. Your iPhone is offline.", "wireless_reconnect_failed", extra={"visibility": visibility.to_public_dict(), "session": session.status()})
        try:
            self._last_recovery_status = "reconnecting"
            self.worker.run(session.reconnect_and_restore(attempts=2), timeout=90)
        except Exception as exc:
            self._last_recovery_status = "failed"
            return self._error("Wireless connection could not be restored. Connect USB to refresh setup.", "wireless_reconnect_failed", extra={"error": _message(exc), "session": session.status()})
        self._last_recovery_status = "restored"
        return {"ok": True, "message": "Wireless connection restored.", "session": self.session_status()}

    def _selected_or_first_wireless_udid(self, *, raise_if_missing: bool = True) -> str:
        with self._lock:
            if self._selected_udid:
                return self._selected_udid
        ready = next((item for item in self.store.list() if item.wireless_setup_valid), None)
        if ready:
            with self._lock:
                self._selected_udid = ready.udid
            return ready.udid
        if raise_if_missing:
            raise ValueError("Connect your iPhone once to enable wireless mode.")
        return ""

    def _device_status(self, device: SavedWirelessDevice) -> dict[str, Any]:
        visibility = None
        try:
            visibility = self.discovery.visibility(device.udid)
        except Exception:
            visibility = None
        wireless_ready = bool(device.wireless_setup_valid and visibility and visibility.network_present and not visibility.errors)
        usb_visible = bool(visibility and visibility.usb_present)
        transport = "Wireless" if wireless_ready else "USB" if usb_visible else "Offline"
        setup_required = not device.wireless_setup_valid
        return {
            **device.to_dict(),
            "wireless_ready": wireless_ready,
            "usb_visible": usb_visible,
            "network_visible": bool(visibility and visibility.network_present),
            "transport": transport,
            "status_label": "Wireless Ready" if wireless_ready else "USB Setup Required" if setup_required else "Phone Offline",
            "selected": self._selected_udid is not None and normalize_udid(self._selected_udid) == normalize_udid(device.udid),
        }

    def _status_message(self) -> str:
        session = self.session_status()
        if session.get("simulation_enabled"):
            return "Simulating Location"
        devices = self.store.list()
        if any(item.wireless_setup_valid and item.last_transport_state == "WIRELESS" for item in devices):
            return "Wireless Ready"
        if devices:
            return "Connect USB once to refresh wireless setup."
        return "Connect your iPhone once to enable wireless mode."

    def _error(self, message: str, code: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
        payload = {"ok": False, "code": code, "message": message}
        if extra:
            payload.update(extra)
        return payload


def _message(exc: BaseException) -> str:
    text = " ".join(str(exc).strip().split())
    return text or repr(exc)
