# Failure-injection matrix

| Injection | Boundary | Deterministic mechanism | Expected first failure | Required recovery assertion |
| --- | --- | --- | --- | --- |
| missing key | signing store load | omit encrypted key blob but retain metadata/cert fixture | `SIGNING.KEY_NOT_FOUND` at `key.load` | no ACL repair; ownership-safe replacement plan; active install untouched |
| missing metadata | state inventory | omit identity record, retain key and matching Apple cert | no failure if cryptographic recovery succeeds | reconstruct metadata without issuing/revoking cert |
| stale certificate | Apple cert fixture | metadata serial absent/expired/mismatched | `CERTIFICATE.STALE` at reconcile | reuse key, issue candidate, retire exact old record |
| exhausted capacity | CSR fixture | list available or ambiguous, then return 7460 | `CERTIFICATE.CAPACITY_EXHAUSTED` | relist; only owned inactive serial; same CSR bounded retry |
| unavailable secure store | wrapping Keychain port | return `errSecNotAvailable`/locked | `SIGNING.STORE_UNAVAILABLE` | no new key/cert/revoke; retryable classification; no prompt |
| corrupt metadata | state decoder | invalid schema/checksum/field bounds | `STATE.CORRUPT_IDENTITY_METADATA` | quarantine file; recover by key/cert proof; preserve original evidence |
| stale profile | profile fixture | expired/wrong device/cert/bundle | `PROFILE.STALE` | request candidate profile; do not replace identity unnecessarily |
| network failure | HTTP transport | fail before send, after headers, after response | operation-specific `NETWORK.*` | retry idempotent reads; reconcile ambiguous writes before repeat |
| Apple API retry | scripted responses | 429/5xx/Retry-After then success | retry event, not terminal first failure | bounded count/delay; same generation/team/request |
| install interruption | AFC/InstallationProxy port | stop after upload or ambiguous install reply | `INSTALL.INTERRUPTED` | refresh inventory before another upload/install; no uninstall |
| iPhone disconnect | native transport | close session at every device stage | `DEVICE.DISCONNECTED` | retain durable domains; resume exact device only |
| locked phone | Lockdown/AppService port | return locked status | `DEVICE.LOCKED` | `USER_ACTION_REQUIRED`; no provisioning reset |
| pairing failure | pairing port | invalid receipt, possession proof, replay, disconnect | precise `PAIRING.*` operation | prior active pairing preserved; candidate not promoted |
| VPN unavailable | VPN port | app missing, approval pending, launch failure, no endpoint | precise `VPN.*` operation | preserve install/pairing; only VPN action/repair |
| DDI unavailable | developer-support port | missing source/build, TSS failure, corrupt cache, mount rejection | precise `DEVELOPER_SUPPORT.*` | do not reinstall apps or reprovision; partial cache quarantined |
| AppService unavailable | RemoteXPC port | connect/handshake/service/launch failure | precise `APPSERVICE.*` operation | reconnect only relevant volatile domains |
| runtime proof failure | Rich proof port | runner absent, write timeout, read mismatch, clear failure | precise `RUNTIME_PROOF.*` operation | persist pending clear; READY false; never replay movement |
| process crash | engine hook | terminate before/after every journal and external mutation | next run starts with `STATE.RECONCILE_INTENT` | no duplicate create/revoke/install; active candidate rules hold |
| expired session | Apple adapter fixture | stored session rejected | `APPLE_AUTH.SESSION_EXPIRED` | discard/replace session only; valid identity/install preserved |
| wrong device appears | discovery fixture | ordering changes or second phone connects | `DEVICE.SELECTION_REQUIRED` or mismatch | no implicit switch and no mutation on wrong phone |
| stale cached READY | readiness fixture | receipt exists but live domain fails | first live domain error | READY downgraded; smallest repair selected |
| other-Mac certificate | cert fixture | structured Veya marker with different installation ID | capacity blocked | never revoke; actionable safe failure |
| prompt attempt | secure-store sentinel | cause API path likely to request UI | `SECURITY.UI_PROMPT_ATTEMPT` | operation killed/fails test; product never waits on SecurityAgent |

## Coverage rule

Inject each local failure before the call, during it where ambiguity matters, and immediately after the external side effect but before Veya records success. The post-side-effect crash cell is mandatory for certificate revocation, certificate issuance, device/App ID creation, installation, pairing promotion, profile install and READY promotion.

Every row runs at Layers 1-2. Storage and signing rows also run at Layers 3-4. Transport rows run against fake ports and selected non-destructive physical probes. No row is considered covered by a test-local substitute engine.

