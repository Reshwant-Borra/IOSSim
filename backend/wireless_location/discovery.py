from __future__ import annotations

import json
from typing import Any

from wireless_testing.command_runner import Runner, SubprocessRunner, concise, pmd3_command

from .models import DeviceVisibility
from .session import normalize_udid, utc_now, validate_udid


def parse_devices(stdout: str) -> list[dict[str, Any]]:
    try:
        payload = json.loads(stdout or "[]")
    except json.JSONDecodeError:
        return []
    if not isinstance(payload, list):
        return []
    return [item for item in payload if isinstance(item, dict)]


def identifier_for(device: dict[str, Any]) -> str | None:
    for key in ("UniqueDeviceID", "Identifier", "SerialNumber", "UDID", "udid"):
        value = device.get(key)
        if value:
            return str(value)
    return None


def device_metadata(device: dict[str, Any]) -> dict[str, Any]:
    return {
        "udid": identifier_for(device),
        "name": device.get("DeviceName") or device.get("name") or "iPhone",
        "product_type": device.get("ProductType") or device.get("product_type"),
        "ios_version": device.get("ProductVersion") or device.get("ios_version"),
    }


class WirelessDeviceDiscovery:
    def __init__(self, runner: Runner | None = None) -> None:
        self.runner = runner or SubprocessRunner()

    def list_usb(self) -> list[dict[str, Any]]:
        result = self.runner.run(pmd3_command("usbmux", "list", "--usb"), timeout_s=12)
        return parse_devices(result.stdout) if result.ok else []

    def list_network(self) -> list[dict[str, Any]]:
        result = self.runner.run(pmd3_command("usbmux", "list", "--network"), timeout_s=12)
        return parse_devices(result.stdout) if result.ok else []

    def visibility(self, udid: str) -> DeviceVisibility:
        target = normalize_udid(validate_udid(udid))
        usb_devices = self.list_usb()
        network_devices = self.list_network()
        usb_matches = self._matches(target, usb_devices)
        network_matches = self._matches(target, network_devices)
        errors: list[str] = []
        if len(usb_matches) > 1:
            errors.append(f"USB discovery is ambiguous for selected UDID ({len(usb_matches)} matches).")
        if len(network_matches) > 1:
            errors.append(f"Wireless discovery is ambiguous for selected UDID ({len(network_matches)} matches).")
        return DeviceVisibility(
            usb_present=len(usb_matches) == 1,
            network_present=len(network_matches) == 1,
            usb_count=len(usb_devices),
            network_count=len(network_devices),
            usb_match_count=len(usb_matches),
            network_match_count=len(network_matches),
            selected_usb=usb_matches[0] if len(usb_matches) == 1 else None,
            selected_network=network_matches[0] if len(network_matches) == 1 else None,
            errors=errors,
        )

    def single_usb_device(self) -> tuple[dict[str, Any] | None, str | None]:
        devices = self.list_usb()
        if not devices:
            return None, "Connect your iPhone with USB, unlock it, and Trust this Mac."
        valid = [device for device in devices if identifier_for(device)]
        if len(valid) > 1:
            return None, "Several iPhones are connected. Leave only the iPhone you want to add connected."
        if not valid:
            return None, "The connected iPhone did not expose a usable device identity."
        return valid[0], None

    def _matches(self, target: str, devices: list[dict[str, Any]]) -> list[dict[str, Any]]:
        matches = []
        for device in devices:
            identifier = identifier_for(device)
            if identifier and normalize_udid(identifier) == target:
                matches.append(device)
        return matches


class WirelessSetupBootstrap:
    def __init__(self, runner: Runner | None = None) -> None:
        self.runner = runner or SubprocessRunner()

    def prepare(self, udid: str) -> dict[str, Any]:
        real_udid = validate_udid(udid)
        bootstrap = self._remote_pairing(real_udid)
        wifi = self._wifi_connections(real_udid)
        ok = bool(bootstrap.get("ok")) and bool(wifi.get("ok"))
        return {
            "ok": ok,
            "status": "READY" if ok else "FAILED",
            "timestamp": utc_now(),
            "remote_pairing": bootstrap,
            "wifi_connections": wifi,
            "message": "Wireless access prepared." if ok else "Connect USB once to refresh wireless setup.",
        }

    def _remote_pairing(self, udid: str) -> dict[str, Any]:
        help_result = self.runner.run(pmd3_command("lockdown", "remotepairing", "--help"), timeout_s=15)
        help_text = help_result.stdout + help_result.stderr
        if not help_result.ok or "--pair" not in help_text:
            return {
                "ok": False,
                "status": "UNSUPPORTED",
                "message": "Installed pymobiledevice3 does not support RemotePairing bootstrap.",
                "detail": concise(help_text, 300),
            }
        command = pmd3_command("lockdown", "remotepairing", "--pair")
        if "--udid" in help_text:
            command.extend(["--udid", udid])
        result = self.runner.run(command, timeout_s=45, input_text="\n")
        return {
            "ok": result.ok,
            "status": "READY" if result.ok else "FAILED",
            "returncode": result.returncode,
            "message": "Pairing prepared." if result.ok else concise(result.stderr or result.stdout, 400),
        }

    def _wifi_connections(self, udid: str) -> dict[str, Any]:
        help_result = self.runner.run(pmd3_command("lockdown", "wifi-connections", "--help"), timeout_s=15)
        help_text = help_result.stdout + help_result.stderr
        if not help_result.ok or "--state" not in help_text:
            return {
                "ok": False,
                "status": "UNSUPPORTED",
                "message": "Installed pymobiledevice3 does not support Wi-Fi connection enablement.",
                "detail": concise(help_text, 300),
            }
        command = pmd3_command("lockdown", "wifi-connections", "--state", "on")
        if "--udid" in help_text:
            command.extend(["--udid", udid])
        result = self.runner.run(command, timeout_s=30, input_text="\n")
        return {
            "ok": result.ok,
            "status": "READY" if result.ok else "FAILED",
            "returncode": result.returncode,
            "message": "Wi-Fi access enabled." if result.ok else concise(result.stderr or result.stdout, 400),
        }
