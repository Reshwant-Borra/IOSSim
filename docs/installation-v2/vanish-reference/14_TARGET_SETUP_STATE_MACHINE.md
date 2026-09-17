# Target consumer setup state machine

Durable domain state is keyed by `{releaseIdentity, teamID, deviceUDIDHash, artifactSetID}`. UI phase is derived from live checks plus committed receipts.

| State | Check/inputs | Execute/repair | Verify/output | Resume/rollback | Timeout/retry/user action | Error |
| --- | --- | --- | --- | --- | --- | --- |
| `VERIFY_INSTALL` | app/helper/bridge/manifest signatures, hashes, schemas | none; update/reinstall app | integrity receipt | restart safe; no mutation | 10s/once; reinstall official artifact | `VEYA-INTEGRITY-*` |
| `DISCOVER_DEVICE` | usbmux list and selected stable ID | refresh/open exact mux record | inspect receipt with UDID/build/connection | preserve all durable state | continuous bounded polls; connect/unlock | `VEYA-DEVICE-*` |
| `PAIR_COMPUTER` | pair-record/session validate | call native `pair_once`; wait | fresh Lockdown session on exact device | old valid record retained; abandon pending request | 180s, poll; tap Trust/enter passcode | `VEYA-TRUST-*` |
| `VERIFY_DEVELOPER_MODE` | native readiness/typed mode status | reveal guidance | readiness progresses or explicit mode state | resume after reboot/reconnect | 10m; enable/reboot/confirm | `VEYA-DEVSERVICE-010` |
| `PREPARE_DEVELOPER_SUPPORT` | readiness first; exact OS build | approved provider acquire, validate, TSS, mount | CoreDeviceProxy/tunnel/RSD/RemoteXPC/AppService receipt | cache candidate; quarantine mismatch; retry service outage | acquire 5m/mount 2m; stay online/unlocked | `VEYA-DEVSERVICE-020..039` |
| `AUTHORIZE_APPLE` | valid scoped session | login/SRP/2FA through adapter | session/team-list receipt | secrets discarded; valid old session preserved | 5m; enter credentials/2FA | `VEYA-APPLE-*` |
| `PREPARE_TEAM_SIGNING` | team, identity, cert limits | select team; create candidate key/CSR/cert only if needed | exact SecIdentity access/codesign probe | retain active identity; candidate cleanup | server-bounded retries; resolve limits | `VEYA-SIGNING-*` |
| `PREPARE_PROFILES` | device/App IDs/profile validity | register/reuse; fetch exact profiles | CMS/team/UDID/App ID/entitlement/expiry receipts | preserve valid active profiles; remove managed failed candidates | idempotent reads then bounded writes | `VEYA-PROFILE-*` |
| `SIGN_ARTIFACTS` | immutable payload hashes + identity/profiles | copy to protected workspace; rewrite IDs; sign nested-first | recursive signature/profile/entitlement hashes | delete temp candidate | 3m/one clean rebuild | `VEYA-SIGNING-*` |
| `INSTALL_ARTIFACTS` | live inventory and candidate identity | stage/upgrade only absent/stale bundles | post-install exact inventory/launchability hint | preserve known-good installed version where protocol permits | 10m/reconnect-resume; trust prompt separate | `VEYA-INSTALL-*` |
| `WAIT_PROFILE_TRUST` | AppService launch classification | no bypass | exact app launches | installed state preserved | user opens Settings and trusts developer | `VEYA-PROFILE-040` |
| `PREPARE_REMOTE_PAIRING` | active operational proof | create/transfer/import/challenge candidate; promote after operational proof | device/request/artifact-bound proof | active slot survives; discard candidate | 3m; keep phone open/unlocked | `VEYA-PAIRING-*` |
| `PREPARE_LOCALDEVVPN` | inventory/version/config/runtime endpoint | guide App Store; launch; phone inbox request; wait permission | authenticated endpoint and developer path receipt | preserve configuration; expire pending request | 10m; approve VPN | `VEYA-VPN-*` |
| `VERIFY_RUNNER` | AppService/RSD and installed runner | launch TestManager/XCTest | runner session reaches control/ready stages | stop failed candidate session | 90s/one reconnect retry | `VEYA-RUNNER-*` |
| `VERIFY_RICH_RUNTIME` | healthy runner, selected device | bounded location write, observe ack/effect signal, clear, stop | time/device/release-bound Rich proof | always clear/stop; retain config | 60s; unlock/retry | `VEYA-RUNTIME-*` |
| `READY` | revalidate TTLs/invalidation graph | smallest expired-domain repair | all live receipts valid | downgrade automatically when a receipt expires | background health; user sees exact next action | domain-specific |

Cancellation is cooperative between safe boundaries; non-idempotent Apple/install operations finish reconciliation before accepting another mutation. A crash journal records intent before mutation and observation after it. Promotion uses atomic replacement plus generation compare-and-swap under an OS file lock.
