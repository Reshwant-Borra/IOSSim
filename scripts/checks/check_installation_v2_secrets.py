#!/usr/bin/env python3
"""Fail if Installation V2 sources, tests, fixtures, or evidence contain secret material.

Deliberate test fixtures must be marked on the line (or, for PEM blocks, the next line) with
CANARY, SENTINEL, SYNTHETIC, or the reserved example.invalid domain.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOTS = [
    "macos/Sources/IOSSimMacCore/Installation",
    "macos/Sources/VeyaQualify",
    "macos/Tests/IOSSimMacCoreTests",
    "native/veya-signing",
    "docs/installation-v2/implementation-v2",
]
SKIP_PARTS = {"target", ".build", "__pycache__"}
PATTERNS = [
    re.compile(rb"-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----"),
    re.compile(rb"(?i)\b(?:password|passcode|2fa_?code|session_?token|wrapping_?key|pairing_?psk)\b\s*[:=]\s*[\"'][^\"'\s]{6,}[\"']"),
    re.compile(rb"(?i)\bmyacinfo=[A-Za-z0-9+/=]{16,}"),
    re.compile(rb"(?i)X-Apple-GS-Token\s*[:=]\s*[A-Za-z0-9+/=]{16,}"),
]


FIXTURE_MARKERS = (b"CANARY", b"SENTINEL", b"SYNTHETIC", b"EXAMPLE.INVALID")


def is_fixture(*lines: bytes) -> bool:
    return any(marker in line.upper() for line in lines for marker in FIXTURE_MARKERS)


def scan(path: Path) -> list[str]:
    hits = []
    lines = path.read_bytes().splitlines()
    for number, line in enumerate(lines, start=1):
        following = lines[number] if number < len(lines) else b""
        if is_fixture(line, following):
            continue
        for pattern in PATTERNS:
            if pattern.search(line):
                hits.append(f"{path.relative_to(ROOT)}:{number}")
    return hits


def main() -> int:
    hits: list[str] = []
    scanned = 0
    for relative in SCAN_ROOTS:
        base = ROOT / relative
        if not base.exists():
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file() and not SKIP_PARTS.intersection(path.parts):
                scanned += 1
                hits.extend(scan(path))
    for hit in hits:
        print(f"SECRET {hit}")
    print(f"scanned {scanned} files, {len(hits)} findings")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
