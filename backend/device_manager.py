"""
device_manager.py — iOS device detection, DDI mounting, and tunnel lifecycle.

iOS < 17 : direct USB, no tunnel needed
iOS 17+  : requires tunneld + RSD (Remote Service Discovery) handshake
"""
from __future__ import annotations

import asyncio
import subprocess
import sys
import threading
from dataclasses import dataclass
from typing import Optional

# pymobiledevice3 imports — lazy so missing dep gives a clear error
try:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
    from pymobiledevice3.services.simulate_location import DtSimulateLocation
    from pymobiledevice3.tunneld import TunneldRunner
    _PMD3_AVAILABLE = True
except ImportError:
    _PMD3_AVAILABLE = False


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

    # ── device detection ─────────────────────────────────────────────────────

    def detect(self) -> Optional[DeviceInfo]:
        """Return DeviceInfo for the first connected device, or None.

        Tries the Python API first; falls back to
        `python -m pymobiledevice3 usbmux list` when the API raises.
        """
        if _PMD3_AVAILABLE:
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
                        udid=d.get("SerialNumber", d.get("UDID", "unknown")),
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
        return {
            "pmd3_available": _PMD3_AVAILABLE,
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
