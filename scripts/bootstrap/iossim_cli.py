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
MAC_DIR = ROOT / "macos"
RELEASE_CONFIG_PATH = ROOT / "config" / "release.json"
RELEASE_OUTPUT_DIR = ROOT / ".build" / "iossim" / "release"
LOCAL_RELEASE_OUTPUT_DIR = ROOT / ".build" / "iossim" / "local-release"
MAC_APP_ENTITLEMENTS = MAC_DIR / "Release" / "IOSSim.entitlements"
MAC_HELPER_ENTITLEMENTS = MAC_DIR / "Release" / "IOSSimProvisioner.entitlements"
MAC_ICON_SOURCE = MAC_DIR / "Resources" / "IOSSimIcon.png"
IDEVICE_LICENSE_SOURCE = IOS_DIR / "Vendor" / "idevice" / "LICENSE.txt"
IOS_PROJECT = IOS_DIR / "IOSSimOnDevicePOC.xcodeproj"
DERIVED_DATA = IOS_DIR / ".build" / "DerivedData"
MAC_APP_PATH = ROOT / ".build" / "iossim" / "mac" / "IOSSim.app"
SELF_CONTAINED_APP_PATH = ROOT / ".build" / "iossim" / "self-contained" / "IOSSim.app"
LOG_DIR = ROOT / ".build" / "iossim" / "logs"
STATE_DIR = ROOT / ".build" / "iossim" / "state"
LOCAL_ENV = ROOT / ".iossim.local.env"
PINNED_IDEVICE_COMMIT = "c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5"
REQUIRED_SCHEMES = {"IOSSimOnDevicePOC", "AppleXCUILocationControl"}
MIN_MACOS = (13, 0, 0)
MIN_XCODE = (15, 0, 0)
MIN_NODE = (20, 0, 0)
MIN_PYTHON = (3, 11, 0)
HELPER_SCHEMA_VERSION = 1


@dataclass(frozen=True)
class ReleaseConfig:
    product_name: str
    bundle_identifier: str
    short_version: str
    build_number: str
    minimum_macos: str
    variant: str
    architectures: tuple[str, ...]


def load_release_config() -> ReleaseConfig:
    try:
        raw = json.loads(RELEASE_CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError(f"invalid release configuration: {exc}") from exc
    required = {
        "productName", "bundleIdentifier", "shortVersion", "buildNumber",
        "minimumMacOS", "variant", "architectures",
    }
    missing = sorted(required - raw.keys())
    if missing:
        raise RuntimeError(f"release configuration is missing: {', '.join(missing)}")
    version = str(raw["shortVersion"])
    build = str(raw["buildNumber"])
    architectures = tuple(str(item) for item in raw["architectures"])
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise RuntimeError("shortVersion must be semantic version form X.Y.Z")
    if not re.fullmatch(r"[1-9]\d*", build):
        raise RuntimeError("buildNumber must be a positive integer")
    if raw["variant"] != "PRODUCTION":
        raise RuntimeError("release variant must be PRODUCTION")
    if not architectures or any(item not in {"arm64", "x86_64"} for item in architectures):
        raise RuntimeError("release architectures must contain arm64 and/or x86_64")
    return ReleaseConfig(
        product_name=str(raw["productName"]),
        bundle_identifier=str(raw["bundleIdentifier"]),
        short_version=version,
        build_number=build,
        minimum_macos=str(raw["minimumMacOS"]),
        variant=str(raw["variant"]),
        architectures=architectures,
    )


RELEASE_CONFIG = load_release_config()
MAC_VERSION = RELEASE_CONFIG.short_version
MAC_BUILD_NUMBER = RELEASE_CONFIG.build_number
PROTECTED_BUNDLE_IDS = {
    "iosMain": "com.iossim.on-device-dvt-poc",
    "locationWitness": "com.iossim.location-witness",
    "locationControlRunner": "com.iossim.location-control-uitests.xctrunner",
}


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


def sha256_tree(path: Path) -> str:
    h = hashlib.sha256()
    files: list[Path] = []
    for root, dirs, names in os.walk(path):
        dirs[:] = [name for name in dirs if not name.startswith(".")]
        for name in names:
            if name.startswith("."):
                continue
            files.append(Path(root) / name)
    for file in sorted(files):
        relative = file.relative_to(path).as_posix()
        h.update(relative.encode("utf-8"))
        h.update(b"\0")
        if file.is_symlink():
            h.update(b"symlink")
            h.update(b"\0")
            h.update(os.readlink(file).encode("utf-8"))
        else:
            with file.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                    h.update(chunk)
        h.update(b"\0")
    return h.hexdigest()


def sha256_path(path: Path) -> str:
    return sha256_tree(path) if path.is_dir() else sha256_file(path)


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


def build_ios(
    runner: Runner,
    configuration: str = "Debug",
    packaged: bool = False,
    signed_for_device: bool = False,
) -> bool:
    ok = True
    ok &= run_step(runner, "Swift package build", "swift-build", ["swift", "build", "--package-path", str(IOS_DIR)])
    build_settings: list[str] = [] if signed_for_device else [
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
    ]
    if packaged:
        build_settings += [
            "DEBUG_INFORMATION_FORMAT=",
            "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
            "SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO",
            f"OTHER_SWIFT_FLAGS=$(inherited) -enable-experimental-concise-pound-file -file-prefix-map {ROOT}=IOSSim -debug-prefix-map {ROOT}=IOSSim -file-compilation-dir IOSSim",
            "COPY_PHASE_STRIP=YES",
            "STRIP_INSTALLED_PRODUCT=YES",
            "DEPLOYMENT_POSTPROCESSING=YES",
        ]
    ok &= run_step(
        runner,
        f"Generic iOS {configuration} app build",
        f"xcodebuild-iossim-{configuration.lower()}",
        xcodebuild_args(
            "-scheme",
            "IOSSimOnDevicePOC",
            "-configuration",
            configuration,
            "-destination",
            "generic/platform=iOS",
            *(["clean"] if packaged else []),
            "build",
            *build_settings,
        ),
    )
    ok &= run_step(
        runner,
        "Internal app/Witness/XCUILocation runner build",
        f"xcodebuild-xcuilocation-runner-{configuration.lower()}",
        xcodebuild_args(
            "-scheme",
            "AppleXCUILocationControl",
            "-configuration",
            configuration,
            "-destination",
            "generic/platform=iOS",
            *(["clean"] if packaged else []),
            "build-for-testing",
            *build_settings,
        ),
    )
    return bool(ok)


def build_mac_app(runner: Runner) -> bool:
    script = MAC_DIR / "scripts" / "build_app.sh"
    if not script.exists():
        print_step("FAIL", "IOSSim Mac app", "macos/scripts/build_app.sh missing")
        return False
    return run_step(runner, "IOSSim Mac app", "build-mac-app", [str(script)])


def test_mac_app(runner: Runner) -> bool:
    if not (MAC_DIR / "Package.swift").exists():
        print_step("FAIL", "Mac tests", "macos/Package.swift missing")
        return False
    return run_step(runner, "Mac tests", "mac-swift-test", ["swift", "test", "--package-path", str(MAC_DIR)])


def check_bundle_identifiers(runner: Runner) -> bool:
    script = ROOT / "scripts" / "checks" / "check_bundle_identifiers.py"
    if not script.exists():
        print_step("FAIL", "Bundle identifier inventory", "scripts/checks/check_bundle_identifiers.py missing")
        return False
    return run_step(runner, "Bundle identifier inventory", "bundle-identifier-check", [sys.executable, str(script)])


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
    ok &= build_mac_app(runner)
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
    ok &= check_bundle_identifiers(runner)
    ok &= run_step(runner, "POCUnitChecks", "swift-run-pocunitchecks", ["swift", "run", "--package-path", str(IOS_DIR), "POCUnitChecks"])
    ok &= test_mac_app(runner)
    ok &= build_mac_app(runner)
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


def built_app_paths(configuration: str = "Debug") -> list[Path]:
    product = DERIVED_DATA / "Build" / "Products" / f"{configuration}-iphoneos"
    return [
        product / "IOSSim DVT POC.app",
        product / "IOSSimLocationWitness.app",
        product / "IOSSimLocationControlUITests-Runner.app",
    ]


def bundled_artifact_specs(configuration: str = "Release") -> list[tuple[str, str, Path]]:
    apps = built_app_paths(configuration)
    return [
        ("iosMain", PROTECTED_BUNDLE_IDS["iosMain"], apps[0]),
        ("locationControlRunner", PROTECTED_BUNDLE_IDS["locationControlRunner"], apps[2]),
    ]


def read_bundle_info(app: Path) -> dict[str, Any]:
    info = app / "Info.plist"
    if not info.exists():
        raise RuntimeError(f"{app} is missing Info.plist")
    with info.open("rb") as fh:
        return plistlib.load(fh)


def replace_bytes_same_length(data: bytes, needle: bytes, replacement_text: str) -> bytes:
    if needle not in data:
        return data
    replacement = replacement_text.encode("utf-8")
    if len(replacement) > len(needle):
        replacement = replacement[: len(needle)]
    replacement = replacement.ljust(len(needle), b"_")
    return data.replace(needle, replacement)


def sanitize_packaged_artifact_paths(path: Path) -> int:
    replacements = [
        (str(ROOT).encode("utf-8"), "IOSSimSourceRoot"),
        (str(ROOT.parent).encode("utf-8"), "IOSSimSourceParent"),
        (str(Path.home()).encode("utf-8"), "IOSSimHome"),
    ]
    changed = 0
    for file in path.rglob("*"):
        if not file.is_file() or file.is_symlink():
            continue
        try:
            data = file.read_bytes()
        except OSError:
            continue
        updated = data
        for needle, replacement in replacements:
            updated = replace_bytes_same_length(updated, needle, replacement)
        if updated != data:
            file.write_bytes(updated)
            changed += 1
    return changed


def resign_ios_artifact(runner: Runner, app: Path) -> bool:
    identity = "-"
    signables: list[Path] = []
    for child in app.rglob("*"):
        if child.suffix in {".framework", ".xctest"} or child.suffix == ".dylib":
            signables.append(child)
    signables.append(app)
    ok = True
    for target in sorted(signables, key=lambda item: len(item.parts), reverse=True):
        if not target.exists():
            continue
        ok &= run_step(
            runner,
            f"Re-sign {target.name}",
            f"resign-ios-{safe_name(target.name)}",
            [
                "codesign",
                "--force",
                "--sign",
                identity,
                "--timestamp=none",
                "--preserve-metadata=identifier,entitlements,flags",
                "--generate-entitlement-der",
                str(target),
            ],
        )
    ok &= run_step(
        runner,
        f"Verify {app.name} signature",
        f"verify-ios-signature-{safe_name(app.name)}",
        ["codesign", "--verify", "--deep", "--strict", str(app)],
    )
    return bool(ok)


def source_commit() -> str:
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def source_dirty() -> bool:
    result = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return bool(result.stdout.strip()) if result.returncode == 0 else True


def build_self_contained_macos_products(runner: Runner) -> bool:
    args = [
        "swift",
        "build",
        "--package-path",
        str(MAC_DIR),
        "-c",
        "release",
        "-Xswiftc",
        "-D",
        "-Xswiftc",
        "IOSSIM_BUNDLED_ENGINE",
    ]
    ok = True
    ok &= run_step(runner, "Self-contained Mac GUI", "swift-build-mac-bundled", args + ["--product", "IOSSimMac"])
    ok &= run_step(runner, "Compiled provisioning helper", "swift-build-provisioner", args + ["--product", "IOSSimProvisioner"])
    return bool(ok)


def macos_bin_path(runner: Runner) -> Path:
    result = runner.run(
        "swift-show-mac-bin-path",
        ["swift", "build", "--package-path", str(MAC_DIR), "-c", "release", "--show-bin-path"],
    )
    return Path(result.stdout.strip())


def build_universal_macos_products(runner: Runner) -> Path:
    intermediates = RELEASE_OUTPUT_DIR / "intermediates"
    architecture_products: dict[str, Path] = {}
    sdk = subprocess.run(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if sdk.returncode != 0:
        raise RuntimeError("the macOS SDK could not be resolved with xcrun")
    for architecture in RELEASE_CONFIG.architectures:
        scratch = intermediates / f"macos-{architecture}"
        triple = f"{architecture}-apple-macosx{RELEASE_CONFIG.minimum_macos}"
        base = [
            "swift", "build",
            "--package-path", str(MAC_DIR),
            "--scratch-path", str(scratch),
            "--configuration", "release",
            "--triple", triple,
            "--sdk", sdk.stdout.strip(),
            "-Xswiftc", "-D", "-Xswiftc", "IOSSIM_BUNDLED_ENGINE",
        ]
        for product in ["IOSSimMac", "IOSSimProvisioner"]:
            result = runner.run(
                f"swift-build-{product}-{architecture}",
                base + ["--product", product],
                check=False,
            )
            if result.code != 0:
                raise CommandError(f"swift-build-{product}-{architecture}", result)
        bin_result = runner.run(
            f"swift-bin-path-{architecture}",
            base + ["--show-bin-path"],
        )
        architecture_products[architecture] = Path(bin_result.stdout.strip())

    universal = intermediates / "macos-universal"
    universal.mkdir(parents=True, exist_ok=True)
    for product in ["IOSSimMac", "IOSSimProvisioner"]:
        inputs = [str(architecture_products[architecture] / product) for architecture in RELEASE_CONFIG.architectures]
        if len(inputs) == 1:
            shutil.copy2(inputs[0], universal / product)
        else:
            runner.run(
                f"lipo-{product}",
                ["/usr/bin/lipo", "-create", *inputs, "-output", str(universal / product)],
            )
        os.chmod(universal / product, 0o755)
    return universal


def build_app_icon(runner: Runner, resources_dir: Path) -> None:
    if not MAC_ICON_SOURCE.is_file():
        raise RuntimeError(f"Mac app icon source is missing: {MAC_ICON_SOURCE}")
    with tempfile.TemporaryDirectory(prefix="iossim-icon-") as temporary:
        iconset = Path(temporary) / "IOSSim.iconset"
        iconset.mkdir()
        sizes = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for size, name in sizes:
            runner.run(
                f"icon-{name}",
                ["/usr/bin/sips", "-z", str(size), str(size), str(MAC_ICON_SOURCE), "--out", str(iconset / name)],
            )
        runner.run(
            "iconutil-iossim",
            ["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(resources_dir / "IOSSim.icns")],
        )


def write_app_info_plist(contents_dir: Path) -> None:
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": RELEASE_CONFIG.product_name,
        "CFBundleExecutable": RELEASE_CONFIG.product_name,
        "CFBundleIconFile": "IOSSim.icns",
        "CFBundleIdentifier": RELEASE_CONFIG.bundle_identifier,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": RELEASE_CONFIG.product_name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": MAC_VERSION,
        "CFBundleVersion": MAC_BUILD_NUMBER,
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "LSMinimumSystemVersion": RELEASE_CONFIG.minimum_macos,
        "NSHighResolutionCapable": True,
    }
    with (contents_dir / "Info.plist").open("wb") as fh:
        plistlib.dump(plist, fh)


def assemble_self_contained_app(
    runner: Runner,
    ios_configuration: str = "Release",
    macos_products_path: Path | None = None,
) -> Path:
    bin_path = macos_products_path or macos_bin_path(runner)
    app_dir = SELF_CONTAINED_APP_PATH
    contents = app_dir / "Contents"
    macos_dir = contents / "MacOS"
    resources = contents / "Resources"
    device_artifacts = resources / "DeviceArtifacts"
    if app_dir.exists():
        shutil.rmtree(app_dir)
    macos_dir.mkdir(parents=True)
    device_artifacts.mkdir(parents=True)

    shutil.copy2(bin_path / "IOSSimMac", macos_dir / "IOSSim")
    shutil.copy2(bin_path / "IOSSimProvisioner", macos_dir / "IOSSimProvisioner")
    os.chmod(macos_dir / "IOSSim", 0o755)
    os.chmod(macos_dir / "IOSSimProvisioner", 0o755)
    write_app_info_plist(contents)
    build_app_icon(runner, resources)
    notices = resources / "ThirdPartyNotices"
    notices.mkdir()
    shutil.copy2(IDEVICE_LICENSE_SOURCE, notices / "idevice-LICENSE.txt")

    components: list[dict[str, Any]] = []
    for role, expected_bundle_id, source in bundled_artifact_specs(ios_configuration):
        if not source.exists():
            raise RuntimeError(f"required iPhone artifact is missing: {source}")
        info = read_bundle_info(source)
        actual_bundle_id = info.get("CFBundleIdentifier")
        if actual_bundle_id != expected_bundle_id:
            raise RuntimeError(f"{source.name} bundle ID is {actual_bundle_id}, expected {expected_bundle_id}")
        destination = device_artifacts / source.name
        shutil.copytree(source, destination, symlinks=True)
        for profile in destination.rglob("embedded.mobileprovision"):
            profile.unlink()
        for dsym in destination.rglob("*.dSYM"):
            if dsym.is_dir():
                shutil.rmtree(dsym)
            else:
                dsym.unlink()
        sanitized_count = sanitize_packaged_artifact_paths(destination)
        if sanitized_count:
            print_step("PASS", f"Sanitized source paths in {source.name}", f"{sanitized_count} file(s)")
        if not resign_ios_artifact(runner, destination):
            raise RuntimeError(f"failed to prepare re-signable iPhone artifact: {destination.name}")
        relative = destination.relative_to(resources).as_posix()
        components.append(
            {
                "role": role,
                "bundleIdentifier": expected_bundle_id,
                "version": str(info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "unknown"),
                "relativePath": relative,
                "sha256": sha256_path(destination),
                "signingMode": "personalTeamResign",
            }
        )

    manifest = {
        "schemaVersion": 1,
        "release": {
            "sourceCommit": source_commit(),
            "sourceDirty": source_dirty(),
            "buildTimestamp": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "macVersion": MAC_VERSION,
            "buildNumber": MAC_BUILD_NUMBER,
            "variant": RELEASE_CONFIG.variant,
            "helperSchemaVersion": HELPER_SCHEMA_VERSION,
        },
        "components": components,
    }
    (device_artifacts / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return app_dir


def sign_self_contained_app(runner: Runner, app_dir: Path) -> bool:
    identity = os.environ.get("IOSSIM_MAC_CODE_SIGN_IDENTITY", "-") or "-"
    ok = True
    for executable in [app_dir / "Contents" / "MacOS" / "IOSSimProvisioner", app_dir / "Contents" / "MacOS" / "IOSSim"]:
        ok &= run_step(runner, f"Strip {executable.name}", f"strip-{executable.name}", ["/usr/bin/strip", "-x", str(executable)])
        ok &= run_step(runner, f"Sign {executable.name}", f"codesign-{executable.name}", ["codesign", "--force", "--sign", identity, str(executable)])
    ok &= run_step(runner, "Sign IOSSim.app", "codesign-iossim-app", ["codesign", "--force", "--deep", "--sign", identity, str(app_dir)])
    ok &= run_step(runner, "Verify IOSSim.app signature", "codesign-verify-iossim-app", ["codesign", "--verify", "--deep", "--strict", str(app_dir)])
    return bool(ok)


@dataclass(frozen=True)
class DeveloperIDIdentity:
    fingerprint: str
    common_name: str
    team_id: str


def certificate_subject_team_id(common_name: str) -> str:
    certificate = subprocess.run(
        ["/usr/bin/security", "find-certificate", "-c", common_name, "-p"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if certificate.returncode != 0 or "BEGIN CERTIFICATE" not in certificate.stdout:
        return ""
    subject = subprocess.run(
        ["/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
        input=certificate.stdout,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if subject.returncode != 0:
        return ""
    match = re.search(r"(?:^|,)OU=([A-Z0-9]{10})(?:,|$)", subject.stdout.removeprefix("subject=").strip())
    return match.group(1) if match else ""


def available_developer_identities() -> list[DeveloperIDIdentity]:
    result = subprocess.run(
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return []
    identities: list[DeveloperIDIdentity] = []
    pattern = re.compile(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"(Developer ID Application:[^"]+)"')
    for line in result.stdout.splitlines():
        match = pattern.search(line)
        if not match:
            continue
        common_name = match.group(2)
        identities.append(DeveloperIDIdentity(
            fingerprint=match.group(1),
            common_name=common_name,
            team_id=certificate_subject_team_id(common_name),
        ))
    return identities


def resolve_developer_id_identity() -> DeveloperIDIdentity:
    identities = available_developer_identities()
    configured = merged_env().get("IOSSIM_DEVELOPER_ID_APPLICATION", "").strip()
    if configured:
        matches = [item for item in identities if configured in {item.fingerprint, item.common_name}]
        if len(matches) != 1:
            raise RuntimeError("IOSSIM_DEVELOPER_ID_APPLICATION does not name one available Developer ID Application identity")
        return matches[0]
    if not identities:
        raise RuntimeError(
            "Developer ID Application identity missing. Install the release team's certificate and private key, "
            "then set IOSSIM_DEVELOPER_ID_APPLICATION to its fingerprint or full common name."
        )
    if len(identities) != 1:
        raise RuntimeError("multiple Developer ID Application identities are available; set IOSSIM_DEVELOPER_ID_APPLICATION explicitly")
    return identities[0]


def validate_release_inputs() -> None:
    for path in [MAC_APP_ENTITLEMENTS, MAC_HELPER_ENTITLEMENTS]:
        try:
            with path.open("rb") as entitlement_file:
                entitlements = plistlib.load(entitlement_file)
        except Exception as exc:
            raise RuntimeError(f"invalid production entitlement file {path.name}: {exc}") from exc
        if entitlements != {}:
            raise RuntimeError(f"production entitlement file {path.name} must remain an empty dictionary")
    if not MAC_ICON_SOURCE.is_file():
        raise RuntimeError("production app icon source is missing")


def distribution_sign_device_artifacts(runner: Runner, app_dir: Path, identity: DeveloperIDIdentity) -> None:
    artifacts = app_dir / "Contents" / "Resources" / "DeviceArtifacts"
    for app in sorted(artifacts.glob("*.app")):
        signables = [
            child for child in app.rglob("*")
            if child.suffix in {".framework", ".xctest", ".dylib"}
        ]
        signables.append(app)
        for target in sorted(signables, key=lambda item: len(item.parts), reverse=True):
            if not target.exists():
                continue
            runner.run(
                f"developer-id-{safe_name(target.relative_to(app_dir).as_posix())}",
                [
                    "/usr/bin/codesign", "--force", "--sign", identity.fingerprint,
                    "--options", "runtime", "--timestamp",
                    "--preserve-metadata=identifier,requirements",
                    str(target),
                ],
            )


def local_sign_device_artifacts(runner: Runner, app_dir: Path) -> None:
    """Ad-hoc sign packaged iPhone code solely so the local DMG is structurally complete."""
    artifacts = app_dir / "Contents" / "Resources" / "DeviceArtifacts"
    for app in sorted(artifacts.glob("*.app")):
        signables = [
            child for child in app.rglob("*")
            if child.suffix in {".framework", ".xctest", ".dylib"}
        ]
        signables.append(app)
        for target in sorted(signables, key=lambda item: len(item.parts), reverse=True):
            if not target.exists():
                continue
            runner.run(
                f"local-sign-{safe_name(target.relative_to(app_dir).as_posix())}",
                [
                    "/usr/bin/codesign", "--force", "--sign", "-",
                    "--options", "runtime", "--timestamp=none",
                    "--preserve-metadata=identifier,requirements",
                    str(target),
                ],
            )


def update_device_artifact_hashes(app_dir: Path) -> None:
    resources = app_dir / "Contents" / "Resources"
    manifest_path = resources / "DeviceArtifacts" / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for component in manifest.get("components", []):
        component["sha256"] = sha256_path(resources / component["relativePath"])
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def distribution_sign_macos_app(runner: Runner, app_dir: Path, identity: DeveloperIDIdentity) -> None:
    helper = app_dir / "Contents" / "MacOS" / "IOSSimProvisioner"
    runner.run("strip-IOSSimProvisioner-release", ["/usr/bin/strip", "-x", str(helper)])
    runner.run(
        "developer-id-IOSSimProvisioner",
        [
            "/usr/bin/codesign", "--force", "--sign", identity.fingerprint,
            "--identifier", f"{RELEASE_CONFIG.bundle_identifier}.provisioner",
            "--options", "runtime", "--timestamp",
            "--entitlements", str(MAC_HELPER_ENTITLEMENTS),
            str(helper),
        ],
    )
    main = app_dir / "Contents" / "MacOS" / "IOSSim"
    runner.run("strip-IOSSim-release", ["/usr/bin/strip", "-x", str(main)])
    runner.run(
        "developer-id-IOSSim-app",
        [
            "/usr/bin/codesign", "--force", "--sign", identity.fingerprint,
            "--options", "runtime", "--timestamp",
            "--entitlements", str(MAC_APP_ENTITLEMENTS),
            str(app_dir),
        ],
    )


def local_sign_macos_app(runner: Runner, app_dir: Path) -> None:
    """Apply explicit hardened-runtime ad-hoc signatures for local physical testing."""
    helper = app_dir / "Contents" / "MacOS" / "IOSSimProvisioner"
    runner.run("strip-IOSSimProvisioner-local", ["/usr/bin/strip", "-x", str(helper)])
    runner.run(
        "local-sign-IOSSimProvisioner",
        [
            "/usr/bin/codesign", "--force", "--sign", "-",
            "--identifier", f"{RELEASE_CONFIG.bundle_identifier}.provisioner",
            "--options", "runtime", "--timestamp=none",
            "--entitlements", str(MAC_HELPER_ENTITLEMENTS),
            str(helper),
        ],
    )
    main = app_dir / "Contents" / "MacOS" / "IOSSim"
    runner.run("strip-IOSSim-local", ["/usr/bin/strip", "-x", str(main)])
    runner.run(
        "local-sign-IOSSim-app",
        [
            "/usr/bin/codesign", "--force", "--sign", "-",
            "--options", "runtime", "--timestamp=none",
            "--entitlements", str(MAC_APP_ENTITLEMENTS),
            str(app_dir),
        ],
    )


def macho_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        result = subprocess.run(["/usr/bin/file", "-b", str(path)], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if result.returncode == 0 and "Mach-O" in result.stdout:
            files.append(path)
    return sorted(files)


def codesign_details(path: Path) -> str:
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return (result.stdout or "") + (result.stderr or "")


def codesign_entitlements(path: Path) -> str:
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return (result.stdout or "") + (result.stderr or "")


def audit_release_signatures(app_dir: Path, expected_team_id: str) -> bool:
    ok = True
    verification = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", str(app_dir)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if verification.returncode == 0:
        ok &= audit_pass("Strict recursive signature verification")
    else:
        ok &= audit_fail("Strict recursive signature verification", verification.stderr)
    disallowed_entitlements = {
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.get-task-allow",
    }
    machos = macho_files(app_dir)
    ok &= audit_pass("Mach-O inventory", f"{len(machos)} executable code item(s)") if machos else audit_fail("Mach-O inventory", "none found")
    for path in machos:
        relative = path.relative_to(app_dir).as_posix()
        details = codesign_details(path)
        valid = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", str(path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        ).returncode == 0
        authority_ok = "Authority=Developer ID Application:" in details
        team_ok = f"TeamIdentifier={expected_team_id}" in details
        runtime_ok = "runtime" in details
        timestamp_ok = "Timestamp=" in details
        entitlements = codesign_entitlements(path)
        forbidden = sorted(item for item in disallowed_entitlements if item in entitlements)
        unexpected_entitlements = "<key>" in entitlements
        item_ok = valid and authority_ok and team_ok and runtime_ok and timestamp_ok and not forbidden and not unexpected_entitlements
        if item_ok:
            ok &= audit_pass(f"Nested signature {relative}", f"Developer ID / {expected_team_id} / hardened runtime")
        else:
            reasons = []
            if not valid: reasons.append("invalid signature")
            if not authority_ok: reasons.append("not Developer ID Application")
            if not team_ok: reasons.append("Team ID mismatch")
            if not runtime_ok: reasons.append("hardened runtime absent")
            if not timestamp_ok: reasons.append("secure timestamp absent")
            if forbidden: reasons.append(f"forbidden entitlements: {', '.join(forbidden)}")
            if unexpected_entitlements: reasons.append("unexpected production entitlements")
            ok &= audit_fail(f"Nested signature {relative}", "; ".join(reasons))
    return bool(ok)


def audit_local_signatures(app_dir: Path) -> bool:
    """Verify local signatures without implying Developer ID or Gatekeeper qualification."""
    ok = True
    verification = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", str(app_dir)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if verification.returncode == 0:
        ok &= audit_pass("Strict recursive local signature verification")
    else:
        ok &= audit_fail("Strict recursive local signature verification", verification.stderr)
    disallowed_entitlements = {
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.get-task-allow",
    }
    machos = macho_files(app_dir)
    ok &= audit_pass("Mach-O inventory", f"{len(machos)} executable code item(s)") if machos else audit_fail("Mach-O inventory", "none found")
    for path in machos:
        relative = path.relative_to(app_dir).as_posix()
        details = codesign_details(path)
        valid = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", str(path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        ).returncode == 0
        ad_hoc_ok = "Signature=adhoc" in details
        runtime_ok = "runtime" in details
        authority_absent = "Authority=" not in details
        entitlements = codesign_entitlements(path)
        forbidden = sorted(item for item in disallowed_entitlements if item in entitlements)
        unexpected_entitlements = "<key>" in entitlements
        item_ok = valid and ad_hoc_ok and runtime_ok and authority_absent and not forbidden and not unexpected_entitlements
        if item_ok:
            ok &= audit_pass(f"Local signature {relative}", "ad hoc / hardened runtime / no entitlements")
        else:
            reasons = []
            if not valid: reasons.append("invalid signature")
            if not ad_hoc_ok: reasons.append("not ad hoc")
            if not runtime_ok: reasons.append("hardened runtime absent")
            if not authority_absent: reasons.append("unexpected signing authority")
            if forbidden: reasons.append(f"forbidden entitlements: {', '.join(forbidden)}")
            if unexpected_entitlements: reasons.append("unexpected production entitlements")
            ok &= audit_fail(f"Local signature {relative}", "; ".join(reasons))
    return bool(ok)


def command_package_app(args: argparse.Namespace) -> int:
    runner = Runner(verbose=args.verbose)
    print("IOSSim Self-Contained App Package")
    print("")
    dirty = source_dirty()
    if dirty:
        print_step("WARN", "Repository state", "working tree has uncommitted changes; manifest will record sourceDirty=true")
    else:
        print_step("PASS", "Repository state", "clean")
    ok = True
    ok &= check_bundle_identifiers(runner)
    ok &= build_idevice(runner)
    ok &= verify_idevice(runner)
    ok &= build_ios(runner, configuration="Release", packaged=True)
    ok &= build_self_contained_macos_products(runner)
    if not ok:
        print("")
        print("Overall: FAIL")
        return 1
    try:
        app_dir = assemble_self_contained_app(runner, ios_configuration="Release")
        print_step("PASS", "Assemble self-contained IOSSim.app", str(app_dir))
    except Exception as exc:
        print_step("FAIL", "Assemble self-contained IOSSim.app", Redactor.redact(str(exc)))
        return 1
    ok &= sign_self_contained_app(runner, app_dir)
    ok &= audit_app(app_dir, verbose=args.verbose)
    print("")
    print(f"App: {app_dir}")
    print(f"Overall: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def notarization_profile_name() -> str:
    profile = merged_env().get("IOSSIM_NOTARY_KEYCHAIN_PROFILE", "").strip()
    if not profile:
        raise RuntimeError(
            "notarization credentials unavailable. Create a notarytool Keychain profile and set "
            "IOSSIM_NOTARY_KEYCHAIN_PROFILE to its name; never place credentials in the repository."
        )
    if any(character in profile for character in "\r\n\0"):
        raise RuntimeError("invalid notarization Keychain profile name")
    return profile


def validate_notarization_credentials(profile: str) -> None:
    result = subprocess.run(
        [
            "/usr/bin/xcrun", "notarytool", "history",
            "--keychain-profile", profile,
            "--output-format", "json",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "the configured notarytool Keychain profile could not authenticate. "
            "Refresh the local Keychain profile and verify network access."
        )


def sanitized_json_text(text: str) -> str:
    sanitized = text.replace(str(ROOT), "IOSSimSourceRoot")
    sanitized = sanitized.replace(str(Path.home()), "IOSSimHome")
    return sanitized


def submit_for_notarization(path: Path, label: str, profile: str, archive_dir: Path) -> dict[str, Any]:
    result = subprocess.run(
        [
            "/usr/bin/xcrun", "notarytool", "submit", str(path),
            "--keychain-profile", profile,
            "--wait", "--output-format", "json",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        response = json.loads(result.stdout)
    except Exception as exc:
        raise RuntimeError(f"{label} notarization did not return valid JSON: {redact(result.stderr)}") from exc
    submission_id = str(response.get("id") or "")
    status = str(response.get("status") or "")
    summary = {
        "id": submission_id,
        "status": status,
        "completedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "artifact": path.name,
    }
    archive_dir.mkdir(parents=True, exist_ok=True)
    (archive_dir / f"{label}-submission.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    if submission_id:
        log_result = subprocess.run(
            [
                "/usr/bin/xcrun", "notarytool", "log", submission_id,
                "--keychain-profile", profile,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if log_result.returncode == 0:
            (archive_dir / f"{label}-log.json").write_text(
                sanitized_json_text(log_result.stdout),
                encoding="utf-8",
            )
    if result.returncode != 0 or status != "Accepted":
        raise RuntimeError(
            f"{label} notarization {status or 'failed'} (submission {submission_id or 'unavailable'}). "
            f"Review {archive_dir / f'{label}-log.json'}"
        )
    return summary


def staple_and_validate(runner: Runner, path: Path, label: str) -> None:
    runner.run(f"staple-{label}", ["/usr/bin/xcrun", "stapler", "staple", "-v", str(path)])
    runner.run(f"stapler-validate-{label}", ["/usr/bin/xcrun", "stapler", "validate", "-v", str(path)])


def create_release_dmg(runner: Runner, app_dir: Path, output: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="iossim-dmg-") as temporary:
        staging = Path(temporary) / "IOSSim"
        staging.mkdir()
        shutil.copytree(app_dir, staging / "IOSSim.app", symlinks=True)
        os.symlink("/Applications", staging / "Applications")
        if output.exists():
            output.unlink()
        runner.run(
            "create-release-dmg",
            [
                "/usr/bin/hdiutil", "create", "-volname", "IOSSim",
                "-srcfolder", str(staging), "-ov", "-format", "UDZO", str(output),
            ],
        )
    runner.run("verify-release-dmg", ["/usr/bin/hdiutil", "verify", str(output)])


def assess_gatekeeper(runner: Runner, app_dir: Path, dmg_path: Path) -> None:
    runner.run(
        "gatekeeper-app",
        ["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app_dir)],
    )
    runner.run(
        "gatekeeper-dmg",
        [
            "/usr/sbin/spctl", "--assess", "--type", "open",
            "--context", "context:primary-signature", "--verbose=4", str(dmg_path),
        ],
    )


def write_distribution_metadata(app_dir: Path, distribution_class: str) -> None:
    is_public = distribution_class == "PUBLIC_RELEASE"
    metadata = {
        "schemaVersion": 1,
        "distributionClass": distribution_class,
        "developerID": is_public,
        "notarized": is_public,
        "gatekeeperQualified": is_public,
        "publicDistribution": is_public,
        "productionUI": True,
        "labels": (
            ["PUBLIC RELEASE", "DEVELOPER ID SIGNED", "NOTARIZED"]
            if is_public
            else ["LOCAL TEST BUILD", "NOT NOTARIZED", "NOT FOR PUBLIC DISTRIBUTION"]
        ),
    }
    path = app_dir / "Contents" / "Resources" / "Distribution.json"
    path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def audit_distribution_metadata(app_dir: Path, distribution_class: str) -> bool:
    path = app_dir / "Contents" / "Resources" / "Distribution.json"
    is_public = distribution_class == "PUBLIC_RELEASE"
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
        expected_labels = (
            ["PUBLIC RELEASE", "DEVELOPER ID SIGNED", "NOTARIZED"]
            if is_public
            else ["LOCAL TEST BUILD", "NOT NOTARIZED", "NOT FOR PUBLIC DISTRIBUTION"]
        )
        valid = (
            metadata.get("distributionClass") == distribution_class
            and metadata.get("developerID") is is_public
            and metadata.get("notarized") is is_public
            and metadata.get("gatekeeperQualified") is is_public
            and metadata.get("publicDistribution") is is_public
            and metadata.get("productionUI") is True
            and metadata.get("labels") == expected_labels
        )
        return audit_pass("Embedded distribution metadata", distribution_class) if valid else audit_fail("Embedded distribution metadata", "classification fields are inconsistent")
    except Exception as exc:
        return audit_fail("Embedded distribution metadata", str(exc))


def write_release_sidecars(
    dmg_path: Path,
    identity: DeveloperIDIdentity,
    app_notarization: dict[str, Any],
    dmg_notarization: dict[str, Any],
) -> tuple[Path, Path]:
    digest = sha256_file(dmg_path)
    checksum_path = dmg_path.with_suffix(dmg_path.suffix + ".sha256")
    checksum_path.write_text(f"{digest}  {dmg_path.name}\n", encoding="utf-8")
    report_path = dmg_path.with_suffix(".release.json")
    report = {
        "schemaVersion": 1,
        "distributionClass": "PUBLIC_RELEASE",
        "developerID": True,
        "notarized": True,
        "gatekeeperQualified": True,
        "publicDistribution": True,
        "productionUI": True,
        "product": RELEASE_CONFIG.product_name,
        "bundleIdentifier": RELEASE_CONFIG.bundle_identifier,
        "shortVersion": MAC_VERSION,
        "buildNumber": MAC_BUILD_NUMBER,
        "sourceCommit": source_commit(),
        "sourceDirty": source_dirty(),
        "buildTimestamp": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "variant": RELEASE_CONFIG.variant,
        "architectures": list(RELEASE_CONFIG.architectures),
        "signing": {
            "type": "Developer ID Application",
            "teamID": identity.team_id,
        },
        "notarization": {
            "app": app_notarization,
            "dmg": dmg_notarization,
        },
        "stapled": {"app": True, "dmg": True},
        "artifact": {
            "fileName": dmg_path.name,
            "sizeBytes": dmg_path.stat().st_size,
            "sha256": digest,
        },
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return checksum_path, report_path


def write_local_release_sidecars(dmg_path: Path) -> tuple[Path, Path]:
    digest = sha256_file(dmg_path)
    checksum_path = dmg_path.with_suffix(dmg_path.suffix + ".sha256")
    checksum_path.write_text(f"{digest}  {dmg_path.name}\n", encoding="utf-8")
    report_path = dmg_path.with_suffix(".release.json")
    report = {
        "schemaVersion": 1,
        "labels": ["LOCAL TEST BUILD", "NOT NOTARIZED", "NOT FOR PUBLIC DISTRIBUTION"],
        "distributionClass": "LOCAL_TEST_ONLY",
        "developerID": False,
        "notarized": False,
        "gatekeeperQualified": False,
        "publicDistribution": False,
        "productionUI": True,
        "product": RELEASE_CONFIG.product_name,
        "bundleIdentifier": RELEASE_CONFIG.bundle_identifier,
        "shortVersion": MAC_VERSION,
        "buildNumber": MAC_BUILD_NUMBER,
        "sourceCommit": source_commit(),
        "sourceDirty": source_dirty(),
        "buildTimestamp": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "variant": RELEASE_CONFIG.variant,
        "architectures": list(RELEASE_CONFIG.architectures),
        "signing": {
            "type": "Ad Hoc",
            "teamID": None,
            "hardenedRuntime": True,
        },
        "stapled": {"app": False, "dmg": False},
        "artifact": {
            "fileName": dmg_path.name,
            "sizeBytes": dmg_path.stat().st_size,
            "sha256": digest,
        },
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return checksum_path, report_path


def command_release(args: argparse.Namespace) -> int:
    print("IOSSim Production Release")
    print("")
    if source_dirty():
        print_step("FAIL", "Repository state", "commit or remove all changes before creating a release")
        return 1
    try:
        validate_release_inputs()
        identity = resolve_developer_id_identity()
        profile = notarization_profile_name()
        validate_notarization_credentials(profile)
    except Exception as exc:
        print_step("FAIL", "Release credentials", str(exc))
        return 1
    if not identity.team_id:
        print_step("FAIL", "Developer ID Team ID", "the identity common name does not contain a 10-character Team ID")
        return 1
    print_step("PASS", "Repository state", source_commit())
    print_step("PASS", "Developer ID Application identity", identity.team_id)
    print_step("PASS", "Notarization credential reference", "Keychain profile configured")
    runner = Runner(verbose=args.verbose)
    RELEASE_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    ok = check_bundle_identifiers(runner)
    ok &= build_idevice(runner)
    ok &= verify_idevice(runner)
    ok &= build_ios(runner, configuration="Release", packaged=True)
    if not ok:
        print_step("FAIL", "Production prerequisites", "build did not complete")
        return 1
    try:
        mac_products = build_universal_macos_products(runner)
        app_dir = assemble_self_contained_app(runner, ios_configuration="Release", macos_products_path=mac_products)
        distribution_sign_device_artifacts(runner, app_dir, identity)
        update_device_artifact_hashes(app_dir)
        write_distribution_metadata(app_dir, "PUBLIC_RELEASE")
        distribution_sign_macos_app(runner, app_dir, identity)
        if not audit_app(app_dir, verbose=args.verbose):
            raise RuntimeError("production package content audit failed")
        if not audit_distribution_metadata(app_dir, "PUBLIC_RELEASE"):
            raise RuntimeError("public distribution metadata audit failed")
        if not audit_release_signatures(app_dir, identity.team_id):
            raise RuntimeError("production signature audit failed")

        notarization_dir = RELEASE_OUTPUT_DIR / "notarization"
        app_zip = RELEASE_OUTPUT_DIR / f"IOSSim-{MAC_VERSION}.app.zip"
        if app_zip.exists():
            app_zip.unlink()
        runner.run(
            "archive-app-for-notarization",
            ["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app_dir), str(app_zip)],
        )
        app_notarization = submit_for_notarization(app_zip, "app", profile, notarization_dir)
        staple_and_validate(runner, app_dir, "app")

        dmg_path = RELEASE_OUTPUT_DIR / f"IOSSim-{MAC_VERSION}.dmg"
        create_release_dmg(runner, app_dir, dmg_path)
        runner.run(
            "sign-release-dmg",
            ["/usr/bin/codesign", "--force", "--sign", identity.fingerprint, "--timestamp", str(dmg_path)],
        )
        dmg_notarization = submit_for_notarization(dmg_path, "dmg", profile, notarization_dir)
        staple_and_validate(runner, dmg_path, "dmg")
        assess_gatekeeper(runner, app_dir, dmg_path)
        checksum_path, report_path = write_release_sidecars(
            dmg_path, identity, app_notarization, dmg_notarization
        )
        if not release_audit(dmg_path, verbose=args.verbose):
            raise RuntimeError("final release audit failed")
    except (CommandError, RuntimeError, OSError) as exc:
        detail = str(exc)
        if isinstance(exc, CommandError):
            detail = f"{exc.name} failed; see {exc.result.log_path}"
        print_step("FAIL", "Production release", redact(detail))
        return 1
    print_step("PASS", "Production release", str(dmg_path))
    print_step("PASS", "SHA-256", sha256_file(dmg_path))
    print_step("PASS", "Release metadata", str(report_path))
    print_step("PASS", "Checksum file", str(checksum_path))
    return 0


def command_release_local(args: argparse.Namespace) -> int:
    print("IOSSim Local Release Candidate")
    print("LOCAL TEST BUILD — NOT NOTARIZED — NOT FOR PUBLIC DISTRIBUTION")
    print("")
    if source_dirty():
        print_step("FAIL", "Repository state", "commit or remove all changes before creating a local release candidate")
        return 1
    try:
        validate_release_inputs()
    except Exception as exc:
        print_step("FAIL", "Local release inputs", str(exc))
        return 1
    print_step("PASS", "Distribution class", "LOCAL_TEST_ONLY")
    print_step("PASS", "Repository state", source_commit())
    print_step("INFO", "Developer ID", "NO")
    print_step("INFO", "Notarized", "NO")
    print_step("INFO", "Gatekeeper qualified", "NO")
    print_step("INFO", "Public distribution", "NO")
    print_step("PASS", "Production UI", "YES")
    runner = Runner(verbose=args.verbose)
    LOCAL_RELEASE_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    ok = check_bundle_identifiers(runner)
    ok &= build_idevice(runner)
    ok &= verify_idevice(runner)
    ok &= build_ios(runner, configuration="Release", packaged=True)
    if not ok:
        print_step("FAIL", "Local release prerequisites", "build did not complete")
        return 1
    try:
        mac_products = build_universal_macos_products(runner)
        app_dir = assemble_self_contained_app(runner, ios_configuration="Release", macos_products_path=mac_products)
        local_sign_device_artifacts(runner, app_dir)
        update_device_artifact_hashes(app_dir)
        write_distribution_metadata(app_dir, "LOCAL_TEST_ONLY")
        local_sign_macos_app(runner, app_dir)
        if not audit_app(app_dir, verbose=args.verbose):
            raise RuntimeError("local package content audit failed")
        if not audit_distribution_metadata(app_dir, "LOCAL_TEST_ONLY"):
            raise RuntimeError("local distribution metadata audit failed")
        if not audit_local_signatures(app_dir):
            raise RuntimeError("local structural signature audit failed")

        dmg_path = LOCAL_RELEASE_OUTPUT_DIR / f"IOSSim-{MAC_VERSION}-local.dmg"
        create_release_dmg(runner, app_dir, dmg_path)
        checksum_path, report_path = write_local_release_sidecars(dmg_path)
        if not local_release_audit(dmg_path, verbose=args.verbose):
            raise RuntimeError("final local release audit failed")
    except (CommandError, RuntimeError, OSError) as exc:
        detail = str(exc)
        if isinstance(exc, CommandError):
            detail = f"{exc.name} failed; see {exc.result.log_path}"
        print_step("FAIL", "Local release candidate", redact(detail))
        return 1
    print_step("PASS", "Local release candidate", str(dmg_path))
    print_step("PASS", "SHA-256", sha256_file(dmg_path))
    print_step("PASS", "Local release metadata", str(report_path))
    print_step("PASS", "Checksum file", str(checksum_path))
    print_step("INFO", "Public distribution", "NO — use ./iossim release after Developer ID and notarization are configured")
    return 0


def audit_pass(label: str, detail: str = "") -> bool:
    print_step("PASS", label, detail or None)
    return True


def audit_fail(label: str, detail: str = "") -> bool:
    print_step("FAIL", label, redact(detail) if detail else None)
    return False


def scan_file_for_bytes(path: Path, needles: list[bytes]) -> list[str]:
    try:
        data = path.read_bytes()
    except OSError:
        return []
    found: list[str] = []
    for needle in needles:
        if needle and needle in data:
            found.append(needle.decode("utf-8", errors="ignore"))
    return found


def audit_app(app_dir: Path, verbose: bool = False) -> bool:
    ok = True
    contents = app_dir / "Contents"
    macos_dir = contents / "MacOS"
    resources = contents / "Resources"
    manifest_path = resources / "DeviceArtifacts" / "manifest.json"
    ok &= audit_pass("App bundle exists", str(app_dir)) if app_dir.is_dir() else audit_fail("App bundle exists", str(app_dir))
    ok &= audit_pass("Mac executable exists", "Contents/MacOS/IOSSim") if os.access(macos_dir / "IOSSim", os.X_OK) else audit_fail("Mac executable exists", "Contents/MacOS/IOSSim")
    ok &= audit_pass("Provisioner executable exists", "Contents/MacOS/IOSSimProvisioner") if os.access(macos_dir / "IOSSimProvisioner", os.X_OK) else audit_fail("Provisioner executable exists", "Contents/MacOS/IOSSimProvisioner")
    ok &= audit_pass("Development repository locator absent") if not (resources / "DevelopmentRepositoryRoot.txt").exists() else audit_fail("Development repository locator absent")
    try:
        with (contents / "Info.plist").open("rb") as info_file:
            info = plistlib.load(info_file)
        expected_info = {
            "CFBundleIdentifier": RELEASE_CONFIG.bundle_identifier,
            "CFBundleDisplayName": RELEASE_CONFIG.product_name,
            "CFBundleShortVersionString": MAC_VERSION,
            "CFBundleVersion": MAC_BUILD_NUMBER,
            "LSMinimumSystemVersion": RELEASE_CONFIG.minimum_macos,
            "CFBundleIconFile": "IOSSim.icns",
        }
        mismatches = [f"{key}={info.get(key)!r}" for key, value in expected_info.items() if str(info.get(key)) != str(value)]
        ok &= audit_pass("Production Info.plist", f"{MAC_VERSION} ({MAC_BUILD_NUMBER})") if not mismatches else audit_fail("Production Info.plist", ", ".join(mismatches))
    except Exception as exc:
        ok &= audit_fail("Production Info.plist", str(exc))
    ok &= audit_pass("Production app icon") if (resources / "IOSSim.icns").is_file() else audit_fail("Production app icon", "Contents/Resources/IOSSim.icns missing")
    packaged_idevice_license = resources / "ThirdPartyNotices" / "idevice-LICENSE.txt"
    license_ok = (
        IDEVICE_LICENSE_SOURCE.is_file()
        and packaged_idevice_license.is_file()
        and sha256_file(packaged_idevice_license) == sha256_file(IDEVICE_LICENSE_SOURCE)
    )
    ok &= audit_pass("idevice MIT license notice") if license_ok else audit_fail(
        "idevice MIT license notice",
        "Contents/Resources/ThirdPartyNotices/idevice-LICENSE.txt missing or changed",
    )
    if not manifest_path.exists():
        ok &= audit_fail("Device artifact manifest", "missing")
        return False
    ok &= audit_pass("Device artifact manifest", "present")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        components = manifest.get("components", [])
        roles = sorted(component.get("role") for component in components)
        expected_roles = ["iosMain", "locationControlRunner"]
        ok &= audit_pass("Consumer install set", ", ".join(roles)) if roles == expected_roles else audit_fail("Consumer install set", f"{roles} != {expected_roles}")
        ok &= audit_pass("Witness consumer artifact absent") if "locationWitness" not in roles else audit_fail("Witness consumer artifact absent")
        release = manifest.get("release", {})
        release_metadata_ok = (
            release.get("variant") == RELEASE_CONFIG.variant
            and release.get("macVersion") == MAC_VERSION
            and str(release.get("buildNumber")) == MAC_BUILD_NUMBER
            and bool(release.get("sourceCommit"))
            and bool(release.get("buildTimestamp"))
        )
        ok &= audit_pass("Production package metadata") if release_metadata_ok else audit_fail("Production package metadata", "missing or inconsistent release provenance")
        for component in components:
            relative = component["relativePath"]
            artifact = resources / relative
            expected_hash = component["sha256"]
            expected_bundle_id = component["bundleIdentifier"]
            actual_hash = sha256_path(artifact) if artifact.exists() else "missing"
            ok &= audit_pass(f"Artifact hash {component['role']}", actual_hash[:12]) if actual_hash == expected_hash else audit_fail(f"Artifact hash {component['role']}", relative)
            try:
                info = read_bundle_info(artifact)
                actual_bundle_id = info.get("CFBundleIdentifier")
                ok &= audit_pass(f"Bundle ID {component['role']}", actual_bundle_id) if actual_bundle_id == expected_bundle_id else audit_fail(f"Bundle ID {component['role']}", f"{actual_bundle_id} != {expected_bundle_id}")
            except Exception as exc:
                ok &= audit_fail(f"Bundle ID {component.get('role', relative)}", str(exc))
    except Exception as exc:
        ok &= audit_fail("Device artifact manifest decode", str(exc))

    forbidden_name_parts = {
        ".git",
        "node_modules",
        "scripts/bootstrap",
        "iossim_cli.py",
        "DevelopmentRepositoryRoot.txt",
        "RPPairing",
        "DerivedData/Logs",
    }
    forbidden_suffixes = {
        ".py",
        ".rs",
        ".swift",
        ".ts",
        ".tsx",
        ".jsx",
        ".sh",
        ".p12",
        ".pem",
        ".key",
        ".xcresult",
        ".dSYM",
    }
    source_like: list[str] = []
    forbidden_material: list[str] = []
    mobileprovisions: list[str] = []
    path_needles = [
        str(ROOT).encode("utf-8"),
        b"/Users/rishiborra",
        b"/Desktop/IOSSim",
        b"DevelopmentRepositoryRoot.txt",
        b"IOSSIM_REPOSITORY_ROOT",
    ]
    secret_needles = [
        b"-----BEGIN PRIVATE KEY-----",
        b"-----BEGIN RSA PRIVATE KEY-----",
        b"-----BEGIN EC PRIVATE KEY-----",
        b"-----BEGIN ENCRYPTED PRIVATE KEY-----",
        b"auth_blob =",
        b"auth_blob:",
        b"auth token=",
        b"auth token:",
        b"private_key =",
        b"private_key:",
        b"psk =",
        b"psk:",
    ]
    path_hits: list[str] = []
    secret_hits: list[str] = []
    world_writable: list[str] = []
    for path in app_dir.rglob("*"):
        relative = path.relative_to(app_dir).as_posix()
        if path.is_dir():
            if any(part in relative for part in forbidden_name_parts):
                forbidden_material.append(relative)
            if path.suffix in forbidden_suffixes:
                source_like.append(relative)
            continue
        if path.name == "embedded.mobileprovision" or path.suffix == ".mobileprovision":
            mobileprovisions.append(relative)
            forbidden_material.append(relative)
        if any(part in relative for part in forbidden_name_parts):
            forbidden_material.append(relative)
        if path.suffix in forbidden_suffixes:
            source_like.append(relative)
        mode = path.stat().st_mode
        if mode & 0o002:
            world_writable.append(relative)
        path_hits.extend(f"{relative}: {hit}" for hit in scan_file_for_bytes(path, path_needles))
        secret_hits.extend(f"{relative}: {hit}" for hit in scan_file_for_bytes(path, secret_needles))
    ok &= audit_pass("No source-like files") if not source_like else audit_fail("No source-like files", ", ".join(source_like[:10]))
    ok &= audit_pass("No forbidden development material") if not forbidden_material else audit_fail("No forbidden development material", ", ".join(sorted(set(forbidden_material))[:10]))
    ok &= audit_pass("No developer provisioning profiles packaged") if not mobileprovisions else audit_fail("No developer provisioning profiles packaged", ", ".join(mobileprovisions[:10]))
    ok &= audit_pass("No absolute repository paths") if not path_hits else audit_fail("No absolute repository paths", "; ".join(path_hits[:10]))
    ok &= audit_pass("No private keys/pairing/auth material") if not secret_hits else audit_fail("No private keys/pairing/auth material", "; ".join(secret_hits[:10]))
    ok &= audit_pass("No world-writable files") if not world_writable else audit_fail("No world-writable files", ", ".join(world_writable[:10]))
    return bool(ok)


def command_audit_app(args: argparse.Namespace) -> int:
    app_dir = Path(args.app).expanduser().resolve()
    print("IOSSim Self-Contained App Audit")
    print("")
    ok = audit_app(app_dir, verbose=args.verbose)
    print("")
    print(f"Overall: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def team_identifier_from_signature(app_dir: Path) -> str | None:
    match = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", codesign_details(app_dir), re.MULTILINE)
    return match.group(1) if match else None


def release_audit(dmg_path: Path, verbose: bool = False) -> bool:
    ok = True
    if not dmg_path.is_file():
        return audit_fail("Release DMG exists", str(dmg_path))
    ok &= audit_pass("Release DMG exists", dmg_path.name)
    verify = subprocess.run(
        ["/usr/bin/hdiutil", "verify", str(dmg_path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    ok &= audit_pass("DMG integrity") if verify.returncode == 0 else audit_fail("DMG integrity", verify.stderr)

    checksum_path = dmg_path.with_suffix(dmg_path.suffix + ".sha256")
    expected_digest = ""
    if checksum_path.is_file():
        parts = checksum_path.read_text(encoding="utf-8", errors="replace").strip().split()
        expected_digest = parts[0] if len(parts) >= 2 and parts[-1] == dmg_path.name else ""
    actual_digest = sha256_file(dmg_path)
    ok &= audit_pass("DMG checksum", actual_digest) if expected_digest == actual_digest else audit_fail("DMG checksum", "missing or mismatched checksum sidecar")

    report_path = dmg_path.with_suffix(".release.json")
    report: dict[str, Any] = {}
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        metadata_ok = (
            report.get("distributionClass") == "PUBLIC_RELEASE"
            and report.get("developerID") is True
            and report.get("notarized") is True
            and report.get("gatekeeperQualified") is True
            and report.get("publicDistribution") is True
            and report.get("productionUI") is True
            and report.get("shortVersion") == MAC_VERSION
            and str(report.get("buildNumber")) == MAC_BUILD_NUMBER
            and report.get("variant") == RELEASE_CONFIG.variant
            and report.get("bundleIdentifier") == RELEASE_CONFIG.bundle_identifier
            and report.get("sourceDirty") is False
            and report.get("artifact", {}).get("sha256") == actual_digest
            and report.get("notarization", {}).get("app", {}).get("status") == "Accepted"
            and report.get("notarization", {}).get("dmg", {}).get("status") == "Accepted"
        )
        ok &= audit_pass("Release metadata") if metadata_ok else audit_fail("Release metadata", "version, provenance, hash, or notarization state is invalid")
    except Exception as exc:
        ok &= audit_fail("Release metadata", str(exc))

    dmg_staple = subprocess.run(
        ["/usr/bin/xcrun", "stapler", "validate", "-v", str(dmg_path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    ok &= audit_pass("DMG stapling") if dmg_staple.returncode == 0 else audit_fail("DMG stapling", dmg_staple.stderr)
    dmg_gatekeeper = subprocess.run(
        [
            "/usr/sbin/spctl", "--assess", "--type", "open",
            "--context", "context:primary-signature", "--verbose=4", str(dmg_path),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    ok &= audit_pass("DMG Gatekeeper assessment") if dmg_gatekeeper.returncode == 0 else audit_fail("DMG Gatekeeper assessment", dmg_gatekeeper.stderr)

    with tempfile.TemporaryDirectory(prefix="iossim-release-audit-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        attach = subprocess.run(
            ["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg_path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if attach.returncode != 0:
            ok &= audit_fail("DMG mount", attach.stderr)
            return bool(ok)
        try:
            visible = sorted(path.name for path in mount.iterdir() if not path.name.startswith("."))
            ok &= audit_pass("DMG contents", ", ".join(visible)) if visible == ["Applications", "IOSSim.app"] else audit_fail("DMG contents", ", ".join(visible))
            applications = mount / "Applications"
            ok &= audit_pass("Applications shortcut") if applications.is_symlink() and os.readlink(applications) == "/Applications" else audit_fail("Applications shortcut")
            app_dir = mount / "IOSSim.app"
            ok &= audit_app(app_dir, verbose=verbose)
            ok &= audit_distribution_metadata(app_dir, "PUBLIC_RELEASE")
            try:
                with (app_dir / "Contents" / "Info.plist").open("rb") as info_file:
                    info = plistlib.load(info_file)
                plist_ok = (
                    info.get("CFBundleIdentifier") == RELEASE_CONFIG.bundle_identifier
                    and info.get("CFBundleDisplayName") == RELEASE_CONFIG.product_name
                    and info.get("CFBundleShortVersionString") == MAC_VERSION
                    and str(info.get("CFBundleVersion")) == MAC_BUILD_NUMBER
                    and info.get("LSMinimumSystemVersion") == RELEASE_CONFIG.minimum_macos
                    and info.get("CFBundleIconFile") == "IOSSim.icns"
                )
                ok &= audit_pass("Production Info.plist") if plist_ok else audit_fail("Production Info.plist", "bundle identity/version/minimum OS/icon mismatch")
            except Exception as exc:
                ok &= audit_fail("Production Info.plist", str(exc))
            manifest_path = app_dir / "Contents" / "Resources" / "DeviceArtifacts" / "manifest.json"
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                release = manifest.get("release", {})
                provenance_ok = (
                    release.get("variant") == "PRODUCTION"
                    and release.get("macVersion") == MAC_VERSION
                    and str(release.get("buildNumber")) == MAC_BUILD_NUMBER
                    and release.get("sourceDirty") is False
                    and release.get("sourceCommit") == report.get("sourceCommit")
                )
                ok &= audit_pass("Bundled production provenance") if provenance_ok else audit_fail("Bundled production provenance")
            except Exception as exc:
                ok &= audit_fail("Bundled production provenance", str(exc))
            team_id = team_identifier_from_signature(app_dir)
            if team_id:
                ok &= audit_release_signatures(app_dir, team_id)
            else:
                ok &= audit_fail("Developer ID Team ID", "missing")
            app_staple = subprocess.run(
                ["/usr/bin/xcrun", "stapler", "validate", "-v", str(app_dir)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            ok &= audit_pass("App stapling") if app_staple.returncode == 0 else audit_fail("App stapling", app_staple.stderr)
            app_gatekeeper = subprocess.run(
                ["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app_dir)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            ok &= audit_pass("App Gatekeeper assessment") if app_gatekeeper.returncode == 0 else audit_fail("App Gatekeeper assessment", app_gatekeeper.stderr)
            for executable in [app_dir / "Contents/MacOS/IOSSim", app_dir / "Contents/MacOS/IOSSimProvisioner"]:
                arch_result = subprocess.run(
                    ["/usr/bin/lipo", "-archs", str(executable)],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                actual_architectures = set(arch_result.stdout.split())
                expected_architectures = set(RELEASE_CONFIG.architectures)
                arch_ok = arch_result.returncode == 0 and actual_architectures == expected_architectures
                ok &= audit_pass(f"Architectures {executable.name}", " ".join(sorted(actual_architectures))) if arch_ok else audit_fail(f"Architectures {executable.name}", arch_result.stderr or arch_result.stdout)
        finally:
            subprocess.run(
                ["/usr/bin/hdiutil", "detach", str(mount)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    if not source_dirty() and report.get("sourceCommit") == source_commit():
        ok &= audit_pass("Source provenance", source_commit())
    else:
        ok &= audit_fail("Source provenance", "working tree is dirty or HEAD differs from release metadata")
    return bool(ok)


def local_release_audit(dmg_path: Path, verbose: bool = False) -> bool:
    """Audit a local-only DMG without performing or claiming public distribution gates."""
    ok = True
    if not dmg_path.is_file():
        return audit_fail("Local DMG exists", str(dmg_path))
    ok &= audit_pass("Local DMG exists", dmg_path.name)
    verify = subprocess.run(
        ["/usr/bin/hdiutil", "verify", str(dmg_path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    ok &= audit_pass("DMG integrity") if verify.returncode == 0 else audit_fail("DMG integrity", verify.stderr)

    checksum_path = dmg_path.with_suffix(dmg_path.suffix + ".sha256")
    expected_digest = ""
    if checksum_path.is_file():
        parts = checksum_path.read_text(encoding="utf-8", errors="replace").strip().split()
        expected_digest = parts[0] if len(parts) >= 2 and parts[-1] == dmg_path.name else ""
    actual_digest = sha256_file(dmg_path)
    ok &= audit_pass("DMG checksum", actual_digest) if expected_digest == actual_digest else audit_fail("DMG checksum", "missing or mismatched checksum sidecar")

    report_path = dmg_path.with_suffix(".release.json")
    report: dict[str, Any] = {}
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        metadata_ok = (
            report.get("distributionClass") == "LOCAL_TEST_ONLY"
            and report.get("developerID") is False
            and report.get("notarized") is False
            and report.get("gatekeeperQualified") is False
            and report.get("publicDistribution") is False
            and report.get("productionUI") is True
            and report.get("labels") == ["LOCAL TEST BUILD", "NOT NOTARIZED", "NOT FOR PUBLIC DISTRIBUTION"]
            and report.get("shortVersion") == MAC_VERSION
            and str(report.get("buildNumber")) == MAC_BUILD_NUMBER
            and report.get("variant") == "PRODUCTION"
            and report.get("bundleIdentifier") == RELEASE_CONFIG.bundle_identifier
            and report.get("sourceDirty") is False
            and report.get("signing", {}).get("type") == "Ad Hoc"
            and report.get("signing", {}).get("teamID") is None
            and report.get("artifact", {}).get("sha256") == actual_digest
        )
        ok &= audit_pass("Local release metadata", "LOCAL_TEST_ONLY") if metadata_ok else audit_fail("Local release metadata", "local-only classification, provenance, or hash is invalid")
    except Exception as exc:
        ok &= audit_fail("Local release metadata", str(exc))

    print_step("INFO", "Developer ID", "NO")
    print_step("INFO", "Notarization", "NO — intentionally not attempted")
    print_step("INFO", "Stapling", "NO — no notarization ticket exists")
    print_step("INFO", "Gatekeeper qualification", "NO — intentionally not claimed")
    print_step("INFO", "Public distribution", "NO")

    with tempfile.TemporaryDirectory(prefix="iossim-local-release-audit-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        attach = subprocess.run(
            ["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg_path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if attach.returncode != 0:
            ok &= audit_fail("DMG mount", attach.stderr)
            return bool(ok)
        try:
            visible = sorted(path.name for path in mount.iterdir() if not path.name.startswith("."))
            ok &= audit_pass("DMG contents", ", ".join(visible)) if visible == ["Applications", "IOSSim.app"] else audit_fail("DMG contents", ", ".join(visible))
            applications = mount / "Applications"
            ok &= audit_pass("Applications shortcut") if applications.is_symlink() and os.readlink(applications) == "/Applications" else audit_fail("Applications shortcut")
            app_dir = mount / "IOSSim.app"
            ok &= audit_app(app_dir, verbose=verbose)
            ok &= audit_distribution_metadata(app_dir, "LOCAL_TEST_ONLY")
            ok &= audit_local_signatures(app_dir)
            try:
                manifest = json.loads((app_dir / "Contents" / "Resources" / "DeviceArtifacts" / "manifest.json").read_text(encoding="utf-8"))
                release = manifest.get("release", {})
                provenance_ok = (
                    release.get("variant") == "PRODUCTION"
                    and release.get("macVersion") == MAC_VERSION
                    and str(release.get("buildNumber")) == MAC_BUILD_NUMBER
                    and release.get("sourceDirty") is False
                    and release.get("sourceCommit") == report.get("sourceCommit")
                )
                ok &= audit_pass("Bundled production provenance") if provenance_ok else audit_fail("Bundled production provenance")
            except Exception as exc:
                ok &= audit_fail("Bundled production provenance", str(exc))
            for executable in [app_dir / "Contents/MacOS/IOSSim", app_dir / "Contents/MacOS/IOSSimProvisioner"]:
                arch_result = subprocess.run(
                    ["/usr/bin/lipo", "-archs", str(executable)],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                actual_architectures = set(arch_result.stdout.split())
                expected_architectures = set(RELEASE_CONFIG.architectures)
                arch_ok = arch_result.returncode == 0 and actual_architectures == expected_architectures
                ok &= audit_pass(f"Architectures {executable.name}", " ".join(sorted(actual_architectures))) if arch_ok else audit_fail(f"Architectures {executable.name}", arch_result.stderr or arch_result.stdout)
        finally:
            subprocess.run(
                ["/usr/bin/hdiutil", "detach", str(mount)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    if not source_dirty() and report.get("sourceCommit") == source_commit():
        ok &= audit_pass("Source provenance", source_commit())
    else:
        ok &= audit_fail("Source provenance", "working tree is dirty or HEAD differs from local release metadata")
    return bool(ok)


def command_release_audit(args: argparse.Namespace) -> int:
    artifact = Path(args.artifact).expanduser().resolve()
    print("IOSSim Production Release Audit")
    print("")
    ok = release_audit(artifact, verbose=args.verbose)
    print("")
    print(f"Overall: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def command_local_release_audit(args: argparse.Namespace) -> int:
    artifact = Path(args.artifact).expanduser().resolve()
    print("IOSSim Local Release Candidate Audit")
    print("LOCAL TEST BUILD — NOT NOTARIZED — NOT FOR PUBLIC DISTRIBUTION")
    print("")
    ok = local_release_audit(artifact, verbose=args.verbose)
    print("")
    print(f"Overall: {'PASS' if ok else 'FAIL'} (LOCAL_TEST_ONLY; public gates not assessed)")
    return 0 if ok else 1


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
    ok &= build_ios(runner, signed_for_device=True)
    if not ok:
        print_step("FAIL", "Build required before install", "fix build failures above")
        return 1
    device = select_device(ready_devices, getattr(args, "device", None))
    if not device:
        print_step("ACTION", "Select a ready iPhone", "rerun ./iossim device --device <redacted id or device name>")
        for item in ready_devices:
            print(f"- {item.get('name', 'iPhone')} ({item.get('identifier', 'unknown')})")
        return 2
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


def select_device(devices: list[dict[str, Any]], selector: str | None) -> dict[str, Any] | None:
    if not selector:
        if len(devices) == 1:
            return devices[0]
        connected = [device for device in devices if device.get("tunnelState") == "connected"]
        return connected[0] if len(connected) == 1 else None
    wanted = selector.strip().lower()
    matches = [
        device for device in devices
        if wanted in str(device.get("identifier", "")).lower()
        or wanted == str(device.get("name", "")).lower()
    ]
    if len(matches) == 1:
        return matches[0]
    return None


def command_info(args: argparse.Namespace) -> int:
    matrix = [
        ("macOS", "runtime", "system", "13.0+", "no", "compatible Mac", "IOSSimProvisioner doctor --json"),
        ("xcrun/devicectl", "runtime", "Apple developer tools", "current Xcode path", "no", "install/select Apple developer tools", "IOSSimProvisioner device-status --json"),
        ("Xcode/xcodebuild", "build-time", "Apple", "15.0+", "yes from packaged runtime", "build machine only", "./iossim package-app"),
        ("SwiftPM package", "build-time", "ios/Package.swift and macos/Package.swift", "Swift tools 5.9", "yes from packaged runtime", "none", "./iossim build"),
        ("iOS app project", "build-time", "ios/IOSSimOnDevicePOC.xcodeproj", "iOS 17 target", "yes from packaged runtime", "Apple signing at package time", "./iossim package-app"),
        ("Mac app", "runtime", "compiled bundle", "macOS 13+", "n/a", "none for ad-hoc development signing", "./iossim audit-app"),
        ("idevice FFI", "build-time", "jkcoxson/idevice pinned commit", PINNED_IDEVICE_COMMIT[:12], "yes from packaged runtime", "Rust required at build time", "./iossim build"),
        ("Rust iOS target", "build-time", "rustup", "aarch64-apple-ios", "yes from packaged runtime", "install rustup on build machine", "./iossim doctor"),
        ("Frontend engineering UI", "development-only", "frontend/package.json", "Node 20+", "yes from packaged runtime", "install Node for tests", "npm test"),
        ("Backend engineering API", "development-only", "backend/requirements.txt", "Python 3.11+", "yes from packaged runtime", "install Python for tests", "pytest backend"),
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
        ("package-app", "build a self-contained IOSSim.app bundle"),
        ("audit-app", "audit a self-contained IOSSim.app bundle"),
        ("release", "build, sign, notarize, staple, and audit a production DMG"),
        ("release-audit", "verify a signed and notarized production DMG"),
        ("release-local", "build and audit an ad-hoc signed local-test-only DMG"),
        ("release-local-audit", "verify a local-test-only DMG without public release claims"),
        ("test", "run current main validation suite"),
        ("device", "build and install internal device-side components"),
        ("info", "print dependency matrix"),
        ("clean", "remove CLI-owned generated state"),
    ]:
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--verbose", action="store_true", help="print detailed command output")
        if name == "doctor":
            p.add_argument("--json", action="store_true", help="emit machine-readable status")
        if name == "device":
            p.add_argument("--device", help="target a ready iPhone by redacted identifier or exact device name")
        if name == "audit-app":
            p.add_argument("app", help="path to IOSSim.app")
        if name in {"release-audit", "release-local-audit"}:
            p.add_argument("artifact", help="path to IOSSim-<version>.dmg")
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
    if args.command == "package-app":
        return command_package_app(args)
    if args.command == "audit-app":
        return command_audit_app(args)
    if args.command == "release":
        return command_release(args)
    if args.command == "release-audit":
        return command_release_audit(args)
    if args.command == "release-local":
        return command_release_local(args)
    if args.command == "release-local-audit":
        return command_local_release_audit(args)
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
