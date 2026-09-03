#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
IOS_DIR = ROOT / "ios"
IOS_PROJECT = IOS_DIR / "IOSSimOnDevicePOC.xcodeproj"
DERIVED_DATA = IOS_DIR / ".build" / "DerivedData"
LOG_DIR = ROOT / ".build" / "iossim" / "logs"
STATE_DIR = ROOT / ".build" / "iossim" / "state"
LOCAL_ENV = ROOT / ".iossim.local.env"
PINNED_IDEVICE_COMMIT = "c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5"
REQUIRED_SCHEMES = {"IOSSimOnDevicePOC", "AppleXCUILocationControl"}
MIN_MACOS = (13, 0, 0)
MIN_XCODE = (15, 0, 0)
MIN_NODE = (20, 0, 0)
MIN_PYTHON = (3, 11, 0)


SENSITIVE_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----", re.I | re.S),
    re.compile(r"\b[A-Fa-f0-9]{32,}\b"),
    re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"),
    re.compile(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})"),
    re.compile(r"(?i)(password|token|secret|private[_ -]?key|psk|auth[_ -]?blob)\s*[:=]\s*\S+"),
]


def redact(text: str) -> str:
    redacted = text
    redacted = SENSITIVE_PATTERNS[0].sub("[REDACTED_PRIVATE_KEY]", redacted)
    redacted = SENSITIVE_PATTERNS[1].sub("[REDACTED_HEX]", redacted)
    redacted = SENSITIVE_PATTERNS[2].sub("[REDACTED_UUID]", redacted)
    redacted = SENSITIVE_PATTERNS[3].sub("[REDACTED_EMAIL]", redacted)
    redacted = SENSITIVE_PATTERNS[4].sub(lambda m: f"{m.group(1).split()[0]}=[REDACTED]", redacted)
    return redacted


def now_stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def parse_version(text: str) -> tuple[int, int, int] | None:
    match = re.search(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?", text)
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())  # type: ignore[return-value]


def version_at_least(found: tuple[int, int, int] | None, minimum: tuple[int, int, int]) -> bool:
    return found is not None and found >= minimum


def short_identifier(value: str | None) -> str:
    if not value:
        return "unknown"
    if len(value) <= 10:
        return value
    return f"{value[:6]}...{value[-4:]}"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_local_env() -> dict[str, str]:
    values: dict[str, str] = {}
    if not LOCAL_ENV.exists():
        return values
    for raw in LOCAL_ENV.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'\"")
        if key:
            values[key] = value
    return values


def merged_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    env = os.environ.copy()
    env.update(load_local_env())
    rust_path = discover_rust_toolchain_bin()
    if rust_path:
        current = env.get("PATH", "")
        parts = current.split(os.pathsep) if current else []
        if str(rust_path) not in parts:
            env["PATH"] = str(rust_path) + os.pathsep + current
    if extra:
        env.update(extra)
    return env


@dataclass
class CommandResult:
    code: int
    stdout: str
    stderr: str
    log_path: Path


class CommandError(RuntimeError):
    def __init__(self, name: str, result: CommandResult):
        self.name = name
        self.result = result
        super().__init__(f"{name} failed with exit code {result.code}")


class Runner:
    def __init__(self, verbose: bool = False, log_commands: bool = True):
        self.verbose = verbose
        self.log_commands = log_commands
        if log_commands:
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            STATE_DIR.mkdir(parents=True, exist_ok=True)

    def run(
        self,
        name: str,
        args: list[str],
        cwd: Path = ROOT,
        env: dict[str, str] | None = None,
        check: bool = True,
        input_text: str | None = None,
    ) -> CommandResult:
        log_path = LOG_DIR / f"{now_stamp()}-{safe_name(name)}.log"
        if self.verbose:
            print(f"[RUN] {name}")
        proc = subprocess.run(
            args,
            cwd=str(cwd),
            env=env or merged_env(),
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout = redact(proc.stdout or "")
        stderr = redact(proc.stderr or "")
        if self.log_commands:
            log_path.write_text(
                "\n".join(
                    [
                        f"$ {redact(' '.join(args))}",
                        f"cwd: {cwd}",
                        f"exit: {proc.returncode}",
                        "",
                        "[stdout]",
                        stdout,
                        "",
                        "[stderr]",
                        stderr,
                    ]
                ),
                encoding="utf-8",
            )
        if self.verbose:
            if stdout.strip():
                print(stdout.rstrip())
            if stderr.strip():
                print(stderr.rstrip(), file=sys.stderr)
        result = CommandResult(proc.returncode, stdout, stderr, log_path)
        if check and proc.returncode != 0:
            raise CommandError(name, result)
        return result


def safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", name).strip("-")[:80] or "command"


def print_step(state: str, message: str, detail: str | None = None) -> None:
    if detail:
        print(f"[{state}] {message}: {detail}")
    else:
        print(f"[{state}] {message}")


def run_step(runner: Runner, message: str, name: str, args: list[str], cwd: Path = ROOT) -> bool:
    try:
        runner.run(name, args, cwd=cwd)
        print_step("PASS", message)
        return True
    except CommandError as exc:
        print_step("FAIL", message, f"see {exc.result.log_path}")
        hint_for_failure(name, exc.result)
        return False


def hint_for_failure(name: str, result: CommandResult) -> None:
    text = f"{result.stdout}\n{result.stderr}"
    lower = text.lower()
    if "license" in lower and "xcode" in lower:
        print_step("ACTION", "Accept the Xcode license", "open Xcode once or run sudo xcodebuild -license")
    elif "requires a development team" in lower or "development team" in lower:
        print_step("ACTION", "Configure Apple signing", "open Xcode Settings > Accounts or set IOSSIM_DEVELOPMENT_TEAM")
    elif "iphoneos sdk unavailable" in lower:
        print_step("ACTION", "Install/select full Xcode", "xcode-select must point at Xcode.app")
    elif "cargo is required" in lower or "rustc" in lower:
        print_step("ACTION", "Install Rust", "install rustup, then rerun ./iossim setup")
    else:
        tail = "\n".join((text.strip().splitlines() or [""])[-6:])
        if tail.strip():
            print(redact(tail))


@dataclass
class Check:
    state: str
    component: str
    name: str
    detail: str = ""
    action: str = ""
    required_for: str = "mac"

    def to_json(self) -> dict[str, str]:
        data = {
            "state": self.state,
            "component": self.component,
            "name": self.name,
            "detail": self.detail,
            "requiredFor": self.required_for,
        }
        if self.action:
            data["action"] = self.action
        return data


@dataclass
class DoctorReport:
    checks: list[Check] = field(default_factory=list)
    devices: list[dict[str, Any]] = field(default_factory=list)

    @property
    def actions(self) -> list[Check]:
        return [c for c in self.checks if c.state == "ACTION"]

    @property
    def failures(self) -> list[Check]:
        return [c for c in self.checks if c.state == "FAIL"]

    @property
    def mac_ready(self) -> bool:
        return not any(c.state in {"FAIL", "ACTION"} and c.required_for in {"mac", "build"} for c in self.checks)

    @property
    def device_ready(self) -> bool:
        return not any(c.state in {"FAIL", "ACTION"} and c.required_for == "device" for c in self.checks)

    @property
    def ready(self) -> bool:
        return self.mac_ready and self.device_ready

    def add(self, state: str, component: str, name: str, detail: str = "", action: str = "", required_for: str = "mac") -> None:
        self.checks.append(Check(state, component, name, detail, action, required_for))

    def to_json(self) -> dict[str, Any]:
        public_devices = [
            {key: value for key, value in device.items() if not key.startswith("_")}
            for device in self.devices
        ]
        return {
            "ready": self.ready,
            "mac": {"ready": self.mac_ready},
            "device": {
                "ready": self.device_ready,
                "connected": bool(self.devices),
                "devices": public_devices,
            },
            "actionsRequired": [c.action or c.name for c in self.actions],
            "checks": [c.to_json() for c in self.checks],
        }


def command_exists(name: str) -> str | None:
    return shutil.which(name)


def discover_rustup() -> str | None:
    for candidate in [
        shutil.which("rustup"),
        "/opt/homebrew/bin/rustup",
        "/usr/local/bin/rustup",
    ]:
        if candidate and Path(candidate).exists():
            return str(candidate)
    return None


def discover_rust_toolchain_bin() -> Path | None:
    rustup = discover_rustup()
    if rustup:
        try:
            out = subprocess.run([rustup, "which", "cargo"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if out.returncode == 0 and out.stdout.strip():
                return Path(out.stdout.strip()).parent
        except OSError:
            pass
    rustup_home = Path(os.environ.get("RUSTUP_HOME", str(Path.home() / ".rustup")))
    for candidate in sorted(rustup_home.glob("toolchains/*/bin/cargo")):
        if candidate.exists():
            return candidate.parent
    return None


def discover_tool(tool: str) -> str | None:
    found = shutil.which(tool)
    if found:
        return found
    rust_bin = discover_rust_toolchain_bin()
    if rust_bin and (rust_bin / tool).exists():
        return str(rust_bin / tool)
    return None


def find_python_for_backend() -> str | None:
    for name in ["python3.13", "python3.12", "python3.11", "python3"]:
        found = shutil.which(name)
        if not found:
            continue
        result = subprocess.run(
            [found, "-c", "import sys; print('.'.join(map(str, sys.version_info[:3])))"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0 and version_at_least(parse_version(result.stdout), MIN_PYTHON):
            return found
    return None


def xcodebuild_args(*parts: str) -> list[str]:
    args = ["xcodebuild", "-project", str(IOS_PROJECT), *parts, "-derivedDataPath", str(DERIVED_DATA)]
    team = os.environ.get("IOSSIM_DEVELOPMENT_TEAM") or load_local_env().get("IOSSIM_DEVELOPMENT_TEAM")
    if team:
        args.append(f"DEVELOPMENT_TEAM={team}")
    return args


def run_doctor(json_output: bool = False, verbose: bool = False) -> DoctorReport:
    runner = Runner(verbose=verbose, log_commands=False)
    report = DoctorReport()
    check_platform(report)
    check_xcode(report, runner)
    check_swift_and_git(report, runner)
    check_rust(report, runner)
    check_node(report, runner)
    check_python(report, runner)
    check_repo_shape(report, runner)
    check_signing(report, runner)
    check_idevice_artifacts(report, runner)
    check_devices(report, runner)
    check_manual_runtime_actions(report)
    if json_output:
        print(json.dumps(report.to_json(), indent=2, sort_keys=True))
    else:
        print_doctor(report)
    return report


def check_platform(report: DoctorReport) -> None:
    if platform.system() != "Darwin":
        report.add("FAIL", "Mac", "macOS host", platform.system(), "Use a compatible Mac.", "mac")
        return
    version = parse_version(platform.mac_ver()[0])
    state = "PASS" if version_at_least(version, MIN_MACOS) else "FAIL"
    report.add(state, "Mac", "macOS supported", platform.mac_ver()[0], "Upgrade macOS." if state == "FAIL" else "", "mac")
    machine = platform.machine()
    if machine == "arm64":
        report.add("PASS", "Mac", "Apple Silicon host", machine)
    elif machine == "x86_64":
        report.add("WARN", "Mac", "Intel Mac host", "cross-compilation should work, but current validation was on Apple Silicon")
    else:
        report.add("WARN", "Mac", "CPU architecture", machine)


def check_xcode(report: DoctorReport, runner: Runner) -> None:
    if not command_exists("xcodebuild"):
        report.add("ACTION", "Xcode", "xcodebuild", "missing", "Install Xcode from Apple and launch it once.", "build")
        return
    selected = runner.run("xcode-select", ["xcode-select", "-p"], check=False)
    if selected.code == 0:
        report.add("PASS", "Xcode", "xcode-select path", selected.stdout.strip())
    else:
        report.add("ACTION", "Xcode", "xcode-select path", "not configured", "Run sudo xcode-select -s /Applications/Xcode.app.", "build")
    version = runner.run("xcodebuild-version", ["xcodebuild", "-version"], check=False)
    parsed = parse_version(version.stdout)
    if version.code == 0 and version_at_least(parsed, MIN_XCODE):
        report.add("PASS", "Xcode", "Xcode version", version.stdout.splitlines()[0])
    elif version.code == 0:
        report.add("FAIL", "Xcode", "Xcode version", version.stdout.splitlines()[0], "Install Xcode 15 or newer.", "build")
    else:
        report.add("ACTION", "Xcode", "Xcode license/tools", "xcodebuild failed", "Open Xcode once and accept required prompts.", "build")
    sdk = runner.run("iphoneos-sdk", ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], check=False)
    if sdk.code == 0 and sdk.stdout.strip():
        report.add("PASS", "Xcode", "iphoneos SDK", sdk.stdout.strip())
    else:
        report.add("ACTION", "Xcode", "iphoneos SDK", "unavailable", "Install/select full Xcode and accept the license.", "build")


def check_swift_and_git(report: DoctorReport, runner: Runner) -> None:
    for tool in ["swift", "git"]:
        if not command_exists(tool):
            report.add("ACTION", "Tools", tool, "missing", f"Install {tool}.", "build")
            continue
        result = runner.run(f"{tool}-version", [tool, "--version"], check=False)
        first = result.stdout.splitlines()[0] if result.stdout.splitlines() else "available"
        if result.code == 0:
            report.add("PASS", "Tools", tool, first, "", "build")
        else:
            report.add("FAIL", "Tools", tool, first, f"Fix {tool} installation.", "build")


def check_rust(report: DoctorReport, runner: Runner) -> None:
    rustup = discover_rustup()
    cargo = discover_tool("cargo")
    rustc = discover_tool("rustc")
    if rustup:
        report.add("PASS", "Rust", "rustup", rustup)
    else:
        report.add("ACTION", "Rust", "rustup", "missing", "Install Rust from https://rustup.rs/.", "build")
    if cargo:
        result = runner.run("cargo-version", [cargo, "--version"], check=False)
        if result.code == 0:
            report.add("PASS", "Rust", "cargo", result.stdout.strip() or cargo, "", "build")
        else:
            report.add("FAIL", "Rust", "cargo", result.stdout.strip() or cargo, "Fix Rust installation.", "build")
    else:
        report.add("ACTION", "Rust", "cargo", "missing", "Install Rust from https://rustup.rs/.", "build")
    if rustc:
        result = runner.run("rustc-version", [rustc, "--version"], check=False)
        if result.code == 0:
            report.add("PASS", "Rust", "rustc", result.stdout.strip() or rustc, "", "build")
        else:
            report.add("FAIL", "Rust", "rustc", result.stdout.strip() or rustc, "Fix Rust installation.", "build")
    else:
        report.add("ACTION", "Rust", "rustc", "missing", "Install Rust from https://rustup.rs/.", "build")
    if rustup:
        target = runner.run("rust-targets", [rustup, "target", "list", "--installed"], check=False)
        if "aarch64-apple-ios" in target.stdout:
            report.add("PASS", "Rust", "aarch64-apple-ios target", "installed")
        else:
            report.add("ACTION", "Rust", "aarch64-apple-ios target", "missing", "Run ./iossim setup to install the Rust iOS target.", "build")


def check_node(report: DoctorReport, runner: Runner) -> None:
    if not (ROOT / "frontend" / "package.json").exists():
        report.add("SKIP", "Frontend", "Node", "frontend package not present")
        return
    node = command_exists("node")
    npm = command_exists("npm")
    if node:
        result = runner.run("node-version", [node, "--version"], check=False)
        state = "PASS" if result.code == 0 and version_at_least(parse_version(result.stdout), MIN_NODE) else "FAIL"
        report.add(state, "Frontend", "Node.js", result.stdout.strip(), "Install Node.js 20 or newer." if state == "FAIL" else "", "mac")
    else:
        report.add("ACTION", "Frontend", "Node.js", "missing", "Install Node.js 20 or newer.", "mac")
    report.add("PASS" if npm else "ACTION", "Frontend", "npm", npm or "missing", "Install Node.js 20 or newer." if not npm else "", "mac")


def check_python(report: DoctorReport, runner: Runner) -> None:
    if not (ROOT / "backend" / "requirements.txt").exists():
        report.add("SKIP", "Backend", "Python", "backend requirements not present")
        return
    py = find_python_for_backend()
    if py:
        result = runner.run("python-version", [py, "--version"], check=False)
        report.add("PASS", "Backend", "Python 3.11+", result.stdout.strip() or py, "", "mac")
    else:
        report.add("ACTION", "Backend", "Python 3.11+", "missing", "Install Python 3.11 or newer.", "mac")


def check_repo_shape(report: DoctorReport, runner: Runner) -> None:
    required_paths = [
        IOS_PROJECT / "project.pbxproj",
        IOS_DIR / "Package.swift",
        IOS_DIR / "Vendor" / "idevice" / "patches" / "0001-gate2-supplied-rsd-xctest-ffi.patch",
        IOS_DIR / "scripts" / "build_idevice_ios.sh",
        IOS_DIR / "scripts" / "verify_idevice_symbols.sh",
    ]
    for path in required_paths:
        report.add("PASS" if path.exists() else "FAIL", "Repository", path.relative_to(ROOT).as_posix(), "present" if path.exists() else "missing", "Restore repository files." if not path.exists() else "", "build")
    listed = runner.run("xcodebuild-list", ["xcodebuild", "-list", "-project", str(IOS_PROJECT)], check=False) if command_exists("xcodebuild") else None
    if listed and listed.code == 0:
        missing = sorted(s for s in REQUIRED_SCHEMES if s not in listed.stdout)
        if missing:
            report.add("FAIL", "Xcode", "required schemes", f"missing: {', '.join(missing)}", "Restore shared Xcode schemes.", "build")
        else:
            report.add("PASS", "Xcode", "required schemes", ", ".join(sorted(REQUIRED_SCHEMES)))
    else:
        report.add("SKIP", "Xcode", "required schemes", "xcodebuild unavailable")


def check_signing(report: DoctorReport, runner: Runner) -> None:
    if not command_exists("security"):
        report.add("WARN", "Signing", "codesigning identities", "security tool unavailable")
        return
    result = runner.run("codesigning-identities", ["security", "find-identity", "-v", "-p", "codesigning"], check=False)
    count = sum(1 for line in result.stdout.splitlines() if "Apple Development" in line)
    if count:
        report.add("PASS", "Signing", "Apple Development identity", f"{count} available")
    else:
        report.add("ACTION", "Signing", "Apple Development identity", "none found", "Open Xcode Settings > Accounts and sign in with your Apple ID.", "build")
    configured_team = os.environ.get("IOSSIM_DEVELOPMENT_TEAM") or load_local_env().get("IOSSIM_DEVELOPMENT_TEAM")
    if configured_team:
        report.add("PASS", "Signing", "IOSSIM_DEVELOPMENT_TEAM override", short_identifier(configured_team))
    else:
        project_team = project_development_team()
        report.add("WARN", "Signing", "development team portability", f"project default {short_identifier(project_team)}", "Set IOSSIM_DEVELOPMENT_TEAM in .iossim.local.env on other Macs if needed.", "build")


def project_development_team() -> str:
    text = (IOS_PROJECT / "project.pbxproj").read_text(encoding="utf-8", errors="ignore")
    match = re.search(r"DEVELOPMENT_TEAM = ([A-Z0-9]+);", text)
    return match.group(1) if match else "unknown"


def check_idevice_artifacts(report: DoctorReport, runner: Runner) -> None:
    source = IOS_DIR / ".build" / "idevice-src"
    lib = IOS_DIR / "Vendor" / "idevice" / "lib" / "libidevice_ffi.a"
    patch = IOS_DIR / "Vendor" / "idevice" / "patches" / "0001-gate2-supplied-rsd-xctest-ffi.patch"
    if source.exists():
        rev = runner.run("idevice-revision", ["git", "-C", str(source), "rev-parse", "--short=12", "HEAD"], check=False)
        state = "PASS" if PINNED_IDEVICE_COMMIT.startswith(rev.stdout.strip()) else "WARN"
        detail = rev.stdout.strip() if rev.stdout.strip() else "unknown"
        report.add(state, "idevice", "pinned source revision", detail, "Run ./iossim setup to restore the pinned source." if state == "WARN" else "", "build")
        reverse = runner.run("idevice-patch-state", ["git", "-C", str(source), "apply", "--reverse", "--check", str(patch)], check=False)
        if reverse.code == 0:
            report.add("PASS", "idevice", "supplied-RSD patch", "applied")
        else:
            forward = runner.run("idevice-patch-forward", ["git", "-C", str(source), "apply", "--check", str(patch)], check=False)
            if forward.code == 0:
                report.add("ACTION", "idevice", "supplied-RSD patch", "not applied", "Run ./iossim setup to apply the checked-in patch.", "build")
            else:
                report.add("FAIL", "idevice", "supplied-RSD patch", "neither applied nor cleanly applicable", "Inspect ios/.build/idevice-src.", "build")
    else:
        report.add("ACTION", "idevice", "pinned source", "missing", "Run ./iossim setup to clone the pinned idevice source.", "build")
    if lib.exists():
        report.add("PASS", "idevice", "libidevice_ffi.a", f"{lib.stat().st_size // (1024 * 1024)} MB")
        verify = runner.run("verify-idevice-symbols", [str(IOS_DIR / "scripts" / "verify_idevice_symbols.sh")], check=False)
        if verify.code == 0:
            report.add("PASS", "idevice", "required FFI symbols", "present", "", "build")
        else:
            report.add("FAIL", "idevice", "required FFI symbols", f"missing; see {verify.log_path}", "Run ./iossim setup.", "build")
    else:
        report.add("ACTION", "idevice", "libidevice_ffi.a", "missing", "Run ./iossim setup to build the ignored static library.", "build")


def check_devices(report: DoctorReport, runner: Runner) -> None:
    devices = discover_devices(runner)
    report.devices = devices
    if not devices:
        report.add("ACTION", "Device", "connected iPhone", "not detected", "Connect and unlock an iPhone, trust this Mac, then run ./iossim device.", "device")
        return
    has_ready_device = any(
        device.get("pairingState") == "paired" and device.get("developerModeStatus") == "enabled"
        for device in devices
    )
    for device in devices:
        name = device.get("name", "iPhone")
        detail = f"{name} {device.get('osVersion', 'iOS unknown')} id={device.get('identifier', 'unknown')}"
        report.add("PASS", "Device", "iPhone detected", detail, "", "device")
        pairing = device.get("pairingState")
        if pairing == "paired":
            report.add("PASS", "Device", "device trusted", "paired", "", "device")
        else:
            state = "WARN" if has_ready_device else "ACTION"
            action = "" if has_ready_device else "Unlock the iPhone and trust this Mac."
            report.add(state, "Device", "device trusted", pairing or "unknown", action, "device")
        developer = device.get("developerModeStatus")
        if developer == "enabled":
            report.add("PASS", "Device", "Developer Mode", "enabled", "", "device")
        else:
            state = "WARN" if has_ready_device else "ACTION"
            action = "" if has_ready_device else "On iPhone: Settings > Privacy & Security > Developer Mode."
            report.add(state, "Device", "Developer Mode", developer or "unknown", action, "device")
        tunnel = device.get("tunnelState")
        if tunnel == "connected":
            report.add("PASS", "Device", "CoreDevice tunnel", "connected", "", "device")
        else:
            report.add("WARN", "Device", "CoreDevice tunnel", tunnel or "unknown", "", "device")


def discover_devices(runner: Runner) -> list[dict[str, Any]]:
    if not command_exists("xcrun"):
        return []
    with tempfile.TemporaryDirectory(prefix="iossim-devices-") as tmp:
        json_path = Path(tmp) / "devices.json"
        result = runner.run(
            "devicectl-list-devices",
            ["xcrun", "devicectl", "list", "devices", "--timeout", "8", "--json-output", str(json_path), "--quiet"],
            check=False,
        )
        if result.code != 0 or not json_path.exists():
            return []
        try:
            raw = json.loads(json_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return []
    devices = []
    for item in raw.get("result", {}).get("devices", []):
        props = item.get("deviceProperties", {})
        hardware = item.get("hardwareProperties", {})
        connection = item.get("connectionProperties", {})
        if hardware.get("deviceType") != "iPhone" and hardware.get("platform") != "iOS":
            continue
        devices.append(
            {
                "name": props.get("name") or hardware.get("marketingName") or "iPhone",
                "identifier": short_identifier(item.get("identifier") or hardware.get("udid")),
                "_deviceIdentifier": item.get("identifier") or hardware.get("udid"),
                "udidRedacted": short_identifier(hardware.get("udid")),
                "osVersion": props.get("osVersionNumber"),
                "developerModeStatus": props.get("developerModeStatus"),
                "pairingState": connection.get("pairingState"),
                "tunnelState": connection.get("tunnelState"),
            }
        )
    return devices


def check_manual_runtime_actions(report: DoctorReport) -> None:
    report.add("ACTION", "Runtime", "PAIRING MATERIAL", "cannot be inspected from Mac CLI", "Import RPPairing inside IOSSim on the iPhone. Contents must never be logged or committed.", "device")
    report.add("ACTION", "Runtime", "LocalDevVPN", "external iPhone app required", "Install/launch LocalDevVPN on the iPhone and approve Apple's VPN prompt.", "device")


def print_doctor(report: DoctorReport) -> None:
    print("IOSSim Environment Check")
    print("")
    current = None
    for check in report.checks:
        if check.component != current:
            current = check.component
            print(current)
        suffix = f": {check.detail}" if check.detail else ""
        print(f"[{check.state}] {check.name}{suffix}")
        if check.state == "ACTION" and check.action:
            print(f"  ACTION: {check.action}")
    print("")
    print("Overall")
    print(f"Mac environment: {'READY' if report.mac_ready else 'NOT READY'}")
    print(f"iPhone provisioning: {'READY' if report.device_ready else 'ACTION REQUIRED'}")
    if report.actions:
        print(f"{len(report.actions)} action(s) required.")


def ensure_backend(runner: Runner) -> bool:
    requirements = [ROOT / "backend" / "requirements.txt"]
    dev_requirements = ROOT / "backend" / "requirements-dev.txt"
    if dev_requirements.exists():
        requirements.append(dev_requirements)
    if not requirements[0].exists():
        print_step("SKIP", "Backend dependencies", "backend requirements not present")
        return True
    py = find_python_for_backend()
    if not py:
        print_step("ACTION", "Python 3.11+ required", "install Python 3.11 or newer")
        return False
    venv_python = ROOT / "backend" / ".venv" / "bin" / "python"
    if not venv_python.exists():
        if not run_step(runner, "Create backend virtualenv", "backend-venv", [py, "-m", "venv", str(ROOT / "backend" / ".venv")]):
            return False
    digest = hashlib.sha256()
    for path in requirements:
        digest.update(path.read_bytes())
    marker = STATE_DIR / "backend-requirements.sha256"
    if marker.exists() and marker.read_text().strip() == digest.hexdigest():
        print_step("PASS", "Backend dependencies", "already current")
        return True
    if not run_step(runner, "Upgrade backend pip", "backend-pip-upgrade", [str(venv_python), "-m", "pip", "install", "--upgrade", "pip"]):
        return False
    for path in requirements:
        if not run_step(runner, f"Install {path.relative_to(ROOT)}", f"pip-install-{path.name}", [str(venv_python), "-m", "pip", "install", "-r", str(path)]):
            return False
    marker.write_text(digest.hexdigest(), encoding="utf-8")
    return True


def ensure_frontend(runner: Runner) -> bool:
    package_json = ROOT / "frontend" / "package.json"
    lock = ROOT / "frontend" / "package-lock.json"
    if not package_json.exists():
        print_step("SKIP", "Frontend dependencies", "frontend package not present")
        return True
    if not command_exists("npm"):
        print_step("ACTION", "npm required", "install Node.js 20 or newer")
        return False
    marker = STATE_DIR / "frontend-package-lock.sha256"
    digest = sha256_file(lock) if lock.exists() else sha256_file(package_json)
    if (ROOT / "frontend" / "node_modules").exists() and marker.exists() and marker.read_text().strip() == digest:
        print_step("PASS", "Frontend dependencies", "already current")
        return True
    command = ["npm", "ci"] if lock.exists() else ["npm", "install"]
    if not run_step(runner, "Install frontend dependencies", "frontend-install", command, cwd=ROOT / "frontend"):
        return False
    marker.write_text(digest, encoding="utf-8")
    return True


def ensure_rust(runner: Runner) -> bool:
    rustup = discover_rustup()
    if not rustup:
        print_step("ACTION", "Rust toolchain required", "install rustup from https://rustup.rs/")
        return False
    ok = True
    ok &= run_step(runner, "Install Rust iOS target", "rust-target-ios", [rustup, "target", "add", "aarch64-apple-ios"])
    component = runner.run("rust-llvm-tools", [rustup, "component", "add", "llvm-tools-preview"], check=False)
    if component.code == 0:
        print_step("PASS", "Install Rust llvm-tools-preview")
    else:
        print_step("WARN", "Install Rust llvm-tools-preview", f"not available; symbol verification can fall back. See {component.log_path}")
    return bool(ok)


def build_idevice(runner: Runner) -> bool:
    return run_step(runner, "Build pinned idevice FFI", "build-idevice-ios", [str(IOS_DIR / "scripts" / "build_idevice_ios.sh")])


def verify_idevice(runner: Runner) -> bool:
    return run_step(runner, "Verify idevice FFI symbols", "verify-idevice-symbols", [str(IOS_DIR / "scripts" / "verify_idevice_symbols.sh")])


def build_ios(runner: Runner) -> bool:
    ok = True
    ok &= run_step(runner, "Swift package build", "swift-build", ["swift", "build", "--package-path", str(IOS_DIR)])
    ok &= run_step(
        runner,
        "Generic iOS Debug app build",
        "xcodebuild-iossim",
        xcodebuild_args("-scheme", "IOSSimOnDevicePOC", "-configuration", "Debug", "-destination", "generic/platform=iOS", "build"),
    )
    ok &= run_step(
        runner,
        "Internal app/Witness/XCUILocation runner build",
        "xcodebuild-xcuilocation-runner",
        xcodebuild_args("-scheme", "AppleXCUILocationControl", "-configuration", "Debug", "-destination", "generic/platform=iOS", "build-for-testing"),
    )
    return bool(ok)


def command_setup(args: argparse.Namespace) -> int:
    runner = Runner(verbose=args.verbose)
    print("IOSSim Setup")
    print("")
    report = run_doctor(json_output=False, verbose=args.verbose)
    print("")
    ok = True
    ok &= ensure_backend(runner)
    ok &= ensure_frontend(runner)
    ok &= ensure_rust(runner)
    ok &= build_idevice(runner)
    ok &= verify_idevice(runner)
    ok &= build_ios(runner)
    print("")
    print("Manual Apple/device actions that remain:")
    print("1. Install Xcode from Apple, launch it once, and accept any license prompts.")
    print("2. Sign in to Xcode and ensure an Apple Development signing identity is available.")
    print("3. Connect and unlock the iPhone, then trust this Mac.")
    print("4. Enable Developer Mode on the iPhone.")
    print("5. Install and approve LocalDevVPN on the iPhone.")
    print("6. Import RPPairing inside IOSSim. Pairing contents are never printed by this CLI.")
    print("")
    print("Final doctor:")
    run_doctor(json_output=False, verbose=args.verbose)
    print("")
    if ok:
        print("IOSSim setup complete.")
        return 0
    print("IOSSim setup did not complete. See the actions/failures above.")
    return 1


def command_build(args: argparse.Namespace) -> int:
    runner = Runner(verbose=args.verbose)
    print("IOSSim Build")
    print("")
    ok = True
    ok &= build_idevice(runner)
    ok &= verify_idevice(runner)
    ok &= build_ios(runner)
    print("")
    print(f"Overall: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def package_has_script(package_json: Path, script: str) -> bool:
    try:
        data = json.loads(package_json.read_text(encoding="utf-8"))
    except Exception:
        return False
    return script in data.get("scripts", {})


def command_test(args: argparse.Namespace) -> int:
    runner = Runner(verbose=args.verbose)
    print("IOSSim Test")
    print("")
    ok = True
    ok &= run_step(runner, "POCUnitChecks", "swift-run-pocunitchecks", ["swift", "run", "--package-path", str(IOS_DIR), "POCUnitChecks"])
    ok &= build_idevice(runner)
    ok &= verify_idevice(runner)
    cargo = discover_tool("cargo")
    source = IOS_DIR / ".build" / "idevice-src"
    if cargo and (source / "Cargo.toml").exists():
        ok &= run_step(runner, "cargo fmt", "cargo-fmt", [cargo, "fmt", "--all", "--check"], cwd=source)
        ok &= run_step(runner, "cargo check", "cargo-check", [cargo, "check", "--workspace"], cwd=source)
        ok &= run_step(runner, "cargo test", "cargo-test", [cargo, "test", "--workspace", "--lib", "--bins"], cwd=source)
    else:
        print_step("NOT APPLICABLE", "idevice cargo checks", "pinned source or cargo unavailable")
        ok = False
    if package_has_script(ROOT / "frontend" / "package.json", "test"):
        ok &= ensure_frontend(runner)
        ok &= run_step(runner, "Frontend tests", "frontend-test", ["npm", "test"], cwd=ROOT / "frontend")
    else:
        print_step("NOT APPLICABLE", "Frontend tests", "no test script")
    if list((ROOT / "backend").glob("test_*.py")):
        ok &= ensure_backend(runner)
        venv_python = ROOT / "backend" / ".venv" / "bin" / "python"
        ok &= run_step(runner, "Backend tests", "backend-pytest", [str(venv_python), "-m", "pytest", "backend"])
    else:
        print_step("NOT APPLICABLE", "Backend tests", "no backend tests")
    print("")
    print(f"Overall: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def built_app_paths() -> list[Path]:
    product = DERIVED_DATA / "Build" / "Products" / "Debug-iphoneos"
    return [
        product / "IOSSim DVT POC.app",
        product / "IOSSimLocationWitness.app",
        product / "IOSSimLocationControlUITests-Runner.app",
    ]


def command_device(args: argparse.Namespace) -> int:
    runner = Runner(verbose=args.verbose)
    print("IOSSim Device")
    print("")
    report = run_doctor(json_output=False, verbose=args.verbose)
    devices = report.devices
    if not devices:
        print_step("ACTION", "No iPhone detected", "connect/unlock/trust an iPhone, then rerun ./iossim device")
        return 2
    ready_devices = [
        d for d in devices
        if d.get("pairingState") == "paired" and d.get("developerModeStatus") == "enabled"
    ]
    if not ready_devices:
        print_step("ACTION", "iPhone is not ready", "trust this Mac and enable Developer Mode before provisioning")
        return 2
    ok = True
    ok &= build_idevice(runner)
    ok &= verify_idevice(runner)
    ok &= build_ios(runner)
    if not ok:
        print_step("FAIL", "Build required before install", "fix build failures above")
        return 1
    device = ready_devices[0]
    raw_id = device.get("_deviceIdentifier")
    installed = 0
    for app in built_app_paths():
        if not app.exists():
            print_step("WARN", "App artifact missing", app.name)
            continue
        result = runner.run(
            f"install-{app.name}",
            ["xcrun", "devicectl", "device", "install", "app", "--device", str(raw_id), str(app), "--timeout", "60", "--quiet"],
            check=False,
        )
        if result.code == 0:
            print_step("PASS", f"Installed {app.name}")
            installed += 1
        else:
            print_step("FAIL", f"Install {app.name}", f"see {result.log_path}")
            hint_for_failure(f"install-{app.name}", result)
            ok = False
    print_step("ACTION", "LocalDevVPN", "install/launch on iPhone and approve VPN configuration")
    print_step("ACTION", "PAIRING MATERIAL", "import RPPairing inside IOSSim; contents are not inspected or logged here")
    print("")
    print(f"Installed artifacts: {installed}")
    print(f"Overall: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def command_info(args: argparse.Namespace) -> int:
    matrix = [
        ("macOS", "yes", "system", "13.0+", "no", "compatible Mac", "./iossim doctor"),
        ("Xcode", "yes", "Apple", "15.0+", "no", "install/sign in/accept license", "./iossim doctor"),
        ("SwiftPM package", "yes", "ios/Package.swift", "Swift tools 5.9", "n/a", "none", "swift build --package-path ios"),
        ("iOS app project", "yes", "ios/IOSSimOnDevicePOC.xcodeproj", "iOS 17 target", "n/a", "Apple signing", "./iossim build"),
        ("idevice FFI", "yes", "jkcoxson/idevice pinned commit", PINNED_IDEVICE_COMMIT[:12], "yes", "Rust required", "./iossim build"),
        ("Rust iOS target", "yes", "rustup", "aarch64-apple-ios", "yes", "install rustup", "./iossim doctor"),
        ("Frontend engineering UI", "yes on main", "frontend/package.json", "Node 20+", "yes", "install Node", "npm test"),
        ("Backend engineering API", "yes on main", "backend/requirements.txt", "Python 3.11+", "yes", "install Python", "pytest backend"),
        ("LocalDevVPN", "runtime", "external iPhone app", "current external app", "no", "install/approve on iPhone", "in-app diagnostics"),
        ("RPPairing", "runtime", "iPhone app Keychain", "valid plist", "no", "import in IOSSim", "in-app diagnostics"),
    ]
    print("IOSSim Dependency Matrix")
    print("")
    print("COMPONENT | REQUIRED | SOURCE | MINIMUM VERSION | AUTO-INSTALLABLE | USER ACTION | VALIDATION")
    for row in matrix:
        print(" | ".join(row))
    return 0


def command_clean(args: argparse.Namespace) -> int:
    if not args.generated:
        print("Clean is conservative. Use ./iossim clean --generated to remove CLI-owned generated state.")
        return 0
    for path in [STATE_DIR]:
        if path.exists():
            shutil.rmtree(path)
            print_step("PASS", "Removed generated state", str(path.relative_to(ROOT)))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="./iossim", description="IOSSim macOS bootstrap CLI")
    sub = parser.add_subparsers(dest="command")
    for name, help_text in [
        ("help", "show this help"),
        ("setup", "configure local dependencies and build IOSSim"),
        ("doctor", "read-only environment check"),
        ("build", "build current iPhone/on-device components"),
        ("test", "run current main validation suite"),
        ("device", "build and install internal device-side components"),
        ("info", "print dependency matrix"),
        ("clean", "remove CLI-owned generated state"),
    ]:
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--verbose", action="store_true", help="print detailed command output")
        if name == "doctor":
            p.add_argument("--json", action="store_true", help="emit machine-readable status")
        if name == "clean":
            p.add_argument("--generated", action="store_true", help="remove CLI-owned generated state")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command or args.command == "help":
        parser.print_help()
        return 0
    if args.command == "doctor":
        run_doctor(json_output=args.json, verbose=args.verbose)
        return 0
    if args.command == "setup":
        return command_setup(args)
    if args.command == "build":
        return command_build(args)
    if args.command == "test":
        return command_test(args)
    if args.command == "device":
        return command_device(args)
    if args.command == "info":
        return command_info(args)
    if args.command == "clean":
        return command_clean(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
