# Definitive Veya installation gap list

| Classification | Exact capability | Evidence and closure |
| --- | --- | --- |
| ALREADY_SOLVED | packaged GUI selects `BundledProvisioningEngine`; helper owns doctor/reconcile/provision | source checks pass; keep release verification |
| ALREADY_SOLVED | native discovery, inspect, inventory, install, upgrade, uninstall, House Arrest, RemotePairing, DDI mount, RSD/AppService APIs | current Swift/Rust code; physical scope varies |
| ALREADY_SOLVED | substantial Personal Team auth/2FA/team/cert/device/App ID/profile flow | current live adapter; private/version-bound |
| ALREADY_SOLVED | encrypted automatic pairing delivery | existing lifecycle/inbox; hardening gaps below |
| ALREADY_SOLVED | Rich retained-RSD XCTest/XCUILocation runtime and cadence invariants | current phone source/existing records |
| PARTIALLY_SOLVED | Developer Mode/profile trust user gates | codes exist; state/action/resume UX needs normalization |
| PARTIALLY_SOLVED | signing identity lifecycle | exact match exists; renewal/promotion/orphan cleanup missing |
| PARTIALLY_SOLVED | profile renewal | validity inspection exists; scheduled staged renewal and promotion incomplete |
| PARTIALLY_SOLVED | LocalDevVPN | coordinator/inbox/endpoint checks exist; installation, permission, scene reactivation, authenticated readiness incomplete |
| PARTIALLY_SOLVED | repair/resume | checkpoints and generation exist; domain invalidation/journal/cross-process lease missing |
| MISSING | initial Lockdown pairing ABI | wrap pinned idevice `pair_once`, persist/validate pair record, expose Trust states |
| MISSING | approved fresh DDI acquisition provider | current production provider only scans existing cache |
| MISSING | runtime-operational READY proof | current final checkpoint says TestManager/XCTest/location not started |
| MISSING | one canonical published release authority/updater | prior GitHub Releases empty; current local artifact test-only |
| UNSAFE | duplicate USB/network record selection | Rust selects matching UDID before expected mux connection |
| UNSAFE | pairing forced repair | deletes active state before candidate proves import/use |
| UNSAFE | pairing proof/request reuse | proof is effectively no-op; bootstrap/request binding and current-Keychain challenge weak |
| UNSAFE | singleton state/profile stores and independent helper processes | cross-device/team collision and lost-update risk |
| UNSAFE | release metadata accepts desired architecture/schema | observed DMG was arm64 despite universal claim and embedded schema 3 vs source 4 |
| UNSAFE | broad support export | replace with allowlist DTO, aliases, and post-export secret scan |
| PHYSICAL_VALIDATION_ONLY | fresh Trust, DDI, AppService launch, XCTest/Rich proof, VPN approval, expiry/renewal, reboot/upgrade, signed DMG | no static test can close these |
| PRODUCT_DECISION_REQUIRED | DDI source, asset rights, update/revocation authority | Vanish confirms third-party mirror, not an approved Veya source |
| PRODUCT_DECISION_REQUIRED | final release/update hosting | choose and operate one authority; GitHub Releases remains proposed |

No broad “improve setup” item is accepted. Each row has an implementation owner and an acceptance gate in documents 17–20.
