"""
location_service.py — Set, clear, and route-play location via pymobiledevice3 CLI.

Uses subprocess so the tunnel/RSD credentials are passed correctly and we don't
need to replicate pymobiledevice3's internal service plumbing.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional

from device_manager import DeviceManager, TunnelInfo


def _pmd3(*args: str, timeout: int = 30) -> dict:
    cmd = [sys.executable, "-m", "pymobiledevice3", *args]
    print("Running:", cmd)
    try:
        result = subprocess.run(
            cmd,
            input="\n",
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        print(f"TimeoutExpired after {timeout}s for: {cmd}")
        return {
            "ok": False,
            "stdout": (exc.stdout or b"").decode() if isinstance(exc.stdout, bytes) else (exc.stdout or ""),
            "stderr": (exc.stderr or b"").decode() if isinstance(exc.stderr, bytes) else (exc.stderr or ""),
            "message": f"Command timed out after {timeout}s — pymobiledevice3 may still be processing",
        }
    print(result.stdout)
    print(result.stderr)
    ok = result.returncode == 0
    return {
        "ok": ok,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
        "message": (result.stdout + result.stderr).strip(),
    }


def _rsd_flags(tunnel: Optional[TunnelInfo]) -> list[str]:
    if tunnel:
        return ["--rsd", tunnel.address, str(tunnel.port)]
    return []


class LocationService:
    """High-level location operations — delegates subprocess calls to pymobiledevice3."""

    def __init__(self, manager: DeviceManager) -> None:
        self._mgr = manager
        self._lock = threading.Lock()
        self._active_location_proc: Optional[subprocess.Popen] = None

    def _dvt_prefix(self) -> list[str]:
        device = self._mgr.device
        if device and device.ios_major >= 17:
            return ["developer", "dvt", "simulate-location"]
        return ["developer", "simulate-location"]

    def set_location(self, lat: float, lon: float) -> dict:
        device = self._mgr.device
        if not device:
            return {"ok": False, "message": "No device connected"}

        if device.ios_major >= 17:
            tunnel = self._mgr.tunnel
            if not tunnel:
                return {"ok": False, "message": "Tunnel not active — call /setup/tunnel first"}
            args = [
                "developer", "dvt", "simulate-location", "set",
                *_rsd_flags(tunnel), "--", str(lat), str(lon),
            ]
        else:
            args = ["developer", "simulate-location", "set", "--", str(lat), str(lon)]

        with self._lock:
            self._terminate_active_locked()
            cmd = [sys.executable, "-m", "pymobiledevice3", *args]
            print("Starting active simulate-location process:", cmd)
            try:
                proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, text=True)
            except Exception as exc:
                return {"ok": False, "message": f"Failed to start simulate-location: {exc}"}
            self._active_location_proc = proc
            print(f"Active simulate-location process started: pid={proc.pid}")
            return {"ok": True, "message": "simulate-location process started", "pid": proc.pid}

    def clear_location(self) -> dict:
        device = self._mgr.device
        if not device:
            return {"ok": False, "message": "No device connected"}

        with self._lock:
            self._terminate_active_locked()

        if device.ios_major >= 17:
            tunnel = self._mgr.tunnel
            if not tunnel:
                return {"ok": False, "message": "Tunnel not active"}
            result = _pmd3(
                "developer", "dvt", "simulate-location", "clear",
                *_rsd_flags(tunnel),
                timeout=90,
            )
        else:
            result = _pmd3("developer", "simulate-location", "clear")

        print(f"reset/clear completed: ok={result.get('ok')}")
        return result

    def _terminate_active_locked(self) -> None:
        proc = self._active_location_proc
        if not proc:
            return

        self._active_location_proc = None
        if proc.poll() is not None:
            if proc.stdin:
                proc.stdin.close()
            print(f"old simulate-location process already exited: pid={proc.pid} code={proc.returncode}")
            return

        print(f"Terminating old simulate-location process: pid={proc.pid}")
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        if proc.stdin:
            proc.stdin.close()
        print(f"old simulate-location process terminated: pid={proc.pid} code={proc.returncode}")

    def play_route(self, waypoints: list[dict], speed_mps: float = 1.4) -> dict:
        """
        Play a route from a list of {lat, lon} dicts via a GPX temp file.
        speed_mps: meters/second (1.4 = walking, 13.9 = ~50km/h driving)
        """
        device = self._mgr.device
        if not device:
            return {"ok": False, "message": "No device connected"}
        if len(waypoints) < 2:
            return {"ok": False, "message": "Need at least 2 waypoints"}

        gpx = _build_gpx(waypoints)
        with tempfile.NamedTemporaryFile(suffix=".gpx", delete=False, mode="w") as f:
            f.write(gpx)
            gpx_path = f.name

        if device.ios_major >= 17:
            tunnel = self._mgr.tunnel
            if not tunnel:
                return {"ok": False, "message": "Tunnel not active"}
            return _pmd3(
                "developer", "dvt", "simulate-location", "play",
                *_rsd_flags(tunnel), gpx_path,
                timeout=3600,
            )
        else:
            return _pmd3("developer", "simulate-location", "play", gpx_path, timeout=3600)


def _build_gpx(waypoints: list[dict]) -> str:
    root = ET.Element("gpx", version="1.1", creator="ios-location-sim")
    trk = ET.SubElement(root, "trk")
    seg = ET.SubElement(trk, "trkseg")
    for wp in waypoints:
        pt = ET.SubElement(seg, "trkpt", lat=str(wp["lat"]), lon=str(wp["lon"]))
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding="unicode")
