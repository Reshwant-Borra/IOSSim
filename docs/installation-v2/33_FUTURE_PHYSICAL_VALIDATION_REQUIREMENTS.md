# Future physical validation requirements

No test in this document was executed during this research. Every row is `PHYSICAL_VALIDATION_REQUIRED` unless prior evidence is explicitly noted.

| Matrix | Required scenarios and pass evidence |
| --- | --- |
| Clean Mac | supported macOS versions/architectures, no Xcode/CoreDevice cache, fresh user and Keychain, install signed/notarized DMG, helper/bridge launch |
| Initial trust | never-trusted iPhones, unlocked/locked/passcode, accept/deny/timeout, cable removal, reboot, host trust reset, exact record reuse |
| Devices | at least two models/iOS 17.4, 18.x, current 26.x; two simultaneous iPhones; duplicate USB/network enumeration; wrong-device rejection |
| Developer Mode | off/on/reboot-required, denial, already enabled |
| Developer support | empty cache acquisition from approved source, exact build selection, TSS outage/reject, corrupt/wrong asset, cache reuse, iOS update, rollback/quota |
| Apple accounts | free Personal Team, multiple teams, 2FA variants, bad credentials, session expiry, rate limit/outage, cert/device/App ID limits |
| Keychain/signing | new user Keychain, locked Keychain, GUI/helper/codesign ACL prompts, renewal/key rotation, no third-party identity impact |
| Install/profile | first install, upgrade, partial runner/main failure, insufficient storage, developer-profile trust required/denied, inventory after reboot |
| AppService | native launch of exact main/runner through final build, no manual launch substitution, locked phone, reconnect/tunnel recovery |
| RemotePairing | first delivery, fresh possession proof, operational proof, forced repair, crash at every candidate/promotion point, old-pair rollback |
| LocalDevVPN | missing App Store app, supported/unsupported update, VPN approval/denial, scene activation after watcher expiry, endpoint identity, reboot |
| Runtime | fresh TestManager attach and Rich proof, Spoof, Drive, 2 Hz/fallback, Stop/Hold/Resume/Clear, crash/disconnect pending Clear, no backlog |
| Renewal | warning threshold, profile expiry, session expiry during renewal, certificate replacement, atomic two-app upgrade, fully expired recovery |
| Concurrency | two app instances/helpers, kill -9 at each journal phase, power/reboot recovery, stale lease, generation collision |
| Upgrade/reinstall | previous IOSSim version to V2, Veya branding migration, app reinstall with retained state, incompatible downgrade block |
| Release | final universal or per-arch policy, clean build, mounted manifest equality, Developer ID/notarization/stapling/Gatekeeper, download reverify |
| Support/privacy | export during every failure class; automated secret/raw-ID/profile/pairing/coordinate scan; user-readable diagnostic usefulness |

Prior saved records support native AppService/main launch and LocalDevVPN readiness on iPhone18,1/iOS 26.6.2, but the final implementation must repeat them from a canonical build. `PHYSICAL_EVIDENCE_FROM_EXISTING_RECORD`

Each lab result records release ID/hash, Mac hardware/OS/user freshness, iPhone model/iOS build/UDID hash, connection path, prior trust/cache state, exact state transitions/error codes, timestamps, logs/support bundle hash, and operator. A screenshot or narrative without identity-bound events is insufficient.
