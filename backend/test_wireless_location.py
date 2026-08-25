from __future__ import annotations

import asyncio
import json
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

from wireless_location.controller import WirelessLocationController
from wireless_location.session import WirelessUserspaceLocationSession, validate_udid
from wireless_location.store import WirelessDeviceStore
from wireless_testing.command_runner import CommandResult


UDID = "00008150-00022D581E12401C"
OTHER_UDID = "00008150-00022D581E124999"


class FakeTunnel:
    close_count = 0
    rsd_udid = UDID

    def __init__(self, serial: str) -> None:
        self.serial = serial

    async def aopen(self):
        return SimpleNamespace(
            udid=self.rsd_udid,
            product_type="iPhone18,1",
            product_version="26.6",
            services={"com.apple.instruments.dtservicehub": {}},
        )

    async def aclose(self):
        FakeTunnel.close_count += 1


class FakeDvt:
    close_count = 0

    def __init__(self, rsd) -> None:
        self.rsd = rsd
        self._dtx = SimpleNamespace(_closed=False)

    async def connect(self):
        return None

    async def close(self):
        FakeDvt.close_count += 1
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
        return ["usr", "bin"]


class FakeLocation:
    instances: list["FakeLocation"] = []

    def __init__(self, dvt) -> None:
        self.dvt = dvt
        self.connected = False
        self.sets: list[tuple[float, float]] = []
        self.clear_count = 0
        FakeLocation.instances.append(self)

    async def connect(self):
        self.connected = True

    async def set(self, lat: float, lon: float):
        self.sets.append((lat, lon))

    async def clear(self):
        self.clear_count += 1


class InlineWorker:
    def run(self, coro, timeout=None):
        return asyncio.run(coro)


class FakeRunner:
    def __init__(self) -> None:
        self.usb = True
        self.network = True
        self.duplicate_network = False
        self.commands: list[list[str]] = []

    def run(self, args: list[str], timeout_s: float = 20.0, input_text: str | None = None) -> CommandResult:
        self.commands.append(list(args))
        tail = args[3:] if len(args) >= 3 and args[2] == "pymobiledevice3" else args
        if tail == ["usbmux", "list", "--usb"]:
            return self._result(self._devices("USB") if self.usb else [])
        if tail == ["usbmux", "list", "--network"]:
            devices = self._devices("Network") if self.network else []
            if self.duplicate_network and devices:
                devices.append(dict(devices[0]))
            return self._result(devices)
        if tail == ["lockdown", "remotepairing", "--help"]:
            return self._text("usage --pair --udid")
        if tail[:3] == ["lockdown", "remotepairing", "--pair"]:
            return self._text('{"wireProtocolVersion":24}')
        if tail == ["lockdown", "wifi-connections", "--help"]:
            return self._text("usage --state --udid")
        if tail[:4] == ["lockdown", "wifi-connections", "--state", "on"]:
            return self._text("")
        return self._text("unexpected", ok=False, returncode=1)

    def popen(self, args: list[str]):
        raise AssertionError("persistent tunnel process should not start")

    def _devices(self, connection_type: str):
        return [
            {
                "UniqueDeviceID": UDID,
                "Identifier": UDID,
                "DeviceName": "Test iPhone",
                "ProductType": "iPhone18,1",
                "ProductVersion": "26.6",
                "ConnectionType": connection_type,
            }
        ]

    def _result(self, payload, ok: bool = True, returncode: int = 0) -> CommandResult:
        return self._text(json.dumps(payload), ok=ok, returncode=returncode)

    def _text(self, stdout: str, ok: bool = True, returncode: int = 0) -> CommandResult:
        now = time.time()
        return CommandResult(ok, ["fake"], returncode, stdout, "", now, now)


def fake_session_factory(udid: str, **kwargs):
    return WirelessUserspaceLocationSession(
        udid,
        tunnel_factory=FakeTunnel,
        dvt_factory=FakeDvt,
        device_info_factory=FakeDeviceInfo,
        location_factory=FakeLocation,
        **kwargs,
    )


class WirelessUserspaceLocationSessionTests(unittest.TestCase):
    def setUp(self) -> None:
        FakeDeviceInfo.calls = []
        FakeLocation.instances = []
        FakeTunnel.close_count = 0
        FakeDvt.close_count = 0
        FakeTunnel.rsd_udid = UDID

    def test_explicit_udid_required(self) -> None:
        for value in ("", "unknown", "none", "short"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    validate_udid(value)

    def test_connect_set_multiple_clear_disconnect_uses_warmup(self) -> None:
        async def scenario() -> None:
            session = fake_session_factory(UDID)
            await session.connect()
            await session.set_location(37.7749, -122.4194)
            await session.set_location(40.7128, -74.006)
            await session.clear_location()
            self.assertEqual(FakeDeviceInfo.calls, ["enter", "ls:/", "exit"])
            self.assertEqual(FakeLocation.instances[-1].sets, [(37.7749, -122.4194), (40.7128, -74.006)])
            self.assertEqual(FakeLocation.instances[-1].clear_count, 1)
            self.assertFalse(session.simulation_enabled)
            await session.disconnect()
            self.assertEqual(FakeDvt.close_count, 1)
            self.assertEqual(FakeTunnel.close_count, 1)

        asyncio.run(scenario())

    def test_wrong_rsd_udid_is_rejected(self) -> None:
        async def scenario() -> None:
            FakeTunnel.rsd_udid = OTHER_UDID
            session = fake_session_factory(UDID)
            with self.assertRaises(RuntimeError):
                await session.connect()
            self.assertIn("different iPhone", session.last_error or "")

        asyncio.run(scenario())


class WirelessLocationControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        FakeDeviceInfo.calls = []
        FakeLocation.instances = []
        FakeTunnel.close_count = 0
        FakeDvt.close_count = 0
        FakeTunnel.rsd_udid = UDID

    def make_controller(self, runner: FakeRunner, path: Path) -> WirelessLocationController:
        return WirelessLocationController(
            stable_status_provider=lambda: {"device_connected": False, "device": None, "tunnel_active": False},
            store=WirelessDeviceStore(path),
            runner=runner,
            worker=InlineWorker(),  # type: ignore[arg-type]
            session_factory=fake_session_factory,
        )

    def test_new_phone_setup_saves_identity_and_never_starts_persistent_tunnel(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runner = FakeRunner()
            controller = self.make_controller(runner, Path(tmp) / "devices.json")
            result = controller.begin_setup()

            self.assertTrue(result["ok"])
            self.assertEqual(result["setup_state"], "READY_TO_UNPLUG")
            self.assertEqual(controller.store.get(UDID).udid, UDID)  # type: ignore[union-attr]
            flat = [" ".join(command) for command in runner.commands]
            self.assertTrue(any("lockdown remotepairing --pair" in command for command in flat))
            self.assertTrue(any("lockdown wifi-connections --state on" in command for command in flat))
            self.assertFalse(any("remote start-tunnel" in command for command in flat))
            self.assertFalse(any("--protocol tcp" in command or "--protocol quic" in command for command in flat))

    def test_startup_marks_previously_paired_network_device_wireless_ready_without_usb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runner = FakeRunner()
            runner.usb = False
            controller = self.make_controller(runner, Path(tmp) / "devices.json")
            controller.store.upsert({"udid": UDID, "name": "Test iPhone", "wireless_setup_valid": True, "setup_state": "WIRELESS_READY"})

            status = controller.status(refresh=True)

            self.assertTrue(status["devices"][0]["wireless_ready"])
            self.assertEqual(status["message"], "Wireless Ready")

    def test_wireless_set_uses_userspace_session_not_persistent_tunnel(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runner = FakeRunner()
            runner.usb = False
            controller = self.make_controller(runner, Path(tmp) / "devices.json")
            controller.store.upsert({"udid": UDID, "name": "Test iPhone", "wireless_setup_valid": True, "setup_state": "WIRELESS_READY"})

            result = controller.set_location(37.7749, -122.4194, udid=UDID)

            self.assertTrue(result["ok"])
            self.assertEqual(FakeDeviceInfo.calls, ["enter", "ls:/", "exit"])
            self.assertEqual(FakeLocation.instances[-1].sets, [(37.7749, -122.4194)])
            flat = [" ".join(command) for command in runner.commands]
            self.assertFalse(any("remote start-tunnel" in command for command in flat))

    def test_clear_disables_restore_and_disconnects(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runner = FakeRunner()
            runner.usb = False
            controller = self.make_controller(runner, Path(tmp) / "devices.json")
            controller.store.upsert({"udid": UDID, "name": "Test iPhone", "wireless_setup_valid": True, "setup_state": "WIRELESS_READY"})
            self.assertTrue(controller.set_location(37.7749, -122.4194, udid=UDID)["ok"])

            result = controller.clear_location(udid=UDID)

            self.assertTrue(result["ok"])
            self.assertFalse(controller.session_status()["simulation_enabled"])
            self.assertEqual(controller.session_status()["session_state"], "DISCONNECTED")
            self.assertEqual(FakeLocation.instances[-1].clear_count, 1)

    def test_ambiguous_network_discovery_fails_safely(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runner = FakeRunner()
            runner.usb = False
            runner.duplicate_network = True
            controller = self.make_controller(runner, Path(tmp) / "devices.json")
            controller.store.upsert({"udid": UDID, "name": "Test iPhone", "wireless_setup_valid": True, "setup_state": "WIRELESS_READY"})

            result = controller.connect_wireless(UDID)

            self.assertFalse(result["ok"])
            self.assertEqual(result["code"], "ambiguous_device")

    def test_automatic_mode_does_not_use_wireless_without_saved_device(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            controller = self.make_controller(FakeRunner(), Path(tmp) / "devices.json")
            self.assertFalse(controller.should_use_wireless("automatic"))


if __name__ == "__main__":
    unittest.main()
