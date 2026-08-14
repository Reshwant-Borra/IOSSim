"""
device_manager.py — iOS device detection, DDI mounting, and tunnel lifecycle.

iOS < 17 : direct USB, no tunnel needed
iOS 17+  : requires tunneld + RSD (Remote Service Discovery) handshake
"""
from __future__ import annotations

import asyncio
import importlib.metadata
import importlib.util
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any, Optional

# pymobiledevice3 imports — lazy so missing dep gives a clear error
try:
    from pymobiledevice3.lockdown import create_using_usbmux
except ImportError:
    create_using_usbmux = None

_PMD3_PYTHON_API_AVAILABLE = create_using_usbmux is not None


def _concise(text: str, limit: int = 500) -> str:
    return " ".join((text or "").strip().split())[:limit]


def _pmd3_package_version() -> str | None:
    try:
        return importlib.metadata.version("pymobiledevice3")
    except importlib.metadata.PackageNotFoundError:
        return None


def _check_pmd3_cli(timeout_s: float = 5.0) -> dict[str, Any]:
    version = _pmd3_package_version()
    base = {
        "python_executable": sys.executable,
        "package_version": version,
        "cli_returncode": None,
        "stderr_summary": "",
    }
    if importlib.util.find_spec("pymobiledevice3") is None:
        return {**base, "available": False, "message": "pymobiledevice3 package is not importable"}
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pymobiledevice3", "--help"],
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
        return {
            **base,
            "available": result.returncode == 0,
            "cli_returncode": result.returncode,
            "stderr_summary": _concise(result.stderr),
            "message": "" if result.returncode == 0 else _concise(result.stderr or result.stdout),
        }
    except subprocess.TimeoutExpired:
        return {**base, "available": False, "message": f"pymobiledevice3 --help timed out after {timeout_s}s"}
    except Exception as exc:
        return {**base, "available": False, "message": str(exc)}


@dataclass
class DeviceInfo:
    udid: str
    name: str
    ios_version: str
    ios_major: int
    connected: bool = True


@dataclass
class TunnelInfo:
    address: str
    port: int
    process: Optional[subprocess.Popen] = None


class DeviceManager:
    """Manages one connected iPhone: detection, DDI mount, tunnel start/stop."""

    def __init__(self) -> None:
        self._device: Optional[DeviceInfo] = None
        self._tunnel: Optional[TunnelInfo] = None
        self._tunnel_proc: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        self._pmd3_cli_status: Optional[dict[str, Any]] = None
        self._pmd3_cli_checked_at = 0.0
        self._pmd3_cli_ttl_s = 30.0

    def _pmd3_cli_info(self, force: bool = False) -> dict[str, Any]:
        now = time.monotonic()
        with self._lock:
            if force or self._pmd3_cli_status is None or now - self._pmd3_cli_checked_at > self._pmd3_cli_ttl_s:
                self._pmd3_cli_status = _check_pmd3_cli()
                self._pmd3_cli_checked_at = now
            return dict(self._pmd3_cli_status)

    # ── device detection ─────────────────────────────────────────────────────

    def detect(self) -> Optional[DeviceInfo]:
        """Return DeviceInfo for the first connected device, or None.

        Tries the Python API first; falls back to
        `python -m pymobiledevice3 usbmux list` when the API raises.
        """
        if create_using_usbmux is not None:
            try:
                ld = create_using_usbmux()
                info = ld.all_values
                version = info.get("ProductVersion", "0.0")
                major = int(version.split(".")[0])
                self._device = DeviceInfo(
                    udid=ld.udid,
                    name=info.get("DeviceName", "iPhone"),
                    ios_version=version,
                    ios_major=major,
                )
                return self._device
            except Exception:
                pass  # fall through to CLI check

        # CLI fallback: python -m pymobiledevice3 usbmux list
        try:
            import json as _json
            result = subprocess.run(
                [sys.executable, "-m", "pymobiledevice3", "usbmux", "list"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0 and result.stdout.strip():
                devices = _json.loads(result.stdout)
                if devices:
                    d = devices[0]
                    version = d.get("ProductVersion", "0.0")
                    major = int(version.split(".")[0])
                    self._device = DeviceInfo(
                        udid=d.get("UniqueDeviceID") or d.get("Identifier") or d.get("SerialNumber") or d.get("UDID") or "unknown",
                        name=d.get("DeviceName", "iPhone"),
                        ios_version=version,
                        ios_major=major,
                    )
                    return self._device
        except Exception:
            pass

        self._device = None
        return None

    @property
    def device(self) -> Optional[DeviceInfo]:
        return self._device

    # ── DDI mounting ─────────────────────────────────────────────────────────

    def mount_ddi(self) -> dict:
        """Auto-mount developer disk image. pymobiledevice3 handles personalized DDI (iOS 17+)."""
        result = subprocess.run(
            [sys.executable, "-m", "pymobiledevice3", "mounter", "auto-mount"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode == 0 or "already mounted" in result.stdout.lower():
            return {"ok": True, "message": "DDI mounted"}
        return {"ok": False, "message": result.stderr.strip() or result.stdout.strip()}

    # ── tunnel (iOS 17+) ─────────────────────────────────────────────────────

    def start_tunnel(self) -> dict:
        """
        Start pymobiledevice3 tunneld in a subprocess.
        Parses RSD address + port from stdout so callers can use --rsd.

        Returns: {"ok": True, "address": "...", "port": N}

        Windows requirements: iTunes installed, run as Administrator, IPv6 enabled.
        """
        if self._tunnel_proc and self._tunnel_proc.poll() is None:
            if self._tunnel:
                return {"ok": True, "address": self._tunnel.address, "port": self._tunnel.port}

        import re, queue, time

        q: queue.Queue = queue.Queue()
        all_output: list[str] = []

        proc = subprocess.Popen(
            [sys.executable, "-m", "pymobiledevice3", "lockdown", "start-tunnel", "--script-mode"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )

        def _read() -> None:
            assert proc.stdout
            for line in proc.stdout:
                q.put(line)

        t = threading.Thread(target=_read, daemon=True)
        t.start()

        # Wait up to 20s for the RSD address + port.
        # Output format:
        #   fdc3:16b1:5cac::1 52954                       (--script-mode)
        #   RSD Address: fdc3:16b1:5cac::1
        #   RSD Port: 52954
        #   Use the follow connection option: --rsd fdc3:16b1:5cac::1 52954
        deadline = time.monotonic() + 20
        addr, port = None, None
        while time.monotonic() < deadline:
            try:
                line = q.get(timeout=0.5)
            except queue.Empty:
                if proc.poll() is not None:
                    break  # process exited, stop waiting
                continue

            all_output.append(line.rstrip())

            # "RSD Address: fdc3:16b1:5cac::1"
            m = re.search(r"RSD Address:\s+(\S+)", line, re.IGNORECASE)
            if m:
                addr = m.group(1)

            # "RSD Port: 52954"
            m = re.search(r"RSD Port:\s+(\d+)", line, re.IGNORECASE)
            if m:
                port = int(m.group(1))

            # "--rsd fdc3:16b1:5cac::1 52954" (combined hint line)
            m = re.search(r"--rsd\s+(\S+)\s+(\d+)", line)
            if m:
                addr, port = m.group(1), int(m.group(2))

            # "fdc3:16b1:5cac::1 52954" from --script-mode.
            m = re.search(r"^\s*(\S+)\s+(\d+)\s*$", line)
            if m:
                addr, port = m.group(1), int(m.group(2))

            if addr and port:
                break

        if addr and port:
            self._tunnel_proc = proc
            self._tunnel = TunnelInfo(address=addr, port=port, process=proc)
            return {"ok": True, "address": addr, "port": port}

        proc.terminate()
        output_summary = "\n".join(all_output[-20:]) or "(no output)"
        return {
            "ok": False,
            "message": (
                "Tunnel failed to start. Windows requirements: "
                "run as Administrator, iTunes installed (for Apple Mobile Device Support), "
                "IPv6 enabled on your network adapter.\n\n"
                f"Tunnel output:\n{output_summary}"
            ),
        }

    def stop_tunnel(self) -> None:
        if self._tunnel_proc and self._tunnel_proc.poll() is None:
            self._tunnel_proc.terminate()
        self._tunnel = None
        self._tunnel_proc = None

    @property
    def tunnel(self) -> Optional[TunnelInfo]:
        return self._tunnel

    # ── status ───────────────────────────────────────────────────────────────

    def status(self) -> dict:
        device = self.detect()
        pmd3_cli = self._pmd3_cli_info()
        return {
            "pmd3_available": bool(pmd3_cli.get("available")),
            "pmd3_cli_available": bool(pmd3_cli.get("available")),
            "pmd3_python_api_available": _PMD3_PYTHON_API_AVAILABLE,
            "pmd3_diagnostics": pmd3_cli,
            "device_connected": device is not None,
            "device": {
                "udid": device.udid,
                "name": device.name,
                "ios_version": device.ios_version,
                "ios_major": device.ios_major,
                "needs_tunnel": device.ios_major >= 17,
            } if device else None,
            "tunnel_active": self._tunnel is not None and (
                self._tunnel_proc is None or self._tunnel_proc.poll() is None
            ),
            "tunnel": {
                "address": self._tunnel.address,
                "port": self._tunnel.port,
            } if self._tunnel else None,
        }
