#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

BOOTSTRAP_MODULE_DIR = Path(__file__).resolve().parent
if str(BOOTSTRAP_MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(BOOTSTRAP_MODULE_DIR))

from artifact_identity import (
    ArtifactIdentityError,
    assert_identity,
    expected_release_identity,
    inspect_app,
    inspect_dmg,
    protocol_versions,
    sha256_file,
    sha256_path,
    sha256_tree,
)


ROOT = Path(__file__).resolve().parents[2]
IOS_DIR = ROOT / "ios"
MAC_DIR = ROOT / "macos"
HOST_BRIDGE_DIR = ROOT / "native" / "iossim-device-bridge"
NATIVE_WORKSPACE_DIR = ROOT / "native"
HOST_BRIDGE_LIB = NATIVE_WORKSPACE_DIR / "target" / "release" / "libiossim_device_bridge.dylib"
HOST_BRIDGE_MANIFEST = HOST_BRIDGE_DIR / "Cargo.toml"
RELEASE_CONFIG_PATH = ROOT / "config" / "release.json"
RELEASE_OUTPUT_DIR = ROOT / ".build" / "iossim" / "release"
LOCAL_RELEASE_OUTPUT_DIR = ROOT / ".build" / "iossim" / "local-release"
MAC_APP_ENTITLEMENTS = MAC_DIR / "Release" / "IOSSim.entitlements"
MAC_HELPER_ENTITLEMENTS = MAC_DIR / "Release" / "IOSSimProvisioner.entitlements"
MAC_HELPER_LOCAL_ENTITLEMENTS = MAC_DIR / "Release" / "IOSSimProvisionerLocal.entitlements"
MAC_ICON_SOURCE = MAC_DIR / "Resources" / "IOSSimIcon.png"
IDEVICE_LICENSE_SOURCE = IOS_DIR / "Vendor" / "idevice" / "LICENSE.txt"
BIGINT_LICENSE_SOURCE = MAC_DIR / "ThirdPartyNotices" / "BigInt-LICENSE.txt"
SBOM_FILE_NAME = "SBOM.spdx.json"
IOS_PROJECT = IOS_DIR / "IOSSimOnDevicePOC.xcodeproj"
DERIVED_DATA = IOS_DIR / ".build" / "DerivedData"
MAC_APP_PATH = ROOT / ".build" / "iossim" / "mac" / "IOSSim.app"
SELF_CONTAINED_APP_PATH = ROOT / ".build" / "iossim" / "self-contained" / "IOSSim.app"
LOG_DIR = ROOT / ".build" / "iossim" / "logs"
STATE_DIR = ROOT / ".build" / "iossim" / "state"
LOCAL_ENV = ROOT / ".iossim.local.env"
PINNED_IDEVICE_COMMIT = "c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5"
REQUIRED_SCHEMES = {"IOSSimOnDevicePOC", "IOSSimPayloadRunner"}
MIN_MACOS = (13, 0, 0)
MIN_XCODE = (15, 0, 0)
MIN_NODE = (20, 0, 0)
MIN_PYTHON = (3, 11, 0)
PAYLOAD_BUILD_VARIANT = "DEVICE_PAYLOAD_RELEASE"
LOCAL_TEST_DDI_PROVIDER = "THIRD_PARTY_MIRROR_DEVELOPMENT_PINNED_V030"
PAYLOAD_CAPABILITIES = {
    "automaticPairingInbox": 2,
    "localDevVPNSetupGate": 2,
    "pairingReceiptSchema": 2,
    "richRuntimeProofInbox": 1,
    "runtimeMappingSchema": 1,
}


@dataclass(frozen=True)
class ReleaseConfig:
    product_name: str
    bundle_identifier: str
    short_version: str
    build_number: str
    minimum_macos: str
    variant: str
    architectures: tuple[str, ...]
    developer_support_provider_classification: str


def load_release_config() -> ReleaseConfig:
    try:
        raw = json.loads(RELEASE_CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError(f"invalid release configuration: {exc}") from exc
    required = {
        "productName", "bundleIdentifier", "shortVersion", "buildNumber",
        "minimumMacOS", "variant", "architectures", "developerSupportProviderClassification",
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
        developer_support_provider_classification=str(raw["developerSupportProviderClassification"]),
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


def run_step(
    runner: Runner,
    message: str,
    name: str,
    args: list[str],
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
) -> bool:
    try:
        runner.run(name, args, cwd=cwd, env=env)
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
        print_step("ACTION", "BUILD_ONLY Xcode license", "required only on a machine rebuilding iPhone payloads")
    elif "requires a development team" in lower or "development team" in lower:
        print_step("ACTION", "BUILD_ONLY Apple signing", "configure an Apple Development identity on the payload build machine")
    elif "iphoneos sdk unavailable" in lower:
        print_step("ACTION", "BUILD_ONLY iPhoneOS SDK", "full Xcode is required only to rebuild iPhone payloads")
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
        # Build-only requirements are useful to source developers, but they are
        # not consumer runtime readiness gates.
        return not any(c.state in {"FAIL", "ACTION"} and c.required_for == "mac" for c in self.checks)

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


@dataclass(frozen=True)
class NativeDiscoveryResult:
    devices: list[dict[str, Any]]
    raw_count: int
    returned_count: int
    diagnostics: list[dict[str, str]]
    helper_path: Path | None
    bridge_path: Path | None
    error_code: str | None = None
    error_detail: str | None = None

    @property
    def available(self) -> bool:
        return self.error_code is None


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
        report.add(
            "WARN", "Build Only · Xcode", "BUILD_ONLY xcodebuild", "missing",
            "Full Xcode is needed only to rebuild iPhone payloads; it is not required for consumer device discovery.", "build"
        )
        return
    selected = runner.run("xcode-select", ["xcode-select", "-p"], check=False)
    if selected.code == 0:
        report.add("PASS", "Build Only · Xcode", "BUILD_ONLY xcode-select path", selected.stdout.strip(), "", "build")
    else:
        report.add("WARN", "Build Only · Xcode", "BUILD_ONLY xcode-select path", "not configured", "Select full Xcode only on a payload build machine.", "build")
    version = runner.run("xcodebuild-version", ["xcodebuild", "-version"], check=False)
    parsed = parse_version(version.stdout)
    if version.code == 0 and version_at_least(parsed, MIN_XCODE):
        report.add("PASS", "Build Only · Xcode", "BUILD_ONLY Xcode version", version.stdout.splitlines()[0], "", "build")
    elif version.code == 0:
        report.add("WARN", "Build Only · Xcode", "BUILD_ONLY Xcode version", version.stdout.splitlines()[0], "Use Xcode 15 or newer only when rebuilding iPhone payloads.", "build")
    else:
        report.add("WARN", "Build Only · Xcode", "BUILD_ONLY Xcode tools", "xcodebuild failed", "Resolve this only on a payload build machine.", "build")
    sdk = runner.run("iphoneos-sdk", ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], check=False)
    if sdk.code == 0 and sdk.stdout.strip():
        report.add("PASS", "Build Only · Xcode", "BUILD_ONLY iphoneos SDK", sdk.stdout.strip(), "", "build")
    else:
        report.add("WARN", "Build Only · Xcode", "BUILD_ONLY iphoneos SDK", "unavailable", "Required only to rebuild iPhone payloads.", "build")


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
        report.add("WARN", "Build Only · Signing", "BUILD_ONLY Apple Development identity", "none found", "Configure an Apple Development identity only on a payload build machine.", "build")
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
    discovery = discover_native_devices(runner)
    devices = discovery.devices
    report.devices = devices
    if not discovery.available:
        report.add(
            "ACTION",
            "Device Bridge",
            discovery.error_code or "DEVICE_DISCOVERY_UNAVAILABLE",
            discovery.error_detail or "native device discovery failed",
            "Run ./iossim device-debug and include its sanitized output when reporting this failure.",
            "diagnostics",
        )
        report.add(
            "ACTION",
            "Device",
            "connected iPhone",
            "DEVICE_DISCOVERY_UNAVAILABLE",
            "IOSSim could not query its native device bridge. Run ./iossim device-debug.",
            "device",
        )
        return
    if not devices:
        report.add("PASS", "Device Bridge", "native discovery", "ZERO_DEVICES_RETURNED", "", "diagnostics")
        report.add("ACTION", "Device", "connected iPhone", "not detected", "Connect and unlock an iPhone, then run ./iossim device-debug.", "device")
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


def native_discovery_candidates() -> list[tuple[Path, Path]]:
    executable_name = "IOSSimProvisioner"
    bridge_name = "libiossim_device_bridge.dylib"
    final_payload_retest_app = ROOT / ".build" / "iossim" / "final-setup-payload-retest" / "IOSSim.app"
    final_setup_retest_app = ROOT / ".build" / "iossim" / "final-setup-retest" / "IOSSim.app"
    physical_retest_app = ROOT / ".build" / "iossim" / "physical-retest" / "IOSSim.app"
    candidates = [
        (
            final_payload_retest_app / "Contents" / "MacOS" / executable_name,
            final_payload_retest_app / "Contents" / "Resources" / "NativeDeviceBridge" / bridge_name,
        ),
        (
            final_setup_retest_app / "Contents" / "MacOS" / executable_name,
            final_setup_retest_app / "Contents" / "Resources" / "NativeDeviceBridge" / bridge_name,
        ),
        (
            physical_retest_app / "Contents" / "MacOS" / executable_name,
            physical_retest_app / "Contents" / "Resources" / "NativeDeviceBridge" / bridge_name,
        ),
        (
            MAC_APP_PATH / "Contents" / "MacOS" / executable_name,
            MAC_APP_PATH / "Contents" / "Resources" / "NativeDeviceBridge" / bridge_name,
        ),
        (MAC_DIR / ".build" / f"{platform.machine()}-apple-macosx" / "release" / executable_name, HOST_BRIDGE_LIB),
        (MAC_DIR / ".build" / f"{platform.machine()}-apple-macosx" / "debug" / executable_name, HOST_BRIDGE_LIB),
        (
            SELF_CONTAINED_APP_PATH / "Contents" / "MacOS" / executable_name,
            SELF_CONTAINED_APP_PATH / "Contents" / "Resources" / "NativeDeviceBridge" / bridge_name,
        ),
        (
            Path("/Applications/IOSSim.app/Contents/MacOS") / executable_name,
            Path("/Applications/IOSSim.app/Contents/Resources/NativeDeviceBridge") / bridge_name,
        ),
    ]
    seen: set[tuple[Path, Path]] = set()
    return [item for item in candidates if not (item in seen or seen.add(item))]


def parse_native_discovery_payload(
    payload: str,
    helper_path: Path,
    bridge_path: Path,
) -> NativeDiscoveryResult:
    try:
        envelope = json.loads(payload)
        data = envelope["data"]
        diagnostics = data.get("diagnostics", [])
        raw_devices = data.get("devices", [])
        raw_count = int(data["rawDeviceCount"])
        returned_count = int(data["returnedDeviceCount"])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        return NativeDiscoveryResult(
            [], 0, 0, [], helper_path, bridge_path,
            "FFI_DECODING_FAILURE", f"native helper diagnostic payload was invalid: {type(exc).__name__}",
        )

    devices: list[dict[str, Any]] = []
    for item in raw_devices:
        if not isinstance(item, dict):
            continue
        selection_identifier = item.get("selectionIdentifier")
        devices.append({
            "name": item.get("name") or "iPhone",
            "identifier": item.get("identifier") or short_identifier(selection_identifier),
            "_deviceIdentifier": selection_identifier,
            "udidRedacted": item.get("udidRedacted") or short_identifier(selection_identifier),
            "osVersion": item.get("osVersion"),
            "model": item.get("model"),
            "developerModeStatus": item.get("developerModeStatus"),
            "pairingState": item.get("pairingState"),
            "tunnelState": item.get("tunnelState"),
            "isLocked": item.get("isLocked"),
        })

    unavailable_codes = {
        "BRIDGE_UNAVAILABLE", "BRIDGE_INITIALIZATION_FAILED", "USBMUX_UNAVAILABLE",
        "ENUMERATION_FAILED", "HELPER_LIBRARY_MISSING", "FFI_DECODING_FAILURE",
    }
    primary = next(
        (item for item in diagnostics if isinstance(item, dict) and item.get("code") in unavailable_codes),
        None,
    )
    if envelope.get("ok") is False or primary is not None:
        primary = primary or {"code": "DEVICE_DISCOVERY_UNAVAILABLE", "detail": "native helper rejected discovery"}
        return NativeDiscoveryResult(
            devices, raw_count, returned_count, diagnostics, helper_path, bridge_path,
            str(primary.get("code")), str(primary.get("detail") or "native device discovery failed"),
        )
    return NativeDiscoveryResult(devices, raw_count, returned_count, diagnostics, helper_path, bridge_path)


def discover_native_devices(runner: Runner) -> NativeDiscoveryResult:
    pair = next(
        ((helper, bridge) for helper, bridge in native_discovery_candidates() if helper.is_file() and bridge.is_file()),
        None,
    )
    if pair is None:
        return NativeDiscoveryResult(
            [], 0, 0, [], None, None, "HELPER_LIBRARY_MISSING",
            "Build the native Mac bridge and IOSSimProvisioner before running discovery.",
        )
    helper, bridge = pair
    environment = merged_env()
    environment.update({
        "IOSSIM_DEVICE_BACKEND": "idevice",
        "IOSSIM_DEVICE_BRIDGE_PATH": str(bridge.resolve()),
        "IOSSIM_FORBID_DEVICETCTL": "1",
    })
    result = runner.run(
        "native-device-diagnostics",
        [str(helper.resolve()), "device-diagnostics"],
        cwd=ROOT,
        env=environment,
        check=False,
    )
    if result.code != 0:
        detail = (result.stderr or result.stdout or "native helper exited unsuccessfully").strip().splitlines()[-1]
        return NativeDiscoveryResult(
            [], 0, 0, [], helper, bridge, "HELPER_EXECUTION_FAILED", detail,
        )
    return parse_native_discovery_payload(result.stdout, helper, bridge)


def discover_devices(runner: Runner) -> list[dict[str, Any]]:
    """Compatibility accessor; doctor must use discover_native_devices to retain errors."""
    return discover_native_devices(runner).devices


def check_manual_runtime_actions(report: DoctorReport) -> None:
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
    required_targets = ["aarch64-apple-darwin", "x86_64-apple-darwin", "aarch64-apple-ios"]
    for target in required_targets:
        ok &= run_step(
            runner,
            f"Install Rust target {target}",
            f"rust-target-{target}",
            [rustup, "target", "add", target],
        )
    for component_name in ["rustfmt", "clippy", "llvm-tools-preview"]:
        ok &= run_step(
            runner,
            f"Install Rust component {component_name}",
            f"rust-component-{component_name}",
            [rustup, "component", "add", component_name],
        )
    return bool(ok)


def build_idevice(runner: Runner) -> bool:
    return run_step(runner, "Build pinned idevice FFI", "build-idevice-ios", [str(IOS_DIR / "scripts" / "build_idevice_ios.sh")])


def build_host_device_bridge(runner: Runner) -> bool:
    cargo = discover_tool("cargo")
    if not cargo:
        print_step("FAIL", "Native Mac device bridge", "cargo is unavailable")
        return False
    built: list[Path] = []
    for architecture in RELEASE_CONFIG.architectures:
        rust_architecture = "aarch64" if architecture == "arm64" else architecture
        target = f"{rust_architecture}-apple-darwin"
        if not run_step(
            runner,
            f"Build native Mac device bridge ({architecture})",
            f"build-host-device-bridge-{architecture}",
            [
                cargo, "build", "--manifest-path", str(HOST_BRIDGE_DIR / "Cargo.toml"),
                "--release", "--target", target,
            ],
        ):
            return False
        artifact = NATIVE_WORKSPACE_DIR / "target" / target / "release" / HOST_BRIDGE_LIB.name
        if not artifact.is_file():
            print_step("FAIL", "Native Mac device bridge", f"missing {artifact}")
            return False
        built.append(artifact)
    HOST_BRIDGE_LIB.parent.mkdir(parents=True, exist_ok=True)
    if len(built) == 1:
        shutil.copy2(built[0], HOST_BRIDGE_LIB)
    else:
        result = runner.run(
            "lipo-native-device-bridge",
            ["/usr/bin/lipo", "-create", *(str(path) for path in built), "-output", str(HOST_BRIDGE_LIB)],
            check=False,
        )
        if result.code != 0:
            print_step("FAIL", "Universal native Mac device bridge", f"see {result.log_path}")
            return False
    actual = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(HOST_BRIDGE_LIB)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    expected = set(RELEASE_CONFIG.architectures)
    if actual.returncode != 0 or set(actual.stdout.split()) != expected:
        print_step("FAIL", "Native Mac device bridge architectures", actual.stderr or actual.stdout)
        return False
    print_step("PASS", "Native Mac device bridge architectures", " ".join(sorted(expected)))
    return True


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
            "IOSSimPayloadRunner",
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
    print("Runtime device actions that remain:")
    print("1. Connect and unlock the iPhone, then trust this Mac if prompted.")
    print("2. Enable Developer Mode on the iPhone if the runtime requests it.")
    print("3. Install and approve LocalDevVPN on the iPhone.")
    print("BUILD_ONLY: Full Xcode and an Apple Development identity are needed only when rebuilding iPhone payloads.")
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
    ok &= build_host_device_bridge(runner)
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
    ok &= run_step(
        runner,
        "No-Xcode device discovery CLI tests",
        "device-discovery-cli-tests",
        [sys.executable, str(ROOT / "scripts" / "checks" / "test_device_discovery_cli.py")],
    )
    ok &= run_step(runner, "POCUnitChecks", "swift-run-pocunitchecks", ["swift", "run", "--package-path", str(IOS_DIR), "POCUnitChecks"])
    ok &= test_mac_app(runner)
    ok &= build_mac_app(runner)
    ok &= build_idevice(runner)
    ok &= verify_idevice(runner)
    ok &= build_host_device_bridge(runner)
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


def command_installation_baseline(args: argparse.Namespace) -> int:
    """Run the reproducible build-only baseline required before Installation V2."""
    runner = Runner(verbose=args.verbose)
    print("Veya Installation V2 Baseline")
    print("")
    cargo = discover_tool("cargo")
    rustc = discover_tool("rustc")
    rustfmt = discover_tool("rustfmt")
    if not cargo or not rustc or not rustfmt:
        print_step("FAIL", "Pinned Rust tools", "cargo, rustc, and rustfmt must resolve through rustup")
        return 1

    # Workspace manifest: the signer crate is tested, linted, and formatted with the bridge.
    manifest = NATIVE_WORKSPACE_DIR / "Cargo.toml"
    ok = True
    ok &= run_step(runner, "Bundle identifier inventory", "baseline-bundle-identifiers", [sys.executable, str(ROOT / "scripts" / "checks" / "check_bundle_identifiers.py")])
    ok &= run_step(runner, "No-Xcode consumer runtime policy", "baseline-no-xcode-runtime", [sys.executable, str(ROOT / "scripts" / "checks" / "check_no_xcode_consumer_runtime.py")])
    ok &= run_step(runner, "No-Xcode install routing policy", "baseline-no-xcode-routing", [sys.executable, str(ROOT / "scripts" / "checks" / "check_no_xcode_install_routing.py")])
    ok &= run_step(runner, "Artifact identity checks", "baseline-artifact-identity", [sys.executable, str(ROOT / "scripts" / "checks" / "test_artifact_identity.py")])
    ok &= run_step(runner, "Device discovery CLI checks", "baseline-device-discovery", [sys.executable, str(ROOT / "scripts" / "checks" / "test_device_discovery_cli.py")])
    ok &= run_step(runner, "Installation V2 secret scan", "baseline-v2-secrets", [sys.executable, str(ROOT / "scripts" / "checks" / "check_installation_v2_secrets.py")])
    ok &= run_step(runner, "Installation V2 legacy-signing guard", "baseline-v2-legacy-guard", [sys.executable, str(ROOT / "scripts" / "checks" / "check_legacy_signing_routes.py"), "--scope", "v2"])
    ok &= run_step(runner, "Rust formatting", "baseline-rust-fmt", [cargo, "fmt", "--manifest-path", str(manifest), "--all", "--check"])
    ok &= run_step(runner, "Rust check", "baseline-rust-check", [cargo, "check", "--manifest-path", str(manifest), "--workspace", "--locked"])
    ok &= run_step(runner, "Rust clippy", "baseline-rust-clippy", [cargo, "clippy", "--manifest-path", str(manifest), "--all-targets", "--workspace", "--locked", "--", "-D", "warnings"])
    ok &= run_step(runner, "Rust tests", "baseline-rust-test", [cargo, "test", "--manifest-path", str(manifest), "--workspace", "--locked"])
    module_cache = ROOT / ".build" / "implementation-v2-module-cache"
    module_cache.mkdir(parents=True, exist_ok=True)
    # The Swift signer facade tests load the real bridge dylib; without it they would skip.
    ok &= run_step(runner, "Rust debug bridge for Swift signer tests", "baseline-rust-debug-bridge",
                   [cargo, "build", "--manifest-path", str(manifest), "--locked", "-p", "iossim-device-bridge"])
    swift_env = merged_env({
        "CLANG_MODULE_CACHE_PATH": str(module_cache),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(module_cache),
        "VEYA_SIGNING_TEST_LIBRARY": str(NATIVE_WORKSPACE_DIR / "target" / "debug" / "libiossim_device_bridge.dylib"),
    })
    swift_command = ["swift", "test", "--package-path", str(MAC_DIR)]
    if args.defer_m4:
        print_step("DEFERRED", "M4", "DEVELOPMENT ONLY; secure persistence remains a pre-release blocker")
        swift_command += ["--skip", "SigningKeyStoreTests.testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction"]
    ok &= run_step(runner, "macOS Swift tests", "baseline-macos-swift", swift_command, env=swift_env)
    ok &= run_step(runner, "iOS shared unit checks", "baseline-ios-unit", ["swift", "run", "--package-path", str(IOS_DIR), "POCUnitChecks"], env=swift_env)
    for architecture in RELEASE_CONFIG.architectures:
        rust_architecture = "aarch64" if architecture == "arm64" else architecture
        target = f"{rust_architecture}-apple-darwin"
        ok &= run_step(
            runner,
            f"Rust release build {target}",
            f"baseline-rust-release-{target}",
            [cargo, "build", "--manifest-path", str(manifest), "--release", "--locked", "--target", target],
        )
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


def assert_iphone_payload_capability_sources() -> None:
    project = (IOS_PROJECT / "project.pbxproj").read_text(encoding="utf-8", errors="replace")
    runner_scheme = (IOS_PROJECT / "xcshareddata" / "xcschemes" / "IOSSimPayloadRunner.xcscheme").read_text(encoding="utf-8")
    app_source = (IOS_DIR / "App" / "IOSSimOnDeviceDVTPOCApp.swift").read_text(encoding="utf-8")
    inbox_source = (IOS_DIR / "Sources" / "IOSSimOnDeviceDVTPOC" / "AutomaticPairingInbox.swift").read_text(encoding="utf-8")
    pairing_store_source = (IOS_DIR / "Sources" / "IOSSimOnDeviceDVTPOC" / "PairingStore.swift").read_text(encoding="utf-8")
    vpn_setup_source = (IOS_DIR / "Sources" / "IOSSimOnDeviceDVTPOC" / "LocalDevVPNSetupInbox.swift").read_text(encoding="utf-8")
    rich_runtime_source = (IOS_DIR / "Sources" / "IOSSimOnDeviceDVTPOC" / "RichRuntimeProofInbox.swift").read_text(encoding="utf-8")
    mapping_source = (IOS_DIR / "Sources" / "IOSSimOnDeviceDVTPOC" / "DvtLocationClient.swift").read_text(encoding="utf-8")
    required = {
        "AutomaticPairingInbox target membership": project.count("AutomaticPairingInbox.swift in Sources") >= 2,
        "automatic pairing startup hook": "AutomaticPairingInboxController()" in app_source and "inbox.reconcile()" in app_source,
        "LocalDevVPN setup target membership": project.count("LocalDevVPNSetupInbox.swift in Sources") >= 2,
        "LocalDevVPN setup startup hook": "LocalDevVPNSetupInboxController()" in app_source and "reconcileIfRequested()" in app_source,
        "LocalDevVPN functional readiness": "localDevVPNFunctionalReady" in vpn_setup_source and "10.7.0.1" in vpn_setup_source,
        "Rich runtime proof target membership": project.count("RichRuntimeProofInbox.swift in Sources") >= 2,
        "Rich runtime proof bounded inbox": (
            "RichRuntimeProofInboxController" in rich_runtime_source
            and "rich-runtime-proof.request" in rich_runtime_source
            and "rich-runtime-proof.receipt" in rich_runtime_source
        ),
        "runtime proof verifies location via Core Location": (
            "dvtLocationVerified" in rich_runtime_source
            and "richLocationVerified" in rich_runtime_source
            and "waitForCoordinate" in rich_runtime_source
        ),
        "automatic pairing receipt": "AutomaticPairingReceipt" in inbox_source and "remote-pairing.receipt" in inbox_source,
        "pairing Keychain candidate import": (
            "KeychainRPPairingStore()" in inbox_source
            and "importCandidatePairingData" in inbox_source
            and "kSecClassGenericPassword" in pairing_store_source
            and "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in pairing_store_source
        ),
        "runtime mapping consumer": "runtime-mapping.json" in mapping_source and "DeliveredRuntimeMapping" in mapping_source,
        "payload-only runner scheme": "IOSSimLocationControlUITests" in runner_scheme and "IOSSimLocationWitness" not in runner_scheme,
    }
    missing = [name for name, present in required.items() if not present]
    if missing:
        raise RuntimeError("PAYLOAD_CAPABILITY_SOURCE_MISMATCH: " + ", ".join(missing))


def assert_iphone_main_binary_capabilities(app: Path) -> None:
    info = read_bundle_info(app)
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise RuntimeError("PAYLOAD_CAPABILITY_BINARY_MISMATCH: main CFBundleExecutable is missing")
    executable = app / executable_name
    try:
        binary = executable.read_bytes()
    except OSError as exc:
        raise RuntimeError(f"PAYLOAD_CAPABILITY_BINARY_MISMATCH: cannot read main executable: {exc}") from exc
    markers = [
        b"AutomaticPairingInboxController",
        b"remote-pairing.bootstrap",
        b"remote-pairing.receipt",
        b"com.iossim.on-device-dvt-poc.rppairing",
        b"runtime-mapping.json",
        b"LocalDevVPNSetupInboxController",
        b"localdevvpn.request",
        b"localdevvpn.receipt",
        b"RichRuntimeProofInboxController",
        b"rich-runtime-proof.request",
        b"rich-runtime-proof.receipt",
        b"dvtLocationVerified",
        b"richLocationVerified",
    ]
    missing = [marker.decode("utf-8") for marker in markers if marker not in binary]
    if missing:
        raise RuntimeError("PAYLOAD_CAPABILITY_BINARY_MISMATCH: " + ", ".join(missing))


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


def payload_source_dirty() -> bool:
    result = subprocess.run(
        ["git", "status", "--porcelain", "--", "ios"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return bool(result.stdout.strip()) if result.returncode == 0 else True


def payload_source_tree_sha256() -> str:
    """Fingerprint the checked-in and generated inputs that define iPhone payload bytes."""
    inputs = [
        IOS_DIR / "Package.swift",
        IOS_DIR / "App",
        IOS_DIR / "Sources",
        IOS_DIR / "Tests",
        IOS_DIR / "LocationWitness",
        IOS_PROJECT / "project.pbxproj",
        IOS_PROJECT / "xcshareddata" / "xcschemes",
        IOS_DIR / "Vendor" / "idevice" / "include",
        IOS_DIR / "Vendor" / "idevice" / "lib" / "libidevice_ffi.a",
    ]
    hasher = hashlib.sha256()
    files: list[Path] = []
    for item in inputs:
        if item.is_file() or item.is_symlink():
            files.append(item)
        elif item.is_dir():
            files.extend(path for path in item.rglob("*") if path.is_file() or path.is_symlink())
    for file in sorted(set(files), key=lambda path: path.relative_to(ROOT).as_posix()):
        relative = file.relative_to(ROOT).as_posix()
        hasher.update(relative.encode("utf-8"))
        hasher.update(b"\0")
        if file.is_symlink():
            hasher.update(b"symlink\0")
            hasher.update(os.readlink(file).encode("utf-8"))
        else:
            with file.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                    hasher.update(chunk)
        hasher.update(b"\0")
    return hasher.hexdigest()


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


def build_universal_macos_products(runner: Runner, local_test_only: bool = False, configuration: str = "release") -> Path:
    if configuration not in {"debug", "release"}:
        raise ValueError("unsupported Mac configuration")
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
        scratch = intermediates / (f"macos-{architecture}" if configuration == "release" else f"macos-development-{architecture}")
        triple = f"{architecture}-apple-macosx{RELEASE_CONFIG.minimum_macos}"
        base = [
            "swift", "build",
            "--package-path", str(MAC_DIR),
            "--scratch-path", str(scratch),
            "--configuration", configuration,
            "--triple", triple,
            "--sdk", sdk.stdout.strip(),
            "-Xswiftc", "-D", "-Xswiftc", "IOSSIM_BUNDLED_ENGINE",
        ]
        if local_test_only:
            base += ["-Xswiftc", "-D", "-Xswiftc", "IOSSIM_LOCAL_TEST_ONLY"]
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

    universal = intermediates / ("macos-universal" if configuration == "release" else "macos-development-universal")
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
        # The executable name is an internal bundle detail and stays stable
        # through the IOSSim -> Veya display-name migration.
        "CFBundleExecutable": "IOSSim",
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


def write_dependency_sbom(resources_dir: Path) -> Path:
    cargo_lock_path = NATIVE_WORKSPACE_DIR / "Cargo.lock"
    swift_lock_path = MAC_DIR / "Package.resolved"
    cargo_lock = tomllib.loads(cargo_lock_path.read_text(encoding="utf-8"))
    swift_lock = json.loads(swift_lock_path.read_text(encoding="utf-8"))
    packages: list[dict[str, Any]] = []

    def spdx_id(name: str, version: str) -> str:
        token = re.sub(r"[^A-Za-z0-9.-]", "-", f"{name}-{version}")
        return f"SPDXRef-Package-{token}"

    for package in cargo_lock.get("package", []):
        name = str(package.get("name") or "unknown")
        version = str(package.get("version") or "unknown")
        external_refs = []
        if package.get("source"):
            external_refs.append({
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:cargo/{name}@{version}",
            })
        item: dict[str, Any] = {
            "SPDXID": spdx_id(name, version),
            "name": name,
            "versionInfo": version,
            "downloadLocation": str(package.get("source") or "NOASSERTION"),
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "externalRefs": external_refs,
        }
        if package.get("checksum"):
            item["checksums"] = [{"algorithm": "SHA256", "checksumValue": package["checksum"]}]
        packages.append(item)

    for pin in swift_lock.get("pins", []):
        state = pin.get("state", {})
        name = str(pin.get("identity") or "unknown")
        version = str(state.get("version") or state.get("revision") or "unknown")
        packages.append({
            "SPDXID": spdx_id(name, version),
            "name": name,
            "versionInfo": version,
            "downloadLocation": str(pin.get("location") or "NOASSERTION"),
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:swift/{name}@{version}",
            }],
        })

    packages.sort(key=lambda package: (package["name"], package["versionInfo"]))
    created = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    product_id = f"SPDXRef-Product-{re.sub(r'[^A-Za-z0-9.-]', '-', RELEASE_CONFIG.product_name)}"
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"{RELEASE_CONFIG.product_name}-{MAC_VERSION}-build{MAC_BUILD_NUMBER}",
        "documentNamespace": (
            f"https://github.com/Reshwant-Borra/IOSSim/releases/sbom/"
            f"{source_commit()}/{payload_source_tree_sha256()[:16]}"
        ),
        "creationInfo": {"created": created, "creators": [f"Tool: {RELEASE_CONFIG.product_name} canonical release pipeline"]},
        "packages": [{
            "SPDXID": product_id,
            "name": RELEASE_CONFIG.product_name,
            "versionInfo": MAC_VERSION,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
        }, *packages],
        "relationships": [
            {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": product_id},
            *[
                {"spdxElementId": product_id, "relationshipType": "DEPENDS_ON", "relatedSpdxElement": package["SPDXID"]}
                for package in packages
            ],
        ],
        "buildInputs": {
            "cargoLockSHA256": sha256_file(cargo_lock_path),
            "swiftPackageResolvedSHA256": sha256_file(swift_lock_path),
        },
    }
    destination = resources_dir / SBOM_FILE_NAME
    destination.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return destination


def write_mpl_notices(notices_dir: Path) -> int:
    """MPL-2.0 §3.2: ship each covered crate's license and where its source is."""
    cargo = discover_tool("cargo")
    if not cargo:
        raise RuntimeError("cargo is required to generate MPL-2.0 notices")
    metadata = json.loads(subprocess.run(
        [cargo, "metadata", "--format-version", "1", "--locked",
         "--manifest-path", str(NATIVE_WORKSPACE_DIR / "Cargo.toml")],
        check=True, text=True, stdout=subprocess.PIPE,
        # The toolchain cargo needs its sibling rustc on PATH.
        env={**os.environ, "PATH": f"{Path(cargo).parent}{os.pathsep}{os.environ.get('PATH', '')}"},
    ).stdout)
    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    # Walk only normal (shipped) dependencies from the bridge; dev/build tools do not ship.
    root = next(p["id"] for p in metadata["packages"] if p["name"] == "iossim-device-bridge")
    shipped, pending = set(), [root]
    while pending:
        current = pending.pop()
        if current in shipped:
            continue
        shipped.add(current)
        for dep in nodes[current]["deps"]:
            if any(kind.get("kind") is None for kind in dep["dep_kinds"]):
                pending.append(dep["pkg"])
    sections = []
    for package in sorted((packages[i] for i in shipped), key=lambda p: (p["name"], p["version"])):
        if "MPL-2.0" not in (package.get("license") or ""):
            continue
        crate_dir = Path(package["manifest_path"]).parent
        license_file = next((crate_dir / n for n in ("LICENSE", "LICENSE.txt", "LICENSE-MPL") if (crate_dir / n).is_file()), None)
        if license_file is None:
            raise RuntimeError(f"MPL-2.0 crate {package['name']} {package['version']} has no license file")
        source = (f"https://crates.io/crates/{package['name']}/{package['version']}"
                  if package.get("source") else "Veya source distribution: native/" + crate_dir.name)
        sections.append(
            f"== {package['name']} {package['version']} (MPL-2.0)\n"
            f"Source Code Form: {source}\n"
            f"Repository: {package.get('repository') or 'n/a'}\n\n"
            f"{license_file.read_text(encoding='utf-8').strip()}\n"
        )
    if not sections:
        raise RuntimeError("expected MPL-2.0 signer dependencies in the shipped bridge graph")
    (notices_dir / "MPL-2.0-Notices.txt").write_text(
        "The native bridge includes the following MPL-2.0 covered software, unmodified.\n"
        "The Source Code Form of each is available at the location listed.\n\n" + "\n".join(sections),
        encoding="utf-8",
    )
    return len(sections)


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
    shutil.copy2(BIGINT_LICENSE_SOURCE, notices / "BigInt-LICENSE.txt")
    write_mpl_notices(notices)
    write_dependency_sbom(resources)
    if not HOST_BRIDGE_LIB.is_file():
        raise RuntimeError("native Mac device bridge dylib is missing; run the host bridge build first")
    bridge_resources = resources / "NativeDeviceBridge"
    bridge_resources.mkdir()
    shutil.copy2(HOST_BRIDGE_LIB, bridge_resources / HOST_BRIDGE_LIB.name)
    os.chmod(bridge_resources / HOST_BRIDGE_LIB.name, 0o755)
    built_protocols = protocol_versions(
        macos_dir / "IOSSimProvisioner",
        bridge_resources / HOST_BRIDGE_LIB.name,
    )
    sanitized_bridge = sanitize_packaged_artifact_paths(bridge_resources)
    if sanitized_bridge:
        print_step("PASS", "Sanitized source paths in native bridge", f"{sanitized_bridge} file(s)")

    assert_iphone_payload_capability_sources()
    main_source = bundled_artifact_specs(ios_configuration)[0][2]
    assert_iphone_main_binary_capabilities(main_source)

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

    payload_timestamp = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    payload_head = source_commit()
    payload_dirty = payload_source_dirty()
    payload_tree_sha256 = payload_source_tree_sha256()
    manifest = {
        "schemaVersion": built_protocols["artifactManifest"],
        "release": {
            "sourceCommit": payload_head,
            "payloadSourceCommit": payload_head,
            "sourceDirty": payload_dirty,
            "buildTimestamp": payload_timestamp,
            "macVersion": MAC_VERSION,
            "buildNumber": MAC_BUILD_NUMBER,
            "variant": RELEASE_CONFIG.variant,
            "helperSchemaVersion": built_protocols["helperProtocol"],
            "payloadSourceHead": payload_head,
            "payloadSourceDirty": payload_dirty,
            "payloadSourceTreeSHA256": payload_tree_sha256,
            "payloadBuildTimestamp": payload_timestamp,
            "payloadBuildVariant": PAYLOAD_BUILD_VARIANT,
            "localDevVPN": {
                "bundleIdentifier": "com.jkcoxson.LocalDevVPN",
                "appStoreIdentifier": "6755608044",
                "minimumVersion": "1.0.0",
                "observedAppStoreVersion": "1.3.0",
                "physicallyTestedVersions": [],
                "setupProtocolSchema": 2,
            },
        },
        "payloadCapabilities": PAYLOAD_CAPABILITIES,
        "components": components,
    }
    (device_artifacts / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    cargo_text = HOST_BRIDGE_MANIFEST.read_text(encoding="utf-8", errors="replace")
    revision_match = re.search(r'idevice.*?rev\s*=\s*"([0-9a-f]+)"', cargo_text, re.DOTALL)
    idevice_revision = revision_match.group(1) if revision_match else "unknown"
    build_provenance = {
        "guiSourceCommit": source_commit(),
        "guiSourceHead": source_commit(),
        "guiSourceDirty": source_dirty(),
        "helperSourceCommit": source_commit(),
        "helperSourceHead": source_commit(),
        "helperSourceDirty": source_dirty(),
        "payloadSourceCommit": manifest["release"]["payloadSourceCommit"],
        "payloadSourceHead": manifest["release"]["payloadSourceHead"],
        "payloadSourceDirty": manifest["release"]["payloadSourceDirty"],
        "payloadSourceTreeSHA256": manifest["release"]["payloadSourceTreeSHA256"],
        "payloadBuildTimestamp": manifest["release"]["payloadBuildTimestamp"],
        "payloadBuildVariant": manifest["release"]["payloadBuildVariant"],
        "payloadManifestVersion": str(manifest["schemaVersion"]),
        "payloadSource": "BUNDLED_PREBUILT_MANIFEST",
        "sourceDirty": source_dirty(),
        "bridgeVersion": f"iossim-device-bridge/0.1.0+idevice-{idevice_revision[:8]}",
        "ideviceRevision": idevice_revision,
        "buildVariant": RELEASE_CONFIG.variant,
        "setupEngine": "BUNDLED_PROVISIONING_ENGINE",
        "setupStateSchema": built_protocols["setupState"],
        "provisioningManifestSchema": built_protocols["provisioningManifest"],
        "helperSchemaVersion": built_protocols["helperProtocol"],
        "artifactManifestSchema": built_protocols["artifactManifest"],
        "nativeBridgeABI": built_protocols["nativeBridgeABI"],
        "discoveryBackend": "NATIVE_IDEVICE_USBMUX",
        "installationBackend": "NATIVE_AFC_INSTALLATION_PROXY",
        "launchBackend": "NATIVE_APPSERVICE_RSD",
        "developerServicesBackend": "NATIVE_COREDEVICE_RSD_REMOTEXPC",
        "developerServicesReceiptSchema": 2,
        "houseArrestBackend": "NATIVE_HOUSE_ARREST_AFC",
        "pairingBackend": "AUTOMATIC_REMOTE_PAIRING_HOUSE_ARREST",
        "ddiBackend": "NATIVE_PERSONALIZED_DEVELOPER_SUPPORT",
        "developerSupportProviderClassification": built_protocols[
            "developerSupportProviderClassification"
        ],
        "legacyFallbackUsed": False,
        "consumerBuildAttempted": False,
        "buildTimestamp": manifest["release"]["buildTimestamp"],
    }
    with (resources / "BuildProvenance.plist").open("wb") as fh:
        plistlib.dump(build_provenance, fh)
    return app_dir


def write_engine_integrity_manifest(app_dir: Path) -> None:
    contents = app_dir / "Contents"
    resources = contents / "Resources"
    helper = contents / "MacOS" / "IOSSimProvisioner"
    bridge = resources / "NativeDeviceBridge" / HOST_BRIDGE_LIB.name
    payload_manifest = resources / "DeviceArtifacts" / "manifest.json"
    protocols = protocol_versions(helper, bridge)
    manifest = {
        "schemaVersion": 1,
        "helperRelativePath": "Contents/MacOS/IOSSimProvisioner",
        "helperSHA256": sha256_file(helper),
        "helperSchemaVersion": protocols["helperProtocol"],
        "setupStateSchemaVersion": protocols["setupState"],
        "artifactManifestSchemaVersion": protocols["artifactManifest"],
        "nativeBridgeRelativePath": f"NativeDeviceBridge/{HOST_BRIDGE_LIB.name}",
        "nativeBridgeSHA256": sha256_file(bridge),
        "nativeBridgeABI": protocols["nativeBridgeABI"],
        "payloadManifestRelativePath": "DeviceArtifacts/manifest.json",
        "payloadManifestSHA256": sha256_file(payload_manifest),
    }
    with (resources / "EngineIntegrity.plist").open("wb") as manifest_file:
        plistlib.dump(manifest, manifest_file, fmt=plistlib.FMT_XML, sort_keys=True)


def sign_self_contained_app(runner: Runner, app_dir: Path) -> bool:
    identity = os.environ.get("IOSSIM_MAC_CODE_SIGN_IDENTITY", "-") or "-"
    ok = True
    bridge = app_dir / "Contents" / "Resources" / "NativeDeviceBridge" / HOST_BRIDGE_LIB.name
    ok &= run_step(
        runner,
        "Sign native device bridge",
        "codesign-native-device-bridge",
        ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp=none", str(bridge)],
    )
    for executable in [app_dir / "Contents" / "MacOS" / "IOSSimProvisioner", app_dir / "Contents" / "MacOS" / "IOSSim"]:
        ok &= run_step(runner, f"Strip {executable.name}", f"strip-{executable.name}", ["/usr/bin/strip", "-x", str(executable)])
        ok &= run_step(runner, f"Sign {executable.name}", f"codesign-{executable.name}", ["codesign", "--force", "--sign", identity, str(executable)])
    if ok:
        write_engine_integrity_manifest(app_dir)
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
    try:
        with MAC_HELPER_LOCAL_ENTITLEMENTS.open("rb") as entitlement_file:
            local_helper_entitlements = plistlib.load(entitlement_file)
    except Exception as exc:
        raise RuntimeError(
            f"invalid local helper entitlement file {MAC_HELPER_LOCAL_ENTITLEMENTS.name}: {exc}"
        ) from exc
    if local_helper_entitlements != {"com.apple.security.cs.disable-library-validation": True}:
        raise RuntimeError(
            "local helper entitlements must contain only the library-validation exception required for the ad-hoc bridge"
        )
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
    bridge = app_dir / "Contents" / "Resources" / "NativeDeviceBridge" / HOST_BRIDGE_LIB.name
    runner.run("developer-id-native-device-bridge", ["/usr/bin/codesign", "--force", "--sign", identity.fingerprint, "--options", "runtime", "--timestamp", str(bridge)])
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
    write_engine_integrity_manifest(app_dir)
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
    bridge = app_dir / "Contents" / "Resources" / "NativeDeviceBridge" / HOST_BRIDGE_LIB.name
    runner.run("local-sign-native-device-bridge", ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", str(bridge)])
    helper = app_dir / "Contents" / "MacOS" / "IOSSimProvisioner"
    runner.run("strip-IOSSimProvisioner-local", ["/usr/bin/strip", "-x", str(helper)])
    runner.run(
        "local-sign-IOSSimProvisioner",
        [
            "/usr/bin/codesign", "--force", "--sign", "-",
            "--identifier", f"{RELEASE_CONFIG.bundle_identifier}.provisioner",
            "--options", "runtime", "--timestamp=none",
            "--entitlements", str(MAC_HELPER_LOCAL_ENTITLEMENTS),
            str(helper),
        ],
    )
    main = app_dir / "Contents" / "MacOS" / "IOSSim"
    runner.run("strip-IOSSim-local", ["/usr/bin/strip", "-x", str(main)])
    write_engine_integrity_manifest(app_dir)
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
        is_local_helper = relative == "Contents/MacOS/IOSSimProvisioner"
        local_library_exception = "com.apple.security.cs.disable-library-validation"
        helper_exception_ok = (
            is_local_helper
            and local_library_exception in entitlements
            and entitlements.count("<key>") == 1
        )
        forbidden = sorted(
            item for item in disallowed_entitlements
            if item in entitlements and not (is_local_helper and item == local_library_exception)
        )
        unexpected_entitlements = "<key>" in entitlements and not helper_exception_ok
        item_ok = (
            valid and ad_hoc_ok and runtime_ok and authority_absent and not forbidden
            and not unexpected_entitlements and (not is_local_helper or helper_exception_ok)
        )
        if item_ok:
            detail = "ad hoc / hardened runtime / helper-only library validation exception" if is_local_helper else "ad hoc / hardened runtime / no entitlements"
            ok &= audit_pass(f"Local signature {relative}", detail)
        else:
            reasons = []
            if not valid: reasons.append("invalid signature")
            if not ad_hoc_ok: reasons.append("not ad hoc")
            if not runtime_ok: reasons.append("hardened runtime absent")
            if not authority_absent: reasons.append("unexpected signing authority")
            if forbidden: reasons.append(f"forbidden entitlements: {', '.join(forbidden)}")
            if unexpected_entitlements: reasons.append("unexpected production entitlements")
            if is_local_helper and not helper_exception_ok: reasons.append("missing exact helper-only library validation exception")
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
    ok &= build_host_device_bridge(runner)
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
        print_step("FAIL", "Assemble self-contained IOSSim.app", redact(str(exc)))
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
        staging = Path(temporary) / RELEASE_CONFIG.product_name
        staging.mkdir()
        shutil.copytree(app_dir, staging / f"{RELEASE_CONFIG.product_name}.app", symlinks=True)
        os.symlink("/Applications", staging / "Applications")
        if output.exists():
            output.unlink()
        runner.run(
            "create-release-dmg",
            [
                "/usr/bin/hdiutil", "create", "-volname", RELEASE_CONFIG.product_name,
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
    identity_report = inspect_dmg(dmg_path)
    assert_identity(identity_report, expected_release_identity({
        "productName": RELEASE_CONFIG.product_name,
        "bundleIdentifier": RELEASE_CONFIG.bundle_identifier,
        "shortVersion": MAC_VERSION,
        "buildNumber": MAC_BUILD_NUMBER,
        "minimumMacOS": RELEASE_CONFIG.minimum_macos,
        "architectures": list(RELEASE_CONFIG.architectures),
        "developerSupportProviderClassification": RELEASE_CONFIG.developer_support_provider_classification,
    }))
    artifact = identity_report["artifact"]
    payload_release = identity_report["payloadManifest"]["release"]
    build_provenance = identity_report["buildProvenance"]
    digest = artifact["sha256"]
    checksum_path = dmg_path.with_suffix(dmg_path.suffix + ".sha256")
    checksum_path.write_text(f"{digest}  {dmg_path.name}\n", encoding="utf-8")
    report_path = dmg_path.with_suffix(".release.json")
    report = {
        "schemaVersion": 2,
        "distributionClass": "PUBLIC_RELEASE",
        "developerID": True,
        "notarized": True,
        "gatekeeperQualified": True,
        "publicDistribution": True,
        "productionUI": True,
        "product": identity_report["productName"],
        "bundleIdentifier": identity_report["bundleIdentifier"],
        "shortVersion": identity_report["version"],
        "buildNumber": identity_report["build"],
        "sourceCommit": build_provenance.get("guiSourceCommit"),
        "sourceDirty": build_provenance.get("sourceDirty"),
        "buildTimestamp": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "variant": RELEASE_CONFIG.variant,
        "channel": "stable",
        "architectures": identity_report["actualArchitectures"],
        "schemas": identity_report["schemas"],
        "components": identity_report["components"],
        "payloads": identity_report["payloads"],
        "signing": identity_report["signing"],
        "notarization": {
            "app": app_notarization,
            "dmg": dmg_notarization,
        },
        "stapled": {"app": True, "dmg": True},
        "developerSupportProvider": {
            "classification": identity_report["developerSupportProvider"]["classification"]
        },
        "dependencies": identity_report["dependencies"],
        "artifact": artifact,
        "artifactIdentity": identity_report,
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return checksum_path, report_path


def write_local_release_sidecars(dmg_path: Path) -> tuple[Path, Path]:
    identity_report = inspect_dmg(dmg_path)
    assert_identity(identity_report, expected_release_identity({
        "productName": RELEASE_CONFIG.product_name,
        "bundleIdentifier": RELEASE_CONFIG.bundle_identifier,
        "shortVersion": MAC_VERSION,
        "buildNumber": MAC_BUILD_NUMBER,
        "minimumMacOS": RELEASE_CONFIG.minimum_macos,
        "architectures": list(RELEASE_CONFIG.architectures),
        "developerSupportProviderClassification": LOCAL_TEST_DDI_PROVIDER,
    }))
    artifact = identity_report["artifact"]
    payload_release = identity_report["payloadManifest"]["release"]
    build_provenance = identity_report["buildProvenance"]
    digest = artifact["sha256"]
    checksum_path = dmg_path.with_suffix(dmg_path.suffix + ".sha256")
    checksum_path.write_text(f"{digest}  {dmg_path.name}\n", encoding="utf-8")
    report_path = dmg_path.with_suffix(".release.json")
    report = {
        "schemaVersion": 2,
        "labels": ["LOCAL TEST BUILD", "NOT NOTARIZED", "NOT FOR PUBLIC DISTRIBUTION"],
        "distributionClass": "LOCAL_TEST_ONLY",
        "developerID": False,
        "notarized": False,
        "gatekeeperQualified": False,
        "publicDistribution": False,
        "productionUI": True,
        "product": identity_report["productName"],
        "bundleIdentifier": identity_report["bundleIdentifier"],
        "shortVersion": identity_report["version"],
        "buildNumber": identity_report["build"],
        "sourceCommit": build_provenance.get("guiSourceCommit"),
        "sourceDirty": build_provenance.get("sourceDirty"),
        "buildTimestamp": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "variant": RELEASE_CONFIG.variant,
        "channel": "local-test",
        "architectures": identity_report["actualArchitectures"],
        "schemas": identity_report["schemas"],
        "components": identity_report["components"],
        "payloads": identity_report["payloads"],
        "signing": identity_report["signing"],
        "stapled": {"app": False, "dmg": False},
        "developerSupportProvider": identity_report["developerSupportProvider"],
        "dependencies": identity_report["dependencies"],
        "artifact": artifact,
        "artifactIdentity": identity_report,
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return checksum_path, report_path


def command_release(args: argparse.Namespace) -> int:
    print("IOSSim Production Release")
    print("")
    if RELEASE_CONFIG.developer_support_provider_classification != "APPROVED_PRODUCTION_SOURCE":
        print_step(
            "FAIL",
            "Production developer-support provider",
            "no approved fresh-acquisition source is configured; public zero-Xcode release is closed",
        )
        return 1
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
    ok &= build_host_device_bridge(runner)
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
        canonical_stem = (
            f"{RELEASE_CONFIG.product_name}-{MAC_VERSION}-build{MAC_BUILD_NUMBER}-"
            f"{source_commit()[:7]}"
        )
        app_zip = RELEASE_OUTPUT_DIR / f"{canonical_stem}.app.zip"
        if app_zip.exists():
            app_zip.unlink()
        runner.run(
            "archive-app-for-notarization",
            ["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app_dir), str(app_zip)],
        )
        app_notarization = submit_for_notarization(app_zip, "app", profile, notarization_dir)
        staple_and_validate(runner, app_dir, "app")

        dmg_path = RELEASE_OUTPUT_DIR / f"{canonical_stem}.dmg"
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
        print_step("WARN", "Repository state", "dirty source is permitted only because this artifact is LOCAL_TEST_ONLY")
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
    ok &= build_host_device_bridge(runner)
    ok &= build_ios(runner, configuration="Release", packaged=True)
    if not ok:
        print_step("FAIL", "Local release prerequisites", "build did not complete")
        return 1
    try:
        mac_products = build_universal_macos_products(runner, local_test_only=True)
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

        canonical_stem = (
            f"{RELEASE_CONFIG.product_name}-{MAC_VERSION}-build{MAC_BUILD_NUMBER}-"
            f"{source_commit()[:7]}-local-test"
        )
        dmg_path = LOCAL_RELEASE_OUTPUT_DIR / f"{canonical_stem}.dmg"
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


def scan_file_for_text_labels(path: Path, labels: list[bytes]) -> list[str]:
    """Find credential labels in printable text, excluding binary entropy matches."""
    try:
        data = path.read_bytes()
    except OSError:
        return []
    printable_runs = re.findall(rb"[\x09\x0a\x0d\x20-\x7e]{4,}", data)
    found: list[str] = []
    for label in labels:
        pattern = re.compile(rb"(?<![A-Za-z0-9_])" + re.escape(label))
        if any(pattern.search(run) for run in printable_runs):
            found.append(label.decode("utf-8"))
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
    packaged_bigint_license = resources / "ThirdPartyNotices" / "BigInt-LICENSE.txt"
    bigint_license_ok = (
        BIGINT_LICENSE_SOURCE.is_file()
        and packaged_bigint_license.is_file()
        and sha256_file(packaged_bigint_license) == sha256_file(BIGINT_LICENSE_SOURCE)
    )
    ok &= audit_pass("BigInt MIT license notice") if bigint_license_ok else audit_fail(
        "BigInt MIT license notice",
        "Contents/Resources/ThirdPartyNotices/BigInt-LICENSE.txt missing or changed",
    )
    sbom_path = resources / SBOM_FILE_NAME
    try:
        sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
        package_names = {str(package.get("name", "")).lower() for package in sbom.get("packages", [])}
        sbom_ok = (
            sbom.get("spdxVersion") == "SPDX-2.3"
            and sbom.get("dataLicense") == "CC0-1.0"
            and {RELEASE_CONFIG.product_name.lower(), "bigint", "idevice"}.issubset(package_names)
            and bool(sbom.get("buildInputs", {}).get("cargoLockSHA256"))
            and bool(sbom.get("buildInputs", {}).get("swiftPackageResolvedSHA256"))
        )
        ok &= audit_pass("SPDX dependency inventory", f"{len(sbom.get('packages', []))} packages") if sbom_ok else audit_fail("SPDX dependency inventory", "schema, roots, or lock digests are incomplete")
    except Exception as exc:
        ok &= audit_fail("SPDX dependency inventory", str(exc))
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
    secret_block_needles = [
        b"-----BEGIN PRIVATE KEY-----",
        b"-----BEGIN RSA PRIVATE KEY-----",
        b"-----BEGIN EC PRIVATE KEY-----",
        b"-----BEGIN ENCRYPTED PRIVATE KEY-----",
    ]
    secret_label_needles = [
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
        secret_hits.extend(f"{relative}: {hit}" for hit in scan_file_for_bytes(path, secret_block_needles))
        secret_hits.extend(f"{relative}: {hit}" for hit in scan_file_for_text_labels(path, secret_label_needles))
    ok &= audit_pass("No source-like files") if not source_like else audit_fail("No source-like files", ", ".join(source_like[:10]))
    ok &= audit_pass("No forbidden development material") if not forbidden_material else audit_fail("No forbidden development material", ", ".join(sorted(set(forbidden_material))[:10]))
    ok &= audit_pass("No developer provisioning profiles packaged") if not mobileprovisions else audit_fail("No developer provisioning profiles packaged", ", ".join(mobileprovisions[:10]))
    ok &= audit_pass("No absolute repository paths") if not path_hits else audit_fail("No absolute repository paths", "; ".join(path_hits[:10]))
    ok &= audit_pass("No private keys/pairing/auth material") if not secret_hits else audit_fail("No private keys/pairing/auth material", "; ".join(secret_hits[:10]))
    ok &= audit_pass("No world-writable files") if not world_writable else audit_fail("No world-writable files", ", ".join(world_writable[:10]))
    try:
        identity_report = inspect_app(app_dir)
        assert_identity(identity_report, expected_release_identity({
            "productName": RELEASE_CONFIG.product_name,
            "bundleIdentifier": RELEASE_CONFIG.bundle_identifier,
            "shortVersion": MAC_VERSION,
            "buildNumber": MAC_BUILD_NUMBER,
            "minimumMacOS": RELEASE_CONFIG.minimum_macos,
            "architectures": list(RELEASE_CONFIG.architectures),
            "developerSupportProviderClassification": (
                LOCAL_TEST_DDI_PROVIDER
                if identity_report.get("distribution", {}).get("distributionClass") == "LOCAL_TEST_ONLY"
                else RELEASE_CONFIG.developer_support_provider_classification
                if identity_report.get("distribution", {}).get("distributionClass") == "PUBLIC_RELEASE"
                else None
            ),
        }))
        ok &= audit_pass(
            "Artifact-derived identity",
            f"architectures={','.join(identity_report['actualArchitectures'])} "
            f"schemas={json.dumps(identity_report['schemas'], sort_keys=True)}",
        )
    except (ArtifactIdentityError, OSError, ValueError) as exc:
        ok &= audit_fail("Artifact-derived identity", str(exc))
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
        observed_identity = inspect_dmg(dmg_path)
        assert_identity(observed_identity, expected_release_identity({
            "productName": RELEASE_CONFIG.product_name,
            "bundleIdentifier": RELEASE_CONFIG.bundle_identifier,
            "shortVersion": MAC_VERSION,
            "buildNumber": MAC_BUILD_NUMBER,
            "minimumMacOS": RELEASE_CONFIG.minimum_macos,
            "architectures": list(RELEASE_CONFIG.architectures),
            "developerSupportProviderClassification": RELEASE_CONFIG.developer_support_provider_classification,
        }))
        metadata_ok = (
            report.get("schemaVersion") == 2
            and report.get("distributionClass") == "PUBLIC_RELEASE"
            and report.get("developerID") is True
            and report.get("notarized") is True
            and report.get("gatekeeperQualified") is True
            and report.get("publicDistribution") is True
            and report.get("productionUI") is True
            and report.get("shortVersion") == MAC_VERSION
            and str(report.get("buildNumber")) == MAC_BUILD_NUMBER
            and report.get("variant") == RELEASE_CONFIG.variant
            and report.get("channel") == "stable"
            and report.get("bundleIdentifier") == RELEASE_CONFIG.bundle_identifier
            and report.get("sourceDirty") is False
            and report.get("artifact", {}).get("sha256") == actual_digest
            and report.get("architectures") == observed_identity.get("actualArchitectures")
            and report.get("developerSupportProvider", {}).get("classification")
                == RELEASE_CONFIG.developer_support_provider_classification
            and report.get("schemas") == observed_identity.get("schemas")
            and report.get("dependencies") == observed_identity.get("dependencies")
            and report.get("artifactIdentity") == observed_identity
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
            expected_app_name = f"{RELEASE_CONFIG.product_name}.app"
            ok &= audit_pass("DMG contents", ", ".join(visible)) if visible == ["Applications", expected_app_name] else audit_fail("DMG contents", ", ".join(visible))
            applications = mount / "Applications"
            ok &= audit_pass("Applications shortcut") if applications.is_symlink() and os.readlink(applications) == "/Applications" else audit_fail("Applications shortcut")
            app_dir = mount / expected_app_name
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
    observed_identity: dict[str, Any] = {}
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        observed_identity = inspect_dmg(dmg_path)
        assert_identity(observed_identity, expected_release_identity({
            "productName": RELEASE_CONFIG.product_name,
            "bundleIdentifier": RELEASE_CONFIG.bundle_identifier,
            "shortVersion": MAC_VERSION,
            "buildNumber": MAC_BUILD_NUMBER,
            "minimumMacOS": RELEASE_CONFIG.minimum_macos,
            "architectures": list(RELEASE_CONFIG.architectures),
            "developerSupportProviderClassification": LOCAL_TEST_DDI_PROVIDER,
        }))
        metadata_ok = (
            report.get("schemaVersion") == 2
            and report.get("distributionClass") == "LOCAL_TEST_ONLY"
            and report.get("developerID") is False
            and report.get("notarized") is False
            and report.get("gatekeeperQualified") is False
            and report.get("publicDistribution") is False
            and report.get("productionUI") is True
            and report.get("labels") == ["LOCAL TEST BUILD", "NOT NOTARIZED", "NOT FOR PUBLIC DISTRIBUTION"]
            and report.get("shortVersion") == MAC_VERSION
            and str(report.get("buildNumber")) == MAC_BUILD_NUMBER
            and report.get("variant") == "PRODUCTION"
            and report.get("channel") == "local-test"
            and report.get("bundleIdentifier") == RELEASE_CONFIG.bundle_identifier
            and report.get("sourceDirty") == observed_identity.get("buildProvenance", {}).get("sourceDirty")
            and report.get("signing", {}).get("classification") == "AD_HOC"
            and report.get("signing", {}).get("teamID") is None
            and report.get("developerSupportProvider", {}).get("classification")
                == LOCAL_TEST_DDI_PROVIDER
            and report.get("artifact", {}).get("sha256") == actual_digest
            and report.get("architectures") == observed_identity.get("actualArchitectures")
            and report.get("schemas") == observed_identity.get("schemas")
            and report.get("dependencies") == observed_identity.get("dependencies")
            and report.get("artifactIdentity") == observed_identity
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
            expected_app_name = f"{RELEASE_CONFIG.product_name}.app"
            ok &= audit_pass("DMG contents", ", ".join(visible)) if visible == ["Applications", expected_app_name] else audit_fail("DMG contents", ", ".join(visible))
            applications = mount / "Applications"
            ok &= audit_pass("Applications shortcut") if applications.is_symlink() and os.readlink(applications) == "/Applications" else audit_fail("Applications shortcut")
            app_dir = mount / expected_app_name
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
                    and release.get("sourceDirty") == observed_identity.get("payloadManifest", {}).get("release", {}).get("sourceDirty")
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
    if report.get("sourceCommit") == observed_identity.get("buildProvenance", {}).get("guiSourceCommit"):
        ok &= audit_pass(
            "Source provenance",
            f"{report.get('sourceCommit')} dirty={str(report.get('sourceDirty')).lower()}",
        )
    else:
        ok &= audit_fail("Source provenance", "sidecar disagrees with mounted BuildProvenance")
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


def _receive_exact(connection: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise ConnectionError("usbmux closed the connection before completing its response")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def probe_apple_usbmux(timeout_seconds: float = 8.0) -> dict[str, Any]:
    endpoint = Path("/var/run/usbmuxd")
    result: dict[str, Any] = {
        "endpoint": "launchd Unix socket /var/run/usbmuxd",
        "connect": False,
        "request": False,
        "count": None,
        "devices": [],
    }
    if not endpoint.exists():
        result.update(error_code="USBMUX_SOCKET_MISSING", error_category="ENDPOINT")
        return result
    request = plistlib.dumps(
        {
            "MessageType": "ListDevices",
            "ClientVersionString": "IOSSim device-debug",
            "ProgName": "iossim-device-debug",
            "kLibUSBMuxVersion": 3,
        },
        fmt=plistlib.FMT_XML,
        sort_keys=False,
    )
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout_seconds)
            connection.connect(str(endpoint))
            result["connect"] = True
            connection.sendall(struct.pack("<IIII", len(request) + 16, 1, 8, 1) + request)
            header = _receive_exact(connection, 16)
            length, version, message_type, _tag = struct.unpack("<IIII", header)
            if length < 16 or length > 16 * 1024 * 1024:
                raise ValueError("usbmux returned an invalid frame length")
            response = plistlib.loads(_receive_exact(connection, length - 16))
            devices = response.get("DeviceList")
            if not isinstance(devices, list):
                raise ValueError("usbmux response did not contain a DeviceList array")
            result.update(request=True, count=len(devices), protocol_version=version, message_type=message_type)
            for item in devices:
                properties = item.get("Properties", {}) if isinstance(item, dict) else {}
                identifier = str(properties.get("SerialNumber") or "")
                result["devices"].append({
                    "identifierHash": hashlib.sha256(identifier.encode()).hexdigest()[:12] if identifier else "unknown",
                    "connection": str(properties.get("ConnectionType") or "unknown").lower(),
                })
    except (OSError, ValueError, plistlib.InvalidFileException, ConnectionError) as exc:
        result.update(
            error_code=type(exc).__name__.upper(),
            error_category="CONNECT" if not result["connect"] else "PROTOCOL",
        )
    return result


def probe_system_usb() -> dict[str, Any]:
    result = subprocess.run(
        ["/usr/sbin/ioreg", "-a", "-p", "IOUSB"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        return {"ok": False, "count": None, "error_code": "IOREG_FAILED"}
    try:
        roots = plistlib.loads(result.stdout)
    except plistlib.InvalidFileException:
        return {"ok": False, "count": None, "error_code": "IOREG_DECODE_FAILED"}

    matches = 0

    def visit(value: Any) -> None:
        nonlocal matches
        if isinstance(value, dict):
            vendor = value.get("idVendor", value.get("USB Vendor ID"))
            product = " ".join(str(value.get(key, "")) for key in (
                "USB Product Name", "kUSBProductString", "IORegistryEntryName", "Product Name",
            )).lower()
            apple_vendor = vendor == 1452 or str(vendor).lower() in {"0x5ac", "0x05ac", "1452"}
            if apple_vendor and "iphone" in product:
                matches += 1
            for child in value.get("IORegistryEntryChildren", []):
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(roots)
    return {"ok": True, "count": matches}


class _CBridgeResult(ctypes.Structure):
    _fields_ = [
        ("status", ctypes.c_int32),
        ("payload", ctypes.POINTER(ctypes.c_uint8)),
        ("payload_len", ctypes.c_size_t),
        ("diagnostic", ctypes.c_char_p),
    ]


def probe_bridge_c_abi(bridge_path: Path, timeout_ms: int = 8_000) -> dict[str, Any]:
    output: dict[str, Any] = {"load": False, "call": False, "count": None, "devices": []}
    try:
        library = ctypes.CDLL(str(bridge_path.resolve()), mode=getattr(os, "RTLD_LOCAL", 4) | getattr(os, "RTLD_NOW", 2))
    except OSError:
        output.update(error_code="BRIDGE_LOAD_FAILED", error_category="LIBRARY")
        return output
    output["load"] = True
    try:
        library.iossim_bridge_abi_version.restype = ctypes.c_uint32
        library.iossim_bridge_version.restype = ctypes.c_char_p
        library.iossim_bridge_list_devices.argtypes = [ctypes.c_uint64]
        library.iossim_bridge_list_devices.restype = ctypes.POINTER(_CBridgeResult)
        library.iossim_bridge_result_free.argtypes = [ctypes.POINTER(_CBridgeResult)]
        abi = int(library.iossim_bridge_abi_version())
        version_bytes = library.iossim_bridge_version()
        version = version_bytes.decode("utf-8", errors="replace") if version_bytes else "unknown"
        pointer = library.iossim_bridge_list_devices(timeout_ms)
        if not pointer:
            output.update(error_code="NULL_RESULT", error_category="FFI", abi=abi, version=version)
            return output
        try:
            value = pointer.contents
            diagnostic = value.diagnostic.decode("utf-8", errors="replace") if value.diagnostic else ""
            payload = ctypes.string_at(value.payload, value.payload_len) if value.payload and value.payload_len else b""
            status = int(value.status)
        finally:
            library.iossim_bridge_result_free(pointer)
        output.update(call=True, abi=abi, version=version, status=status, diagnostic=diagnostic)
        if status != 0:
            output.update(error_code=f"C_STATUS_{status}", error_category="BRIDGE")
            return output
        devices = json.loads(payload.decode("utf-8"))
        if not isinstance(devices, list):
            raise ValueError("bridge device payload is not an array")
        output["count"] = len(devices)
        for item in devices:
            identifier = str(item.get("stableId") or "") if isinstance(item, dict) else ""
            output["devices"].append({
                "identifierHash": hashlib.sha256(identifier.encode()).hexdigest()[:12] if identifier else "unknown",
                "connection": str(item.get("connection") or "unknown") if isinstance(item, dict) else "unknown",
            })
    except (AttributeError, TypeError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
        output.update(error_code="C_ABI_DECODE_FAILED", error_category="FFI")
    return output


def discovery_count_mismatches(apple: int, rust: int, c_abi: int, swift: int) -> list[str]:
    values = {"Apple usbmux": apple, "Rust parsed": rust, "C ABI": c_abi, "Swift": swift}
    first = apple
    return [f"{name}={count}" for name, count in values.items() if count != first]


def command_device_debug(args: argparse.Namespace) -> int:
    print("IOSSim Device Discovery Debug")
    print("")
    usb = probe_system_usb()
    print_step("PASS" if usb.get("ok") else "FAIL", "System USB", f"devices: {usb.get('count', 'unknown')}")

    apple = probe_apple_usbmux()
    apple_ok = bool(apple.get("connect") and apple.get("request"))
    print_step("PASS" if apple_ok else "FAIL", "Apple usbmux", f"devices: {apple.get('count', 'unknown')}")
    print(f"  endpoint: {apple['endpoint']}")
    if not apple_ok:
        print(f"  error: {apple.get('error_category', 'UNKNOWN')}/{apple.get('error_code', 'UNKNOWN')}")

    pair = next(
        ((helper, bridge) for helper, bridge in native_discovery_candidates() if helper.is_file() and bridge.is_file()),
        None,
    )
    if pair is None:
        print_step("FAIL", "Rust bridge", "HELPER_LIBRARY_MISSING")
        print_step("FAIL", "C ABI", "not attempted")
        print_step("FAIL", "Swift", "not attempted")
        print_step("FAIL", "Discovery", "DEVICE_DISCOVERY_UNAVAILABLE")
        return 1
    helper, bridge = pair
    print(f"  bridge: {bridge.resolve()}")
    print(f"  helper: {helper.resolve()}")

    c_probe = probe_bridge_c_abi(bridge)
    c_ok = c_probe.get("load") and c_probe.get("call") and c_probe.get("status") == 0
    rust_count = c_probe.get("count")
    print_step("PASS" if c_ok else "FAIL", "Rust bridge", f"devices: {rust_count if rust_count is not None else 'unknown'}")
    if c_probe.get("version"):
        print(f"  version: {c_probe['version']}")
    print_step("PASS" if c_ok else "FAIL", "C ABI", f"devices: {c_probe.get('count', 'unknown')}")
    if not c_ok:
        print(f"  error: {c_probe.get('error_category', 'UNKNOWN')}/{c_probe.get('error_code', 'UNKNOWN')}")

    swift = discover_native_devices(Runner(verbose=args.verbose, log_commands=False))
    print_step("PASS" if swift.available else "FAIL", "Swift", f"devices: {swift.returned_count}")
    if not swift.available:
        print(f"  error: {swift.error_code or 'UNKNOWN'}")

    if swift.returned_count == 0:
        print_step("SKIP", "Lockdown", "no enumerated device")
    else:
        lockdown_codes = {"LOCKDOWN_FAILED", "TRUST_REQUIRED", "DEVICE_LOCKED"}
        warnings = [item.get("code", "UNKNOWN") for item in swift.diagnostics if item.get("code") in lockdown_codes]
        print_step("WARN" if warnings else "PASS", "Lockdown", ", ".join(warnings) if warnings else "metadata inspected")
        first = swift.devices[0]
        print(f"Product: {first.get('model') or 'iPhone'}")
        print(f"OS: {first.get('osVersion') or 'unknown'}")

    counts_available = apple.get("count") is not None and c_probe.get("count") is not None
    mismatches = []
    if counts_available:
        mismatches = discovery_count_mismatches(
            int(apple["count"]), int(c_probe["count"]), int(c_probe["count"]), swift.returned_count
        )
    if not apple_ok or not c_ok or not swift.available:
        print_step("FAIL", "Discovery", "DEVICE_DISCOVERY_UNAVAILABLE")
        return 1
    if mismatches:
        print_step("FAIL", "Discovery", "COUNT_MISMATCH: " + ", ".join(mismatches))
        return 1
    if swift.returned_count == 0:
        print_step("ACTION", "Discovery", "NO_DEVICE_AT_APPLE_USBMUX")
        return 2
    print_step("PASS", "Discovery", f"devices: {swift.returned_count}")
    return 0


def command_readiness_debug(args: argparse.Namespace) -> int:
    pair = next(
        ((helper, bridge) for helper, bridge in native_discovery_candidates() if helper.is_file() and bridge.is_file()),
        None,
    )
    if pair is None:
        print_step("FAIL", "Developer services", "HELPER_LIBRARY_MISSING")
        return 1
    helper, bridge = pair
    resources = helper.parent.parent / "Resources"
    command = [str(helper), "--resources", str(resources), "developer-services-debug"]
    if args.device:
        command.extend(["--device", args.device])
    environment = merged_env({"IOSSIM_DEVICE_BRIDGE_PATH": str(bridge)})
    return subprocess.run(command, env=environment, check=False).returncode


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
        ("native idevice/usbmux", "runtime", "bundled bridge", "pinned bridge revision", "yes in app", "connect/unlock iPhone", "./iossim device-debug"),
        ("xcrun/devicectl", "developer-only comparison", "Apple developer tools", "n/a", "not used by consumer runtime", "none", "explicit backend comparison only"),
        ("Xcode/xcodebuild", "build-time", "Apple", "15.0+", "yes from packaged runtime", "build machine only", "./iossim package-app"),
        ("SwiftPM package", "build-time", "ios/Package.swift and macos/Package.swift", "Swift tools 5.9", "yes from packaged runtime", "none", "./iossim build"),
        ("iOS app project", "build-time", "ios/IOSSimOnDevicePOC.xcodeproj", "iOS 17 target", "yes from packaged runtime", "Apple signing at package time", "./iossim package-app"),
        ("Mac app", "runtime", "compiled bundle", "macOS 13+", "n/a", "none for ad-hoc development signing", "./iossim audit-app"),
        ("idevice FFI", "build-time", "jkcoxson/idevice pinned commit", PINNED_IDEVICE_COMMIT[:12], "yes from packaged runtime", "Rust required at build time", "./iossim build"),
        ("Rust iOS target", "build-time", "rustup", "aarch64-apple-ios", "yes from packaged runtime", "install rustup on build machine", "./iossim doctor"),
        ("Frontend engineering UI", "development-only", "frontend/package.json", "Node 20+", "yes from packaged runtime", "install Node for tests", "npm test"),
        ("Backend engineering API", "development-only", "backend/requirements.txt", "Python 3.11+", "yes from packaged runtime", "install Python for tests", "pytest backend"),
        ("LocalDevVPN", "runtime", "external iPhone app", "current external app", "no", "install/approve on iPhone", "in-app diagnostics"),
        ("Remote pairing", "runtime", "native IOSSim pairing lifecycle", "current device", "yes", "keep iPhone unlocked when requested", "in-app diagnostics"),
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
        ("installation-baseline", "run the pinned Installation V2 build-only baseline"),
        ("diagnose-apple-srp-init", "run the password-free Apple SRP initialization probe"),
        ("device-debug", "trace no-Xcode device discovery at every boundary"),
        ("readiness-debug", "probe CoreDevice/RSD/AppService readiness without starting runtime"),
        ("device", "build and install internal device-side components"),
        ("info", "print dependency matrix"),
        ("clean", "remove CLI-owned generated state"),
    ]:
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--verbose", action="store_true", help="print detailed command output")
        if name == "installation-baseline":
            p.add_argument("--defer-m4", action="store_true", help="development only: defer the M4 packaged persistence gate; release still requires it")
        if name == "doctor":
            p.add_argument("--json", action="store_true", help="emit machine-readable status")
        if name == "device":
            p.add_argument("--device", help="target a ready iPhone by redacted identifier or exact device name")
        if name == "readiness-debug":
            p.add_argument("--device", help="target an iPhone by exact or redacted identifier")
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
    if args.command == "installation-baseline":
        return command_installation_baseline(args)
    if args.command == "diagnose-apple-srp-init":
        return subprocess.run(
            ["swift", "run", "IOSSimAuthDiagnostic"],
            cwd=str(MAC_DIR),
            env=merged_env(),
            check=False,
        ).returncode
    if args.command == "device-debug":
        return command_device_debug(args)
    if args.command == "readiness-debug":
        return command_readiness_debug(args)
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
