from __future__ import annotations

import platform
import subprocess
import threading
import time
import ipaddress
from pathlib import Path
from typing import Any, Callable

from device_manager import DeviceInfo, TunnelInfo
from location_service import LocationService

from .command_runner import (
    CommandResult,
    Runner,
    SubprocessRunner,
    capability_report,
    concise,
    parse_json_array_or_object,
    pmd3_command,
    pmd3_version,
    start_tunnel_process,
)
from .experiment_store import WirelessExperimentStore, abbreviate_identifier, redact, utc_now
from .report_generator import generate_report


StatusProvider = Callable[[], dict[str, Any]]
LocationWriter = Callable[[float, float], dict[str, Any]]
LocationClearer = Callable[[], dict[str, Any]]

EXPERIMENT_A = "remove_cable_after_pairing"
EXPERIMENT_B = "fresh_cable_free_session"
VALID_TEST_TYPES = {EXPERIMENT_A, EXPERIMENT_B}


class WirelessLocationAdapter:
    def __init__(self) -> None:
        self.device: DeviceInfo | None = None
        self.tunnel: TunnelInfo | None = None

    def configure(self, device: DeviceInfo, tunnel: TunnelInfo) -> None:
        self.device = device
        self.tunnel = tunnel

    def clear(self) -> None:
        self.device = None
        self.tunnel = None


class WirelessTestingController:
    def __init__(
        self,
        stable_status_provider: StatusProvider,
        stable_set_location: LocationWriter,
        stable_clear_location: LocationClearer,
        stable_drive_status_provider: StatusProvider,
        drive_testing_active_provider: Callable[[], bool],
        store: WirelessExperimentStore | None = None,
        runner: Runner | None = None,
        operation_lock: threading.RLock | None = None,
    ) -> None:
        self._stable_status = stable_status_provider
        self._stable_set_location = stable_set_location
        self._stable_clear_location = stable_clear_location
        self._stable_drive_status = stable_drive_status_provider
        self._drive_testing_active = drive_testing_active_provider
        self.store = store or WirelessExperimentStore()
        self.runner = runner or SubprocessRunner()
        self._operation_lock = operation_lock or threading.RLock()
        self._lock = threading.RLock()
        self._adapter = WirelessLocationAdapter()
        self._wireless_location = LocationService(self._adapter)  # type: ignore[arg-type]
        self._wifi_tunnel_proc: subprocess.Popen | None = None
        self._active_experiment_id: str | None = None
        self._runtime: dict[str, Any] = self._idle_runtime()
        self._capabilities: dict[str, Any] | None = None
        self._capabilities_checked_at = 0.0
        self._baseline_udid_full: str | None = None

    def _idle_runtime(self) -> dict[str, Any]:
        return {
            "ok": True,
            "experiment_id": None,
            "test_type": None,
            "state": "idle",
            "current_stage": "idle",
            "current_transport": "UNKNOWN",
            "usb_detected": False,
            "wireless_device_detected": False,
            "wireless_same_device": None,
            "wifi_tunnel_active": False,
            "wifi_tunnel_pid": None,
            "tunnel_transport": None,
            "rsd_ready": False,
            "rsd_source": None,
            "location_session_active": False,
            "last_successful_contact": None,
            "last_error": None,
            "verdict": "INCONCLUSIVE",
            "message": "",
            "manual_location_confirmation": None,
            "manual_reset_confirmation": None,
            "pairing_bootstrap_status": None,
            "wifi_connections_status": None,
            "wireless_discovery_status": None,
            "pairing_preparation_status": None,
            "tunnel_strategy": None,
            "tunnel_attempts": [],
            "selected_protocol": None,
            "selected_candidate": None,
            "last_tunnel_failure_class": None,
            "fresh_rsd_proof_state": "NOT_READY",
        }

    def status(self) -> dict[str, Any]:
        try:
            stable = self._stable_status()
            backend_reachable = True
        except Exception as exc:
            stable = {"pmd3_available": False, "device_connected": False, "device": None, "tunnel_active": False, "status_error": str(exc)}
            backend_reachable = False
        usb = self.usb_state()
        capabilities = self.capabilities()
        with self._lock:
            runtime = dict(self._runtime)
            proc_alive = self._wifi_tunnel_proc is not None and self._wifi_tunnel_proc.poll() is None
            runtime["wifi_tunnel_active"] = proc_alive
            runtime["wifi_tunnel_pid"] = self._wifi_tunnel_proc.pid if proc_alive else None
            runtime["rsd_ready"] = proc_alive and self._adapter.tunnel is not None
            runtime["location_session_active"] = self._wireless_location_active()
            if usb.get("usb_detected"):
                runtime["current_transport"] = "USB" if not proc_alive else "USB+WIFI"
            elif proc_alive:
                runtime["current_transport"] = "WIFI"
            else:
                runtime["current_transport"] = "UNKNOWN"
        return {
            "ok": True,
            "backend_reachable": backend_reachable,
            "stable_status": self._redact_stable_status(stable),
            "usb": usb,
            "capabilities": capabilities,
            "xcode": self.xcode_info(),
            "connection": runtime,
            "readiness": self.readiness(stable, usb, capabilities),
            "history": self.store.list()[:20],
            "pairing_guidance": self.pairing_guidance(),
        }

    def capabilities(self, force: bool = False) -> dict[str, Any]:
        now = time.monotonic()
        with self._lock:
            if force or self._capabilities is None or now - self._capabilities_checked_at > 120:
                self._capabilities = capability_report(self.runner)
                self._capabilities_checked_at = now
            return redact(self._capabilities)

    def xcode_info(self) -> dict[str, Any]:
        if platform.system() != "Darwin":
            return {
                "platform": platform.system(),
                "installed": False,
                "version": None,
                "instruction_variant": "not_available_on_this_host",
                "message": "Xcode pairing preparation is available on macOS. This host is not macOS.",
            }
        result = self.runner.run(["xcodebuild", "-version"], timeout_s=8)
        version_text = (result.stdout or result.stderr).strip()
        major = None
        for token in version_text.replace("\n", " ").split():
            try:
                major = int(token.split(".")[0])
                break
            except ValueError:
                continue
        variant = "device_hub_or_devices_window" if major and major >= 16 else "devices_and_simulators"
        return {
            "platform": platform.system(),
            "installed": result.ok,
            "version": version_text if result.ok else None,
            "instruction_variant": variant if result.ok else "xcode_not_detected",
            "message": "Use the installed Xcode device-management interface to enable network/wireless development." if result.ok else "xcodebuild was not found.",
        }

    def pairing_guidance(self) -> list[str]:
        info = self.xcode_info()
        if info.get("instruction_variant") == "not_available_on_this_host":
            return [
                "Connect the iPhone by cable, unlock it, Trust the host, and keep Developer Mode enabled.",
                "Run IOSSim's Wireless Pairing Check to bootstrap RemotePairing and enable Wi-Fi connections over trusted USB.",
                "If native preparation is unsupported on this host, use a Mac/Xcode wireless-development flow as troubleshooting.",
            ]
        if info.get("instruction_variant") == "device_hub_or_devices_window":
            return [
                "Connect the iPhone by cable, unlock it, and Trust the Mac if prompted.",
                "Run IOSSim's Wireless Pairing Check to perform RemotePairing bootstrap and enable Wi-Fi connections.",
                "If that is partial or unsupported, use Xcode's current device-management interface as a fallback.",
                "Keep Mac and iPhone on the same Wi-Fi/LAN, then return to IOSSim and run Wireless Pairing Check.",
            ]
        return [
            "Connect the iPhone by cable, unlock it, and Trust the Mac if prompted.",
            "Run IOSSim's Wireless Pairing Check to perform RemotePairing bootstrap and enable Wi-Fi connections.",
            "If that is partial or unsupported, open Xcode Devices and Simulators and enable Connect via network.",
            "Keep Mac and iPhone on the same Wi-Fi/LAN, then return to IOSSim and run Wireless Pairing Check.",
        ]

    def readiness(self, stable: dict[str, Any], usb: dict[str, Any], capabilities: dict[str, Any]) -> dict[str, Any]:
        stable_drive = self._stable_drive_status()
        checks = [
            {"name": "Backend reachable", "status": "PASS", "detail": ""},
            {
                "name": "pymobiledevice3 available",
                "status": "PASS" if capabilities.get("pymobiledevice3_importable") else "FAIL",
                "detail": capabilities.get("pymobiledevice3_version") or "not importable",
            },
            {
                "name": "Required wireless CLI commands",
                "status": "PASS" if capabilities.get("required_wireless_commands_available") else "FAIL",
                "detail": "remote browse, remote start-tunnel, usbmux list, DVT set/clear, and rsd-info are required",
            },
            {"name": "Stable Drive Mode inactive", "status": "PASS" if stable_drive.get("state") not in {"starting", "driving", "paused"} else "FAIL", "detail": ""},
            {"name": "Drive Testing inactive", "status": "PASS" if not self._drive_testing_active() else "FAIL", "detail": ""},
            {
                "name": "USB baseline available",
                "status": "PASS" if stable.get("device_connected") or usb.get("usb_detected") else "WARNING",
                "detail": "Expected for Experiment A; Experiment B starts without USB.",
            },
            {
                "name": "IOSSim native pairing preparation",
                "status": "PASS" if capabilities.get("commands", {}).get("lockdown_remotepairing", {}).get("available") and capabilities.get("commands", {}).get("lockdown_wifi_connections", {}).get("available") else "WARNING",
                "detail": "Uses lockdown remotepairing --pair and lockdown wifi-connections while trusted USB is present.",
            },
            {"name": "Xcode pairing fallback", "status": "UNKNOWN", "detail": "Optional macOS troubleshooting path if native preparation is unsupported or incomplete."},
        ]
        statuses = {item["status"] for item in checks}
        overall = "FAIL" if "FAIL" in statuses else "WARNING" if "WARNING" in statuses or "UNKNOWN" in statuses else "PASS"
        return {"overall": overall, "checks": checks}

    def create_experiment(self, test_type: str) -> dict[str, Any]:
        if test_type not in VALID_TEST_TYPES:
            return self._error("Invalid wireless experiment type", "invalid_test_type")
        with self._lock:
            if self._active_experiment_id:
                return self._error("A Wireless Testing experiment is already active", "duplicate_start")
        usb = self.usb_state()
        stable = self._stable_status()
        manifest = self.store.create(
            test_type,
            session_started_usb_present=bool(usb.get("usb_detected")),
            metadata={
                "platform": platform.platform(),
                "python_version": platform.python_version(),
                "pymobiledevice3_version": pmd3_version(),
                "initial_usb": usb,
                "initial_stable_status": stable,
            },
        )
        with self._lock:
            self._baseline_udid_full = self._valid_identifier((stable.get("device") or {}).get("udid")) or self._baseline_udid_full
            self._active_experiment_id = manifest["experiment_id"]
            self._runtime = {
                **self._idle_runtime(),
                "experiment_id": manifest["experiment_id"],
                "test_type": test_type,
                "state": "created",
                "current_stage": "Wired Baseline" if test_type == EXPERIMENT_A else "Detect Without USB",
                "usb_detected": bool(usb.get("usb_detected")),
                "message": "Wireless experiment created",
            }
        self.store.append_event(manifest["experiment_id"], {"event_type": "experiment_created", "test_type": test_type, "usb": usb})
        return {"ok": True, "experiment": manifest, "status": dict(self._runtime)}

    def wired_baseline(self, experiment_id: str) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        stable = self._stable_status()
        usb = self.usb_state()
        device = stable.get("device") or {}
        baseline = {
            "backend_reachable": True,
            "pymobiledevice3_available": bool(stable.get("pmd3_available")),
            "iphone_detected": bool(stable.get("device_connected")),
            "device": device,
            "ios_version": device.get("ios_version"),
            "developer_mode": self._read_developer_mode(),
            "ddi": self._read_ddi_state(),
            "tunnel_active": bool(stable.get("tunnel_active")),
            "rsd_ready": bool((stable.get("tunnel") or {}).get("address")),
            "usb": usb,
        }
        with self._lock:
            valid_udid = self._valid_identifier(device.get("udid"))
            if valid_udid:
                self._baseline_udid_full = valid_udid
            self._runtime.update({
                "state": "wired_baseline",
                "current_stage": "Wireless Pairing Preparation",
                "usb_detected": bool(usb.get("usb_detected")),
                "last_successful_contact": utc_now() if baseline["iphone_detected"] else self._runtime.get("last_successful_contact"),
                "message": "Wired baseline captured",
            })
        self.store.append_event(experiment_id, {"event_type": "wired_baseline", "baseline": baseline})
        self._update_summary(experiment_id, {
            "ios_version": device.get("ios_version"),
            "usb_connected_at_start": bool(usb.get("usb_detected")),
            "usb_state": "USB" if usb.get("usb_detected") else "NO_USB",
        })
        return {"ok": True, "baseline": redact(baseline), "status": dict(self._runtime)}

    def stable_set_location(self, experiment_id: str, lat: float, lon: float) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        with self._operation_lock:
            result = self._stable_set_location(lat, lon)
        self.store.append_event(experiment_id, {"event_type": "wired_baseline_set_location", "lat": lat, "lon": lon, "result": result})
        return result if result.get("ok") else self._error(result.get("message", "Stable Set Location failed"), "stable_set_failed", extra=result)

    def stable_reset_gps(self, experiment_id: str) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        with self._operation_lock:
            result = self._stable_clear_location()
        self.store.append_event(experiment_id, {"event_type": "wired_baseline_reset_gps", "result": result})
        return result if result.get("ok") else self._error(result.get("message", "Stable Reset GPS failed"), "stable_reset_failed", extra=result)

    def pairing_check(self, experiment_id: str) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        stable = self._stable_status()
        usb = self.usb_state()
        prerequisites = self._preparation_prerequisites(stable, usb)
        bootstrap = self._bootstrap_remote_pairing(stable, usb)
        wifi_connections = self._enable_wifi_connections(stable, usb)
        discovery = self.discover()
        pairing_status = self._pairing_status(discovery)
        preparation_status, reasons = self._preparation_status(prerequisites, bootstrap, wifi_connections, discovery)
        with self._lock:
            self._runtime.update({
                "state": "pairing_checked",
                "current_stage": "Ready to Unplug",
                "usb_detected": bool(usb.get("usb_detected")),
                "wireless_device_detected": bool(discovery.get("wireless_device_detected")),
                "wireless_same_device": discovery.get("same_device"),
                "last_successful_contact": utc_now() if discovery.get("wireless_device_detected") else self._runtime.get("last_successful_contact"),
                "pairing_bootstrap_status": bootstrap.get("status"),
                "wifi_connections_status": wifi_connections.get("status"),
                "wireless_discovery_status": "FOUND" if discovery.get("wireless_device_detected") else "NOT_FOUND",
                "pairing_preparation_status": preparation_status,
                "last_error": None if preparation_status in {"READY", "PARTIAL"} else "; ".join(reasons),
                "message": f"Pairing preparation: {preparation_status}",
            })
        self.store.append_event(experiment_id, {
            "event_type": "wireless_pairing_check",
            "prerequisites": prerequisites,
            "pairing_bootstrap": bootstrap,
            "wifi_connections": wifi_connections,
            "discovery": discovery,
            "pairing_status": pairing_status,
            "preparation_status": preparation_status,
            "reasons": reasons,
        })
        self._update_summary(experiment_id, {
            "pairing_bootstrap_status": bootstrap.get("status"),
            "wifi_connections_status": wifi_connections.get("status"),
            "pairing_preparation_status": preparation_status,
            "wireless_discovery": "FOUND" if discovery.get("wireless_device_detected") else "NOT_FOUND",
        })
        return {
            "ok": True,
            "pairing_status": pairing_status,
            "preparation_status": preparation_status,
            "preparation_reasons": reasons,
            "prerequisites": redact(prerequisites),
            "pairing_bootstrap": redact(bootstrap),
            "wifi_connections": redact(wifi_connections),
            "discovery": redact(discovery),
            "status": dict(self._runtime),
        }

    def prepare_unplug(self, experiment_id: str) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        stable = self._stable_status()
        usb = self.usb_state()
        record = {
            "timestamp": utc_now(),
            "device": stable.get("device"),
            "transport": "USB" if usb.get("usb_detected") else "UNKNOWN",
            "tunnel_state": stable.get("tunnel_active"),
            "rsd_state": bool((stable.get("tunnel") or {}).get("address")),
            "pairing_state": "UNKNOWN",
        }
        with self._lock:
            self._runtime.update({"state": "ready_to_unplug", "current_stage": "Ready to Unplug", "usb_detected": bool(usb.get("usb_detected")), "message": "State recorded. It is safe to unplug when the UI says Ready."})
        self.store.append_event(experiment_id, {"event_type": "prepare_unplug", "record": record})
        return {"ok": True, "record": redact(record), "status": dict(self._runtime)}

    def confirm_cable_removed(self, experiment_id: str) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        usb = self.usb_state()
        absent = not bool(usb.get("usb_detected"))
        with self._lock:
            self._runtime.update({
                "state": "usb_removed" if absent else "usb_still_connected",
                "current_stage": "Detect Without USB",
                "usb_detected": not absent,
                "last_error": None if absent else "USB still appears connected",
                "message": "USB is absent. Continue wireless discovery." if absent else "USB still appears connected. Remove the cable before claiming cable-free results.",
            })
        self.store.append_event(experiment_id, {"event_type": "cable_removed_check", "usb": usb, "usb_absent": absent})
        self._update_summary(experiment_id, {"usb_absent_before_tunnel": absent, "usb_state": "NO_USB" if absent else "USB_PRESENT"})
        return {"ok": True, "usb_absent": absent, "usb": usb, "status": dict(self._runtime)}

    def detect_without_usb(self, experiment_id: str) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        usb = self.usb_state()
        discovery = self.discover()
        with self._lock:
            self._runtime.update({
                "state": "wireless_detected" if discovery.get("wireless_device_detected") else "wireless_not_detected",
                "current_stage": "Establish Wi-Fi Tunnel",
                "usb_detected": bool(usb.get("usb_detected")),
                "wireless_device_detected": bool(discovery.get("wireless_device_detected")),
                "wireless_same_device": discovery.get("same_device"),
                "message": "Wireless candidate detected" if discovery.get("wireless_device_detected") else "No wireless candidate detected yet",
            })
        self.store.append_event(experiment_id, {"event_type": "detect_without_usb", "usb": usb, "discovery": discovery})
        self._update_summary(experiment_id, {
            "usb_absent_before_tunnel": not bool(usb.get("usb_detected")),
            "wireless_discovery": "FOUND" if discovery.get("wireless_device_detected") else "NOT_FOUND",
            "discovery_method": discovery.get("best_method") or "none",
        })
        return {"ok": True, "usb": usb, "discovery": redact(discovery), "status": dict(self._runtime)}

    def start_wifi_tunnel(self, experiment_id: str, protocol: str | None = None) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        usb = self.usb_state()
        usb_absent_before = not bool(usb.get("usb_detected"))
        discovery = self.discover()
        self._remember_baseline_from_discovery(discovery)
        candidates = discovery.get("remote_pairing_candidates") or []
        selected_candidate = candidates[0] if candidates else None
        preflight_discovery = self._tunnel_preflight_discovery(discovery)
        requested_protocol = protocol if protocol in {"tcp", "quic"} else "default"
        protocol_plan = [requested_protocol] if requested_protocol in {"tcp", "quic"} else self._default_tunnel_protocol_plan()
        strategy = {
            "requested_protocol": requested_protocol,
            "protocol_plan": protocol_plan,
            "usb_absent_before_tunnel": usb_absent_before,
            "candidate_count": len(candidates),
            "candidate_selection": "routeable_preferred" if selected_candidate else "none_discovered",
            "baseline_udid_abbreviated": abbreviate_identifier(str(self._baseline_identifier() or "")),
            "preflight_discovery": preflight_discovery,
            "fallback_policy": "default tries QUIC first, then TCP only after QUIC protocol negotiation failure",
        }
        with self._lock:
            if self._wifi_tunnel_proc and self._wifi_tunnel_proc.poll() is None:
                return {"ok": True, "message": "Wi-Fi tunnel already active", "tunnel_strategy": strategy, "tunnel_attempts": list(self._runtime.get("tunnel_attempts") or []), "status": dict(self._runtime)}
        attempts: list[dict[str, Any]] = []
        winning_proc: subprocess.Popen | None = None
        winning_result: dict[str, Any] | None = None
        for attempt_protocol in protocol_plan:
            command = self._wifi_tunnel_command(attempt_protocol)
            proc, result = start_tunnel_process(self.runner, command, protocol=attempt_protocol, candidate=selected_candidate)
            result["preflight_discovery"] = preflight_discovery
            attempts.append(result)
            if result.get("ok"):
                winning_proc = proc
                winning_result = result
                break
            if requested_protocol in {"tcp", "quic"}:
                break
            if attempt_protocol == "quic" and result.get("failure_class") == "quic_protocol_error":
                continue
            break
        if not winning_result:
            failure_class = next((attempt.get("failure_class") for attempt in reversed(attempts) if attempt.get("failure_class")), "unknown")
            failure_message = self._tunnel_failure_message(attempts)
            with self._lock:
                self._runtime.update({
                    "state": "wifi_tunnel_failed",
                    "current_stage": "Validate Fresh RSD",
                    "usb_detected": bool(usb.get("usb_detected")),
                    "wireless_device_detected": bool(discovery.get("wireless_device_detected")),
                    "wireless_same_device": discovery.get("same_device"),
                    "tunnel_strategy": strategy,
                    "tunnel_attempts": redact(attempts),
                    "selected_protocol": None,
                    "selected_candidate": selected_candidate,
                    "last_tunnel_failure_class": failure_class,
                    "fresh_rsd_proof_state": "DISCOVERY_PASS_TUNNEL_FAILED" if discovery.get("wireless_device_detected") else "NO_DISCOVERY_TUNNEL_FAILED",
                    "last_error": failure_message,
                    "message": "Discovery passed but tunnel failed" if discovery.get("wireless_device_detected") else "Wi-Fi tunnel failed",
                })
            self.store.append_event(experiment_id, {"event_type": "wifi_tunnel_start", "usb": usb, "usb_absent_before": usb_absent_before, "discovery": discovery, "tunnel_strategy": strategy, "attempts": attempts})
            self._update_summary(experiment_id, {
                "wifi_tunnel": "FAIL",
                "fresh_wifi_rsd": False,
                "tunnel_created_after_usb_absence": False,
                "wireless_discovery": "FOUND" if discovery.get("wireless_device_detected") else "NOT_FOUND",
                "tunnel_strategy": strategy,
                "tunnel_attempts": attempts,
                "last_tunnel_failure_class": failure_class,
            })
            return self._error(failure_message, "wifi_tunnel_failed", extra={
                "tunnel_strategy": redact(strategy),
                "tunnel_attempts": redact(attempts),
                "selected_candidate": redact(selected_candidate),
                "last_tunnel_failure_class": failure_class,
                "discovery": redact(discovery),
                "status": dict(self._runtime),
            })
        self._wifi_tunnel_proc = winning_proc
        tunnel = TunnelInfo(str(winning_result["address"]), int(winning_result["port"]), process=winning_proc)
        device = self._device_from_current_context()
        self._adapter.configure(device, tunnel)
        fresh_proof_state = "FRESH_WIFI_RSD_READY" if usb_absent_before else "TUNNEL_CREATED_WITH_USB_PRESENT"
        with self._lock:
            self._runtime.update({
                "state": "wifi_tunnel_active",
                "current_stage": "Validate Fresh RSD",
                "current_transport": "WIFI" if usb_absent_before else "USB+WIFI",
                "wifi_tunnel_active": True,
                "wifi_tunnel_pid": winning_result.get("pid"),
                "tunnel_transport": "WIFI",
                "rsd_ready": True,
                "rsd_source": "fresh_wifi_tunnel",
                "tunnel_strategy": strategy,
                "tunnel_attempts": redact(attempts),
                "selected_protocol": winning_result.get("protocol"),
                "selected_candidate": selected_candidate,
                "last_tunnel_failure_class": None,
                "fresh_rsd_proof_state": fresh_proof_state,
                "last_successful_contact": utc_now(),
                "message": "Fresh Wi-Fi tunnel started" if usb_absent_before else "Wi-Fi tunnel started, but USB was still connected at tunnel start",
            })
        self.store.append_event(experiment_id, {
            "event_type": "wifi_tunnel_start",
            "usb": usb,
            "usb_absent_before": usb_absent_before,
            "transport_requested": "WIFI",
            "transport_reported": "WIFI",
            "discovery": discovery,
            "tunnel_strategy": strategy,
            "attempts": attempts,
            "result": winning_result,
        })
        self._update_summary(experiment_id, {
            "wifi_tunnel": "PASS",
            "fresh_wifi_rsd": bool(usb_absent_before),
            "tunnel_created_after_usb_absence": bool(usb_absent_before),
            "tunnel_created_at": utc_now(),
            "transport_requested": "WIFI",
            "transport_reported": "WIFI",
            "rsd_source": "fresh_wifi_tunnel",
            "wireless_discovery": "FOUND" if discovery.get("wireless_device_detected") else "NOT_FOUND",
            "tunnel_strategy": strategy,
            "tunnel_attempts": attempts,
            "selected_protocol": winning_result.get("protocol"),
            "selected_candidate": selected_candidate,
        })
        return {
            "ok": True,
            "tunnel": redact(winning_result),
            "tunnel_strategy": redact(strategy),
            "tunnel_attempts": redact(attempts),
            "selected_protocol": winning_result.get("protocol"),
            "selected_candidate": redact(selected_candidate),
            "wireless_rsd_proof_complete": usb_absent_before,
            "status": dict(self._runtime),
        }

    def validate_rsd(self, experiment_id: str) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        tunnel = self._adapter.tunnel
        if not tunnel:
            return self._error("No Wi-Fi RSD endpoint is active", "rsd_missing")
        result = self.runner.run(pmd3_command("remote", "rsd-info", "--rsd", tunnel.address, str(tunnel.port)), timeout_s=25)
        parsed = self._parse_rsd_info(result)
        if result.ok and parsed:
            device = self._device_from_rsd(parsed)
            self._adapter.configure(device, tunnel)
        with self._lock:
            self._runtime.update({
                "state": "rsd_validated" if result.ok else "rsd_validation_failed",
                "current_stage": "Test Wireless Set Location",
                "rsd_ready": bool(result.ok),
                "last_successful_contact": utc_now() if result.ok else self._runtime.get("last_successful_contact"),
                "last_error": None if result.ok else concise(result.stderr or result.stdout),
                "message": "Fresh RSD validated" if result.ok else "RSD validation failed",
            })
        self.store.append_event(experiment_id, {"event_type": "rsd_validate", "result": result.as_dict(), "parsed": parsed})
        self._update_summary(experiment_id, {
            "rsd": "PASS" if result.ok else "FAIL",
            "ios_version": (parsed.get("Properties") or {}).get("OSVersion") if isinstance(parsed, dict) else None,
        })
        return {"ok": result.ok, "rsd_info": redact(parsed), "command": redact(result.as_dict()), "status": dict(self._runtime)}

    def wireless_set_location(self, experiment_id: str, lat: float, lon: float) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        if not self._adapter.tunnel or not self._adapter.device:
            return self._error("Fresh Wi-Fi RSD is not ready", "wireless_rsd_not_ready")
        with self._operation_lock:
            result = self._wireless_location.set_location(lat, lon)
            time.sleep(0.5)
            proc = getattr(self._wireless_location, "_active_location_proc", None)
            process_alive = bool(proc is not None and proc.poll() is None)
        ok = bool(result.get("ok")) and process_alive
        payload = {**result, "process_alive_after_start": process_alive}
        with self._lock:
            self._runtime.update({
                "state": "wireless_location_set" if ok else "wireless_location_set_failed",
                "current_stage": "Manual Device Confirmation",
                "location_session_active": process_alive,
                "last_successful_contact": utc_now() if ok else self._runtime.get("last_successful_contact"),
                "last_error": None if ok else result.get("message", "Wireless Set Location failed"),
                "message": "Wireless Set Location issued. Confirm on the iPhone." if ok else "Wireless Set Location failed",
            })
        self.store.append_event(experiment_id, {"event_type": "wireless_set_location", "lat": lat, "lon": lon, "result": payload})
        self._update_summary(experiment_id, {"set_location": "PASS" if ok else "FAIL"})
        return {"ok": ok, "result": redact(payload), "status": dict(self._runtime)}

    def record_location_confirmation(self, experiment_id: str, confirmation: str, notes: str = "") -> dict[str, Any]:
        if confirmation not in {"yes", "no", "not_sure"}:
            return self._error("Invalid location confirmation", "invalid_confirmation")
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        observation = self.store.add_observation(experiment_id, {"location_changed": confirmation, "notes": notes})
        with self._lock:
            self._runtime.update({
                "manual_location_confirmation": confirmation,
                "current_stage": "Test Wireless Reset GPS",
                "message": f"Manual location confirmation recorded: {confirmation}",
            })
        self.store.append_event(experiment_id, {"event_type": "manual_location_confirmation", "confirmation": confirmation})
        self._update_summary(experiment_id, {"manual_location_confirmation": confirmation})
        return {"ok": True, "observation": observation, "status": dict(self._runtime)}

    def wireless_reset_gps(self, experiment_id: str) -> dict[str, Any]:
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        if not self._adapter.tunnel or not self._adapter.device:
            return self._error("Fresh Wi-Fi RSD is not ready", "wireless_rsd_not_ready")
        with self._operation_lock:
            result = self._wireless_location.clear_location()
        ok = bool(result.get("ok"))
        with self._lock:
            self._runtime.update({
                "state": "wireless_reset_complete" if ok else "wireless_reset_failed",
                "current_stage": "Final Verdict",
                "location_session_active": False if ok else self._wireless_location_active(),
                "last_successful_contact": utc_now() if ok else self._runtime.get("last_successful_contact"),
                "last_error": None if ok else result.get("message", "Wireless Reset GPS failed"),
                "message": "Wireless Reset GPS succeeded" if ok else "Wireless Reset GPS failed. Reconnect USB and use stable Reset GPS.",
            })
        self.store.append_event(experiment_id, {"event_type": "wireless_reset_gps", "result": result})
        self._update_summary(experiment_id, {"reset_gps": "PASS" if ok else "FAIL", "tunnel_stable": self._tunnel_alive()})
        self.finalize(experiment_id)
        return {"ok": ok, "result": redact(result), "status": dict(self._runtime)}

    def record_reset_confirmation(self, experiment_id: str, confirmation: str, notes: str = "") -> dict[str, Any]:
        if confirmation not in {"yes", "no", "not_sure"}:
            return self._error("Invalid reset confirmation", "invalid_confirmation")
        if not self._select(experiment_id):
            return self._error("Wireless experiment not found or not active", "not_found")
        observation = self.store.add_observation(experiment_id, {"reset_confirmed": confirmation, "notes": notes})
        with self._lock:
            self._runtime.update({"manual_reset_confirmation": confirmation})
        self.store.append_event(experiment_id, {"event_type": "manual_reset_confirmation", "confirmation": confirmation})
        self._update_summary(experiment_id, {"manual_reset_confirmation": confirmation})
        self.finalize(experiment_id)
        return {"ok": True, "observation": observation, "status": dict(self._runtime)}

    def finalize(self, experiment_id: str) -> dict[str, Any]:
        if not self.store.exists(experiment_id):
            return self._error("Wireless experiment not found", "not_found")
        record = self.store.get(experiment_id)
        verdict, interpretation = self._verdict(record)
        manifest = self.store.update_manifest(experiment_id, state="completed", verdict=verdict, summary={**(record.get("summary") or {}), "interpretation": interpretation})
        report = generate_report(self.store.get(experiment_id))
        (self.store.path_for(experiment_id) / "report.md").write_text(report, encoding="utf-8")
        with self._lock:
            if self._runtime.get("experiment_id") == experiment_id:
                self._runtime.update({"state": "completed", "verdict": verdict, "message": verdict})
        return {"ok": True, "experiment": manifest, "verdict": verdict, "report": report, "status": dict(self._runtime)}

    def stop(self, experiment_id: str | None = None, clear_state: bool = False) -> dict[str, Any]:
        selected = experiment_id or self._active_experiment_id
        if selected:
            self.store.append_event(selected, {"event_type": "wireless_stop_requested", "clear_state": clear_state})
        try:
            if self._adapter.tunnel and self._adapter.device:
                self._wireless_location.clear_location()
        except Exception:
            pass
        self.stop_wifi_tunnel()
        if clear_state:
            self._adapter.clear()
            with self._lock:
                self._active_experiment_id = None
                self._runtime = self._idle_runtime()
        return {"ok": True, "message": "Wireless test stopped", "status": dict(self._runtime)}

    def stop_wifi_tunnel(self) -> dict[str, Any]:
        proc = self._wifi_tunnel_proc
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        self._wifi_tunnel_proc = None
        self._adapter.tunnel = None
        with self._lock:
            self._runtime.update({"wifi_tunnel_active": False, "wifi_tunnel_pid": None, "rsd_ready": False, "current_transport": "UNKNOWN"})
        return {"ok": True, "message": "Wi-Fi tunnel stopped"}

    def usb_state(self) -> dict[str, Any]:
        result = self.runner.run(pmd3_command("usbmux", "list", "--usb"), timeout_s=12)
        devices = self._parse_devices(result)
        self._remember_baseline_from_usb_devices(devices)
        return {
            "usb_detected": bool(devices),
            "transport": "USB" if devices else "UNKNOWN",
            "devices": [self._safe_device_row(device) for device in devices],
            "command": redact(result.as_dict()),
        }

    def discover(self) -> dict[str, Any]:
        methods = {
            "usb": self.runner.run(pmd3_command("usbmux", "list", "--usb"), timeout_s=12),
            "usbmux_network": self.runner.run(pmd3_command("usbmux", "list", "--network"), timeout_s=12),
            "remote_browse": self.runner.run(pmd3_command("remote", "browse", "--timeout", "2"), timeout_s=18),
            "bonjour_remotepairing": self.runner.run(pmd3_command("bonjour", "remotepairing", "--timeout", "2"), timeout_s=18),
            "bonjour_rsd": self.runner.run(pmd3_command("bonjour", "rsd"), timeout_s=18),
            "bonjour_mobdev2": self.runner.run(pmd3_command("bonjour", "mobdev2", "--timeout", "2"), timeout_s=18),
        }
        parsed = {name: self._parse_discovery_result(name, result) for name, result in methods.items()}
        wireless_names = ["usbmux_network", "remote_browse", "bonjour_remotepairing", "bonjour_rsd", "bonjour_mobdev2"]
        wireless_found = any(parsed[name]["found"] for name in wireless_names)
        best = next((name for name in wireless_names if parsed[name]["found"]), None)
        same_device = self._same_device(parsed)
        candidates = self._remote_pairing_candidates(parsed)
        self._remember_baseline_from_parsed_discovery(parsed)
        same_device = self._same_device(parsed)
        public_methods = {
            name: {key: value for key, value in method.items() if key != "_raw_parsed"}
            for name, method in parsed.items()
        }
        return {
            "wireless_device_detected": wireless_found,
            "same_device": same_device,
            "best_method": best,
            "methods": public_methods,
            "remote_pairing_candidates": candidates,
        }

    def _preparation_prerequisites(self, stable: dict[str, Any], usb: dict[str, Any]) -> dict[str, Any]:
        device = stable.get("device") or {}
        usb_devices = usb.get("devices") or []
        return {
            "usb_present": bool(usb.get("usb_detected")),
            "trusted_lockdown_available": bool(stable.get("device_connected")),
            "developer_mode": self._read_developer_mode(),
            "baseline_udid_abbreviated": abbreviate_identifier(str(self._baseline_identifier() or "")),
            "device_name": device.get("name") or (usb_devices[0].get("name") if usb_devices else None),
            "product_type": device.get("product_type") or device.get("ProductType") or (usb_devices[0].get("product_type") if usb_devices else None),
            "ios_version": device.get("ios_version") or device.get("ProductVersion") or (usb_devices[0].get("ios_version") if usb_devices else None),
        }

    def _bootstrap_remote_pairing(self, stable: dict[str, Any], usb: dict[str, Any]) -> dict[str, Any]:
        started_at = time.time()
        udid = self._baseline_identifier()
        if not usb.get("usb_detected") or not stable.get("device_connected"):
            return {
                "status": "FAILED",
                "ok": False,
                "reason": "trusted_usb_required",
                "message": "RemotePairing bootstrap requires the trusted USB lockdown path.",
                "udid_abbreviated": abbreviate_identifier(str(udid or "")),
                "timestamp": utc_now(),
                "latency_s": 0.0,
            }
        help_result = self.runner.run(pmd3_command("lockdown", "remotepairing", "--help"), timeout_s=15)
        if not help_result.ok or "--pair" not in (help_result.stdout + help_result.stderr):
            return {
                "status": "UNSUPPORTED",
                "ok": False,
                "reason": "command_unsupported",
                "command_capability": redact(help_result.as_dict()),
                "udid_abbreviated": abbreviate_identifier(str(udid or "")),
                "timestamp": utc_now(),
                "latency_s": max(0.0, time.time() - started_at),
            }
        command = pmd3_command("lockdown", "remotepairing", "--pair")
        if udid and "--udid" in (help_result.stdout + help_result.stderr):
            command.extend(["--udid", str(udid)])
        result = self.runner.run(command, timeout_s=45, input_text="\n")
        evidence = self._remote_pairing_evidence(result)
        return {
            "status": "READY" if result.ok else "FAILED",
            "ok": result.ok,
            "command": result.as_dict().get("command"),
            "returncode": result.returncode,
            "timed_out": result.timed_out,
            "udid_abbreviated": abbreviate_identifier(str(udid or "")),
            "device": evidence,
            "wireProtocolVersion": evidence.get("wireProtocolVersion"),
            "timestamp": utc_now(),
            "latency_s": result.latency_s,
            "message": "RemotePairing pair record bootstrapped over trusted USB." if result.ok else concise(result.stderr or result.stdout, 400),
        }

    def _enable_wifi_connections(self, stable: dict[str, Any], usb: dict[str, Any]) -> dict[str, Any]:
        started_at = time.time()
        udid = self._baseline_identifier()
        if not usb.get("usb_detected") or not stable.get("device_connected"):
            return {
                "status": "FAILED",
                "ok": False,
                "reason": "trusted_usb_required",
                "message": "Wi-Fi lockdown enablement requires the trusted USB lockdown path.",
                "timestamp": utc_now(),
                "latency_s": 0.0,
            }
        help_result = self.runner.run(pmd3_command("lockdown", "wifi-connections", "--help"), timeout_s=15)
        help_text = help_result.stdout + help_result.stderr
        if not help_result.ok:
            return {
                "status": "UNSUPPORTED",
                "ok": False,
                "reason": "command_unsupported",
                "command_capability": redact(help_result.as_dict()),
                "timestamp": utc_now(),
                "latency_s": max(0.0, time.time() - started_at),
            }
        if "--state" not in help_text:
            return {
                "status": "UNSUPPORTED",
                "ok": False,
                "reason": "state_syntax_not_supported",
                "detected_syntax": concise(help_text, 300),
                "timestamp": utc_now(),
                "latency_s": max(0.0, time.time() - started_at),
            }
        command = pmd3_command("lockdown", "wifi-connections", "--state", "on")
        if udid and "--udid" in help_text:
            command.extend(["--udid", str(udid)])
        result = self.runner.run(command, timeout_s=30, input_text="\n")
        return {
            "status": "READY" if result.ok else "FAILED",
            "ok": result.ok,
            "detected_syntax": "--state on",
            "command": result.as_dict().get("command"),
            "returncode": result.returncode,
            "timed_out": result.timed_out,
            "timestamp": utc_now(),
            "latency_s": result.latency_s,
            "message": "Wi-Fi connections enabled via lockdown." if result.ok else concise(result.stderr or result.stdout, 400),
        }

    def _preparation_status(
        self,
        prerequisites: dict[str, Any],
        bootstrap: dict[str, Any],
        wifi_connections: dict[str, Any],
        discovery: dict[str, Any],
    ) -> tuple[str, list[str]]:
        reasons: list[str] = []
        if not prerequisites.get("usb_present"):
            reasons.append("USB is not present, so native preparation could not run.")
        if not prerequisites.get("trusted_lockdown_available"):
            reasons.append("Trusted lockdown device is not available.")
        if bootstrap.get("status") == "UNSUPPORTED" or wifi_connections.get("status") == "UNSUPPORTED":
            return "UNSUPPORTED", reasons or ["Installed pymobiledevice3 does not support one or more native preparation commands."]
        if bootstrap.get("status") != "READY":
            reasons.append("RemotePairing bootstrap did not complete.")
        if wifi_connections.get("status") != "READY":
            reasons.append("Wi-Fi connections were not enabled.")
        if not discovery.get("wireless_device_detected"):
            reasons.append("Wireless discovery did not find the device yet.")
        if not reasons:
            return "READY", []
        if bootstrap.get("status") == "READY" or wifi_connections.get("status") == "READY" or discovery.get("wireless_device_detected"):
            return "PARTIAL", reasons
        return "FAILED", reasons

    def _remote_pairing_evidence(self, result: CommandResult) -> dict[str, Any]:
        evidence: dict[str, Any] = {}
        parsed: Any = None
        try:
            parsed = parse_json_array_or_object(result.stdout)
        except Exception:
            parsed = None
        values = self._flatten_values(parsed if parsed is not None else result.stdout)
        for key, value in values:
            lower = key.lower()
            if lower in {"wireprotocolversion", "wire_protocol_version"}:
                evidence["wireProtocolVersion"] = value
            elif lower in {"devicename", "device_name", "name"} and "device_name" not in evidence:
                evidence["device_name"] = str(value)
            elif lower in {"producttype", "product_type", "model"} and "product_type" not in evidence:
                evidence["product_type"] = str(value)
            elif lower in {"productversion", "osversion", "ios_version"} and "ios_version" not in evidence:
                evidence["ios_version"] = str(value)
        if "wireProtocolVersion" not in evidence:
            text = result.stdout or ""
            import re
            match = re.search(r"wireProtocolVersion['\"]?\s*[:=]\s*['\"]?(\d+)", text)
            if match:
                evidence["wireProtocolVersion"] = int(match.group(1))
        return evidence

    def _flatten_values(self, value: Any, key: str = "") -> list[tuple[str, Any]]:
        rows: list[tuple[str, Any]] = []
        if isinstance(value, dict):
            for child_key, child_value in value.items():
                rows.extend(self._flatten_values(child_value, str(child_key)))
        elif isinstance(value, list):
            for child in value:
                rows.extend(self._flatten_values(child, key))
        elif key:
            rows.append((key, value))
        return rows

    def _remote_pairing_candidates(self, parsed: dict[str, Any]) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for source in ("remote_browse", "bonjour_remotepairing"):
            for item in self._candidate_items(parsed.get(source, {}).get("_raw_parsed")):
                host = item.get("host") or item.get("hostname") or item.get("address") or item.get("ip")
                port = item.get("port") or item.get("Port")
                if not host or not port:
                    continue
                try:
                    port_int = int(port)
                except Exception:
                    continue
                candidate = self._score_candidate(str(host), port_int, str(source), item.get("interface") or item.get("interface_name"))
                if candidate not in rows:
                    rows.append(candidate)
        return sorted(rows, key=lambda row: row.get("score", 0), reverse=True)

    def _candidate_items(self, value: Any) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        if isinstance(value, dict):
            if any(key in value for key in ("host", "hostname", "address", "ip")) and any(key in value for key in ("port", "Port")):
                rows.append(value)
            for item in value.values():
                rows.extend(self._candidate_items(item))
        elif isinstance(value, list):
            for item in value:
                rows.extend(self._candidate_items(item))
        return rows

    def _score_candidate(self, host: str, port: int, source: str, interface: Any = None) -> dict[str, Any]:
        score = 10
        routeable = "unknown"
        reason = "host name candidate"
        clean_host = host.split("%", 1)[0].strip("[]")
        try:
            ip = ipaddress.ip_address(clean_host)
            if ip.version == 4:
                score += 60
                routeable = "likely"
                reason = "IPv4 RemotePairing candidate preferred over link-local duplicates"
            elif ip.is_link_local:
                score -= 20
                routeable = "link_local"
                reason = "link-local IPv6 candidate may require the right interface"
            else:
                score += 30
                routeable = "likely"
                reason = "non-link-local IPv6 candidate"
        except ValueError:
            score += 20
        if source == "bonjour_remotepairing":
            score += 5
        return {
            "source": source,
            "candidate_host": host,
            "candidate_port": port,
            "interface": interface,
            "routeable": routeable,
            "score": score,
            "selection_reason": reason,
        }

    def _default_tunnel_protocol_plan(self) -> list[str]:
        help_result = self.runner.run(pmd3_command("remote", "start-tunnel", "--help"), timeout_s=15)
        text = help_result.stdout + help_result.stderr
        if help_result.ok and "<tcp|quic>" not in text and "--protocol" not in text:
            return ["quic"]
        return ["quic", "tcp"]

    def _wifi_tunnel_command(self, protocol: str) -> list[str]:
        command = pmd3_command("remote", "start-tunnel", "--connection-type", "wifi", "--script-mode")
        udid = self._baseline_identifier()
        command.extend(["--protocol", protocol])
        if udid:
            command.extend(["--udid", str(udid)])
        return command

    def _tunnel_failure_message(self, attempts: list[dict[str, Any]]) -> str:
        parts = []
        for attempt in attempts:
            protocol = str(attempt.get("protocol") or "unknown").upper()
            failure = attempt.get("failure_class") or "unknown"
            detail = attempt.get("failure_message") or "no detail"
            parts.append(f"{protocol}: {failure} ({detail})")
        return "Wi-Fi tunnel failed. " + "; ".join(parts)

    def report_text(self, experiment_id: str) -> str:
        path = self.store.path_for(experiment_id) / "report.md"
        if not path.exists():
            self.finalize(experiment_id)
        return path.read_text(encoding="utf-8")

    def _select(self, experiment_id: str) -> bool:
        if not self.store.exists(experiment_id):
            return False
        with self._lock:
            if self._active_experiment_id is None:
                self._active_experiment_id = experiment_id
                record = self.store.get(experiment_id)
                self._runtime.update({"experiment_id": experiment_id, "test_type": record.get("test_type")})
            return self._active_experiment_id == experiment_id

    def _update_summary(self, experiment_id: str, changes: dict[str, Any]) -> None:
        record = self.store.get(experiment_id)
        summary = {**(record.get("summary") or {}), "pymobiledevice3_version": pmd3_version(), **{k: v for k, v in changes.items() if v is not None}}
        self.store.update_manifest(experiment_id, summary=summary)

    def _parse_devices(self, result: CommandResult) -> list[dict[str, Any]]:
        if not result.ok:
            return []
        try:
            parsed = parse_json_array_or_object(result.stdout)
        except Exception:
            return []
        return parsed if isinstance(parsed, list) else []

    def _parse_discovery_result(self, name: str, result: CommandResult) -> dict[str, Any]:
        parsed: Any = None
        found = False
        try:
            parsed = parse_json_array_or_object(result.stdout)
        except Exception:
            parsed = None
        if name == "remote_browse" and isinstance(parsed, dict):
            found = bool(parsed.get("wifi") or parsed.get("usb"))
        elif isinstance(parsed, list):
            found = bool(parsed)
        return {
            "ok": result.ok,
            "found": found,
            "returncode": result.returncode,
            "stdout_summary": concise(result.stdout, 600),
            "stderr_summary": concise(result.stderr, 600),
            "parsed": redact(parsed),
            "_raw_parsed": parsed,
            "transport": "USB" if name == "usb" and found else "WIFI" if name != "usb" and found else "UNKNOWN",
        }

    def _same_device(self, parsed: dict[str, Any]) -> bool | None:
        baseline = self._baseline_identifier()
        if not baseline:
            return None
        found_identifiers = []
        for method in parsed.values():
            raw = method.get("_raw_parsed")
            found_identifiers.extend(self._extract_identifiers(raw))
        if not found_identifiers:
            return None
        normalized = baseline.replace("-", "").lower()
        return any(str(item).replace("-", "").lower() == normalized for item in found_identifiers)

    def _baseline_identifier(self) -> str | None:
        valid = self._valid_identifier(self._baseline_udid_full)
        if valid:
            return valid
        self._baseline_udid_full = None
        try:
            device = (self._stable_status().get("device") or {})
        except Exception:
            device = {}
        valid = self._valid_identifier(device.get("udid") or device.get("UniqueDeviceID") or device.get("Identifier"))
        if valid:
            self._baseline_udid_full = valid
            return valid
        return None

    @staticmethod
    def _valid_identifier(value: Any) -> str | None:
        if value is None:
            return None
        text = str(value).strip()
        if not text or text.lower() in {"unknown", "none", "null", "wireless-device"}:
            return None
        compact = text.replace("-", "")
        if len(compact) < 12:
            return None
        return text

    def _remember_baseline_from_usb_devices(self, devices: list[dict[str, Any]]) -> None:
        if self._baseline_identifier():
            return
        for device in devices:
            identifier = self._valid_identifier(device.get("UniqueDeviceID") or device.get("Identifier") or device.get("SerialNumber") or device.get("UDID"))
            if identifier:
                with self._lock:
                    self._baseline_udid_full = identifier
                return

    def _remember_baseline_from_discovery(self, discovery: dict[str, Any]) -> None:
        if self._baseline_identifier():
            return
        methods = discovery.get("methods") or {}
        identifiers: list[str] = []
        for method in methods.values():
            identifiers.extend(self._extract_identifiers(method.get("parsed")))
        for identifier in identifiers:
            valid = self._valid_identifier(identifier)
            if valid:
                with self._lock:
                    self._baseline_udid_full = valid
                return

    def _remember_baseline_from_parsed_discovery(self, parsed: dict[str, Any]) -> None:
        if self._baseline_identifier():
            return
        identifiers: list[str] = []
        for method in parsed.values():
            identifiers.extend(self._extract_identifiers(method.get("_raw_parsed")))
        for identifier in identifiers:
            valid = self._valid_identifier(identifier)
            if valid:
                with self._lock:
                    self._baseline_udid_full = valid
                return

    def _tunnel_preflight_discovery(self, discovery: dict[str, Any]) -> dict[str, Any]:
        methods = discovery.get("methods") or {}
        selected_methods = {}
        for name in ("remote_browse", "bonjour_remotepairing"):
            method = methods.get(name) or {}
            selected_methods[name] = {
                "ok": method.get("ok"),
                "found": method.get("found"),
                "returncode": method.get("returncode"),
                "stdout_summary": method.get("stdout_summary"),
                "stderr_summary": method.get("stderr_summary"),
                "transport": method.get("transport"),
            }
        return {
            "baseline_udid_abbreviated": abbreviate_identifier(str(self._baseline_identifier() or "")),
            "baseline_present": discovery.get("same_device") is True,
            "wireless_device_detected": bool(discovery.get("wireless_device_detected")),
            "best_method": discovery.get("best_method"),
            "remote_pairing_candidate_count": len(discovery.get("remote_pairing_candidates") or []),
            "methods": selected_methods,
        }

    def _extract_identifiers(self, value: Any) -> list[str]:
        found: list[str] = []
        if isinstance(value, dict):
            for key, item in value.items():
                if key.lower() in {"udid", "uniquedeviceid", "identifier", "serialnumber", "unique_device_id"} and isinstance(item, str):
                    found.append(item)
                else:
                    found.extend(self._extract_identifiers(item))
        elif isinstance(value, list):
            for item in value:
                found.extend(self._extract_identifiers(item))
        return found

    def _pairing_status(self, discovery: dict[str, Any]) -> str:
        methods = discovery.get("methods") or {}
        remote = methods.get("remote_browse") or {}
        network = methods.get("usbmux_network") or {}
        bonjour = methods.get("bonjour_remotepairing") or {}
        if remote.get("found") and discovery.get("same_device") is True:
            return "CONFIRMED BY IOSSim"
        if remote.get("found") or network.get("found"):
            return "LIKELY READY"
        if bonjour.get("found"):
            return "MANUAL CONFIRMATION REQUIRED"
        if methods and not discovery.get("wireless_device_detected"):
            return "UNKNOWN"
        return "NOT READY"

    def _read_developer_mode(self) -> dict[str, Any]:
        result = self.runner.run(pmd3_command("amfi", "developer-mode-status"), timeout_s=15)
        return {"status": result.stdout.strip() if result.ok else "UNKNOWN", "ok": result.ok, "detail": concise(result.stderr or result.stdout)}

    def _read_ddi_state(self) -> dict[str, Any]:
        result = self.runner.run(pmd3_command("mounter", "list"), timeout_s=20)
        mounted = False
        try:
            parsed = parse_json_array_or_object(result.stdout)
            mounted = any(item.get("IsMounted") and "DeveloperDiskImage" in str(item.get("PersonalizedImageType", "")) for item in parsed or [])
        except Exception:
            parsed = None
        return {"mounted": mounted if result.ok else None, "ok": result.ok, "detail": redact(parsed) if parsed is not None else concise(result.stderr or result.stdout)}

    def _parse_rsd_info(self, result: CommandResult) -> dict[str, Any] | None:
        try:
            parsed = parse_json_array_or_object(result.stdout)
            return parsed if isinstance(parsed, dict) else None
        except Exception:
            return None

    def _device_from_rsd(self, parsed: dict[str, Any]) -> DeviceInfo:
        props = parsed.get("Properties") or {}
        version = str(props.get("OSVersion") or props.get("ProductVersion") or "17.0")
        return DeviceInfo(
            udid=str(props.get("UniqueDeviceID") or self._baseline_identifier() or "wireless-device"),
            name=str(props.get("DeviceName") or props.get("ProductType") or "Wireless iPhone"),
            ios_version=version,
            ios_major=self._major(version, default=17),
        )

    def _device_from_current_context(self) -> DeviceInfo:
        stable_device = (self._stable_status().get("device") or {})
        version = str(stable_device.get("ios_version") or "26.5.2")
        return DeviceInfo(
            udid=str(stable_device.get("udid") or "wireless-device"),
            name=str(stable_device.get("name") or "Wireless iPhone"),
            ios_version=version,
            ios_major=self._major(version, default=26),
        )

    @staticmethod
    def _major(version: str, default: int) -> int:
        try:
            return int(str(version).split(".")[0])
        except Exception:
            return default

    def _safe_device_row(self, device: dict[str, Any]) -> dict[str, Any]:
        identifier = str(device.get("UniqueDeviceID") or device.get("Identifier") or device.get("SerialNumber") or "")
        return {
            "name": device.get("DeviceName") or device.get("ProductType") or "iPhone",
            "ios_version": device.get("ProductVersion"),
            "product_type": device.get("ProductType"),
            "connection_type": device.get("ConnectionType"),
            "udid_abbreviated": abbreviate_identifier(identifier) if identifier else "",
        }

    def _redact_stable_status(self, stable: dict[str, Any]) -> dict[str, Any]:
        data = redact(stable)
        device = data.get("device") if isinstance(data, dict) else None
        if isinstance(device, dict):
            raw = (stable.get("device") or {}).get("udid")
            if raw:
                device["udid_abbreviated"] = abbreviate_identifier(str(raw))
        return data

    def _wireless_location_active(self) -> bool:
        proc = getattr(self._wireless_location, "_active_location_proc", None)
        return bool(proc is not None and proc.poll() is None)

    def _tunnel_alive(self) -> bool:
        return bool(self._wifi_tunnel_proc is not None and self._wifi_tunnel_proc.poll() is None)

    def _verdict(self, record: dict[str, Any]) -> tuple[str, str]:
        summary = record.get("summary") or {}
        test_type = record.get("test_type")
        usb_absent_before_tunnel = summary.get("usb_absent_before_tunnel") is True
        tunnel_after_absence = summary.get("tunnel_created_after_usb_absence") is True
        discovery = summary.get("wireless_discovery") == "FOUND"
        tunnel = summary.get("wifi_tunnel") == "PASS"
        rsd = summary.get("rsd") == "PASS"
        set_ok = summary.get("set_location") == "PASS"
        reset_ok = summary.get("reset_gps") == "PASS"
        manual_yes = summary.get("manual_location_confirmation") == "yes"
        started_without_usb = record.get("session_started_usb_present") is False
        if discovery and tunnel and rsd and set_ok and reset_ok and manual_yes and usb_absent_before_tunnel and tunnel_after_absence:
            if test_type == EXPERIMENT_B and started_without_usb:
                return (
                    "CABLE-FREE IOSIM CONFIRMED ON THIS TESTED DEVICE/CONFIGURATION",
                    "Experiment B passed with no USB present at IOSSim session start and with a fresh Wi-Fi RSD tunnel created after USB absence.",
                )
            return (
                "WIRELESS LOCATION SET + RESET CONFIRMED",
                "The tested iPhone was reachable wirelessly after USB removal, a fresh Wi-Fi RSD tunnel was created, Set Location succeeded, manual confirmation was positive, and Reset GPS succeeded.",
            )
        if discovery and tunnel and rsd and set_ok and not reset_ok:
            return ("WIRELESS DVT SET CONFIRMED, RESET UNCONFIRMED", "Set Location worked through Wi-Fi RSD, but Reset GPS did not complete successfully.")
        if discovery and tunnel and rsd and set_ok and not manual_yes:
            return ("WIRELESS DVT SET ISSUED, DEVICE CONFIRMATION INCONCLUSIVE", "The command path succeeded, but manual device-side confirmation was not positive.")
        if discovery and tunnel and rsd:
            return ("WIRELESS TUNNEL CONFIRMED, LOCATION UNCONFIRMED", "Wireless discovery, tunnel, and RSD worked, but Set Location and Reset GPS were not fully confirmed.")
        if discovery and tunnel:
            return ("WI-FI TUNNEL CONFIRMED, RSD UNCONFIRMED", "A Wi-Fi tunnel process started, but RSD or DVT proof is incomplete.")
        if discovery and summary.get("wifi_tunnel") == "FAIL":
            failure = summary.get("last_tunnel_failure_class") or "unknown"
            return ("DEVICE DISCOVERED BUT TUNNEL FAILED", f"The same device appeared wirelessly, but no fresh Wi-Fi RSD tunnel was obtained. Last tunnel failure class: {failure}.")
        if discovery:
            return ("WIRELESS DEVICE DISCOVERY ONLY", "The device appeared through at least one wireless discovery method, but tunnel, RSD, Set Location, and Reset GPS proof are incomplete.")
        if summary.get("usb_state") == "USB_PRESENT":
            return ("WIRELESS RSD PROOF INCOMPLETE", "USB was still present at the point where cable-free proof required it to be absent.")
        return ("INCONCLUSIVE", "The experiment did not produce enough evidence for wireless IOSSim operation.")

    @staticmethod
    def _error(message: str, code: str, extra: dict[str, Any] | None = None) -> dict[str, Any]:
        return {"ok": False, "code": code, "message": message, **(extra or {})}
