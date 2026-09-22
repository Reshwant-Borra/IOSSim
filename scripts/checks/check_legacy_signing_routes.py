#!/usr/bin/env python3
"""M11 gate (spec 27): prohibited legacy payload-signing symbols in production sources.

--scope v2    Installation V2 modules + signer crates only. Must always pass.
--scope all   Every production source. Fails until the legacy route is removed (M11).
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROHIBITED = {
    "external codesign": r"/usr/bin/codesign|\"codesign\"",
    "security CLI mutation": r"/usr/bin/security|set-key-partition-list",
    "keychain search list": r"SecKeychain(Set|Copy)SearchList",
    "SecIdentity signing": r"SecIdentityCreate\w*|kSecClassIdentity",
    "ACL/partition repair": r"SecKeychainItemSetAccess|SecTrustedApplicationCreateFromPath|SecAccessCreate",
    "custom keychain creation": r"SecKeychainCreate\b",
}
V2 = [ROOT / "macos/Sources/IOSSimMacCore/Installation", ROOT / "native/veya-signing-core/src",
      ROOT / "native/iossim-device-bridge/src/signing_ffi.rs"]
ALL = [ROOT / "macos/Sources", ROOT / "native/iossim-device-bridge/src", ROOT / "native/veya-signing-core/src"]
# Spec 27 enforcement for the new route: no subprocess anywhere in engine/payload work. The only
# Installation V2 process launch is the client starting the packaged helper itself.
V2_ONLY = {"subprocess execution": r"\bProcess\(\)|ProcessRunner|posix_spawn|NSTask|std::process::Command"}
V2_SUBPROCESS_ALLOWED = {"macos/Sources/IOSSimMacCore/Installation/ProvisionerEngineClient.swift"}


def production_files(roots):
    for root in roots:
        files = [root] if root.is_file() else sorted(root.rglob("*"))
        for path in files:
            if path.suffix not in {".swift", ".rs"} or "test" in path.name.lower():
                continue
            yield path


def strip_rust_tests(text: str) -> str:
    # `#[cfg(test)]` items (test-only diagnostics such as the independent codesign verifier) do not ship.
    return re.split(r"#\[cfg\(test\)\]\s*mod tests", text)[0]


def findings(roots, v2=False):
    rules = dict(PROHIBITED)
    if v2:
        rules.update(V2_ONLY)
    for path in production_files(roots):
        text = path.read_text(encoding="utf-8", errors="replace")
        # Comments document prohibitions; only code counts.
        text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
        if path.suffix == ".rs":
            text = strip_rust_tests(text)
            text = re.sub(r"#\[cfg\(test\)\]\s*(if|\{)[\s\S]*?\n    \}\n", "", text)
        for label, pattern in rules.items():
            if label in V2_ONLY and str(path.relative_to(ROOT)) in V2_SUBPROCESS_ALLOWED:
                continue
            count = len(re.findall(pattern, text))
            if count:
                yield path.relative_to(ROOT), label, count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scope", choices=["v2", "all"], default="all")
    args = parser.parse_args()
    results = list(findings(V2, v2=True) if args.scope == "v2" else findings(ALL))
    for path, label, count in results:
        print(f"PROHIBITED {label}: {path} ({count})")
    print(f"scope={args.scope} findings={len(results)} files={len({r[0] for r in results})}")
    return 1 if results else 0


if __name__ == "__main__":
    sys.exit(main())
