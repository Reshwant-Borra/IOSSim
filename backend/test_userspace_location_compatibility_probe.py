from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from debug.userspace_location_compatibility_probe import (
    COREDEVICE_LOCATION_SERVICE,
    DVT_RSD_SERVICE,
    CompatibilitySession,
    CoreDeviceLocationBackend,
    DeviceDiscovery,
    DvtLocationBackend,
    ProbeError,
    Recorder,
    backend_availability,
    coredevice_set_clear_supported,
    location_related_services,
    service_inventory,
    validate_udid,
)


UDID = "00008150-00022D581E12401C"


class FakeCli:
    def __init__(self) -> None:
        self.usb = False
        self.network = True
        self.commands: list[tuple[str, ...]] = []

    def run(self, *args: str, timeout: float = 20.0):
        self.commands.append(args)
        if args == ("usbmux", "list", "--usb"):
            return self._result(self._devices("USB") if self.usb else [])
        if args == ("usbmux", "list", "--network"):
            return self._result(self._devices("Network") if self.network else [])
        return SimpleNamespace(returncode=1, stdout="", stderr="unexpected")

    def _devices(self, connection_type: str):
        return [
            {
                "UniqueDeviceID": UDID,
                "Identifier": UDID,
                "DeviceName": "Test iPhone",
                "ConnectionType": connection_type,
            }
        ]

    def _result(self, payload):
        return SimpleNamespace(returncode=0, stdout=json.dumps(payload), stderr="")


class FakeDvt:
    def __init__(self, rsd) -> None:
        self.rsd = rsd
        self._service_name = DVT_RSD_SERVICE
        self._dtx = SimpleNamespace(_closed=False, _reader_task=None)
        self.closed = False

    async def connect(self):
        return None

    async def close(self):
        self.closed = True
        self._dtx._closed = True


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


class FakeLocation:
    instances: list["FakeLocation"] = []

    def __init__(self, dvt) -> None:
        self.dvt = dvt
        self.connected = False
        self.sets: list[tuple[float, float]] = []
        self.clear_count = 0
        self.service = SimpleNamespace(
            IDENTIFIER="com.apple.instruments.server.services.LocationSimulation",
            _channel=SimpleNamespace(code=2, identifier="location", _closed=False),
        )
        FakeLocation.instances.append(self)

    async def connect(self):
        self.connected = True

    async def set(self, lat: float, lon: float):
        self.sets.append((lat, lon))

    async def clear(self):
        self.clear_count += 1


class FakeCoreUnavailable:
    def __init__(self, rsd) -> None:
        self.rsd = rsd


class FakeCoreAvailable:
    instances: list["FakeCoreAvailable"] = []

    def __init__(self, rsd) -> None:
        self.rsd = rsd
        self.connected = False
        self.closed = False
        self.sets: list[tuple[float, float]] = []
        self.clear_count = 0
        FakeCoreAvailable.instances.append(self)

    async def connect(self):
        self.connected = True

    async def set(self, lat: float, lon: float):
        self.sets.append((lat, lon))

    async def clear(self):
        self.clear_count += 1

    async def close(self):
        self.closed = True


class FakeSelectableBackend:
    def __init__(self, name: str) -> None:
        self.name = name
        self.connect_count = 0
        self.sets: list[tuple[float, float]] = []
        self.clear_count = 0
        self.close_count = 0

    async def connect(self) -> None:
        self.connect_count += 1

    async def set(self, lat: float, lon: float) -> None:
        self.sets.append((lat, lon))

    async def clear(self) -> None:
        self.clear_count += 1

    async def close(self) -> None:
        self.close_count += 1

    def state(self):
        return {"backend": self.name}


class FakeTunnel:
    def __init__(self) -> None:
        self.close_count = 0

    async def aclose(self):
        self.close_count += 1


class UserspaceLocationCompatibilityProbeTests(unittest.TestCase):
    def test_strict_real_udid_handling(self) -> None:
        for value in ("", "unknown", "UNKNOWN", "none", "short"):
            with self.subTest(value=value):
                with self.assertRaises(ProbeError):
                    validate_udid(value)
        self.assertEqual(validate_udid(UDID), UDID)

    def test_service_inventory_parsing_and_location_filtering(self) -> None:
        services = {
            DVT_RSD_SERVICE: {"Port": 1},
            COREDEVICE_LOCATION_SERVICE: {"Properties": {"Features": ["com.apple.coredevice.feature.simulatelocation"]}},
            "com.apple.mobile.lockdown.remote.trusted": {"Port": 2},
        }
        rsd = SimpleNamespace(peer_info={"Services": services})
        self.assertEqual(service_inventory(rsd), services)
        related = location_related_services(services)
        self.assertIn(DVT_RSD_SERVICE, related)
        self.assertIn(COREDEVICE_LOCATION_SERVICE, related)
        self.assertNotIn("com.apple.mobile.lockdown.remote.trusted", related)

    def test_dvt_and_coredevice_availability_detection(self) -> None:
        services = {DVT_RSD_SERVICE: {}, COREDEVICE_LOCATION_SERVICE: {}}
        self.assertTrue(coredevice_set_clear_supported(FakeCoreAvailable))
        self.assertFalse(coredevice_set_clear_supported(FakeCoreUnavailable))
        self.assertEqual(backend_availability(services, FakeCoreAvailable), {"DVT": True, "COREDEVICE": True})
        self.assertEqual(backend_availability(services, FakeCoreUnavailable), {"DVT": True, "COREDEVICE": False})

    def test_discovery_uses_explicit_udid_and_no_persistent_tunnel_cli(self) -> None:
        cli = FakeCli()
        visibility = DeviceDiscovery(UDID, cli).visibility()
        self.assertFalse(visibility.usb_present)
        self.assertTrue(visibility.network_present)
        flat = [" ".join(command) for command in cli.commands]
        self.assertTrue(any("usbmux list --usb" in command for command in flat))
        self.assertTrue(any("usbmux list --network" in command for command in flat))
        self.assertFalse(any("remote start-tunnel" in command for command in flat))
        self.assertFalse(any("--protocol quic" in command or "--protocol tcp" in command for command in flat))

    def test_dvt_backend_set_clear_dispatches_to_selected_backend(self) -> None:
        async def scenario() -> None:
            with tempfile.TemporaryDirectory() as tmp:
                recorder = Recorder(Path(tmp) / "compat.log", echo=False)
                try:
                    FakeDeviceInfo.calls = []
                    FakeLocation.instances = []
                    backend = DvtLocationBackend(
                        SimpleNamespace(),
                        recorder,
                        dvt_factory=FakeDvt,
                        device_info_factory=FakeDeviceInfo,
                        location_factory=FakeLocation,
                    )
                    await backend.connect()
                    await backend.set(37.7749, -122.4194)
                    await backend.clear()
                    self.assertEqual(FakeDeviceInfo.calls, ["enter", "ls:/", "exit"])
                    self.assertEqual(FakeLocation.instances[-1].sets, [(37.7749, -122.4194)])
                    self.assertEqual(FakeLocation.instances[-1].clear_count, 1)
                    self.assertEqual(backend.set_count, 1)
                    self.assertEqual(backend.clear_count, 1)
                finally:
                    recorder.close()

        asyncio.run(scenario())

    def test_coredevice_backend_unavailable_without_real_set_clear(self) -> None:
        async def scenario() -> None:
            with tempfile.TemporaryDirectory() as tmp:
                recorder = Recorder(Path(tmp) / "compat.log", echo=False)
                try:
                    backend = CoreDeviceLocationBackend(
                        SimpleNamespace(),
                        recorder,
                        location_service_factory=FakeCoreUnavailable,
                    )
                    with self.assertRaises(ProbeError):
                        await backend.connect()
                finally:
                    recorder.close()

        asyncio.run(scenario())

    def test_coredevice_backend_dispatches_if_implementation_exists(self) -> None:
        async def scenario() -> None:
            with tempfile.TemporaryDirectory() as tmp:
                recorder = Recorder(Path(tmp) / "compat.log", echo=False)
                try:
                    FakeCoreAvailable.instances = []
                    backend = CoreDeviceLocationBackend(
                        SimpleNamespace(),
                        recorder,
                        location_service_factory=FakeCoreAvailable,
                    )
                    await backend.connect()
                    await backend.set(40.7128, -74.0060)
                    await backend.clear()
                    self.assertEqual(FakeCoreAvailable.instances[-1].sets, [(40.7128, -74.006)])
                    self.assertEqual(FakeCoreAvailable.instances[-1].clear_count, 1)
                finally:
                    recorder.close()

        asyncio.run(scenario())

    def test_backend_switch_requires_clear_first(self) -> None:
        async def scenario() -> None:
            with tempfile.TemporaryDirectory() as tmp:
                recorder = Recorder(Path(tmp) / "compat.log", echo=False)
                try:
                    session = CompatibilitySession(UDID, recorder)
                    dvt = FakeSelectableBackend("DVT")
                    core = FakeSelectableBackend("COREDEVICE")
                    session.backends = {"DVT": dvt, "COREDEVICE": core}
                    session.available = {"DVT": True, "COREDEVICE": True}
                    session.active_method = "DVT"
                    await session.select_method("2")
                    self.assertEqual(dvt.clear_count, 1)
                    self.assertEqual(core.connect_count, 1)
                    self.assertEqual(session.active_method, "COREDEVICE")
                finally:
                    recorder.close()

        asyncio.run(scenario())

    def test_manual_marker_logging_and_continuous_flush(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "compat.log"
            recorder = Recorder(path, echo=False)
            try:
                recorder.manual("Maps=NY FindMy=CA Life360=loading")
                text = path.read_text(encoding="utf-8")
            finally:
                recorder.close()
        self.assertIn("MANUAL Maps=NY FindMy=CA Life360=loading", text)

    def test_cleanup_closes_backends_and_userspace_tunnel(self) -> None:
        async def scenario() -> None:
            with tempfile.TemporaryDirectory() as tmp:
                recorder = Recorder(Path(tmp) / "compat.log", echo=False)
                try:
                    session = CompatibilitySession(UDID, recorder)
                    dvt = FakeSelectableBackend("DVT")
                    core = FakeSelectableBackend("COREDEVICE")
                    tunnel = FakeTunnel()
                    session.backends = {"DVT": dvt, "COREDEVICE": core}
                    session.tunnel = tunnel
                    await session.disconnect()
                    self.assertEqual(dvt.close_count, 1)
                    self.assertEqual(core.close_count, 1)
                    self.assertEqual(tunnel.close_count, 1)
                finally:
                    recorder.close()

        asyncio.run(scenario())

    def test_production_usb_path_untouched_by_probe(self) -> None:
        source = Path(__file__).with_name("location_service.py").read_text(encoding="utf-8")
        self.assertIn("simulate-location", source)
        self.assertNotIn("userspace_location_compatibility_probe", source)


if __name__ == "__main__":
    unittest.main()
