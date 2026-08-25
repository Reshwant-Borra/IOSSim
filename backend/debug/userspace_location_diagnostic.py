#!/usr/bin/env python3
"""Long-running userspace RSD/DVT location diagnostic recorder.

This debug-only harness intentionally does not use IOSSim's production
LocationService. It opens the known-good userspace RSD -> DVT
LocationSimulation stack, keeps all relevant objects referenced until the
operator quits, and records observable state for physical correlation.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
import traceback
import weakref
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation


RESULTS_DIR = Path(__file__).resolve().parent / "results"
DEFAULT_UDID_REJECTS = {"", "unknown", "<unknown>", "none", "null"}
SF = (37.7749, -122.4194)
NYC = (40.7128, -74.0060)
MIAMI = (25.7617, -80.1918)


class DiagnosticError(RuntimeError):
    """Raised for safe, expected diagnostic setup failures."""


def validate_udid(udid: str) -> str:
    value = (udid or "").strip()
    if value.lower() in DEFAULT_UDID_REJECTS:
        raise DiagnosticError("A real explicit device UDID is required; refusing placeholder value.")
    if len(value) < 12:
        raise DiagnosticError("UDID is too short to be a safe explicit device identifier.")
    return value


def timestamp() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def log_filename() -> Path:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return RESULTS_DIR / f"userspace_location_diagnostic_{stamp}.log"


def compact(value: Any, limit: int = 900) -> str:
    text = str(value)
    text = " ".join(text.split())
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


class Recorder:
    def __init__(self, path: Path | None = None, echo: bool = True) -> None:
        self.path = path or log_filename()
        self.echo = echo
        self._handle = self.path.open("a", encoding="utf-8", buffering=1)
        self._seen_errors: set[str] = set()
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
            if self._handle.closed:
                if self.echo:
                    print(line, flush=True)
                return
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

    def error(self, message: str, exc: BaseException | None = None, repeat: bool = False, **fields: Any) -> None:
        key = f"{message}:{type(exc).__name__ if exc else ''}:{exc!r}"
        if not repeat and key in self._seen_errors:
            return
        self._seen_errors.add(key)
        if exc is not None:
            fields = {
                **fields,
                "exception_type": type(exc).__name__,
                "exception": repr(exc),
            }
        self.line("ERROR", message, **fields)
        if exc is not None:
            stack = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
            with self._lock:
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

    def bootstrap(self, recorder: Recorder) -> None:
        for command in (
            ("lockdown", "remotepairing", "--pair", "--udid", self.udid),
            ("lockdown", "wifi-connections", "--state", "on", "--udid", self.udid),
        ):
            recorder.event("bootstrap_command_start", command=" ".join(command))
            try:
                result = self.cli.run(*command, timeout=60)
            except Exception as exc:
                recorder.error("bootstrap_command_exception", exc, command=" ".join(command))
                raise DiagnosticError(f"Bootstrap command failed: {' '.join(command)}") from exc
            recorder.event(
                "bootstrap_command_complete",
                command=" ".join(command),
                returncode=result.returncode,
                stdout=compact(result.stdout, 1200),
                stderr=compact(result.stderr, 1200),
            )
            if result.returncode != 0:
                raise DiagnosticError(f"Bootstrap command failed: {' '.join(command)}")

    def wait_for_usb_removed_and_network_visible(
        self,
        recorder: Recorder,
        timeout_s: float,
        poll_s: float = 2.0,
    ) -> DeviceVisibility:
        deadline = time.monotonic() + timeout_s
        last: DeviceVisibility | None = None
        recorder.event("waiting_for_usb_removed_and_network_visible", timeout_s=timeout_s)
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
        raise DiagnosticError(
            "Timed out waiting for selected device to be visible over Wi-Fi with USB absent. "
            f"Last visibility: {last}"
        )

    def _matches(self, devices: list[dict[str, Any]]) -> list[dict[str, Any]]:
        matches = []
        for device in devices:
            identifiers = [
                device.get("UniqueDeviceID"),
                device.get("Identifier"),
                device.get("SerialNumber"),
                device.get("UDID"),
            ]
            if self.udid in identifiers:
                matches.append(device)
        return matches


class UserspaceLocationDiagnosticSession:
    def __init__(
        self,
        udid: str,
        recorder: Recorder,
        *,
        tunnel_factory: Callable[..., Any] = UserspaceRsdTunnel,
        dvt_factory: Callable[..., Any] = DvtProvider,
        device_info_factory: Callable[..., Any] = DeviceInfo,
        location_factory: Callable[..., Any] = LocationSimulation,
    ) -> None:
        self.udid = validate_udid(udid)
        self.recorder = recorder
        self._tunnel_factory = tunnel_factory
        self._dvt_factory = dvt_factory
        self._device_info_factory = device_info_factory
        self._location_factory = location_factory
        self.tunnel: Any | None = None
        self.rsd: Any | None = None
        self.dvt: Any | None = None
        self.location: Any | None = None
        self.connected_at: float | None = None
        self.last_set_at: float | None = None
        self.last_set_lat: float | None = None
        self.last_set_lon: float | None = None
        self.clear_count = 0
        self.set_count = 0
        self._finalizers: list[weakref.finalize] = []
        self._closing = False

    async def connect(self) -> None:
        if self.location is not None:
            self.recorder.event("connect_noop_already_connected")
            return
        self.recorder.event("userspace_rsd_connect_start", udid=self.udid)
        self.tunnel = self._tunnel_factory(serial=self.udid)
        self._watch_object("userspace_tunnel", self.tunnel)
        self.rsd = await self.tunnel.aopen()
        self._watch_object("rsd", self.rsd)
        self.recorder.event(
            "userspace_rsd_connected",
            rsd_udid=getattr(self.rsd, "udid", None),
            product_type=getattr(self.rsd, "product_type", None),
            product_version=getattr(self.rsd, "product_version", None),
            in_process_tunnel=getattr(self.rsd, "is_in_process_tunnel", None),
            service_count=len(service_names(self.rsd)),
            has_dtservicehub="com.apple.instruments.dtservicehub" in service_names(self.rsd),
            has_coredevice_location="com.apple.coredevice.locationservice" in service_names(self.rsd),
        )

        self.dvt = self._dvt_factory(self.rsd)
        self._watch_object("dvt_provider", self.dvt)
        await self.dvt.connect()
        self.recorder.event("dvt_provider_connected", service_name=getattr(self.dvt, "_service_name", None))

        await self._open_device_info_warmup_channel()

        self.location = self._location_factory(self.dvt)
        self._watch_object("location_simulation", self.location)
        await self.location.connect()
        self._watch_dtx()
        self.connected_at = time.monotonic()
        service = getattr(self.location, "service", None)
        self.recorder.event(
            "location_simulation_ready",
            service_identifier=getattr(service, "IDENTIFIER", None),
            channel_code=self._channel_attr("code"),
            channel_identifier=self._channel_attr("identifier"),
        )

    async def set_location(self, lat: float, lon: float) -> None:
        if self.location is None:
            raise DiagnosticError("Set Location requested before userspace LocationSimulation is connected.")
        started = time.monotonic()
        self.recorder.event("location_set_start", lat=lat, lon=lon)
        result = await self.location.set(lat, lon)
        self.last_set_at = time.monotonic()
        self.last_set_lat = lat
        self.last_set_lon = lon
        self.set_count += 1
        self.recorder.event(
            "location_set",
            lat=lat,
            lon=lon,
            result=repr(result),
            elapsed_s=f"{self.last_set_at - started:.3f}",
            set_count=self.set_count,
        )

    async def clear_location(self) -> None:
        if self.location is None:
            raise DiagnosticError("Clear requested before userspace LocationSimulation is connected.")
        started = time.monotonic()
        self.recorder.event("location_clear_start")
        result = await self.location.clear()
        self.clear_count += 1
        self.recorder.event(
            "location_clear",
            result=repr(result),
            elapsed_s=f"{time.monotonic() - started:.3f}",
            clear_count=self.clear_count,
            awaiting_physical_confirmation=True,
        )

    async def disconnect(self) -> None:
        if self._closing:
            return
        self._closing = True
        self.recorder.event("diagnostic_disconnect_start")
        if self.dvt is not None:
            try:
                await self.dvt.close()
                self.recorder.event("dvt_provider_closed")
            except Exception as exc:
                self.recorder.error("dvt_provider_close_exception", exc)
        if self.tunnel is not None:
            try:
                await self.tunnel.aclose()
                self.recorder.event("userspace_tunnel_closed")
            except Exception as exc:
                self.recorder.error("userspace_tunnel_close_exception", exc)
        self.location = None
        self.dvt = None
        self.rsd = None
        self.tunnel = None
        self.recorder.event("diagnostic_disconnect_complete")

    def state(self, visibility: DeviceVisibility | None = None) -> dict[str, Any]:
        now = time.monotonic()
        dtx = getattr(self.dvt, "_dtx", None) if self.dvt is not None else None
        reader_task = getattr(dtx, "_reader_task", None) if dtx is not None else None
        channel = self._channel()
        state = {
            "process_alive": "yes",
            "target_udid": self.udid,
            "elapsed_s": f"{now - self.connected_at:.1f}" if self.connected_at else "not_connected",
            "rsd_object": "yes" if self.rsd is not None else "no",
            "rsd_health_check_supported": "false",
            "rsd_udid": getattr(self.rsd, "udid", None) if self.rsd is not None else None,
            "dvt_object": "yes" if self.dvt is not None else "no",
            "dvt_connected_observable": "yes" if dtx is not None and not getattr(dtx, "_closed", True) else "no",
            "dtx_closed": getattr(dtx, "_closed", None) if dtx is not None else None,
            "dtx_reader_task_done": reader_task.done() if reader_task is not None else None,
            "location_object": "yes" if self.location is not None else "no",
            "location_channel_closed": getattr(channel, "_closed", None) if channel is not None else None,
            "location_channel_health_check_supported": "private_state_only" if channel is not None else "false",
            "last_set_lat": self.last_set_lat,
            "last_set_lon": self.last_set_lon,
            "seconds_since_last_set": f"{now - self.last_set_at:.1f}" if self.last_set_at else None,
            "set_count": self.set_count,
            "clear_count": self.clear_count,
            "gc_counts": gc.get_count(),
            "finalizers_alive": sum(1 for item in self._finalizers if item.alive),
        }
        if visibility is not None:
            state.update(
                {
                    "usb_present": visibility.usb_present,
                    "wifi_device_visible": visibility.network_present,
                    "usb_count": visibility.usb_count,
                    "network_count": visibility.network_count,
                    "usb_match_count": visibility.usb_match_count,
                    "network_match_count": visibility.network_match_count,
                    "visibility_errors": "; ".join(visibility.errors),
                }
            )
        return state

    async def _open_device_info_warmup_channel(self) -> None:
        """Mirror the known-good debug probe's DeviceInfo channel warmup.

        The physical success checkpoint used this sequence before opening
        LocationSimulation:

            async with DeviceInfo(dvt) as device_info:
                await device_info.ls("/")

        Keep the same operation here rather than assuming DVT service ordering
        is irrelevant.
        """
        self.recorder.event("device_info_warmup_start")
        device_info = self._device_info_factory(self.dvt)
        self._watch_object("device_info", device_info)
        async with device_info:
            root_entries = await device_info.ls("/")
            self.recorder.event(
                "device_info_warmup_complete",
                root_count=len(root_entries),
                root_sample=root_entries[:5],
            )

    def _watch_dtx(self) -> None:
        dtx = getattr(self.dvt, "_dtx", None) if self.dvt is not None else None
        reader_task = getattr(dtx, "_reader_task", None) if dtx is not None else None
        if reader_task is not None:
            reader_task.add_done_callback(self._dtx_reader_done)
            self.recorder.event("dtx_reader_task_observed", done=reader_task.done())
        channel = self._channel()
        if channel is not None:
            old_on_closed = getattr(channel, "on_closed", None)

            def on_closed(reason: str = "") -> None:
                self.recorder.event("location_channel_closed", reason=reason)
                if old_on_closed is not None:
                    old_on_closed(reason)

            channel.on_closed = on_closed

    def _dtx_reader_done(self, task: asyncio.Task[Any]) -> None:
        if task.cancelled():
            self.recorder.event("dtx_reader_task_done", cancelled=True)
            return
        try:
            exc = task.exception()
        except Exception as err:
            self.recorder.error("dtx_reader_task_exception_lookup_failed", err)
            return
        if exc is None:
            self.recorder.event("dtx_reader_task_done", exception=None)
        else:
            self.recorder.error("dtx_reader_task_done_with_exception", exc)

    def _watch_object(self, label: str, obj: Any) -> None:
        try:
            finalizer = weakref.finalize(obj, self.recorder.event, "object_finalized", object_label=label)
            self._finalizers.append(finalizer)
            self.recorder.event("object_created", object_label=label, object_type=type(obj).__name__)
        except TypeError:
            self.recorder.event("object_created", object_label=label, object_type=type(obj).__name__, weakref_supported=False)

    def _channel(self) -> Any | None:
        try:
            service = getattr(self.location, "service", None) if self.location is not None else None
            return getattr(service, "_channel", None) if service is not None else None
        except Exception:
            return None

    def _channel_attr(self, name: str) -> Any:
        channel = self._channel()
        return getattr(channel, name, None) if channel is not None else None


def service_names(rsd: Any) -> set[str]:
    peer_info = getattr(rsd, "peer_info", None)
    if isinstance(peer_info, dict):
        value = peer_info.get("Services")
        if isinstance(value, dict):
            return set(value)
    services = getattr(rsd, "services", None)
    if isinstance(services, dict):
        return set(services)
    all_values = getattr(rsd, "all_values", None)
    if isinstance(all_values, dict):
        value = all_values.get("Services")
        if isinstance(value, dict):
            return set(value)
    return set()


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
                self.recorder.error("input_thread_exception", exc)
                self.commands.put(("q", None))
                return
            if raw == "m":
                try:
                    marker = input("Marker: ").strip()
                except EOFError:
                    marker = "EOF while entering marker"
                self.commands.put(("m", marker))
            elif raw == "4":
                try:
                    lat = input("Latitude: ").strip()
                    lon = input("Longitude: ").strip()
                    self.commands.put(("custom", f"{lat},{lon}"))
                except EOFError:
                    self.commands.put(("q", None))
                    return
            else:
                self.commands.put((raw, None))


async def monitor_loop(
    session: UserspaceLocationDiagnosticSession,
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
                running = await handle_command(command, value, session, discovery, recorder)
            except Exception as exc:
                recorder.error("command_failed", exc, command=command, value=value)
        await asyncio.sleep(0.2)


async def handle_command(
    command: str,
    value: str | None,
    session: UserspaceLocationDiagnosticSession,
    discovery: DeviceDiscovery,
    recorder: Recorder,
) -> bool:
    if command in {"h", "help", "?"}:
        print_menu()
    elif command == "1":
        await session.set_location(*SF)
    elif command == "2":
        await session.set_location(*NYC)
    elif command == "3":
        await session.set_location(*MIAMI)
    elif command == "custom":
        if not value:
            raise DiagnosticError("Missing custom coordinate")
        lat_s, lon_s = value.split(",", 1)
        await session.set_location(float(lat_s), float(lon_s))
    elif command == "m":
        recorder.manual(value or "")
    elif command == "r":
        recorder.manual("physical spoof disappeared")
    elif command == "s":
        visibility = discovery.visibility()
        recorder.event("operator_status_request", **session.state(visibility))
    elif command == "c":
        await session.clear_location()
    elif command == "q":
        recorder.event("operator_quit_requested")
        try:
            await session.clear_location()
        except Exception as exc:
            recorder.error("quit_clear_failed", exc)
        await session.disconnect()
        return False
    elif command:
        recorder.event("unknown_command", command=command)
        print_menu()
    return True


def print_menu() -> None:
    print(
        """
IOSSim Userspace Location Diagnostic

1 - Set San Francisco
2 - Set New York
3 - Set Miami
4 - Custom coordinate
m - Add manual observation marker
r - Record "physical spoof disappeared"
s - Print current diagnostic state
c - Clear simulated location
q - Clear, clean up and quit
h - Show this menu
""".strip(),
        flush=True,
    )


async def run(args: argparse.Namespace) -> int:
    udid = validate_udid(args.udid)
    recorder = Recorder()
    print(f"Log path: {recorder.path}", flush=True)
    recorder.event("diagnostic_start", pid=os.getpid(), python=sys.executable, udid=udid)
    discovery = DeviceDiscovery(udid)
    session = UserspaceLocationDiagnosticSession(udid, recorder)
    stop_requested = asyncio.Event()

    def request_stop(signum: int, _: Any) -> None:
        recorder.event("signal_received", signal=signum, note="closing without automatic clear; use q for clear during normal operation")
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
            "startup_visibility",
            usb_present=visibility.usb_present,
            network_present=visibility.network_present,
            usb_count=visibility.usb_count,
            network_count=visibility.network_count,
            usb_match_count=visibility.usb_match_count,
            network_match_count=visibility.network_match_count,
            selected_udid=udid,
            errors="; ".join(visibility.errors),
        )
        if args.bootstrap:
            if visibility.usb_present:
                discovery.bootstrap(recorder)
            else:
                recorder.event("bootstrap_skipped_no_usb", selected_udid=udid)
        if args.wait_for_unplug:
            print("If USB is connected, unplug the iPhone now. Waiting for same UDID over Wi-Fi only.", flush=True)
            visibility = discovery.wait_for_usb_removed_and_network_visible(recorder, args.wait_timeout)
        else:
            visibility = discovery.visibility()
        if visibility.usb_present:
            raise DiagnosticError("USB is still present. Unplug USB before userspace wireless diagnostic connection.")
        if not visibility.network_present:
            raise DiagnosticError("Selected UDID is not visible over Wi-Fi/network.")

        recorder.event("userspace_connection_preconditions_passed", selected_udid=udid)
        await session.connect()
        recorder.event("startup_ready", dvt_location_simulation_ready=True)
        print_menu()
        input_thread = InputThread(recorder)
        input_thread.start()
        monitor = asyncio.create_task(
            monitor_loop(session, discovery, recorder, input_thread, args.heartbeat_seconds),
            name="userspace-location-diagnostic-monitor",
        )
        stop_task = asyncio.create_task(stop_requested.wait(), name="userspace-location-diagnostic-stop-signal")
        done, pending = await asyncio.wait({monitor, stop_task}, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        for task in done:
            if task is monitor:
                task.result()
        if stop_requested.is_set():
            recorder.event("signal_stop_disconnect_start")
            await session.disconnect()
        recorder.event("diagnostic_end")
        return 0
    except DiagnosticError as exc:
        recorder.error("diagnostic_failed_safely", exc)
        return 2
    except Exception as exc:
        recorder.error("diagnostic_unhandled_exception", exc)
        return 1
    finally:
        recorder.close()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True, help="Explicit real target UDID. Placeholder values are rejected.")
    parser.add_argument("--bootstrap", action="store_true", help="Run USB RemotePairing and Wi-Fi enablement if USB is present.")
    parser.add_argument("--wait-for-unplug", action="store_true", help="Wait until USB is absent and the same UDID is visible over Wi-Fi.")
    parser.add_argument("--wait-timeout", type=float, default=300.0)
    parser.add_argument("--heartbeat-seconds", type=float, default=3.0)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    return asyncio.run(run(parse_args(argv)))


if __name__ == "__main__":
    raise SystemExit(main())
