from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from debug.userspace_location_diagnostic import (
    DeviceDiscovery,
    DiagnosticError,
    Recorder,
    UserspaceLocationDiagnosticSession,
    validate_udid,
)


UDID = "00008150-00022D581E12401C"


class FakeCli:
    def __init__(self) -> None:
        self.usb = True
        self.network = True
        self.duplicate_network = False
        self.commands: list[tuple[str, ...]] = []

    def run(self, *args: str, timeout: float = 20.0):
        self.commands.append(args)
        if args == ("usbmux", "list", "--usb"):
            return self._result(self._devices("USB") if self.usb else [])
        if args == ("usbmux", "list", "--network"):
            return self._result(self._devices("Network") if self.network else [])
        if args[:3] == ("lockdown", "remotepairing", "--pair"):
            return self._result({"wireProtocolVersion": 24})
        if args[:3] == ("lockdown", "wifi-connections", "--state"):
            return self._result("")
        return SimpleNamespace(returncode=1, stdout="", stderr="unexpected")

    def _devices(self, connection_type: str):
        devices = [
            {
                "UniqueDeviceID": UDID,
                "Identifier": UDID,
                "DeviceName": "Test iPhone",
                "ConnectionType": connection_type,
            }
        ]
        if connection_type == "Network" and self.duplicate_network:
            devices.append(dict(devices[0]))
        return devices

    def _result(self, payload):
        stdout = payload if isinstance(payload, str) else json.dumps(payload)
        return SimpleNamespace(returncode=0, stdout=stdout, stderr="")


class FakeTunnel:
    def __init__(self, serial: str) -> None:
        self.serial = serial
        self.closed = False

    async def aopen(self):
        return SimpleNamespace(
            udid=self.serial,
            product_type="iPhone18,1",
            product_version="26.6",
            is_in_process_tunnel=True,
            services={"com.apple.instruments.dtservicehub": {}, "com.apple.coredevice.locationservice": {}},
        )

    async def aclose(self):
        self.closed = True


class FakeDvt:
    def __init__(self, rsd) -> None:
        self.rsd = rsd
        self._service_name = "com.apple.instruments.dtservicehub"
        self._dtx = SimpleNamespace(_closed=False, _reader_task=None)
        self.closed = False

    async def connect(self):
        return None

    async def close(self):
        self.closed = True
        self._dtx._closed = True


class FakeChannel:
    def __init__(self) -> None:
        self.code = 1
        self.identifier = "com.apple.instruments.server.services.LocationSimulation"
        self._closed = False
        self.on_closed = None


class FakeLocation:
    def __init__(self, dvt) -> None:
        self.dvt = dvt
        self.sets: list[tuple[float, float]] = []
        self.clear_count = 0
        self.service = SimpleNamespace(IDENTIFIER="com.apple.instruments.server.services.LocationSimulation")
        self.service._channel = FakeChannel()

    async def connect(self):
        return None

    async def set(self, lat: float, lon: float):
        self.sets.append((lat, lon))
        return None

    async def clear(self):
        self.clear_count += 1
        return None


class FakeDeviceInfo:
    calls: list[str] = []

    def __init__(self, dvt) -> None:
        self.dvt = dvt

    async def __aenter__(self):
        FakeDeviceInfo.calls.append("enter")
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        FakeDeviceInfo.calls.append("exit")

    async def ls(self, path: str):
        FakeDeviceInfo.calls.append(f"ls:{path}")
        return ["usr", ".resolve", "bin", "sbin", ".file"]


class UserspaceLocationDiagnosticTests(unittest.TestCase):
    def test_explicit_udid_required(self) -> None:
        for value in ("", "unknown", "UNKNOWN", "none", "short"):
            with self.subTest(value=value):
                with self.assertRaises(DiagnosticError):
                    validate_udid(value)
        self.assertEqual(validate_udid(UDID), UDID)

    def test_discovery_reports_selected_usb_and_network(self) -> None:
        cli = FakeCli()
        discovery = DeviceDiscovery(UDID, cli)
        visibility = discovery.visibility()
        self.assertTrue(visibility.usb_present)
        self.assertTrue(visibility.network_present)
        self.assertEqual(visibility.usb_count, 1)
        self.assertEqual(visibility.network_count, 1)
        self.assertEqual(visibility.usb_match_count, 1)
        self.assertEqual(visibility.network_match_count, 1)

    def test_ambiguous_duplicate_udid_fails_safely(self) -> None:
        cli = FakeCli()
        cli.duplicate_network = True
        discovery = DeviceDiscovery(UDID, cli)
        visibility = discovery.visibility()
        self.assertFalse(visibility.network_present)
        self.assertEqual(visibility.network_match_count, 2)
        self.assertTrue(any("ambiguous" in error for error in visibility.errors))

    def test_missing_network_fails_precondition_for_operator(self) -> None:
        cli = FakeCli()
        cli.network = False
        discovery = DeviceDiscovery(UDID, cli)
        visibility = discovery.visibility()
        self.assertTrue(visibility.usb_present)
        self.assertFalse(visibility.network_present)

    def test_bootstrap_uses_lockdown_only_not_persistent_tunnels(self) -> None:
        cli = FakeCli()
        with tempfile.TemporaryDirectory() as tmp:
            recorder = Recorder(Path(tmp) / "diag.log", echo=False)
            try:
                DeviceDiscovery(UDID, cli).bootstrap(recorder)
            finally:
                recorder.close()
        flat = [" ".join(command) for command in cli.commands]
        self.assertTrue(any("lockdown remotepairing --pair" in command for command in flat))
        self.assertTrue(any("lockdown wifi-connections --state on" in command for command in flat))
        self.assertFalse(any("remote start-tunnel" in command for command in flat))
        self.assertFalse(any("--protocol quic" in command or "--protocol tcp" in command for command in flat))

    def test_set_before_connect_fails_safely(self) -> None:
        async def scenario() -> None:
            with tempfile.TemporaryDirectory() as tmp:
                recorder = Recorder(Path(tmp) / "diag.log", echo=False)
                try:
                    session = UserspaceLocationDiagnosticSession(
                        UDID,
                        recorder,
                        tunnel_factory=FakeTunnel,
                        dvt_factory=FakeDvt,
                        device_info_factory=FakeDeviceInfo,
                        location_factory=FakeLocation,
                    )
                    with self.assertRaises(DiagnosticError):
                        await session.set_location(1.0, 2.0)
                finally:
                    recorder.close()

        asyncio.run(scenario())

    def test_session_set_clear_disconnect_state_transitions(self) -> None:
        async def scenario() -> None:
            with tempfile.TemporaryDirectory() as tmp:
                recorder = Recorder(Path(tmp) / "diag.log", echo=False)
                try:
                    FakeDeviceInfo.calls = []
                    session = UserspaceLocationDiagnosticSession(
                        UDID,
                        recorder,
                        tunnel_factory=FakeTunnel,
                        dvt_factory=FakeDvt,
                        device_info_factory=FakeDeviceInfo,
                        location_factory=FakeLocation,
                    )
                    await session.connect()
                    self.assertEqual(FakeDeviceInfo.calls, ["enter", "ls:/", "exit"])
                    self.assertEqual(session.state()["rsd_object"], "yes")
                    await session.set_location(37.0, -122.0)
                    await session.set_location(40.0, -74.0)
                    await session.clear_location()
                    self.assertEqual(session.set_count, 2)
                    self.assertEqual(session.clear_count, 1)
                    self.assertEqual(session.last_set_lat, 40.0)
                    await session.disconnect()
                    self.assertEqual(session.state()["rsd_object"], "no")
                    self.assertEqual(session.state()["dvt_object"], "no")
                finally:
                    recorder.close()

        asyncio.run(scenario())

    def test_log_file_records_flushable_events(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "diag.log"
            recorder = Recorder(path, echo=False)
            try:
                recorder.event("test_event", value="ok")
                text = path.read_text(encoding="utf-8")
            finally:
                recorder.close()
        self.assertIn("EVENT test_event", text)
        self.assertIn("value=ok", text)


if __name__ == "__main__":
    unittest.main()
