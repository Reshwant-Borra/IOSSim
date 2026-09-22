# Observability and Error Codes

## Event schema

```json
{
  "schemaVersion": 1,
  "eventID": "uuid",
  "runID": "uuid",
  "stage": "certificate",
  "operation": "issue",
  "generation": 7,
  "attempt": 1,
  "lifecycle": "candidate",
  "result": "failed",
  "errorCode": "VEYA-CERT-046",
  "osStatus": null,
  "retryable": false,
  "userAction": "accountResourceActionRequired",
  "destructiveRepairRequired": false,
  "subsystem": "appleDeveloperAPI",
  "durationMs": 812,
  "evidenceRef": "sha256:...",
  "timestamp": "RFC3339"
}
```

The first event with result `failed` for a run is copied to `firstFailure`; later failures cannot overwrite it. Absence of a later checkpoint is never diagnosis.

## Namespaces

| Namespace | Domain | Reserved codes |
|---|---|---|
| `VEYA-ART-` | artifact/package | 001 missing, 002 integrity, 003 architecture, 004 protocol |
| `VEYA-STATE-` | journal/engine | 001 schema, 002 invariant, 003 corrupt, 004 write, 005 stale generation, 006 lease conflict |
| `VEYA-AUTH-` | Apple auth | 001 absent, 002 expired, 003 2FA, 004 rejected, 005 Keychain, 006 interaction forbidden, 007 protocol drift |
| `VEYA-TEAM-` | team/device registration | 001 none, 002 ambiguous, 003 registration |
| `VEYA-KEY-` | signing key store | 001 missing, 002 wrapper missing, 003 corrupt, 004 access, 005 algorithm, 006 import |
| `VEYA-CERT-` | certificate | 001 inventory, 002 mismatch, 003 expired, 046 capacity unsafe, 047 revoke, 048 issue ambiguous |
| `VEYA-PROFILE-` | App ID/profile | 001 invalid, 002 stale, 003 entitlement, 004 device, 005 issue |
| `VEYA-SIGN-` | in-process signing | 001 graph, 002 key, 003 Mach-O, 004 CMS, 005 resources, 006 verification |
| `VEYA-INSTALL-` | staging/install | 001 staging, 002 rejected, 003 ambiguous, 004 inventory, 005 rollback |
| `VEYA-DEVICE-` | discovery/Lockdown | 001 absent, 002 multiple, 003 disconnected, 004 locked, 005 trust, 006 Developer Mode |
| `VEYA-DDI-` | developer support | 001 exact build missing, 002 integrity, 003 TSS, 004 mount, 005 service proof |
| `VEYA-PAIR-` | RemotePairing | 001 missing, 002 delivery, 003 replay, 004 wrong device, 005 possession, 006 service |
| `VEYA-VPN-` | LocalDevVPN | 001 missing, 002 permission, 003 config, 004 start, 005 endpoint |
| `VEYA-RUNTIME-` | runtime proof | 001 tunnel, 002 RSD, 003 RemoteXPC, 004 AppService, 005 runner, 006 TestManager, 007 XCTest, 060 Rich write, 061 cleanup |
| `VEYA-MIG-` | migration | 001 inventory, 002 ambiguous, 003 import, 004 partial |
| `VEYA-SEC-` | security policy | 001 permission, 002 symlink, 003 secret leak, 004 tamper |

Codes are stable semantics, not source line IDs. Raw Apple/device/library messages are redacted, length-bounded diagnostic details and never the code. OSStatus is recorded numerically only when safe.

Redaction denies passwords, 2FA, cookies/tokens, PKCS#8, wrapping keys, pairing records/escrow bags, profile payloads, device serial/UDID (hash instead), email, and filesystem usernames. Automated canary-secret tests fail support export and every logger sink on leakage.

