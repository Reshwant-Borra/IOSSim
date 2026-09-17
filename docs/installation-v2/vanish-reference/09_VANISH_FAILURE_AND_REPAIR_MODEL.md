# Vanish failure and repair model

## Observable patterns

Vanish assigns domain codes and user actions rather than exposing helper command names. Examples include unlock (`VAN-110`), Trust (`VAN-111`), Developer Mode (`VAN-112`), Apple developer setup (`VAN-113`), DDI/device preparation (`VAN-120`), and sideload/pairing failures (`VAN-6xx`). Locked-device paths retry; tunnel exit triggers rediscovery/rebootstrap; bounded retry counts distinguish transient timeouts from terminal errors; repair pairing is separate from install; updater cleanup runs before replacement. `CONFIRMED_VANISH_STATIC_CODE`

## Veya behavior derived from the reference

Every failed transition returns: stable Veya code, safe cause, last verified state, preserved resources, smallest repair, required user action, resumability, retry time, and diagnostic correlation ID.

| Scenario | Preserve | Smallest repair / user action | Veya category |
| --- | --- | --- | --- |
| no/locked/disconnected phone | all durable provisioning and installed-state hints | reconnect/unlock same device; re-inspect before resume | `VEYA-DEVICE` |
| Trust pending | account/signing state | issue/poll native pair request; user taps Trust | `VEYA-TRUST` |
| Developer Mode off | installation state | reveal guidance; user enables/reboots/confirms | `VEYA-DEVSERVICE` |
| DDI unavailable | signing/install state | acquire approved exact build or report unsupported build/source outage | `VEYA-DEVSERVICE` |
| Apple login/2FA/session failure | nonsecret device state; valid identities | retry only auth/session step; never log secret | `VEYA-APPLE` |
| cert/device/App ID limit | installed app and existing resources | present exact server constraint and selectable safe remediation | `VEYA-SIGNING`/`PROFILE` |
| signing/install failure | immutable source payload and valid profiles | discard temp candidate; restage/reinstall only affected bundle | `VEYA-SIGNING`/`INSTALL` |
| profile trust pending | installed bundles | guide Settings action, then relaunch through AppService | `VEYA-PROFILE` |
| pairing import/proof failure | active pairing | discard candidate; retry transfer/challenge | `VEYA-PAIRING` |
| LocalDevVPN missing/approval pending | all other verified domains | App Store/install or Apple approval; resume on scene activation | `VEYA-VPN` |
| AppService/runner/Rich proof failure | configuration checkpoints | reconnect developer services, relaunch runner, test bounded write/clear | `VEYA-DEVSERVICE`/`RUNNER`/`RUNTIME` |
| profile/session expiry | active runtime until invalid | renew candidate credentials/profile, sign/install upgrade, verify, promote | `VEYA-PROFILE`/`APPLE` |
| crash/reboot | committed snapshot and journal | recover or roll back incomplete candidate under lease | `VEYA-STATE` |
| old/wrong-team install | unrelated user data | inventory, classify ownership, staged replacement; never delete unknown app | `VEYA-INSTALL`/`STATE` |

The reference is behavioral. Veya's rollback and cryptographic proof requirements are stricter because its source exposes current shortcomings that cannot be assessed in Vanish.
