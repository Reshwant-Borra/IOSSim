# Error taxonomy

Codes are stable API. Messages may improve; category and semantic condition may not be reused.

| Namespace | Representative codes and meaning |
| --- | --- |
| `VEYA-INTEGRITY` | 001 helper missing; 002 hash/signature mismatch; 003 launch denied; 004 manifest/component mismatch |
| `VEYA-DEVICE` | 001 none; 002 multiple/selection required; 003 disconnected; 004 locked; 005 wrong mux connection; 006 identity changed |
| `VEYA-TRUST` | 001 USB required; 002 passcode/unlock required; 003 Trust prompt pending; 004 user denied; 005 pairing timeout; 006 persist failed; 007 session validation failed |
| `VEYA-APPLE` | 001 bad credentials; 002 2FA required; 003 2FA rejected; 004 session expired; 005 outage; 006 protocol incompatible; 007 timeout; 008 rate limit; 011 team ambiguous; 020 certificate limit; 021 device limit; 022 App ID limit |
| `VEYA-SIGNING` | 001 key create; 002 key unavailable; 003 cert/key mismatch; 004 identity inaccessible; 010 codesign failed; 011 strict verify failed |
| `VEYA-PROFILE` | 001 issuance failed; 002 invalid envelope; 003 expired; 004 near expiry; 005 entitlement mismatch; 010 user trust required; 011 trust denied/unverified |
| `VEYA-INSTALL` | 001 main install; 002 runner install; 003 inventory mismatch; 004 upgrade failed; 005 uninstall denied; 006 insufficient space |
| `VEYA-PAIRING` | 001 request write; 002 bootstrap timeout; 003 envelope rejected; 004 import rejected; 005 receipt mismatch; 020 possession proof; 021 operational proof; 022 candidate expired; 023 promotion conflict |
| `VEYA-VPN` | 001 app missing; 002 version unsupported; 003 permission required; 004 permission denied; 005 request timeout; 006 receipt invalid; 007 endpoint unreachable; 008 wrong route/identity |
| `VEYA-DEVSUPPORT` | 002 approved DDI unavailable; 003 wrong BuildIdentity; 004 corrupt asset; 005 TSS unavailable/rejected; 006 mount rejected |
| `VEYA-DEVSERVICE` | 001 Developer Mode required; 007 CoreDevice proxy unavailable; 008 software tunnel unavailable; 009 RSD unavailable; 010 RemoteXPC unavailable; 020 AppService unavailable; 021 launch failed; 022 operational proof unavailable |
| `VEYA-RUNNER` | 001 missing; 002 mapping invalid; 003 launch failed; 004 TestManager attach failed; 005 generation mismatch |
| `VEYA-RUNTIME` | 001 Rich transport unavailable; 002 command timeout; 003 writer conflict; 004 clear unconfirmed; 005 cadence failed; 006 proof mismatch |
| `VEYA-STATE` | 001 lock busy; 002 stale lease; 003 generation conflict; 004 corrupt journal; 005 migration ambiguous; 006 identity collision |
| `VEYA-UPDATE` | 001 schema mismatch; 002 unsupported migration; 003 downgrade blocked; 004 channel/manifest invalid |

## Error envelope

```json
{
  "code": "VEYA-TRUST-003",
  "domain": "DEVICE_TRUST",
  "severity": "ACTION_REQUIRED",
  "retryability": "AFTER_USER_ACTION",
  "userMessage": "Unlock your iPhone and tap Trust.",
  "remediation": "Keep the USB cable connected, then continue in Veya.",
  "operationID": "…",
  "safeContext": {"deviceHashPrefix": "…", "stage": "PAIR_REQUESTED"}
}
```

Developer details remain structured and redacted. Raw server bodies, command lines with secrets, paths outside the bundle/support roots, and arbitrary NSError descriptions are never user messages. Unknown errors map to the owning namespace’s `099 INTERNAL` with a correlation ID, never to “could not find doctor.”
