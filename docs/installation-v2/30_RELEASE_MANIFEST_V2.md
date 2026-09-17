# Release manifest V2

The manifest is canonical JSON with deterministic key order/encoding and an external detached signature. It is generated after mounting the DMG.

```json
{
  "schemaVersion": 2,
  "release": {
    "product": "Veya",
    "version": "0.5.0",
    "build": 41,
    "channel": "stable",
    "sourceCommit": "a81c21f…",
    "sourceDirty": false,
    "buildTimestamp": "…",
    "releaseID": "Veya/0.5.0/41/a81c21f"
  },
  "artifact": {
    "fileName": "Veya-0.5.0-build41-a81c21f.dmg",
    "size": 0,
    "sha256": "…",
    "mountedAppTreeSHA256": "…"
  },
  "macApp": {
    "bundleID": "…",
    "infoPlistSHA256": "…",
    "architectures": ["arm64", "x86_64"],
    "minimumOS": "…",
    "designatedRequirement": "…",
    "teamID": "…",
    "notarizationTicket": "VALID"
  },
  "schemas": {
    "helperProtocol": 1,
    "setupState": 5,
    "artifactManifest": 2,
    "nativeBridgeABI": 2,
    "pairingWire": 2,
    "vpnWire": 2,
    "supportBundle": 8
  },
  "components": [],
  "payloads": [],
  "dependencies": {"sbomSHA256": "…", "noticesTreeSHA256": "…"},
  "qualification": {"automatedSuiteID": "…", "physicalMatrixID": "…"}
}
```

Each component records relative path, kind, size/tree hash, actual architectures, bundle ID/version where relevant, code-signature CDHash/designated requirement/team, entitlements digest, and schema/ABI reported by the binary. Each iPhone payload records role, bundle IDs including extensions/test bundle, minimum iOS, tree hash, expected re-sign mode, capability contract, and original signature-stripping state.

The manifest never says “universal” because configuration requested it; `architectures` is the sorted result of parsing every final Mach-O. It never copies a setup schema literal from release configuration; it compares the built helper and app’s generated schema declarations and records their agreed value.

Local test builds use the same schema and audits but a distinct `LOCAL_TEST_ONLY` distribution class, ad hoc signing facts, and nonpublishable channel. A dirty build cannot share a public filename or release ID.
