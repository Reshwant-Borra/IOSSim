#!/usr/bin/env python3
from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "bootstrap"))

from artifact_identity import (  # noqa: E402
    ArtifactIdentityError,
    assert_identity,
    identity_mismatches,
)


def valid_identity() -> dict:
    architectures = ["arm64", "x86_64"]
    schemas = {
        "helperProtocol": 1,
        "setupState": 5,
        "provisioningManifest": 4,
        "artifactManifest": 2,
        "nativeBridgeABIExpected": 1,
        "nativeBridgeABI": 1,
        "developerSupportProviderClassification": "UNRESOLVED_PRODUCTION_PROVIDER",
    }
    return {
        "productName": "Veya",
        "bundleIdentifier": "com.iossim.mac-provisioner",
        "version": "0.1.0",
        "build": "1",
        "minimumMacOS": "13.0",
        "actualArchitectures": architectures,
        "schemas": schemas,
        "developerSupportProvider": {"classification": "UNRESOLVED_PRODUCTION_PROVIDER"},
        "components": [
            {"role": role, "architectures": architectures, "sha256": digest}
            for role, digest in [
                ("macApp", "a" * 64),
                ("provisioner", "b" * 64),
                ("nativeDeviceBridge", "c" * 64),
            ]
        ],
        "buildProvenance": {"setupStateSchema": 5, "provisioningManifestSchema": 4},
        "engineIntegrity": {
            "helperSHA256": "b" * 64,
            "nativeBridgeSHA256": "c" * 64,
            "payloadManifestSHA256": "d" * 64,
            "helperSchemaVersion": 1,
            "setupStateSchemaVersion": 5,
            "artifactManifestSchemaVersion": 2,
            "nativeBridgeABI": 1,
        },
        "payloadManifest": {
            "schemaVersion": 2,
            "sha256": "d" * 64,
            "release": {"helperSchemaVersion": 1},
        },
        "payloads": [
            {
                "role": "iosMain",
                "sha256": "a" * 64,
                "declaredSHA256": "a" * 64,
                "bundleIdentifier": "com.iossim.on-device-dvt-poc",
                "declaredBundleIdentifier": "com.iossim.on-device-dvt-poc",
                "version": "1.0",
                "declaredVersion": "1.0",
            }
        ],
    }


EXPECTATION = {
    "productName": "Veya",
    "bundleIdentifier": "com.iossim.mac-provisioner",
    "version": "0.1.0",
    "build": "1",
    "minimumMacOS": "13.0",
    "architectures": ["arm64", "x86_64"],
    "developerSupportProviderClassification": "UNRESOLVED_PRODUCTION_PROVIDER",
}


class ArtifactIdentityTests(unittest.TestCase):
    def test_matching_artifact_passes(self) -> None:
        self.assertEqual(identity_mismatches(valid_identity(), EXPECTATION), [])
        assert_identity(valid_identity(), EXPECTATION)

    def test_desired_universal_but_actual_arm64_fails(self) -> None:
        identity = valid_identity()
        for component in identity["components"]:
            component["architectures"] = ["arm64"]
        with self.assertRaisesRegex(ArtifactIdentityError, "architectures macApp"):
            assert_identity(identity, EXPECTATION)

    def test_stale_setup_schema_fails(self) -> None:
        identity = valid_identity()
        identity["buildProvenance"]["setupStateSchema"] = 3
        with self.assertRaisesRegex(ArtifactIdentityError, "schema setupState"):
            assert_identity(identity, EXPECTATION)

    def test_stale_helper_and_bridge_schemas_fail(self) -> None:
        identity = valid_identity()
        identity["payloadManifest"]["release"]["helperSchemaVersion"] = 0
        identity["schemas"]["nativeBridgeABI"] = 2
        mismatches = identity_mismatches(identity, EXPECTATION)
        self.assertTrue(any("schema helperProtocol" in value for value in mismatches))
        self.assertTrue(any("schema nativeBridgeABIExpected" in value for value in mismatches))

    def test_payload_claims_are_verified_from_bytes(self) -> None:
        identity = copy.deepcopy(valid_identity())
        identity["payloads"][0]["declaredSHA256"] = "b" * 64
        with self.assertRaisesRegex(ArtifactIdentityError, "payload hash iosMain"):
            assert_identity(identity, EXPECTATION)

    def test_developer_support_provider_is_read_from_helper_bytes(self) -> None:
        identity = valid_identity()
        identity["developerSupportProvider"]["classification"] = (
            "THIRD_PARTY_MIRROR_DEVELOPMENT_PINNED_V030"
        )
        with self.assertRaisesRegex(ArtifactIdentityError, "developerSupportProvider.classification"):
            assert_identity(identity, EXPECTATION)


if __name__ == "__main__":
    unittest.main()
