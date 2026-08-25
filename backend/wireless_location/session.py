from __future__ import annotations

import asyncio
import threading
import time
from datetime import datetime, timezone
from typing import Any, Callable

from .models import WirelessSessionState

try:
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
except ImportError:  # pragma: no cover - exercised through dependency-injection tests.
    UserspaceRsdTunnel = None  # type: ignore[assignment]
    DeviceInfo = None  # type: ignore[assignment]
    DvtProvider = None  # type: ignore[assignment]
    LocationSimulation = None  # type: ignore[assignment]


UDID_REJECTS = {"", "unknown", "<unknown>", "none", "null", "wireless-device"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_udid(value: str) -> str:
    return str(value or "").strip().replace("-", "").lower()


def validate_udid(udid: str) -> str:
    value = str(udid or "").strip()
    if value.lower() in UDID_REJECTS:
        raise ValueError("A real explicit device UDID is required.")
    if len(value.replace("-", "")) < 12:
        raise ValueError("UDID is too short to be a safe explicit device identifier.")
    return value


class AsyncWorker:
    """Single event-loop owner for long-lived pymobiledevice3 async objects."""

    def __init__(self) -> None:
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, name="wireless-userspace-loop", daemon=True)
        self._thread.start()

    def run(self, coro: Any, timeout: float | None = None) -> Any:
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        return future.result(timeout=timeout)

    def stop(self) -> None:
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=3)

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()


class WirelessUserspaceLocationSession:
    def __init__(
        self,
        device_udid: str,
        *,
        device_metadata: dict[str, Any] | None = None,
        tunnel_factory: Callable[..., Any] | None = None,
        dvt_factory: Callable[..., Any] | None = None,
        device_info_factory: Callable[..., Any] | None = None,
        location_factory: Callable[..., Any] | None = None,
    ) -> None:
        self.device_udid = validate_udid(device_udid)
        self.device_metadata = dict(device_metadata or {})
        self.state = WirelessSessionState.DISCONNECTED
        self.tunnel_factory = tunnel_factory or UserspaceRsdTunnel
        self.dvt_factory = dvt_factory or DvtProvider
        self.device_info_factory = device_info_factory or DeviceInfo
        self.location_factory = location_factory or LocationSimulation
        self.tunnel: Any | None = None
        self.rsd: Any | None = None
        self.dvt: Any | None = None
        self.location: Any | None = None
        self.desired_location: tuple[float, float] | None = None
        self.simulation_enabled = False
        self.connected_at: str | None = None
        self.last_successful_set_at: str | None = None
        self.last_successful_clear_at: str | None = None
        self.last_error: str | None = None
        self.last_reconnect_at: str | None = None
        self.reconnect_count = 0
        self.cleanup_complete = True

    async def connect(self) -> None:
        if self.location is not None and self.state in {WirelessSessionState.CONNECTED, WirelessSessionState.SIMULATING}:
            return
        self._require_factories()
        self.state = WirelessSessionState.CONNECTING
        self.cleanup_complete = False
        self.last_error = None
        try:
            self.tunnel = self.tunnel_factory(serial=self.device_udid)
            self.rsd = await self.tunnel.aopen()
            self._verify_rsd_udid()
            self.dvt = self.dvt_factory(self.rsd)
            await self.dvt.connect()
            await self._device_info_warmup()
            self.location = self.location_factory(self.dvt)
            await self.location.connect()
            self.connected_at = utc_now()
            self.state = WirelessSessionState.CONNECTED
        except Exception as exc:
            self.state = WirelessSessionState.FAILED
            self.last_error = user_facing_error(exc)
            await self.disconnect()
            raise

    async def set_location(self, lat: float, lon: float) -> None:
        self.desired_location = (lat, lon)
        self.simulation_enabled = True
        if self.location is None:
            await self.connect()
        if self.location is None:
            raise RuntimeError("Wireless location session is not connected.")
        try:
            self.state = WirelessSessionState.SIMULATING
            await self.location.set(lat, lon)
            self.last_successful_set_at = utc_now()
            self.last_error = None
        except Exception as exc:
            self.state = WirelessSessionState.FAILED
            self.last_error = user_facing_error(exc)
            raise

    async def clear_location(self) -> None:
        self.simulation_enabled = False
        self.desired_location = None
        if self.location is None:
            raise RuntimeError("Wireless location session is not connected.")
        try:
            self.state = WirelessSessionState.CLEARING
            await self.location.clear()
            self.last_successful_clear_at = utc_now()
            self.last_error = None
            self.state = WirelessSessionState.CONNECTED
        except Exception as exc:
            self.state = WirelessSessionState.FAILED
            self.last_error = user_facing_error(exc)
            raise

    async def reconnect_and_restore(self, *, attempts: int = 2, base_delay_s: float = 0.5) -> None:
        if not self.simulation_enabled or self.desired_location is None:
            return
        target = self.desired_location
        last_exc: Exception | None = None
        for index in range(max(1, attempts)):
            self.state = WirelessSessionState.RECONNECTING
            self.reconnect_count += 1
            self.last_reconnect_at = utc_now()
            try:
                await self.disconnect()
                await self.connect()
                await self.set_location(*target)
                return
            except Exception as exc:
                last_exc = exc
                await asyncio.sleep(base_delay_s * (2 ** index))
        self.state = WirelessSessionState.FAILED
        if last_exc is not None:
            self.last_error = user_facing_error(last_exc)
            raise last_exc

    async def disconnect(self) -> None:
        dvt = self.dvt
        tunnel = self.tunnel
        self.location = None
        self.dvt = None
        self.rsd = None
        self.tunnel = None
        if dvt is not None:
            close = getattr(dvt, "close", None)
            if close is not None:
                result = close()
                if hasattr(result, "__await__"):
                    await result
        if tunnel is not None:
            close = getattr(tunnel, "aclose", None)
            if close is not None:
                result = close()
                if hasattr(result, "__await__"):
                    await result
        self.cleanup_complete = True
        if self.state != WirelessSessionState.FAILED:
            self.state = WirelessSessionState.DISCONNECTED

    def status(self) -> dict[str, Any]:
        lat = self.desired_location[0] if self.desired_location else None
        lon = self.desired_location[1] if self.desired_location else None
        dtx = getattr(self.dvt, "_dtx", None) if self.dvt is not None else None
        return {
            "device_udid": self.device_udid,
            "device_name": self.device_metadata.get("name"),
            "connection": "wireless" if self.location is not None else "none",
            "wireless_ready": self.location is not None,
            "session_state": self.state.value,
            "simulation_enabled": self.simulation_enabled,
            "latitude": lat,
            "longitude": lon,
            "connected_at": self.connected_at,
            "last_set_at": self.last_successful_set_at,
            "last_clear_at": self.last_successful_clear_at,
            "last_error": self.last_error,
            "last_reconnect_at": self.last_reconnect_at,
            "reconnect_count": self.reconnect_count,
            "cleanup_complete": self.cleanup_complete,
            "dvt_connected": dtx is not None and not getattr(dtx, "_closed", True),
        }

    async def _device_info_warmup(self) -> None:
        device_info = self.device_info_factory(self.dvt)
        async with device_info:
            await device_info.ls("/")

    def _verify_rsd_udid(self) -> None:
        rsd_udid = getattr(self.rsd, "udid", None)
        if rsd_udid and normalize_udid(str(rsd_udid)) != normalize_udid(self.device_udid):
            raise RuntimeError("Wireless discovery returned a different iPhone.")

    def _require_factories(self) -> None:
        missing = [
            name for name, value in (
                ("UserspaceRsdTunnel", self.tunnel_factory),
                ("DvtProvider", self.dvt_factory),
                ("DeviceInfo", self.device_info_factory),
                ("LocationSimulation", self.location_factory),
            )
            if value is None
        ]
        if missing:
            raise RuntimeError(f"pymobiledevice3 userspace APIs are unavailable: {', '.join(missing)}")


def user_facing_error(exc: BaseException) -> str:
    text = " ".join(str(exc).strip().split())
    if not text:
        text = repr(exc)
    return text[:500]
