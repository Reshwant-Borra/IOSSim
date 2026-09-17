#!/usr/bin/env python3
"""Artifact-derived identity inspection for IOSSim/Veya release outputs.

Desired release configuration is accepted only as an expectation. Every value
reported by this module is read from the built app or mounted DMG.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
WORKSPACE_TEMP_ROOT = ROOT / ".build" / "iossim" / "artifact-identity-tmp"


class ArtifactIdentityError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def sha256_tree(path: Path) -> str:
    """Compatibility hash used by the current DeviceArtifacts manifest."""
    hasher = hashlib.sha256()
    files: list[Path] = []
    for root, dirs, names in os.walk(path):
        dirs[:] = [name for name in dirs if not name.startswith(".")]
        for name in names:
            if not name.startswith("."):
                files.append(Path(root) / name)
    for file in sorted(files):
        hasher.update(file.relative_to(path).as_posix().encode("utf-8"))
        hasher.update(b"\0")
        if file.is_symlink():
            hasher.update(b"symlink\0")
            hasher.update(os.readlink(file).encode("utf-8"))
        else:
            with file.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    hasher.update(chunk)
        hasher.update(b"\0")
    return hasher.hexdigest()


def sha256_path(path: Path) -> str:
    return sha256_tree(path) if path.is_dir() else sha256_file(path)


def _run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise ArtifactIdentityError(f"command failed ({Path(args[0]).name}): {detail}")
    return result


def _read_plist(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except Exception as exc:
        raise ArtifactIdentityError(f"cannot read plist {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ArtifactIdentityError(f"plist root is not a dictionary: {path}")
    return value


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ArtifactIdentityError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ArtifactIdentityError(f"JSON root is not an object: {path}")
    return value


def mach_architectures(path: Path) -> list[str]:
    result = _run(["/usr/bin/lipo", "-archs", str(path)])
    architectures = sorted(set(result.stdout.split()))
    if not architectures:
        raise ArtifactIdentityError(f"Mach-O architecture inventory is empty: {path}")
    return architectures


def signing_identity(path: Path) -> dict[str, Any]:
    result = _run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)], check=False)
    detail = f"{result.stdout}\n{result.stderr}"
    if result.returncode != 0:
        return {"classification": "UNSIGNED", "teamID": None, "cdhash": None}
    team_match = re.search(r"^TeamIdentifier=(.+)$", detail, re.MULTILINE)
    cdhash_match = re.search(r"^CDHash=(.+)$", detail, re.MULTILINE)
    if "Signature=adhoc" in detail:
        classification = "AD_HOC"
    elif "Developer ID Application:" in detail:
        classification = "DEVELOPER_ID_APPLICATION"
    else:
        classification = "OTHER_SIGNED"
    team = team_match.group(1).strip() if team_match and team_match.group(1).strip() != "not set" else None
    return {
        "classification": classification,
        "teamID": team,
        "cdhash": cdhash_match.group(1).strip() if cdhash_match else None,
    }


def protocol_versions(helper: Path, bridge: Path) -> dict[str, Any]:
    result = _run([str(helper), "protocol-info", "--json"])
    try:
        envelope = json.loads(result.stdout)
        data = envelope["data"]
        values = {
            "helperProtocol": int(data["helperSchemaVersion"]),
            "setupState": int(data["setupStateSchemaVersion"]),
            "provisioningManifest": int(data["provisioningManifestSchemaVersion"]),
            "artifactManifest": int(data["artifactManifestSchemaVersion"]),
            "nativeBridgeABIExpected": int(data["nativeBridgeABIExpected"]),
            "developerSupportProviderClassification": str(
                data["developerSupportProviderClassification"]
            ),
        }
        if int(envelope["schemaVersion"]) != values["helperProtocol"]:
            raise ArtifactIdentityError("helper protocol envelope disagrees with its protocol-info payload")
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise ArtifactIdentityError(f"invalid helper protocol-info response: {exc}") from exc

    probe = _run([
        sys.executable,
        "-B",
        "-c",
        (
            "import ctypes,sys; "
            "library=ctypes.CDLL(sys.argv[1]); "
            "function=library.iossim_bridge_abi_version; "
            "function.argtypes=[]; function.restype=ctypes.c_uint32; "
            "print(int(function()))"
        ),
        str(bridge),
    ])
    try:
        values["nativeBridgeABI"] = int(probe.stdout.strip())
    except ValueError as exc:
        raise ArtifactIdentityError(f"cannot query native bridge ABI: {probe.stdout!r}") from exc
    return values


def _component(
    app: Path,
    role: str,
    relative_path: str,
    *,
    bundle: bool = False,
) -> dict[str, Any]:
    path = app / relative_path
    if not path.exists():
        raise ArtifactIdentityError(f"required component is missing: {relative_path}")
    item: dict[str, Any] = {
        "role": role,
        "relativePath": relative_path,
        "sizeBytes": path.stat().st_size if path.is_file() else None,
        "sha256": sha256_path(path),
    }
    if path.is_file() and os.access(path, os.X_OK):
        item["architectures"] = mach_architectures(path)
        item["signing"] = signing_identity(path)
    if bundle:
        info = _read_plist(path / "Info.plist")
        executable_name = info.get("CFBundleExecutable")
        item.update({
            "bundleIdentifier": info.get("CFBundleIdentifier"),
            "version": info.get("CFBundleShortVersionString"),
            "build": str(info.get("CFBundleVersion")) if info.get("CFBundleVersion") is not None else None,
        })
        if isinstance(executable_name, str) and (path / executable_name).is_file():
            item["architectures"] = mach_architectures(path / executable_name)
    return item


def inspect_app(app: Path) -> dict[str, Any]:
    app = app.resolve()
    contents = app / "Contents"
    resources = contents / "Resources"
    info = _read_plist(contents / "Info.plist")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise ArtifactIdentityError("Info.plist does not declare CFBundleExecutable")
    main_relative = f"Contents/MacOS/{executable_name}"
    helper_relative = "Contents/MacOS/IOSSimProvisioner"
    bridge_relative = "Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib"
    main = app / main_relative
    helper = app / helper_relative
    bridge = app / bridge_relative
    schemas = protocol_versions(helper, bridge)
    provenance = _read_plist(resources / "BuildProvenance.plist")
    engine_integrity = _read_plist(resources / "EngineIntegrity.plist")
    payload_manifest_path = resources / "DeviceArtifacts" / "manifest.json"
    payload_manifest = _read_json(payload_manifest_path)
    distribution_path = resources / "Distribution.json"
    distribution = _read_json(distribution_path) if distribution_path.is_file() else {}
    sbom_path = resources / "SBOM.spdx.json"
    sbom = _read_json(sbom_path)
    if sbom.get("spdxVersion") != "SPDX-2.3" or not isinstance(sbom.get("packages"), list):
        raise ArtifactIdentityError("packaged SPDX SBOM is missing required schema/package inventory")
    notices_path = resources / "ThirdPartyNotices"
    notice_files = sorted(path for path in notices_path.iterdir() if path.is_file())

    components = [
        _component(app, "macApp", main_relative),
        _component(app, "provisioner", helper_relative),
        _component(app, "nativeDeviceBridge", bridge_relative),
    ]
    payloads: list[dict[str, Any]] = []
    for declaration in payload_manifest.get("components", []):
        if not isinstance(declaration, dict):
            raise ArtifactIdentityError("payload manifest component is not an object")
        relative = declaration.get("relativePath")
        if not isinstance(relative, str) or not relative.startswith("DeviceArtifacts/"):
            raise ArtifactIdentityError("payload manifest component has an invalid relative path")
        inspected = _component(
            app,
            str(declaration.get("role") or "unknown"),
            f"Contents/Resources/{relative}",
            bundle=True,
        )
        inspected["declaredSHA256"] = declaration.get("sha256")
        inspected["declaredBundleIdentifier"] = declaration.get("bundleIdentifier")
        inspected["declaredVersion"] = declaration.get("version")
        inspected["signingMode"] = declaration.get("signingMode")
        payloads.append(inspected)

    mac_architectures = [component["architectures"] for component in components]
    common_architectures = mac_architectures[0] if all(value == mac_architectures[0] for value in mac_architectures) else []
    identity = {
        "schemaVersion": 2,
        "productName": info.get("CFBundleDisplayName") or info.get("CFBundleName"),
        "bundleIdentifier": info.get("CFBundleIdentifier"),
        "version": info.get("CFBundleShortVersionString"),
        "build": str(info.get("CFBundleVersion")) if info.get("CFBundleVersion") is not None else None,
        "minimumMacOS": info.get("LSMinimumSystemVersion"),
        "actualArchitectures": common_architectures,
        "schemas": schemas,
        "developerSupportProvider": {
            "classification": schemas["developerSupportProviderClassification"]
        },
        "components": components,
        "payloads": payloads,
        "payloadManifest": {
            "schemaVersion": payload_manifest.get("schemaVersion"),
            "sha256": sha256_file(payload_manifest_path),
            "release": payload_manifest.get("release", {}),
            "capabilities": payload_manifest.get("payloadCapabilities", {}),
        },
        "buildProvenance": provenance,
        "engineIntegrity": engine_integrity,
        "distribution": distribution,
        "signing": signing_identity(app),
        "dependencies": {
            "sbom": {
                "relativePath": "Contents/Resources/SBOM.spdx.json",
                "sha256": sha256_file(sbom_path),
                "spdxVersion": sbom.get("spdxVersion"),
                "packageCount": len(sbom["packages"]),
            },
            "lockDigests": sbom.get("buildInputs", {}),
            "notices": [
                {
                    "relativePath": f"Contents/Resources/ThirdPartyNotices/{path.name}",
                    "sha256": sha256_file(path),
                }
                for path in notice_files
            ],
        },
        "appTreeSHA256": sha256_tree(app),
    }
    return identity


def expected_release_identity(config: dict[str, Any]) -> dict[str, Any]:
    return {
        "productName": config.get("productName"),
        "bundleIdentifier": config.get("bundleIdentifier"),
        "version": str(config.get("shortVersion")) if config.get("shortVersion") is not None else None,
        "build": str(config.get("buildNumber")) if config.get("buildNumber") is not None else None,
        "minimumMacOS": str(config.get("minimumMacOS")) if config.get("minimumMacOS") is not None else None,
        "architectures": sorted(str(value) for value in config.get("architectures", [])),
        "developerSupportProviderClassification": config.get(
            "developerSupportProviderClassification"
        ),
    }


def identity_mismatches(identity: dict[str, Any], expectation: dict[str, Any]) -> list[str]:
    mismatches: list[str] = []
    mappings = {
        "productName": "productName",
        "bundleIdentifier": "bundleIdentifier",
        "version": "version",
        "build": "build",
        "minimumMacOS": "minimumMacOS",
        "developerSupportProviderClassification": "developerSupportProvider.classification",
    }
    for expected_key, actual_key in mappings.items():
        expected = expectation.get(expected_key)
        if "." in actual_key:
            section, child = actual_key.split(".", 1)
            actual = identity.get(section, {}).get(child)
        else:
            actual = identity.get(actual_key)
        if expected is not None and str(actual) != str(expected):
            mismatches.append(f"{actual_key}: expected {expected!r}, actual {actual!r}")

    expected_architectures = sorted(expectation.get("architectures", []))
    if expected_architectures:
        for component in identity.get("components", []):
            actual = sorted(component.get("architectures", []))
            if actual != expected_architectures:
                mismatches.append(
                    f"architectures {component.get('role')}: expected {expected_architectures}, actual {actual}"
                )

    schemas = identity.get("schemas", {})
    provenance = identity.get("buildProvenance", {})
    payload_manifest = identity.get("payloadManifest", {})
    payload_release = payload_manifest.get("release", {})
    engine_integrity = identity.get("engineIntegrity", {})
    schema_checks = [
        ("setupState", provenance.get("setupStateSchema")),
        ("provisioningManifest", provenance.get("provisioningManifestSchema")),
        ("helperProtocol", payload_release.get("helperSchemaVersion")),
        ("artifactManifest", payload_manifest.get("schemaVersion")),
        ("nativeBridgeABIExpected", schemas.get("nativeBridgeABI")),
    ]
    for schema_name, declared in schema_checks:
        actual = schemas.get(schema_name)
        try:
            agrees = int(declared) == int(actual)
        except (TypeError, ValueError):
            agrees = False
        if not agrees:
            mismatches.append(f"schema {schema_name}: artifact metadata {declared!r}, built component {actual!r}")

    component_by_role = {
        component.get("role"): component for component in identity.get("components", [])
    }
    integrity_hash_checks = [
        ("helper", engine_integrity.get("helperSHA256"), component_by_role.get("provisioner", {}).get("sha256")),
        ("native bridge", engine_integrity.get("nativeBridgeSHA256"), component_by_role.get("nativeDeviceBridge", {}).get("sha256")),
        ("payload manifest", engine_integrity.get("payloadManifestSHA256"), payload_manifest.get("sha256")),
    ]
    for role, declared, actual in integrity_hash_checks:
        if declared != actual:
            mismatches.append(f"engine integrity hash {role}: manifest {declared!r}, actual {actual!r}")
    integrity_schema_checks = [
        ("helperProtocol", engine_integrity.get("helperSchemaVersion")),
        ("setupState", engine_integrity.get("setupStateSchemaVersion")),
        ("artifactManifest", engine_integrity.get("artifactManifestSchemaVersion")),
        ("nativeBridgeABI", engine_integrity.get("nativeBridgeABI")),
    ]
    for schema_name, declared in integrity_schema_checks:
        actual = schemas.get(schema_name)
        try:
            agrees = int(declared) == int(actual)
        except (TypeError, ValueError):
            agrees = False
        if not agrees:
            mismatches.append(f"engine integrity schema {schema_name}: manifest {declared!r}, built component {actual!r}")

    for payload in identity.get("payloads", []):
        if payload.get("sha256") != payload.get("declaredSHA256"):
            mismatches.append(f"payload hash {payload.get('role')} disagrees with manifest")
        if payload.get("bundleIdentifier") != payload.get("declaredBundleIdentifier"):
            mismatches.append(f"payload bundle ID {payload.get('role')} disagrees with manifest")
        if str(payload.get("version")) != str(payload.get("declaredVersion")):
            mismatches.append(f"payload version {payload.get('role')} disagrees with manifest")
    return mismatches


def assert_identity(identity: dict[str, Any], expectation: dict[str, Any]) -> None:
    mismatches = identity_mismatches(identity, expectation)
    if mismatches:
        raise ArtifactIdentityError("ARTIFACT_IDENTITY_MISMATCH: " + "; ".join(mismatches))


def inspect_dmg(dmg: Path) -> dict[str, Any]:
    dmg = dmg.resolve()
    WORKSPACE_TEMP_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mount-", dir=WORKSPACE_TEMP_ROOT) as temporary:
        mount = Path(temporary) / "volume"
        mount.mkdir()
        attached = False
        device_entry: str | None = None
        try:
            attach = _run([
                "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse",
                "-mountpoint", str(mount), str(dmg),
            ])
            attached = True
            device_lines = [line for line in attach.stdout.splitlines() if line.startswith("/dev/")]
            if device_lines:
                device_entry = re.sub(r"s\d+$", "", device_lines[-1].split()[0])
            apps = sorted(mount.glob("*.app"))
            if len(apps) != 1:
                raise ArtifactIdentityError(f"mounted DMG must contain exactly one app, found {len(apps)}")
            identity = inspect_app(apps[0])
            identity["artifact"] = {
                "fileName": dmg.name,
                "sizeBytes": dmg.stat().st_size,
                "sha256": sha256_file(dmg),
                "mountedAppTreeSHA256": identity["appTreeSHA256"],
            }
            identity["mountedVolumeContents"] = sorted(
                path.name for path in mount.iterdir() if not path.name.startswith(".")
            )
            return identity
        finally:
            if attached:
                _run(["/usr/bin/hdiutil", "detach", device_entry or str(mount)], check=False)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect actual IOSSim/Veya artifact identity")
    sub = parser.add_subparsers(dest="command", required=True)
    protocol = sub.add_parser("protocol-info")
    protocol.add_argument("--helper", required=True)
    protocol.add_argument("--bridge", required=True)
    for name in ["inspect-app", "inspect-dmg"]:
        command = sub.add_parser(name)
        command.add_argument("path")
        command.add_argument("--expect-config")
        command.add_argument("--output")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "protocol-info":
            value = protocol_versions(Path(args.helper), Path(args.bridge))
        elif args.command == "inspect-app":
            value = inspect_app(Path(args.path))
        else:
            value = inspect_dmg(Path(args.path))
        config_path = getattr(args, "expect_config", None)
        if config_path:
            config = _read_json(Path(config_path))
            assert_identity(value, expected_release_identity(config))
        encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
        output = getattr(args, "output", None)
        if output:
            Path(output).write_text(encoded, encoding="utf-8")
        else:
            print(encoded, end="")
        return 0
    except ArtifactIdentityError as exc:
        print(str(exc), file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
