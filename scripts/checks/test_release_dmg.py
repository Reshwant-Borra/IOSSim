#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "bootstrap"))

import iossim_cli as cli  # noqa: E402


class InspectingRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[str, list[str]]] = []
        self.staged_names: list[str] = []
        self.staged_app_name = ""
        self.staged_app_payload = ""
        self.applications_target = ""
        self.volume_name = ""

    def run(self, label: str, command: list[str], **_: object) -> None:
        self.calls.append((label, command))
        if label != "create-release-dmg":
            return
        source = Path(command[command.index("-srcfolder") + 1])
        self.volume_name = command[command.index("-volname") + 1]
        self.staged_names = sorted(path.name for path in source.iterdir())
        app = next(path for path in source.iterdir() if path.suffix == ".app")
        self.staged_app_name = app.name
        self.staged_app_payload = (app / "Contents" / "marker.txt").read_text(encoding="utf-8")
        self.applications_target = os.readlink(source / "Applications")
        output = Path(command[-1])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"test-dmg")


class ReleaseDMGTests(unittest.TestCase):
    def make_app(self, root: Path) -> Path:
        app = root / "Source.app"
        contents = app / "Contents"
        contents.mkdir(parents=True)
        (contents / "marker.txt").write_text("signed bundle bytes", encoding="utf-8")
        return app

    def test_default_names_preserve_release_behavior(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = InspectingRunner()
            cli.create_release_dmg(runner, self.make_app(root), root / "release.dmg")

        self.assertEqual(runner.volume_name, cli.RELEASE_CONFIG.product_name)
        self.assertEqual(runner.staged_app_name, f"{cli.RELEASE_CONFIG.product_name}.app")
        self.assertEqual(runner.staged_names, ["Applications", f"{cli.RELEASE_CONFIG.product_name}.app"])
        self.assertEqual(runner.applications_target, "/Applications")
        self.assertEqual(runner.staged_app_payload, "signed bundle bytes")
        self.assertEqual([label for label, _ in runner.calls], ["create-release-dmg", "verify-release-dmg"])

    def test_target_a_names_are_staged_by_shared_implementation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = InspectingRunner()
            cli.create_release_dmg(
                runner,
                self.make_app(root),
                root / "Veya-Test.dmg",
                volume_name="Veya Test",
                app_bundle_name="Veya Development.app",
            )

        self.assertEqual(runner.volume_name, "Veya Test")
        self.assertEqual(runner.staged_app_name, "Veya Development.app")
        self.assertEqual(runner.staged_names, ["Applications", "Veya Development.app"])
        self.assertEqual(runner.applications_target, "/Applications")
        self.assertEqual(runner.staged_app_payload, "signed bundle bytes")

    def test_names_must_be_single_safe_path_components(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.make_app(root)
            runner = InspectingRunner()
            with self.assertRaises(ValueError):
                cli.create_release_dmg(runner, app, root / "bad.dmg", volume_name="bad/name")
            with self.assertRaises(ValueError):
                cli.create_release_dmg(runner, app, root / "bad.dmg", app_bundle_name="../Bad.app")


if __name__ == "__main__":
    unittest.main()
