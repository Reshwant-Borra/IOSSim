#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import subprocess
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
REPORT_DIR = ROOT / "docs" / "installation-v2" / "implementation" / "live-qualification"
STATE_PATH = REPORT_DIR / "LIVE_QUALIFICATION_STATE.json"
TIMELINE_PATH = REPORT_DIR / "LIVE_QUALIFICATION_TIMELINE.jsonl"
REPORT_PATH = REPORT_DIR / "LIVE_QUALIFICATION_REPORT.md"
MATRIX_PATH = REPORT_DIR / "LIVE_QUALIFICATION_MATRIX.md"

UDID_RE = re.compile(
    r"\b(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|"
    r"[0-9A-Fa-f]{24,40})(?=\s+\(UDID\))"
)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def run(args: list[str], timeout: int = 30) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            args,
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return {
            "command": args,
            "exitCode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
            "timedOut": False,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "command": args,
            "exitCode": None,
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or "",
            "timedOut": True,
        }


def safe_alias(value: str) -> str:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]
    return f"sha256:{digest}"


def redact(text: str) -> str:
    return UDID_RE.sub(lambda match: safe_alias(match.group(0)), text)


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


class Qualification:
    def __init__(self, artifact: Path | None) -> None:
        self.artifact = artifact
        self.records: list[dict[str, Any]] = []
        REPORT_DIR.mkdir(parents=True, exist_ok=True)

    def record(
        self,
        stage: str,
        classification: str,
        expected: str,
        actual: str,
        status: str,
        automatic_action: str,
        error: str | None = None,
        extra: dict[str, Any] | None = None,
    ) -> None:
        item = {
            "timestamp": now(),
            "stage": stage,
            "classification": classification,
            "expectedResult": expected,
            "actualResult": redact(actual),
            "artifactIdentity": self.artifact_identity_safe(),
            "safeDeviceAlias": self.device_alias(),
            "stableErrorCode": error,
            "automaticAction": automatic_action,
            "userAction": None,
            "status": status,
        }
        if extra:
            item.update(extra)
        self.records.append(item)
        with TIMELINE_PATH.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(item, sort_keys=True) + "\n")

    def artifact_identity_safe(self) -> dict[str, Any] | None:
        if not self.artifact:
            return None
        if not self.artifact.exists():
            return {"path": str(self.artifact), "exists": False}
        return {
            "path": str(self.artifact.relative_to(ROOT)) if self.artifact.is_relative_to(ROOT) else self.artifact.name,
            "sha256": sha256_file(self.artifact),
            "sizeBytes": self.artifact.stat().st_size,
        }

    def device_alias(self) -> str | None:
        for record in reversed(self.records):
            alias = record.get("discoveredDeviceAlias")
            if alias:
                return alias
        return None

    def baseline(self) -> None:
        branch = run(["git", "branch", "--show-current"])
        head = run(["git", "rev-parse", "HEAD"])
        status = run(["git", "status", "--branch", "--short"])
        detail = "\n".join([
            f"branch={branch['stdout'].strip()}",
            f"head={head['stdout'].strip()}",
            redact(status["stdout"].strip()),
        ])
        ok = branch["exitCode"] == head["exitCode"] == status["exitCode"] == 0
        self.record(
            "baseline",
            "AUTOMATABLE",
            "Capture branch, HEAD, and non-destructive git status",
            detail,
            "PASS" if ok else "FAIL",
            "git branch/rev-parse/status",
            None if ok else "VEYA-QUAL-BASELINE",
        )

    def discover_device(self) -> None:
        result = run(["xcrun", "devicectl", "list", "devices"])
        output = result["stdout"] + result["stderr"]
        physical_lines = [line for line in output.splitlines() if "physical" in line.lower()]
        available = [line for line in physical_lines if "available" in line.lower()]
        alias = None
        os_version = None
        model = None
        if available:
            udids = UDID_RE.findall(available[0])
            if udids:
                alias = safe_alias(udids[0])
            version_match = re.search(r"\((\d+(?:\.\d+)*)\)", available[0])
            if version_match:
                os_version = version_match.group(1)
            model_match = re.search(r"available \(paired\)\s+(.+?)\s+physical", available[0])
            if model_match:
                model = model_match.group(1).strip()
        ok = result["exitCode"] == 0 and alias is not None
        self.record(
            "connected-device-discovery",
            "PHYSICAL_DEVICE_REQUIRED",
            "One paired physical iPhone available for Veya qualification",
            output,
            "PASS" if ok else "BLOCKED",
            "xcrun devicectl list devices",
            None if ok else "VEYA-QUAL-NO-PAIRED-IPHONE",
            {
                "discoveredDeviceAlias": alias,
                "deviceOSVersion": os_version,
                "deviceModel": model,
                "connectionType": "USB_OR_NETWORK_REPORTED_BY_COREDEVICE",
            },
        )

    def inspect_authorization_item(self) -> None:
        result = run([
            "security",
            "find-generic-password",
            "-s",
            "com.iossim.mac.apple-authorization",
            "-a",
            "personal-team-session",
        ])
        output = result["stdout"] + result["stderr"]
        missing = "could not be found" in output.lower()
        ok = result["exitCode"] == 0 or missing
        self.record(
            "apple-authorization-keychain-item-metadata",
            "AUTOMATABLE",
            "Capture metadata only for the Veya-owned authorization item",
            output if output.strip() else "not found",
            "PASS" if ok else "FAIL",
            "security metadata lookup without secret retrieval",
            None if ok else "VEYA-QUAL-AUTH-ITEM-METADATA",
        )

    def inspect_artifact(self) -> None:
        if not self.artifact:
            self.record(
                "artifact-identity",
                "AUTOMATABLE",
                "Artifact supplied when build stage has produced one",
                "No artifact argument supplied",
                "NOT_RUN",
                "skip",
            )
            return
        if not self.artifact.exists():
            self.record(
                "artifact-identity",
                "AUTOMATABLE",
                "Artifact path exists",
                str(self.artifact),
                "FAIL",
                "filesystem stat",
                "VEYA-QUAL-ARTIFACT-MISSING",
            )
            return
        actual = json.dumps(self.artifact_identity_safe(), sort_keys=True)
        self.record(
            "artifact-identity",
            "AUTOMATABLE",
            "SHA-256 and size captured for exact artifact under test",
            actual,
            "PASS",
            "sha256/stat",
        )

    def secret_scan_reports(self) -> None:
        patterns = [
            "password=",
            "2FA code",
            "Apple token:",
            "BEGIN PRIVATE KEY",
            "pairing record:",
            "raw UDID:",
            "PSK=",
        ]
        text = "\n".join(path.read_text(encoding="utf-8", errors="replace") for path in REPORT_DIR.glob("LIVE_QUALIFICATION_*") if path.is_file())
        hits = [pattern for pattern in patterns if pattern.lower() in text.lower()]
        self.record(
            "support-secret-scan",
            "AUTOMATABLE",
            "Live qualification artifacts contain no secret material",
            "hits=" + ",".join(hits) if hits else "no hits",
            "PASS" if not hits else "FAIL",
            "keyword sentinel scan of live qualification outputs",
            None if not hits else "VEYA-QUAL-SECRET-SCAN",
        )

    def write_outputs(self) -> None:
        state = {
            "schemaVersion": 1,
            "generatedAt": now(),
            "startingBuild": "3",
            "records": self.records,
        }
        STATE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
        lines = [
            "# Live Qualification Report",
            "",
            f"Generated: {state['generatedAt']}",
            "",
            "| Stage | Classification | Status | Error | Actual |",
            "| --- | --- | --- | --- | --- |",
        ]
        for record in self.records:
            actual = str(record["actualResult"]).replace("\n", "<br>")
            lines.append(
                f"| {record['stage']} | {record['classification']} | {record['status']} | "
                f"{record.get('stableErrorCode') or ''} | {actual[:500]} |"
            )
        REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.write_matrix()

    def write_matrix(self) -> None:
        rows = [
            "Mac launch", "authorization first use", "authorization reuse", "authorization upgrade",
            "authorization reinstall", "certificate fresh", "certificate reuse", "certificate full",
            "certificate stale", "certificate revoke", "profile generation", "profile refresh",
            "signing probe", "native install", "install interruption", "inventory", "DDI empty cache",
            "DDI cache reuse", "TSS", "mount", "pairing initial", "pairing repair", "VPN install",
            "VPN permission", "VPN running", "AppService", "runner", "Rich proof", "Spoof", "Drive",
            "clear", "relaunch", "reinstall", "upgrade", "secret scan",
        ]
        status_by_row = {
            "secret scan": "PASS" if self.records and self.records[-1]["status"] == "PASS" else "FAIL",
        }
        lines = [
            "# Live Qualification Matrix",
            "",
            "| Row | AUTOMATED | PHYSICAL | USER AUTH | STATUS | LAST BUILD | EVIDENCE | ERROR | NOTES |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for row in rows:
            status = status_by_row.get(row, "NOT_RUN")
            physical = "yes" if row in {"native install", "inventory", "DDI empty cache", "mount", "pairing initial", "VPN running", "AppService", "runner", "Rich proof", "Spoof", "Drive", "clear"} else "no"
            lines.append(f"| {row} | yes | {physical} | no | {status} | 3 | LIVE_QUALIFICATION_TIMELINE.jsonl |  |  |")
        MATRIX_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Veya live physical qualification harness")
    parser.add_argument("--artifact", type=Path)
    args = parser.parse_args()
    TIMELINE_PATH.unlink(missing_ok=True)
    qualification = Qualification(args.artifact)
    qualification.baseline()
    qualification.discover_device()
    qualification.inspect_authorization_item()
    qualification.inspect_artifact()
    qualification.secret_scan_reports()
    qualification.write_outputs()
    failed = [record for record in qualification.records if record["status"] in {"FAIL", "BLOCKED"}]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
