from __future__ import annotations

import importlib.metadata
import importlib.util
import json
import os
import platform
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any, Protocol


PMD3 = [sys.executable, "-m", "pymobiledevice3"]
RELEVANT_ENV_PREFIXES = ("PYTHON", "VIRTUAL_ENV", "USBMUX", "PMD3", "PYMOBILEDEVICE3")
RELEVANT_ENV_KEYS = ("HOME", "PATH", "USER", "LOGNAME", "SUDO_USER", "SUDO_UID", "SUDO_GID")


def concise(text: str, limit: int = 1200) -> str:
    return " ".join((text or "").strip().split())[:limit]


def tail_text(lines: list[str], limit: int = 3000) -> str:
    text = "\n".join(lines[-80:])
    if len(text) <= limit:
        return text
    return text[-limit:]


def abbreviate_diagnostic_identifier(value: str | None) -> str:
    if not value:
        return ""
    text = str(value)
    if len(text) <= 10:
        return "****"
    return f"{text[:4]}...{text[-4:]}"


def redact_diagnostic_text(value: str) -> str:
    value = re.sub(
        r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16,40}\b|\b[0-9A-Fa-f]{24,40}\b",
        lambda match: abbreviate_diagnostic_identifier(match.group(0)),
        value,
    )
    value = re.sub(r"\b(?:[0-9A-Fa-f]{1,4}:){2,}[0-9A-Fa-f:]*\b", "[RSD_ADDRESS_REDACTED]", value)
    return value


def redact_diagnostic_argv(command: list[str]) -> list[str]:
    redacted: list[str] = []
    skip_rsd = 0
    for item in command:
        if skip_rsd:
            redacted.append("[REDACTED]")
            skip_rsd -= 1
            continue
        redacted.append(redact_diagnostic_text(str(item)))
        if item == "--rsd":
            skip_rsd = 2
    return redacted


def relevant_environment() -> dict[str, str]:
    result: dict[str, str] = {}
    for key, value in os.environ.items():
        if key in RELEVANT_ENV_KEYS or key.startswith(RELEVANT_ENV_PREFIXES):
            result[key] = redact_diagnostic_text(value)
    return dict(sorted(result.items()))


def subprocess_diagnostics(command: list[str], protocol: str | None = None, candidate: dict[str, Any] | None = None) -> dict[str, Any]:
    euid = os.geteuid() if hasattr(os, "geteuid") else None
    python_executable = command[0]
    if command[:1] == ["sudo"] and len(command) > 1:
        python_executable = command[1]
    return {
        "argv_redacted": redact_diagnostic_argv(command),
        "python_executable": python_executable,
        "current_process_python": sys.executable,
        "cwd": os.getcwd(),
        "environment": relevant_environment(),
        "effective_uid": euid,
        "is_root": euid == 0 if euid is not None else None,
        "sudo_command_prefix": command[:1] == ["sudo"],
        "sudo_environment": {
            key: os.environ.get(key)
            for key in ("SUDO_USER", "SUDO_UID", "SUDO_GID")
            if os.environ.get(key) is not None
        },
        "stdin_isatty": bool(sys.stdin and sys.stdin.isatty()),
        "stdout_isatty": bool(sys.stdout and sys.stdout.isatty()),
        "stderr_isatty": bool(sys.stderr and sys.stderr.isatty()),
        "subprocess_stdio": {
            "stdin": "inherit",
            "stdout": "PIPE",
            "stderr": "STDOUT",
            "text": True,
            "bufsize": 1,
        },
        "protocol": protocol,
        "candidate": candidate,
    }


def pmd3_version() -> str | None:
    try:
        return importlib.metadata.version("pymobiledevice3")
    except importlib.metadata.PackageNotFoundError:
        return None


@dataclass
class CommandResult:
    ok: bool
    command: list[str]
    returncode: int | None
    stdout: str
    stderr: str
    started_at: float
    completed_at: float
    timed_out: bool = False

    @property
    def latency_s(self) -> float:
        return max(0.0, self.completed_at - self.started_at)

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "command": list(self.command),
            "returncode": self.returncode,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "started_at": self.started_at,
            "completed_at": self.completed_at,
            "latency_s": self.latency_s,
            "timed_out": self.timed_out,
        }


class Runner(Protocol):
    def run(self, args: list[str], timeout_s: float = 20.0, input_text: str | None = None) -> CommandResult:
        ...

    def popen(self, args: list[str]) -> subprocess.Popen:
        ...


class SubprocessRunner:
    def run(self, args: list[str], timeout_s: float = 20.0, input_text: str | None = None) -> CommandResult:
        command = [str(part) for part in args]
        started = time.time()
        try:
            result = subprocess.run(
                command,
                input=input_text,
                capture_output=True,
                text=True,
                timeout=timeout_s,
            )
            completed = time.time()
            return CommandResult(
                ok=result.returncode == 0,
                command=command,
                returncode=result.returncode,
                stdout=result.stdout or "",
                stderr=result.stderr or "",
                started_at=started,
                completed_at=completed,
            )
        except subprocess.TimeoutExpired as exc:
            completed = time.time()
            stdout = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
            stderr = exc.stderr.decode() if isinstance(exc.stderr, bytes) else (exc.stderr or "")
            return CommandResult(
                ok=False,
                command=command,
                returncode=None,
                stdout=stdout,
                stderr=stderr,
                started_at=started,
                completed_at=completed,
                timed_out=True,
            )
        except Exception as exc:
            completed = time.time()
            return CommandResult(
                ok=False,
                command=command,
                returncode=None,
                stdout="",
                stderr=str(exc),
                started_at=started,
                completed_at=completed,
            )

    def popen(self, args: list[str]) -> subprocess.Popen:
        return subprocess.Popen(
            [str(part) for part in args],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )


def pmd3_command(*parts: str) -> list[str]:
    return [*PMD3, *parts]


def command_available(runner: Runner, *parts: str) -> dict[str, Any]:
    result = runner.run(pmd3_command(*parts, "--help"), timeout_s=15)
    return {
        "available": result.ok,
        "command": " ".join(pmd3_command(*parts)),
        "returncode": result.returncode,
        "detail": concise(result.stderr or result.stdout, 400),
    }


def capability_report(runner: Runner) -> dict[str, Any]:
    importable = importlib.util.find_spec("pymobiledevice3") is not None
    checks = {
        "remote_browse": command_available(runner, "remote", "browse"),
        "remote_start_tunnel": command_available(runner, "remote", "start-tunnel"),
        "remote_tunneld": command_available(runner, "remote", "tunneld"),
        "remote_pair": command_available(runner, "remote", "pair"),
        "usbmux_list": command_available(runner, "usbmux", "list"),
        "bonjour_remotepairing": command_available(runner, "bonjour", "remotepairing"),
        "bonjour_rsd": command_available(runner, "bonjour", "rsd"),
        "bonjour_mobdev2": command_available(runner, "bonjour", "mobdev2"),
        "lockdown_start_tunnel": command_available(runner, "lockdown", "start-tunnel"),
        "lockdown_wifi_connections": command_available(runner, "lockdown", "wifi-connections"),
        "lockdown_remotepairing": command_available(runner, "lockdown", "remotepairing"),
        "dvt_set": command_available(runner, "developer", "dvt", "simulate-location", "set"),
        "dvt_clear": command_available(runner, "developer", "dvt", "simulate-location", "clear"),
        "rsd_info": command_available(runner, "remote", "rsd-info"),
    }
    required = ["remote_browse", "remote_start_tunnel", "usbmux_list", "dvt_set", "dvt_clear", "rsd_info"]
    return {
        "python_executable": sys.executable,
        "python_version": platform.python_version(),
        "platform": platform.platform(),
        "pymobiledevice3_importable": importable,
        "pymobiledevice3_version": pmd3_version(),
        "commands": checks,
        "required_wireless_commands_available": importable and all(checks[name]["available"] for name in required),
    }


def terminating_signal(returncode: int | None, output: str = "") -> str | None:
    if returncode is None:
        return None
    number: int | None = None
    if returncode < 0:
        number = abs(returncode)
    elif returncode >= 128:
        number = returncode - 128
    if number:
        try:
            return signal.Signals(number).name
        except ValueError:
            return f"SIG{number}"
    if "bus error" in output.lower():
        return "SIGBUS"
    return None


def classify_tunnel_failure(
    output: str,
    returncode: int | None,
    timed_out: bool,
    address: str | None = None,
    port: int | None = None,
) -> tuple[str, str]:
    text = (output or "").lower()
    sig = terminating_signal(returncode, output)
    if address and not port:
        return "parse_failure", "RSD address was printed without a usable port."
    if timed_out:
        return "timeout", "Tunnel process did not emit an RSD endpoint before the timeout."
    if sig:
        if sig == "SIGBUS" or "bus error" in text:
            return "sigbus", "Tunnel process crashed with SIGBUS/bus error."
        return "process_crash", f"Tunnel process exited because of {sig}."
    if "no route to host" in text or "errno 65" in text:
        return "no_route_to_host", "RemotePairing candidate was unreachable from this host."
    if "encountered a quic protocol error" in text or "quic protocol error" in text:
        return "quic_protocol_error", "QUIC reached the device but failed protocol negotiation."
    if "tcp" in text and "protocol" in text:
        return "tcp_protocol_error", "TCP tunnel failed with a protocol-level error."
    if "protocol error" in text:
        return "generic_protocol_error", "Tunnel failed with a protocol-level error."
    if "no such device" in text or "device is not connected" in text or "device not connected" in text:
        return "device_not_connected", "pymobiledevice3 did not find the target device."
    if "remotepairing" in text and ("not found" in text or "no service" in text):
        return "no_tunnel_service", "RemotePairing tunnel service was not available."
    if "permission" in text or "operation not permitted" in text or "administrator" in text or "root" in text:
        return "permission_required", "Host permissions prevented tunnel setup."
    if not output.strip():
        return "parse_failure", "Tunnel process exited without printing an RSD endpoint or diagnostic output."
    return "unknown", concise(output, 300) or "Tunnel failed for an unknown reason."


def parse_json_array_or_object(text: str) -> Any:
    payload = (text or "").strip()
    if not payload:
        return None
    return json.loads(payload)


def parse_rsd_endpoint(line: str, current_address: str | None = None, current_port: int | None = None) -> tuple[str | None, int | None]:
    address, port = current_address, current_port
    m = re.search(r"RSD Address:\s+(\S+)", line, re.IGNORECASE)
    if m:
        address = m.group(1)
    m = re.search(r"RSD Port:\s+(\d+)", line, re.IGNORECASE)
    if m:
        port = int(m.group(1))
    m = re.search(r"--rsd\s+(\S+)\s+(\d+)", line)
    if m:
        address, port = m.group(1), int(m.group(2))
    m = re.search(r"^\s*(\S+)\s+(\d+)\s*$", line)
    if m:
        address, port = m.group(1), int(m.group(2))
    return address, port


def start_tunnel_process(
    runner: Runner,
    args: list[str],
    timeout_s: float = 35.0,
    protocol: str | None = None,
    candidate: dict[str, Any] | None = None,
) -> tuple[subprocess.Popen | None, dict[str, Any]]:
    started_at = time.time()
    command = [str(part) for part in args]
    diagnostics = subprocess_diagnostics(command, protocol=protocol, candidate=candidate)
    proc = runner.popen(command)
    q: queue.Queue[str] = queue.Queue()
    all_output: list[str] = []

    def _read() -> None:
        if not proc.stdout:
            return
        for line in proc.stdout:
            q.put(line)

    threading.Thread(target=_read, daemon=True).start()
    deadline = time.monotonic() + timeout_s
    address: str | None = None
    port: int | None = None
    while time.monotonic() < deadline:
        try:
            line = q.get(timeout=0.4)
        except queue.Empty:
            if proc.poll() is not None:
                break
            continue
        all_output.append(line.rstrip())
        address, port = parse_rsd_endpoint(line, address, port)
        if address and port:
            completed_at = time.time()
            return proc, {
                "ok": True,
                "command": command,
                "diagnostics": diagnostics,
                "protocol": protocol,
                "candidate": candidate,
                "pid": proc.pid,
                "address": address,
                "port": port,
                "returncode": None,
                "terminating_signal": None,
                "timed_out": False,
                "process_state": "running" if proc.poll() is None else f"exited:{proc.returncode}",
                "stdout_tail": tail_text(all_output),
                "stderr_tail": "",
                "failure_class": None,
                "failure_message": None,
                "started_at": started_at,
                "completed_at": completed_at,
                "latency_s": max(0.0, completed_at - started_at),
            }

    returncode = proc.poll()
    if returncode is not None:
        time.sleep(0.05)
    timed_out = returncode is None
    if returncode is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
        returncode = proc.poll()
    while True:
        try:
            line = q.get_nowait()
        except queue.Empty:
            break
        all_output.append(line.rstrip())
        address, port = parse_rsd_endpoint(line, address, port)
    completed_at = time.time()
    output = "\n".join(all_output)
    failure_class, failure_message = classify_tunnel_failure(output, returncode, timed_out, address, port)
    sig = terminating_signal(returncode, output)
    return None, {
        "ok": False,
        "command": command,
        "diagnostics": diagnostics,
        "protocol": protocol,
        "candidate": candidate,
        "pid": getattr(proc, "pid", None),
        "address": None,
        "port": None,
        "returncode": returncode,
        "terminating_signal": sig,
        "timed_out": timed_out,
        "started_at": started_at,
        "completed_at": completed_at,
        "latency_s": max(0.0, completed_at - started_at),
        "process_state": "timed_out" if timed_out else f"exited:{returncode}",
        "stdout_tail": tail_text(all_output),
        "stderr_tail": "",
        "failure_class": failure_class,
        "failure_message": failure_message,
    }
