from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from wireless_testing.command_runner import CommandResult
from wireless_testing.controller import EXPERIMENT_A, EXPERIMENT_B, WirelessTestingController
from wireless_testing.experiment_store import WirelessExperimentStore
from wireless_testing.router import build_router


UDID = "00008150-00022D581E12401C"


class FakeProcess:
    def __init__(self, stdout: list[str] | None = None, alive: bool = True, pid: int = 4321, returncode: int | None = None) -> None:
        self.stdout = iter(stdout or [])
        self.pid = pid
        self.returncode = None if alive else (1 if returncode is None else returncode)
        self.stdin = SimpleNamespace(close=lambda: None)
        self.terminated = False
        self.killed = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = 0

    def kill(self):
        self.killed = True
        self.returncode = -9

    def wait(self, timeout=None):
        if self.returncode is None:
            self.returncode = 0
        return self.returncode


class FakeRunner:
    def __init__(self) -> None:
        self.usb_connected = True
        self.network_found = False
        self.remote_found = False
        self.tunnel_ok = True
        self.rsd_ok = True
        self.help_ok = True
        self.remote_pairing_supported = True
        self.wifi_connections_supported = True
        self.remote_pairing_ok = True
        self.wifi_connections_ok = True
        self.commands: list[list[str]] = []
        self.tunnel_process = FakeProcess(["fd12:3456::1 54321\n"])
        self.tunnel_by_protocol: dict[str, FakeProcess] = {}
        self.remote_browse_payload: dict | None = None
        self.bonjour_remotepairing_payload: list | None = None
        self.remote_pairing_payload: dict | None = None

    def result(self, args: list[str], ok: bool = True, stdout: str = "", stderr: str = "") -> CommandResult:
        return CommandResult(ok=ok, command=args, returncode=0 if ok else 1, stdout=stdout, stderr=stderr, started_at=1.0, completed_at=2.0)

    def run(self, args: list[str], timeout_s: float = 20.0, input_text: str | None = None) -> CommandResult:
        self.commands.append(args)
        text = " ".join(args)
        if "--help" in args:
            if "lockdown remotepairing" in text:
                return self.result(args, self.help_ok and self.remote_pairing_supported, "Usage lockdown remotepairing --pair --udid <str>")
            if "lockdown wifi-connections" in text:
                return self.result(args, self.help_ok and self.wifi_connections_supported, "Usage lockdown wifi-connections --state <on|off> --udid <str>")
            if "remote start-tunnel" in text:
                return self.result(args, self.help_ok, "Usage remote start-tunnel --protocol <tcp|quic> --udid <str>")
            return self.result(args, self.help_ok, "help")
        if "xcodebuild -version" in text:
            return self.result(args, False, "", "not found")
        if "usbmux list --usb" in text:
            devices = [{
                "UniqueDeviceID": UDID,
                "Identifier": UDID,
                "DeviceName": "Test iPhone",
                "ProductVersion": "26.5.2",
                "ProductType": "iPhone18,1",
                "ConnectionType": "USB",
            }] if self.usb_connected else []
            return self.result(args, True, json.dumps(devices))
        if "usbmux list --network" in text:
            devices = [{
                "UniqueDeviceID": UDID,
                "DeviceName": "Test iPhone",
                "ProductVersion": "26.5.2",
                "ConnectionType": "Network",
            }] if self.network_found else []
            return self.result(args, True, json.dumps(devices))
        if "remote browse" in text:
            payload = self.remote_browse_payload
            if payload is None:
                payload = {"usb": [], "wifi": [{"identifier": UDID, "address": "10.0.0.44", "port": 58783}]} if self.remote_found else {"usb": [], "wifi": []}
            return self.result(args, True, json.dumps(payload))
        if "bonjour remotepairing" in text:
            payload = self.bonjour_remotepairing_payload
            if payload is None:
                payload = [{"hostname": "fe80::1%en0", "port": 49152}, {"hostname": "10.0.0.44", "port": 49152}] if self.remote_found else []
            return self.result(args, True, json.dumps(payload))
        if "bonjour rsd" in text or "bonjour mobdev2" in text:
            return self.result(args, True, "[]")
        if "remote rsd-info" in text:
            payload = {
                "Properties": {"UniqueDeviceID": UDID, "OSVersion": "26.5.2", "ProductType": "iPhone18,1"},
                "Services": {"com.apple.instruments.remoteserver.DVTSecureSocketProxy": {"Port": "123"}},
            }
            return self.result(args, self.rsd_ok, json.dumps(payload) if self.rsd_ok else "", "rsd failed")
        if "amfi developer-mode-status" in text:
            return self.result(args, True, "true")
        if "mounter list" in text:
            return self.result(args, True, json.dumps([{"IsMounted": True, "PersonalizedImageType": "DeveloperDiskImage"}]))
        if "lockdown remotepairing --pair" in text:
            payload = self.remote_pairing_payload or {"peerDeviceInfo": {"DeviceName": "Test iPhone", "ProductType": "iPhone18,1", "ProductVersion": "26.5.2"}, "wireProtocolVersion": 24}
            return self.result(args, self.remote_pairing_ok, json.dumps(payload) if self.remote_pairing_ok else "", "pair failed")
        if "lockdown wifi-connections --state on" in text:
            return self.result(args, self.wifi_connections_ok, "on" if self.wifi_connections_ok else "", "wifi failed")
        return self.result(args, True, "[]")

    def popen(self, args: list[str]) -> FakeProcess:
        self.commands.append(args)
        protocol = "default"
        if "--protocol" in args:
            protocol = args[args.index("--protocol") + 1]
        if protocol in self.tunnel_by_protocol:
            return self.tunnel_by_protocol[protocol]
        if not self.tunnel_ok:
            return FakeProcess([], alive=False)
        return self.tunnel_process


class FakeWirelessLocation:
    def __init__(self, set_ok: bool = True, reset_ok: bool = True, process_alive: bool = True) -> None:
        self.set_ok = set_ok
        self.reset_ok = reset_ok
        self._active_location_proc = FakeProcess([], alive=process_alive, pid=999)

    def set_location(self, lat: float, lon: float) -> dict:
        if not self.set_ok:
            self._active_location_proc = FakeProcess([], alive=False)
            return {"ok": False, "message": "set failed"}
        return {"ok": True, "pid": self._active_location_proc.pid, "message": "started"}

    def clear_location(self) -> dict:
        self._active_location_proc = FakeProcess([], alive=False)
        return {"ok": self.reset_ok, "message": "cleared" if self.reset_ok else "reset failed"}


def stable_status(connected: bool = True) -> dict:
    return {
        "pmd3_available": True,
        "device_connected": connected,
        "device": {"udid": UDID, "name": "Test iPhone", "ios_version": "26.5.2", "ios_major": 26, "needs_tunnel": True} if connected else None,
        "tunnel_active": connected,
        "tunnel": {"address": "fd00::usb", "port": 1111} if connected else None,
    }


class WirelessTestingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.runner = FakeRunner()
        self.stable_set_calls = 0
        self.controller = WirelessTestingController(
            lambda: stable_status(self.runner.usb_connected),
            self._stable_set,
            lambda: {"ok": True, "message": "stable reset"},
            lambda: {"state": "idle"},
            lambda: False,
            WirelessExperimentStore(Path(self.temp.name)),
            self.runner,
        )
        self.controller._wireless_location = FakeWirelessLocation()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _stable_set(self, lat: float, lon: float) -> dict:
        self.stable_set_calls += 1
        return {"ok": True, "pid": 1}

    def create(self, test_type: str = EXPERIMENT_A) -> str:
        return self.controller.create_experiment(test_type)["experiment"]["experiment_id"]

    def tunnel_commands(self) -> list[list[str]]:
        return [command for command in self.runner.commands if "start-tunnel" in command and "--script-mode" in command]

    def tunnel_protocols_started(self) -> list[str]:
        protocols = []
        for command in self.tunnel_commands():
            if "--protocol" in command:
                protocols.append(command[command.index("--protocol") + 1])
            else:
                protocols.append("default")
        return protocols

    def prepare_success(self, test_type: str = EXPERIMENT_A, manual: str = "yes", reset_ok: bool = True) -> str:
        experiment_id = self.create(test_type)
        if test_type == EXPERIMENT_A:
            self.controller.wired_baseline(experiment_id)
            self.runner.remote_found = True
            self.controller.pairing_check(experiment_id)
            self.controller.prepare_unplug(experiment_id)
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.controller.confirm_cable_removed(experiment_id)
        self.controller.detect_without_usb(experiment_id)
        self.controller.start_wifi_tunnel(experiment_id)
        self.controller.validate_rsd(experiment_id)
        self.controller._wireless_location = FakeWirelessLocation(reset_ok=reset_ok)
        self.controller.wireless_set_location(experiment_id, 37.0, -122.0)
        self.controller.record_location_confirmation(experiment_id, manual)
        self.controller.wireless_reset_gps(experiment_id)
        return experiment_id

    def test_feature_disabled_returns_403(self) -> None:
        app = FastAPI()
        app.include_router(build_router(self.controller))
        client = TestClient(app)
        with patch.dict(os.environ, {}, clear=True):
            response = client.get("/api/experimental/wireless-testing/status")
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json()["code"], "wireless_testing_disabled")

    def test_command_capabilities_report_unavailable(self) -> None:
        self.runner.help_ok = False
        report = self.controller.capabilities(force=True)
        self.assertFalse(report["required_wireless_commands_available"])

    def test_usb_baseline_connected_records_ios_and_ddi(self) -> None:
        experiment_id = self.create()
        result = self.controller.wired_baseline(experiment_id)
        self.assertTrue(result["ok"])
        self.assertEqual(result["baseline"]["ios_version"], "26.5.2")
        self.assertEqual(result["baseline"]["ddi"]["mounted"], True)

    def test_usb_removed_records_no_usb_state(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        result = self.controller.confirm_cable_removed(experiment_id)
        self.assertTrue(result["usb_absent"])

    def test_remote_device_discovery_success_and_failure(self) -> None:
        experiment_id = self.create()
        self.runner.remote_found = False
        self.assertFalse(self.controller.detect_without_usb(experiment_id)["discovery"]["wireless_device_detected"])
        self.runner.remote_found = True
        result = self.controller.detect_without_usb(experiment_id)
        self.assertTrue(result["discovery"]["wireless_device_detected"])
        self.assertEqual(result["discovery"]["same_device"], True)
        self.assertEqual(result["discovery"]["remote_pairing_candidates"][0]["candidate_host"], "10.0.0.44")

    def test_equal_score_candidate_selection_is_deterministic(self) -> None:
        experiment_id = self.create()
        self.runner.remote_found = True
        self.runner.remote_browse_payload = {"usb": [], "wifi": []}
        self.runner.bonjour_remotepairing_payload = [
            {"hostname": "10.0.0.10", "port": 49152},
            {"hostname": "10.0.0.11", "port": 49152},
        ]
        first = self.controller.detect_without_usb(experiment_id)["discovery"]["remote_pairing_candidates"]
        second = self.controller.detect_without_usb(experiment_id)["discovery"]["remote_pairing_candidates"]
        self.assertEqual([item["candidate_host"] for item in first], ["10.0.0.10", "10.0.0.11"])
        self.assertEqual(first, second)

    def test_remote_pairing_bootstrap_success(self) -> None:
        experiment_id = self.create()
        result = self.controller.pairing_check(experiment_id)
        self.assertTrue(result["ok"])
        self.assertEqual(result["pairing_bootstrap"]["status"], "READY")
        self.assertEqual(result["pairing_bootstrap"]["wireProtocolVersion"], 24)
        self.assertIn(["--udid", UDID], [[cmd[i], cmd[i + 1]] for cmd in self.runner.commands for i in range(len(cmd) - 1)])

    def test_remote_pairing_command_unsupported(self) -> None:
        experiment_id = self.create()
        self.runner.remote_pairing_supported = False
        result = self.controller.pairing_check(experiment_id)
        self.assertEqual(result["pairing_bootstrap"]["status"], "UNSUPPORTED")
        self.assertEqual(result["preparation_status"], "UNSUPPORTED")
        self.assertEqual(result["wifi_connections"]["status"], "READY")

    def test_wifi_connections_state_on_success(self) -> None:
        experiment_id = self.create()
        result = self.controller.pairing_check(experiment_id)
        self.assertEqual(result["wifi_connections"]["status"], "READY")
        self.assertTrue(any("lockdown wifi-connections --state on" in " ".join(command) for command in self.runner.commands))

    def test_pairing_preparation_requires_usb_for_native_steps(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        result = self.controller.pairing_check(experiment_id)
        self.assertEqual(result["pairing_bootstrap"]["reason"], "trusted_usb_required")
        self.assertEqual(result["wifi_connections"]["reason"], "trusted_usb_required")
        self.assertIn(result["preparation_status"], {"FAILED", "PARTIAL"})

    def test_pairing_preparation_partial_when_bootstrap_ready_but_wifi_enablement_fails(self) -> None:
        experiment_id = self.create()
        self.runner.wifi_connections_ok = False
        result = self.controller.pairing_check(experiment_id)
        self.assertEqual(result["pairing_bootstrap"]["status"], "READY")
        self.assertEqual(result["wifi_connections"]["status"], "FAILED")
        self.assertEqual(result["preparation_status"], "PARTIAL")

    def test_remote_pairing_bootstrap_evidence_redacts_sensitive_blobs(self) -> None:
        experiment_id = self.create()
        self.runner.remote_pairing_payload = {
            "wireProtocolVersion": 24,
            "peerDeviceInfo": {"DeviceName": "Test iPhone", "ProductType": "iPhone18,1", "ProductVersion": "26.5.2"},
            "pairRecord": {"HostPrivateKey": "FULL-PRIVATE-KEY", "EscrowBag": "FULL-ESCROW-BAG"},
            "deviceKVSData": "SENSITIVE-REMOTE-PAIRING-KVS-BLOB",
        }
        result = self.controller.pairing_check(experiment_id)
        serialized = json.dumps(result)
        self.assertEqual(result["pairing_bootstrap"]["status"], "READY")
        self.assertNotIn("FULL-PRIVATE-KEY", serialized)
        self.assertNotIn("FULL-ESCROW-BAG", serialized)
        self.assertNotIn("SENSITIVE-REMOTE-PAIRING-KVS-BLOB", serialized)
        self.assertNotIn("pairRecord", serialized)

    def test_wifi_tunnel_success_and_command_construction(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        result = self.controller.start_wifi_tunnel(experiment_id, protocol="tcp")
        self.assertTrue(result["ok"])
        command = next(command for command in reversed(self.runner.commands) if "start-tunnel" in command and "--script-mode" in command)
        self.assertIn("remote", command)
        self.assertIn("start-tunnel", command)
        self.assertIn("wifi", command)
        self.assertIn("tcp", command)
        self.assertEqual(result["selected_protocol"], "tcp")

    def test_tunnel_subprocess_invocation_matches_expected_interpreter_and_arguments(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        result = self.controller.start_wifi_tunnel(experiment_id, protocol="quic")
        self.assertTrue(result["ok"])
        command = self.tunnel_commands()[-1]
        self.assertEqual(command[:5], [command[0], "-m", "pymobiledevice3", "remote", "start-tunnel"])
        self.assertEqual(command[5:], ["--connection-type", "wifi", "--script-mode", "--protocol", "quic", "--udid", UDID])
        self.assertNotIn("unknown", command)

    def test_tunnel_attempt_diagnostics_include_safe_generated_argv(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Device is not connected\n"], alive=False)
        result = self.controller.start_wifi_tunnel(experiment_id, protocol="quic")
        self.assertFalse(result["ok"])
        diagnostics = result["tunnel_attempts"][0]["diagnostics"]
        self.assertEqual(diagnostics["python_executable"], diagnostics["argv_redacted"][0])
        self.assertIn("cwd", diagnostics)
        self.assertIn("effective_uid", diagnostics)
        self.assertIn("subprocess_stdio", diagnostics)
        self.assertIn("0000...401C", diagnostics["argv_redacted"])
        self.assertNotIn(UDID, json.dumps(diagnostics))

    def test_wifi_tunnel_failure(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.tunnel_ok = False
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "wifi_tunnel_failed")
        self.assertIn("tunnel_attempts", result)

    def test_wireless_candidate_found_but_no_tunnel_service(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["RemotePairing service not found\n"], alive=False)
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["last_tunnel_failure_class"], "no_tunnel_service")

    def test_baseline_udid_discovery_is_preserved_before_device_not_connected(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Device is not connected\n"], alive=False)
        result = self.controller.start_wifi_tunnel(experiment_id, protocol="quic")
        self.assertFalse(result["ok"])
        attempt = result["tunnel_attempts"][0]
        self.assertEqual(attempt["failure_class"], "device_not_connected")
        self.assertTrue(attempt["preflight_discovery"]["baseline_present"])
        self.assertTrue(attempt["preflight_discovery"]["methods"]["remote_browse"]["found"])

    def test_quic_success(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["fd12:3456::1 54321\n"], alive=True)
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertTrue(result["ok"])
        self.assertEqual(result["selected_protocol"], "quic")
        self.assertEqual(len(result["tunnel_attempts"]), 1)
        self.assertIsNone(self.runner.tunnel_by_protocol["quic"].poll())

    def test_default_protocol_starts_quic_only_not_tcp(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Encountered a QUIC protocol error.\n"], alive=False)
        self.runner.tunnel_by_protocol["tcp"] = FakeProcess(["fd12:3456::1 54321\n"], alive=True)
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(self.tunnel_protocols_started(), ["quic"])
        self.assertEqual([attempt["protocol"] for attempt in result["tunnel_attempts"]], ["quic"])
        self.assertIn("explicit diagnostic-only", result["tunnel_strategy"]["fallback_policy"])

    def test_quic_protocol_error_does_not_fallback_to_tcp_success(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Encountered a QUIC protocol error.\n"], alive=False)
        self.runner.tunnel_by_protocol["tcp"] = FakeProcess(["fd12:3456::1 54321\n"], alive=True, pid=4444)
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["last_tunnel_failure_class"], "quic_protocol_error")
        self.assertEqual([attempt["protocol"] for attempt in result["tunnel_attempts"]], ["quic"])
        self.assertIsNotNone(self.runner.tunnel_by_protocol["quic"].poll())
        self.assertIsNone(self.runner.tunnel_by_protocol["tcp"].returncode)

    def test_explicit_tcp_sigbus_is_structured_failure(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["tcp"] = FakeProcess(["bus error\n"], alive=False, returncode=138)
        result = self.controller.start_wifi_tunnel(experiment_id, protocol="tcp")
        self.assertFalse(result["ok"])
        self.assertEqual(result["last_tunnel_failure_class"], "sigbus")
        self.assertEqual(result["tunnel_attempts"][-1]["terminating_signal"], "SIGBUS")
        self.assertEqual(result["tunnel_attempts"][-1]["returncode"], 138)
        self.assertEqual(self.tunnel_protocols_started(), ["tcp"])

    def test_no_route_to_host_classification(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["OSError: [Errno 65] No route to host\n"], alive=False)
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["last_tunnel_failure_class"], "no_route_to_host")
        self.assertEqual(self.tunnel_protocols_started(), ["quic"])
        self.assertNotEqual(result["tunnel_attempts"][0]["failure_class"], "quic_protocol_error")

    def test_quic_timeout_does_not_trigger_tcp_fallback(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        hanging = FakeProcess([], alive=True)
        self.runner.tunnel_by_protocol["quic"] = hanging
        self.runner.tunnel_by_protocol["tcp"] = FakeProcess(["fd12:3456::1 54321\n"], alive=True)
        with patch("wireless_testing.controller.start_tunnel_process") as fake_start:
            from wireless_testing.command_runner import start_tunnel_process as real_start
            fake_start.side_effect = lambda runner, args, protocol=None, candidate=None: real_start(runner, args, timeout_s=0.05, protocol=protocol, candidate=candidate)
            result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["last_tunnel_failure_class"], "timeout")
        self.assertEqual(self.tunnel_protocols_started(), ["quic"])

    def test_quic_generic_failure_does_not_trigger_tcp_fallback(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["unexpected tunnel failure\n"], alive=False)
        self.runner.tunnel_by_protocol["tcp"] = FakeProcess(["fd12:3456::1 54321\n"], alive=True)
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["last_tunnel_failure_class"], "unknown")
        self.assertEqual(self.tunnel_protocols_started(), ["quic"])

    def test_device_not_connected_does_not_trigger_tcp_fallback(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Device is not connected\n"], alive=False)
        self.runner.tunnel_by_protocol["tcp"] = FakeProcess(["fd12:3456::1 54321\n"], alive=True)
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["last_tunnel_failure_class"], "device_not_connected")
        self.assertEqual(self.tunnel_protocols_started(), ["quic"])

    def test_timeout_cleanup_and_process_termination(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        hanging = FakeProcess([], alive=True)
        self.runner.tunnel_by_protocol["quic"] = hanging
        with patch("wireless_testing.controller.start_tunnel_process") as fake_start:
            from wireless_testing.command_runner import start_tunnel_process as real_start
            fake_start.side_effect = lambda runner, args, protocol=None, candidate=None: real_start(runner, args, timeout_s=0.05, protocol=protocol, candidate=candidate)
            result = self.controller.start_wifi_tunnel(experiment_id, protocol="quic")
        self.assertFalse(result["ok"])
        self.assertTrue(hanging.terminated)
        self.assertEqual(result["last_tunnel_failure_class"], "timeout")

    def test_explicit_protocol_does_not_fallback(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Encountered a QUIC protocol error.\n"], alive=False)
        self.runner.tunnel_by_protocol["tcp"] = FakeProcess(["fd12:3456::1 54321\n"], alive=True)
        result = self.controller.start_wifi_tunnel(experiment_id, protocol="quic")
        self.assertFalse(result["ok"])
        self.assertEqual([attempt["protocol"] for attempt in result["tunnel_attempts"]], ["quic"])
        self.assertEqual(self.tunnel_protocols_started(), ["quic"])

    def test_explicit_tcp_never_starts_quic(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["tcp"] = FakeProcess(["fd12:3456::1 54321\n"], alive=True)
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Encountered a QUIC protocol error.\n"], alive=False)
        result = self.controller.start_wifi_tunnel(experiment_id, protocol="tcp")
        self.assertTrue(result["ok"])
        self.assertEqual(result["selected_protocol"], "tcp")
        self.assertEqual(self.tunnel_protocols_started(), ["tcp"])

    def test_no_remote_pairing_candidates_returns_structured_failure(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = False
        self.runner.tunnel_ok = False
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertFalse(result["ok"])
        self.assertEqual(result["tunnel_strategy"]["candidate_count"], 0)
        self.assertEqual(result["tunnel_strategy"]["candidate_selection"], "none_discovered")
        self.assertIn("tunnel_attempts", result)

    def test_rsd_parsing_success_and_failure(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.controller.start_wifi_tunnel(experiment_id)
        self.assertTrue(self.controller.validate_rsd(experiment_id)["ok"])
        self.runner.rsd_ok = False
        self.assertFalse(self.controller.validate_rsd(experiment_id)["ok"])

    def test_wireless_set_location_success_and_failure(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.controller.start_wifi_tunnel(experiment_id)
        self.controller.validate_rsd(experiment_id)
        self.controller._wireless_location = FakeWirelessLocation(set_ok=True)
        self.assertTrue(self.controller.wireless_set_location(experiment_id, 1, 2)["ok"])
        self.controller._wireless_location = FakeWirelessLocation(set_ok=False, process_alive=False)
        self.assertFalse(self.controller.wireless_set_location(experiment_id, 1, 2)["ok"])

    def test_wireless_reset_success_and_failure(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.controller.start_wifi_tunnel(experiment_id)
        self.controller.validate_rsd(experiment_id)
        self.controller._wireless_location = FakeWirelessLocation(reset_ok=True)
        self.assertTrue(self.controller.wireless_reset_gps(experiment_id)["ok"])
        self.controller.stop(experiment_id, clear_state=True)
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.controller.start_wifi_tunnel(experiment_id)
        self.controller.validate_rsd(experiment_id)
        self.controller._wireless_location = FakeWirelessLocation(reset_ok=False)
        self.assertFalse(self.controller.wireless_reset_gps(experiment_id)["ok"])

    def test_tunnel_created_while_usb_connected_cannot_confirm_cable_free(self) -> None:
        experiment_id = self.prepare_success(EXPERIMENT_B)
        self.controller.store.update_manifest(experiment_id, session_started_usb_present=True)
        record = self.controller.finalize(experiment_id)
        self.assertNotEqual(record["verdict"], "CABLE-FREE IOSIM CONFIRMED ON THIS TESTED DEVICE/CONFIGURATION")

    def test_tunnel_created_after_usb_absence_can_qualify_for_experiment_b(self) -> None:
        self.runner.usb_connected = False
        experiment_id = self.prepare_success(EXPERIMENT_B)
        verdict = self.controller.finalize(experiment_id)["verdict"]
        self.assertEqual(verdict, "CABLE-FREE IOSIM CONFIRMED ON THIS TESTED DEVICE/CONFIGURATION")

    def test_cached_usb_rsd_cannot_qualify_as_fresh_wifi_rsd(self) -> None:
        experiment_id = self.prepare_success(EXPERIMENT_B)
        self.controller.store.update_manifest(experiment_id, summary={**self.controller.store.get(experiment_id)["summary"], "fresh_wifi_rsd": False, "tunnel_created_after_usb_absence": False, "rsd_source": "cached_usb"})
        verdict = self.controller.finalize(experiment_id)["verdict"]
        self.assertNotIn("CABLE-FREE", verdict)

    def test_no_stale_usb_rsd_can_count_as_fresh_wifi_rsd_when_usb_present(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = True
        result = self.controller.start_wifi_tunnel(experiment_id)
        self.assertTrue(result["ok"])
        self.assertFalse(result["wireless_rsd_proof_complete"])
        summary = self.controller.store.get(experiment_id)["summary"]
        self.assertFalse(summary["fresh_wifi_rsd"])
        self.assertFalse(summary["tunnel_created_after_usb_absence"])

    def test_current_usb_absence_overrides_older_usb_found_evidence(self) -> None:
        experiment_id = self.create()
        record = self.controller.store.get(experiment_id)
        self.assertTrue(record["session_started_usb_present"])
        self.assertTrue(record["metadata"]["initial_usb"]["usb_detected"])
        self.runner.usb_connected = False
        result = self.controller.confirm_cable_removed(experiment_id)
        self.assertTrue(result["usb_absent"])
        self.assertFalse(result["usb"]["usb_detected"])
        summary = self.controller.store.get(experiment_id)["summary"]
        self.assertEqual(summary["usb_state"], "NO_USB")

    def test_successful_set_with_failed_reset_is_partial(self) -> None:
        experiment_id = self.prepare_success(EXPERIMENT_A, reset_ok=False)
        verdict = self.controller.finalize(experiment_id)["verdict"]
        self.assertEqual(verdict, "WIRELESS DVT SET CONFIRMED, RESET UNCONFIRMED")

    def test_commands_without_manual_confirmation_are_inconclusive(self) -> None:
        experiment_id = self.prepare_success(EXPERIMENT_A, manual="not_sure")
        verdict = self.controller.finalize(experiment_id)["verdict"]
        self.assertEqual(verdict, "WIRELESS DVT SET ISSUED, DEVICE CONFIRMATION INCONCLUSIVE")

    def test_experiment_a_and_b_are_stored_distinctly(self) -> None:
        a = self.create(EXPERIMENT_A)
        self.controller.stop(clear_state=True)
        b = self.create(EXPERIMENT_B)
        self.assertEqual(self.controller.store.get(a)["test_type"], EXPERIMENT_A)
        self.assertEqual(self.controller.store.get(b)["test_type"], EXPERIMENT_B)

    def test_stable_usb_behavior_not_mutated_by_wireless_failure(self) -> None:
        experiment_id = self.create()
        self.runner.tunnel_ok = False
        self.runner.usb_connected = False
        self.controller.start_wifi_tunnel(experiment_id)
        self.assertEqual(self.stable_set_calls, 0)
        self.assertEqual(stable_status(True)["tunnel"]["address"], "fd00::usb")

    def test_sensitive_fields_are_redacted(self) -> None:
        experiment_id = self.create()
        self.runner.remote_found = True
        text = json.dumps(self.controller.detect_without_usb(experiment_id))
        self.assertNotIn(UDID, text)
        self.assertIn("0000...401C", text)

    def test_stop_returns_to_recoverable_state(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.controller.start_wifi_tunnel(experiment_id)
        result = self.controller.stop(experiment_id, clear_state=True)
        self.assertTrue(result["ok"])
        self.assertIsNone(self.controller._active_experiment_id)
        self.assertFalse(self.controller.status()["connection"]["wifi_tunnel_active"])

    def test_device_disappears_during_experiment(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = False
        result = self.controller.detect_without_usb(experiment_id)
        self.assertFalse(result["discovery"]["wireless_device_detected"])
        self.assertEqual(result["status"]["state"], "wireless_not_detected")

    def test_api_returns_attempt_details_on_tunnel_failure(self) -> None:
        app = FastAPI()
        app.include_router(build_router(self.controller))
        client = TestClient(app)
        with patch.dict(os.environ, {"IOS_SIM_ENABLE_EXPERIMENTAL": "1", "IOS_SIM_ENABLE_WIRELESS_TESTING": "1"}):
            create = client.post("/api/experimental/wireless-testing/experiments", json={"test_type": EXPERIMENT_A}).json()
            experiment_id = create["experiment"]["experiment_id"]
            self.runner.usb_connected = False
            self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Encountered a QUIC protocol error.\n"], alive=False)
            response = client.post(f"/api/experimental/wireless-testing/experiments/{experiment_id}/start-wifi-tunnel", json={"protocol": "quic"})
        self.assertEqual(response.status_code, 409)
        payload = response.json()
        self.assertEqual(payload["tunnel_attempts"][0]["failure_class"], "quic_protocol_error")
        self.assertEqual(payload["status"]["last_tunnel_failure_class"], "quic_protocol_error")

    def test_report_verdict_device_discovered_but_tunnel_failed(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.runner.tunnel_by_protocol["quic"] = FakeProcess(["Encountered a QUIC protocol error.\n"], alive=False)
        self.controller.detect_without_usb(experiment_id)
        self.controller.start_wifi_tunnel(experiment_id, protocol="quic")
        finalized = self.controller.finalize(experiment_id)
        self.assertEqual(finalized["verdict"], "DEVICE DISCOVERED BUT TUNNEL FAILED")
        self.assertIn("QUIC", finalized["report"])
        self.assertIn("quic_protocol_error", finalized["report"])

    def test_final_verdict_cannot_pass_from_discovery_only(self) -> None:
        experiment_id = self.create()
        self.runner.usb_connected = False
        self.runner.remote_found = True
        self.controller.detect_without_usb(experiment_id)
        finalized = self.controller.finalize(experiment_id)
        self.assertEqual(finalized["verdict"], "WIRELESS DEVICE DISCOVERY ONLY")
        self.assertNotIn("CONFIRMED", finalized["verdict"])


if __name__ == "__main__":
    unittest.main()
