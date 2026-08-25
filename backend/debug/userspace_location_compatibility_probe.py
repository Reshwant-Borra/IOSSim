#!/usr/bin/env python3
"""Debug-only userspace RSD location compatibility probe.

This harness intentionally stays outside IOSSim production paths. It keeps the
known-good userspace RSD -> DVT -> DeviceInfo warmup -> LocationSimulation
sequence as the control, inventories location-adjacent RSD services, and checks
whether the installed pymobiledevice3 CoreDevice location wrapper exposes a real
set/clear implementation.
"""

from __future__ import annotations

import argparse
import asyncio
import inspect
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Protocol

from pymobiledevice3.remote.core_device.location_service import LocationService as CoreDeviceLocationService
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation


RESULTS_DIR = Path(__file__).resolve().parent / "results"
DEFAULT_UDID = "00008150-00022D581E12401C"
UDID_REJECTS = {"", "unknown", "<unknown>", "none", "null"}

SF = (37.7749, -122.4194)
NYC = (40.7128, -74.0060)
MIAMI = (25.7617, -80.1918)

DVT_RSD_SERVICE = "com.apple.instruments.dtservicehub"
DVT_LOCATION_IDENTIFIER = "com.apple.instruments.server.services.LocationSimulation"
COREDEVICE_LOCATION_SERVICE = "com.apple.coredevice.locationservice"
COREDEVICE_SIMULATE_FEATURE = "com.apple.coredevice.feature.simulatelocation"
COREDEVICE_AVAILABLE_SCENARIOS_ACTION = "com.apple.coredevice.action.availablelocationscenarios"
SERVICE_TERMS = ("location", "simulation", "coredevice", "gps", "instruments", "developer")


class ProbeError(RuntimeError):
    """Raised for expected probe setup or operator errors."""


def validate_udid(udid: str) -> str:
    value = (udid or "").strip()
    if value.lower() in UDID_REJECTS:
        raise ProbeError("A real explicit device UDID is required; refusing placeholder value.")
    if len(value) < 12:
        raise ProbeError("UDID is too short to be a safe explicit device identifier.")
    return value


def timestamp() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def log_filename() -> Path:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return RESULTS_DIR / f"userspace_location_compatibility_{stamp}.log"


def compact(value: Any, limit: int = 1400) -> str:
    text = str(value)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


class Recorder:
    def __init__(self, path: Path | None = None, echo: bool = True) -> None:
        self.path = path or log_filename()
        self.echo = echo
        self._handle = self.path.open("a", encoding="utf-8", buffering=1)
        self._lock = threading.Lock()

    def close(self) -> None:
        with self._lock:
            if not self._handle.closed:
                self._handle.flush()
                self._handle.close()

    def line(self, kind: str, message: str = "", **fields: Any) -> None:
        parts = [f"[{timestamp()}]", kind]
        if message:
            parts.append(message)
        for key, value in fields.items():
            parts.append(f"{key}={compact(value)}")
        line = " ".join(parts)
        with self._lock:
            if not self._handle.closed:
                self._handle.write(line + "\n")
                self._handle.flush()
        if self.echo:
            print(line, flush=True)

    def event(self, message: str, **fields: Any) -> None:
        self.line("EVENT", message, **fields)

    def heartbeat(self, **fields: Any) -> None:
        self.line("HEARTBEAT", **fields)

    def manual(self, message: str) -> None:
        self.line("MANUAL", message)

    def error(self, message: str, exc: BaseException | None = None, **fields: Any) -> None:
        if exc is not None:
            fields = {**fields, "exception_type": type(exc).__name__, "exception": repr(exc)}
        self.line("ERROR", message, **fields)
        if exc is not None:
            stack = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
            with self._lock:
                if not self._handle.closed:
                    self._handle.write(stack + "\n")
                    self._handle.flush()


class Pmd3Cli:
    def __init__(self, python: str = sys.executable) -> None:
        self.python = python

    def run(self, *args: str, timeout: float = 20.0) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [self.python, "-m", "pymobiledevice3", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )


@dataclass(frozen=True)
class DeviceVisibility:
    usb_present: bool
    network_present: bool
    usb_count: int
    network_count: int
    usb_match_count: int
    network_match_count: int
    selected_usb: dict[str, Any] | None
    selected_network: dict[str, Any] | None
    errors: list[str]


class DeviceDiscovery:
    def __init__(self, udid: str, cli: Pmd3Cli | None = None) -> None:
        self.udid = validate_udid(udid)
        self.cli = cli or Pmd3Cli()

    def _list(self, mode: str) -> tuple[list[dict[str, Any]], str | None]:
        try:
            result = self.cli.run("usbmux", "list", mode, timeout=12)
        except Exception as exc:
            return [], f"{mode}: {type(exc).__name__}: {exc!r}"
        if result.returncode != 0:
            return [], f"{mode}: rc={result.returncode} stderr={compact(result.stderr or result.stdout)}"
        try:
            payload = json.loads(result.stdout or "[]")
        except json.JSONDecodeError as exc:
            return [], f"{mode}: json_error={exc}"
        if not isinstance(payload, list):
            return [], f"{mode}: unexpected_payload={type(payload).__name__}"
        return [item for item in payload if isinstance(item, dict)], None

    def visibility(self) -> DeviceVisibility:
        usb_devices, usb_error = self._list("--usb")
        network_devices, network_error = self._list("--network")
        errors = [error for error in (usb_error, network_error) if error]
        usb_matches = self._matches(usb_devices)
        network_matches = self._matches(network_devices)
        if len(usb_matches) > 1:
            errors.append(f"--usb: ambiguous selected UDID appeared {len(usb_matches)} times")
        if len(network_matches) > 1:
            errors.append(f"--network: ambiguous selected UDID appeared {len(network_matches)} times")
        selected_usb = usb_matches[0] if len(usb_matches) == 1 else None
        selected_network = network_matches[0] if len(network_matches) == 1 else None
        return DeviceVisibility(
            usb_present=selected_usb is not None,
            network_present=selected_network is not None,
            usb_count=len(usb_devices),
            network_count=len(network_devices),
            usb_match_count=len(usb_matches),
            network_match_count=len(network_matches),
            selected_usb=selected_usb,
            selected_network=selected_network,
            errors=errors,
        )

    def _matches(self, devices: list[dict[str, Any]]) -> list[dict[str, Any]]:
        matches = []
        target = self.udid.replace("-", "")
        for device in devices:
            identifiers = [
                device.get("UniqueDeviceID"),
                device.get("Identifier"),
                device.get("SerialNumber"),
                device.get("UDID"),
            ]
            if any(isinstance(item, str) and item.replace("-", "") == target for item in identifiers):
                matches.append(device)
        return matches

    def wait_for_wifi_only(self, recorder: Recorder, timeout_s: float, poll_s: float = 2.0) -> DeviceVisibility:
        deadline = time.monotonic() + timeout_s
        last: DeviceVisibility | None = None
        recorder.event("waiting_for_usb_absent_and_network_visible", timeout_s=timeout_s)
        while time.monotonic() < deadline:
            last = self.visibility()
            recorder.event(
                "device_visibility",
                usb_present=last.usb_present,
                network_present=last.network_present,
                usb_count=last.usb_count,
                network_count=last.network_count,
                usb_match_count=last.usb_match_count,
                network_match_count=last.network_match_count,
                errors="; ".join(last.errors),
            )
            if not last.usb_present and last.network_present:
                return last
            time.sleep(poll_s)
        raise ProbeError(f"Timed out waiting for Wi-Fi-only visibility for selected UDID. Last visibility: {last}")


def service_inventory(rsd: Any) -> dict[str, Any]:
    peer_info = getattr(rsd, "peer_info", None)
    if isinstance(peer_info, dict):
        services = peer_info.get("Services")
        if isinstance(services, dict):
            return services
    services = getattr(rsd, "services", None)
    if isinstance(services, dict):
        return services
    all_values = getattr(rsd, "all_values", None)
    if isinstance(all_values, dict):
        services = all_values.get("Services")
        if isinstance(services, dict):
            return services
    return {}


def location_related_services(services: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name, metadata in services.items():
        searchable = name.lower()
        if isinstance(metadata, dict):
            searchable += " " + json.dumps(metadata, default=str).lower()
        if any(term in searchable for term in SERVICE_TERMS):
            result[name] = metadata
    return result


def service_features(services: dict[str, Any], service_name: str) -> list[str]:
    entry = services.get(service_name)
    if not isinstance(entry, dict):
        return []
    properties = entry.get("Properties")
    if not isinstance(properties, dict):
        return []
    features = properties.get("Features") or []
    return [str(item) for item in features]


def coredevice_set_clear_supported(location_cls: type[Any] = CoreDeviceLocationService) -> bool:
    return callable(getattr(location_cls, "set", None)) and callable(getattr(location_cls, "clear", None))


def backend_availability(services: dict[str, Any], location_cls: type[Any] = CoreDeviceLocationService) -> dict[str, bool]:
    return {
        "DVT": DVT_RSD_SERVICE in services,
        "COREDEVICE": COREDEVICE_LOCATION_SERVICE in services and coredevice_set_clear_supported(location_cls),
    }


def implementation_file(obj: Any) -> str:
    try:
        return str(inspect.getsourcefile(obj) or "<unknown>")
    except Exception:
        return "<unknown>"


class LocationBackend(Protocol):
    name: str

    async def connect(self) -> None: ...

    async def set(self, lat: float, lon: float) -> None: ...

    async def clear(self) -> None: ...

    async def close(self) -> None: ...

    def state(self) -> dict[str, Any]: ...


class DvtLocationBackend:
    name = "DVT"

    def __init__(
        self,
        rsd: Any,
        recorder: Recorder,
        *,
        dvt_factory: Callable[..., Any] = DvtProvider,
        device_info_factory: Callable[..., Any] = DeviceInfo,
        location_factory: Callable[..., Any] = LocationSimulation,
    ) -> None:
        self.rsd = rsd
        self.recorder = recorder
        self._dvt_factory = dvt_factory
        self._device_info_factory = device_info_factory
        self._location_factory = location_factory
        self.dvt: Any | None = None
        self.location: Any | None = None
        self.set_count = 0
        self.clear_count = 0
        self.last_set_at: float | None = None
        self.last_set_lat: float | None = None
        self.last_set_lon: float | None = None

    async def connect(self) -> None:
        if self.location is not None:
            return
        self.recorder.event("DVT_INITIALIZATION_START")
        self.dvt = self._dvt_factory(self.rsd)
        await self.dvt.connect()
        self.recorder.event("DVT_CONNECTED", service_name=getattr(self.dvt, "_service_name", None))
        await self._device_info_warmup()
        self.location = self._location_factory(self.dvt)
        await self.location.connect()
        service = getattr(self.location, "service", None)
        self.recorder.event(
            "DVT_LOCATION_READY",
            service_identifier=getattr(service, "IDENTIFIER", None),
            implementation_file=implementation_file(LocationSimulation),
            set_selector="simulateLocationWithLatitude:longitude:",
            clear_selector="stopLocationSimulation",
            channel_code=self._channel_attr("code"),
            channel_identifier=self._channel_attr("identifier"),
        )

    async def _device_info_warmup(self) -> None:
        self.recorder.event("DEVICEINFO_WARMUP_START", method=self.name)
        async with self._device_info_factory(self.dvt) as device_info:
            root_entries = await device_info.ls("/")
        self.recorder.event(
            "DEVICEINFO_WARMUP_COMPLETE",
            method=self.name,
            root_count=len(root_entries),
            root_sample=root_entries[:5],
        )

    async def set(self, lat: float, lon: float) -> None:
        if self.location is None:
            raise ProbeError("DVT Set requested before LocationSimulation is connected.")
        started = time.monotonic()
        self.recorder.event("LOCATION_SET_START", method=self.name, lat=lat, lon=lon)
        result = await self.location.set(lat, lon)
        self.last_set_at = time.monotonic()
        self.last_set_lat = lat
        self.last_set_lon = lon
        self.set_count += 1
        self.recorder.event(
            "LOCATION_SET",
            method=self.name,
            lat=lat,
            lon=lon,
            result=repr(result),
            elapsed_s=f"{self.last_set_at - started:.3f}",
            set_count=self.set_count,
        )

    async def clear(self) -> None:
        if self.location is None:
            raise ProbeError("DVT Clear requested before LocationSimulation is connected.")
        started = time.monotonic()
        self.recorder.event("LOCATION_CLEAR_START", method=self.name)
        result = await self.location.clear()
        self.clear_count += 1
        self.recorder.event(
            "LOCATION_CLEAR",
            method=self.name,
            result=repr(result),
            elapsed_s=f"{time.monotonic() - started:.3f}",
            clear_count=self.clear_count,
        )

    async def close(self) -> None:
        if self.dvt is not None:
            await self.dvt.close()
            self.recorder.event("DVT_CLOSED")
        self.location = None
        self.dvt = None

    def state(self) -> dict[str, Any]:
        dtx = getattr(self.dvt, "_dtx", None) if self.dvt is not None else None
        reader_task = getattr(dtx, "_reader_task", None) if dtx is not None else None
        channel = self._channel()
        return {
            "dvt_object": self.dvt is not None,
            "dvt_connected_observable": dtx is not None and not getattr(dtx, "_closed", True),
            "dtx_closed": getattr(dtx, "_closed", None) if dtx is not None else None,
            "dtx_reader_task_done": reader_task.done() if reader_task is not None else None,
            "location_object": self.location is not None,
            "location_channel_closed": getattr(channel, "_closed", None) if channel is not None else None,
            "last_set_lat": self.last_set_lat,
            "last_set_lon": self.last_set_lon,
            "seconds_since_last_set": (
                f"{time.monotonic() - self.last_set_at:.1f}" if self.last_set_at is not None else None
            ),
            "set_count": self.set_count,
            "clear_count": self.clear_count,
        }

    def _channel(self) -> Any | None:
        try:
            service = getattr(self.location, "service", None) if self.location is not None else None
            return getattr(service, "_channel", None) if service is not None else None
        except Exception:
            return None

    def _channel_attr(self, name: str) -> Any:
        channel = self._channel()
        return getattr(channel, name, None) if channel is not None else None


class CoreDeviceLocationBackend:
    name = "COREDEVICE"

    def __init__(
        self,
        rsd: Any,
        recorder: Recorder,
        *,
        location_service_factory: Callable[..., Any] = CoreDeviceLocationService,
    ) -> None:
        self.rsd = rsd
        self.recorder = recorder
        self._location_service_factory = location_service_factory
        self.service: Any | None = None
        self.set_count = 0
        self.clear_count = 0

    @property
    def set_clear_supported(self) -> bool:
        cls = self._location_service_factory
        return callable(getattr(cls, "set", None)) and callable(getattr(cls, "clear", None))

    async def connect(self) -> None:
        if not self.set_clear_supported:
            raise ProbeError("COREDEVICE_LOCATION_SIMULATION_UNAVAILABLE")
        self.recorder.event("COREDEVICE_LOCATION_INITIALIZATION_START")
        self.service = self._location_service_factory(self.rsd)
        await self.service.connect()
        self.recorder.event(
            "COREDEVICE_LOCATION_READY",
            service_identifier=COREDEVICE_LOCATION_SERVICE,
            implementation_file=implementation_file(self._location_service_factory),
            set_method="set",
            clear_method="clear",
        )

    async def set(self, lat: float, lon: float) -> None:
        if self.service is None:
            raise ProbeError("CoreDevice Set requested before service is connected.")
        started = time.monotonic()
        self.recorder.event("LOCATION_SET_START", method=self.name, lat=lat, lon=lon)
        result = await self.service.set(lat, lon)
        self.set_count += 1
        self.recorder.event(
            "LOCATION_SET",
            method=self.name,
            lat=lat,
            lon=lon,
            result=repr(result),
            elapsed_s=f"{time.monotonic() - started:.3f}",
            set_count=self.set_count,
        )

    async def clear(self) -> None:
        if self.service is None:
            raise ProbeError("CoreDevice Clear requested before service is connected.")
        started = time.monotonic()
        self.recorder.event("LOCATION_CLEAR_START", method=self.name)
        result = await self.service.clear()
        self.clear_count += 1
        self.recorder.event(
            "LOCATION_CLEAR",
            method=self.name,
            result=repr(result),
            elapsed_s=f"{time.monotonic() - started:.3f}",
            clear_count=self.clear_count,
        )

    async def close(self) -> None:
        if self.service is not None:
            await self.service.close()
            self.recorder.event("COREDEVICE_LOCATION_CLOSED")
        self.service = None

    def state(self) -> dict[str, Any]:
        return {
            "coredevice_location_object": self.service is not None,
            "coredevice_set_clear_supported": self.set_clear_supported,
            "set_count": self.set_count,
            "clear_count": self.clear_count,
        }


class CompatibilitySession:
    def __init__(
        self,
        udid: str,
        recorder: Recorder,
        *,
        tunnel_factory: Callable[..., Any] = UserspaceRsdTunnel,
    ) -> None:
        self.udid = validate_udid(udid)
        self.recorder = recorder
        self._tunnel_factory = tunnel_factory
        self.tunnel: Any | None = None
        self.rsd: Any | None = None
        self.services: dict[str, Any] = {}
        self.backends: dict[str, LocationBackend] = {}
        self.available: dict[str, bool] = {}
        self.active_method = "DVT"
        self.connected_at: float | None = None

    async def connect(self) -> None:
        self.recorder.event("USERSPACE_RSD_CONNECT_START", udid=self.udid)
        self.tunnel = self._tunnel_factory(serial=self.udid)
        self.rsd = await self.tunnel.aopen()
        self.connected_at = time.monotonic()
        self.services = service_inventory(self.rsd)
        self.available = backend_availability(self.services)
        related = location_related_services(self.services)
        self.recorder.event(
            "USERSPACE_RSD_CONNECTED",
            rsd_udid=getattr(self.rsd, "udid", None),
            product_type=getattr(self.rsd, "product_type", None),
            product_version=getattr(self.rsd, "product_version", None),
            in_process_tunnel=getattr(self.rsd, "is_in_process_tunnel", None),
            service_count=len(self.services),
            location_related_count=len(related),
            dvt_service_present=DVT_RSD_SERVICE in self.services,
            coredevice_location_service_present=COREDEVICE_LOCATION_SERVICE in self.services,
        )
        for name, metadata in sorted(related.items()):
            self.recorder.event("RSD_LOCATION_RELATED_SERVICE", service_identifier=name, metadata=json.dumps(metadata, default=str))
        self._record_source_summary()
        await self._inspect_coredevice_location_service()
        self.backends["DVT"] = DvtLocationBackend(self.rsd, self.recorder)
        self.backends["COREDEVICE"] = CoreDeviceLocationBackend(self.rsd, self.recorder)
        if not self.available.get("DVT"):
            raise ProbeError(f"Known-good DVT control service missing from RSD inventory: {DVT_RSD_SERVICE}")
        await self.select_method("DVT", clear_current=False)

    async def _inspect_coredevice_location_service(self) -> None:
        present = COREDEVICE_LOCATION_SERVICE in self.services
        supported = self.available.get("COREDEVICE", False)
        self.recorder.event(
            "COREDEVICE_LOCATION_IMPLEMENTATION_INSPECTED",
            service_present=present,
            implementation_file=implementation_file(CoreDeviceLocationService),
            available_scenarios_method=callable(getattr(CoreDeviceLocationService, "available_location_scenarios", None)),
            set_supported=coredevice_set_clear_supported(),
            clear_supported=coredevice_set_clear_supported(),
            feature_identifier=COREDEVICE_SIMULATE_FEATURE,
            available_scenarios_action=COREDEVICE_AVAILABLE_SCENARIOS_ACTION,
        )
        if not present:
            self.recorder.event("COREDEVICE_LOCATION_SIMULATION_UNAVAILABLE", reason="RSD service not present")
            return
        try:
            async with CoreDeviceLocationService(self.rsd) as service:
                scenarios = await service.available_location_scenarios()
            self.recorder.event("COREDEVICE_AVAILABLE_LOCATION_SCENARIOS", result=json.dumps(scenarios, default=str))
        except Exception as exc:
            self.recorder.error("COREDEVICE_AVAILABLE_LOCATION_SCENARIOS_FAILED", exc)
        if not supported:
            self.recorder.event(
                "COREDEVICE_LOCATION_SIMULATION_UNAVAILABLE",
                reason="installed pymobiledevice3 exposes available scenarios only; no set/clear implementation",
            )

    def _record_source_summary(self) -> None:
        self.recorder.event(
            "PYMOBILEDEVICE3_DVT_SOURCE",
            provider="DvtProvider",
            service_identifier=DVT_RSD_SERVICE,
            implementation_file=implementation_file(LocationSimulation),
            set_supported=True,
            clear_supported=True,
            set_selector="simulateLocationWithLatitude:longitude:",
            clear_selector="stopLocationSimulation",
            requires_rsd=True,
            requires_persistent_tunnel=False,
            cli_entry_point="developer dvt simulate-location set|clear --rsd HOST PORT",
        )
        self.recorder.event(
            "PYMOBILEDEVICE3_COREDEVICE_LOCATION_SOURCE",
            provider="CoreDevice LocationService",
            service_identifier=COREDEVICE_LOCATION_SERVICE,
            implementation_file=implementation_file(CoreDeviceLocationService),
            purpose="List built-in location simulation scenarios",
            set_supported=coredevice_set_clear_supported(),
            clear_supported=coredevice_set_clear_supported(),
            requires_rsd=True,
            requires_persistent_tunnel=False,
            cli_entry_point="developer core-device location available-scenarios",
        )

    async def select_method(self, method: str, clear_current: bool = True) -> None:
        normalized = normalize_method(method)
        if normalized not in self.backends:
            raise ProbeError(f"Unknown backend method: {method}")
        if not self.available.get(normalized):
            self.recorder.event("METHOD_UNAVAILABLE", method=normalized)
            if normalized == "COREDEVICE":
                self.recorder.event("COREDEVICE_LOCATION_SIMULATION_UNAVAILABLE")
            raise ProbeError(f"{normalized}_LOCATION_SIMULATION_UNAVAILABLE")
        if clear_current and self.active_method != normalized:
            await self.clear()
        backend = self.backends[normalized]
        await backend.connect()
        self.active_method = normalized
        self.recorder.event("METHOD_SELECTED", method=normalized)

    async def set_location(self, lat: float, lon: float) -> None:
        await self.backends[self.active_method].set(lat, lon)

    async def clear(self) -> None:
        await self.backends[self.active_method].clear()

    async def disconnect(self) -> None:
        self.recorder.event("TEARDOWN_START")
        for name, backend in list(self.backends.items()):
            try:
                await backend.close()
                self.recorder.event("BACKEND_CLOSED", method=name)
            except Exception as exc:
                self.recorder.error("BACKEND_CLOSE_FAILED", exc, method=name)
        if self.tunnel is not None:
            await self.tunnel.aclose()
            self.recorder.event("USERSPACE_RSD_DISCONNECTED")
        self.tunnel = None
        self.rsd = None
        self.recorder.event("TEARDOWN_COMPLETE")

    def state(self, visibility: DeviceVisibility | None = None) -> dict[str, Any]:
        now = time.monotonic()
        backend = self.backends.get(self.active_method)
        state: dict[str, Any] = {
            "target_udid": self.udid,
            "active_method": self.active_method,
            "elapsed_s": f"{now - self.connected_at:.1f}" if self.connected_at else "not_connected",
            "rsd_object": self.rsd is not None,
            "service_count": len(self.services),
            "available_methods": ",".join(name for name, ok in self.available.items() if ok),
            "coredevice_location_simulation_available": self.available.get("COREDEVICE", False),
        }
        if backend is not None:
            state.update(backend.state())
        if visibility is not None:
            state.update(
                {
                    "usb_present": visibility.usb_present,
                    "network_present": visibility.network_present,
                    "usb_count": visibility.usb_count,
                    "network_count": visibility.network_count,
                    "usb_match_count": visibility.usb_match_count,
                    "network_match_count": visibility.network_match_count,
                    "visibility_errors": "; ".join(visibility.errors),
                }
            )
        return state


def normalize_method(method: str) -> str:
    value = (method or "").strip().lower()
    if value in {"1", "d", "dvt"}:
        return "DVT"
    if value in {"2", "c", "core", "coredevice", "core-device"}:
        return "COREDEVICE"
    raise ProbeError(f"Unknown backend method: {method}")


class InputThread:
    def __init__(self, recorder: Recorder) -> None:
        self.recorder = recorder
        self.commands: queue.Queue[tuple[str, str | None]] = queue.Queue()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def _run(self) -> None:
        while True:
            try:
                raw = input("> ").strip()
            except EOFError:
                self.commands.put(("q", None))
                return
            except Exception as exc:
                self.recorder.error("INPUT_THREAD_FAILED", exc)
                self.commands.put(("q", None))
                return
            if raw == "m":
                try:
                    marker = input("Observation: ").strip()
                except EOFError:
                    marker = "EOF while entering observation"
                self.commands.put(("m", marker))
            elif raw == "x":
                try:
                    method = input("Backend method (1=DVT, 2=CoreDevice): ").strip()
                except EOFError:
                    method = ""
                self.commands.put(("x", method))
            else:
                self.commands.put((raw, None))


async def handle_command(command: str, value: str | None, session: CompatibilitySession, recorder: Recorder) -> bool:
    if command in {"h", "help", "?"}:
        print_menu(session)
    elif command == "s":
        await session.set_location(*SF)
    elif command == "n":
        await session.set_location(*NYC)
    elif command == "a":
        await session.set_location(*MIAMI)
    elif command == "m":
        recorder.manual(value or "")
    elif command == "c":
        await session.clear()
    elif command == "i":
        recorder.event("OPERATOR_STATUS", **session.state())
    elif command == "x":
        await session.select_method(value or "")
    elif command == "q":
        recorder.event("OPERATOR_QUIT_REQUESTED")
        try:
            await session.clear()
        except Exception as exc:
            recorder.error("QUIT_CLEAR_FAILED", exc)
        await session.disconnect()
        return False
    elif command:
        recorder.event("UNKNOWN_COMMAND", command=command)
        print_menu(session)
    return True


async def monitor_loop(
    session: CompatibilitySession,
    discovery: DeviceDiscovery,
    recorder: Recorder,
    input_thread: InputThread,
    heartbeat_s: float,
) -> None:
    last_heartbeat = 0.0
    running = True
    while running:
        now = time.monotonic()
        if now - last_heartbeat >= heartbeat_s:
            visibility = discovery.visibility()
            recorder.heartbeat(**session.state(visibility))
            last_heartbeat = now
        while True:
            try:
                command, value = input_thread.commands.get_nowait()
            except queue.Empty:
                break
            try:
                running = await handle_command(command, value, session, recorder)
            except Exception as exc:
                recorder.error("COMMAND_FAILED", exc, command=command, value=value)
        await asyncio.sleep(0.2)


def print_menu(session: CompatibilitySession | None = None) -> None:
    core_line = "2 - CoreDevice Location Simulation"
    if session is not None and not session.available.get("COREDEVICE", False):
        core_line += " (COREDEVICE_LOCATION_SIMULATION_UNAVAILABLE)"
    print(
        f"""
IOSSim Location Compatibility Probe

Available methods:
1 - DVT LocationSimulation
{core_line}

Actions:
s - Set San Francisco
n - Set New York
a - Set Miami
m - Add manual observation marker
c - Clear simulated location
i - Show current session/method status
x - Switch backend method
q - Clear + disconnect + quit
h - Show this menu
""".strip(),
        flush=True,
    )


async def run(args: argparse.Namespace) -> int:
    udid = validate_udid(args.udid)
    recorder = Recorder()
    print(f"Log path: {recorder.path}", flush=True)
    recorder.event("PROBE_START", pid=os.getpid(), python=sys.executable, selected_udid=udid)
    discovery = DeviceDiscovery(udid)
    session = CompatibilitySession(udid, recorder)
    stop_requested = asyncio.Event()

    def request_stop(signum: int, _: Any) -> None:
        recorder.event("SIGNAL_RECEIVED", signal=signum, note="disconnecting without automatic clear; use q for normal clear")
        stop_requested.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, request_stop, sig, None)
        except NotImplementedError:
            signal.signal(sig, request_stop)

    try:
        visibility = discovery.visibility()
        recorder.event(
            "STARTUP_VISIBILITY",
            usb_present=visibility.usb_present,
            network_present=visibility.network_present,
            usb_count=visibility.usb_count,
            network_count=visibility.network_count,
            usb_match_count=visibility.usb_match_count,
            network_match_count=visibility.network_match_count,
            selected_usb=visibility.selected_usb,
            selected_network=visibility.selected_network,
            errors="; ".join(visibility.errors),
        )
        if args.wait_for_unplug:
            print("If USB is connected, unplug the iPhone now. Waiting for the same UDID over Wi-Fi only.", flush=True)
            visibility = discovery.wait_for_wifi_only(recorder, args.wait_timeout)
        if visibility.usb_present and not args.allow_usb:
            raise ProbeError("USB is present. This compatibility probe is for the Wi-Fi/userspace path; unplug USB.")
        if not visibility.network_present and not args.allow_usb:
            raise ProbeError("Selected UDID is not visible over Wi-Fi/network.")
        recorder.event("CONNECTION_PRECONDITIONS_PASSED", selected_udid=udid)
        await session.connect()
        recorder.event("PROBE_READY", **session.state(visibility))
        print_menu(session)
        input_thread = InputThread(recorder)
        input_thread.start()
        monitor = asyncio.create_task(
            monitor_loop(session, discovery, recorder, input_thread, args.heartbeat_seconds),
            name="userspace-location-compatibility-monitor",
        )
        stop_task = asyncio.create_task(stop_requested.wait(), name="userspace-location-compatibility-stop")
        done, pending = await asyncio.wait({monitor, stop_task}, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        for task in done:
            if task is monitor:
                task.result()
        if stop_requested.is_set():
            await session.disconnect()
        recorder.event("PROBE_END")
        return 0
    except ProbeError as exc:
        recorder.error("PROBE_FAILED_SAFELY", exc)
        return 2
    except Exception as exc:
        recorder.error("PROBE_UNHANDLED_EXCEPTION", exc)
        return 1
    finally:
        recorder.close()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", default=DEFAULT_UDID, help="Explicit real target UDID. Placeholder values are rejected.")
    parser.add_argument("--wait-for-unplug", action="store_true", help="Wait until USB is absent and the same UDID is visible over Wi-Fi.")
    parser.add_argument("--wait-timeout", type=float, default=300.0)
    parser.add_argument("--heartbeat-seconds", type=float, default=3.0)
    parser.add_argument("--allow-usb", action="store_true", help="Debug escape hatch; normal compatibility runs should leave USB absent.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    return asyncio.run(run(parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
