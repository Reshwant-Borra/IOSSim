# Unified Readiness and Recovery Architecture

Use a ReadinessSnapshot with independent domain records, not one Boolean. Each domain has UNKNOWN, CHECKING, READY, USER_ACTION_REQUIRED, TRANSIENT_FAILURE, REPAIRABLE, BLOCKED, UNSUPPORTED, EXPIRED or STALE, plus reason code, evidence version, selected-device token and timestamp.

Domains: HOST; DEVICE; APPLE ACCOUNT; SIGNING; INSTALLATION; PAIRING; VPN/TUNNEL; DEVELOPER SERVICES; RUNTIME; USER INTENT. Runtime depends on the preceding domains. Unknown is never ready.

## Domain Evidence and Reasons

| Domain | READY evidence | User-action reasons | Automatic repair reasons | Blocking/unsupported reasons |
|---|---|---|---|---|
| HOST | supported macOS, signed helper/manifest hashes match, required network policy reachable | reconnect network if offline | reinstall corrupted helper from signed app update | unsupported macOS/CPU |
| DEVICE | exactly selected UDID connected, unlocked, Lockdown session validates, supported OS, Developer Mode enabled | unlock, Trust This Computer, enable Developer Mode and reboot | reconnect transport, refresh observation | unsupported iOS, identity mismatch |
| APPLE ACCOUNT | non-expired scoped session and successful team query | sign in, complete 2FA | bounded retry, refresh valid session | account/team unavailable |
| SIGNING | private-key reference matches certificate; device/App IDs/profile entitlements and dates match | resolve Apple revocation/account prompt | refresh profiles, regenerate identity only on classified revocation/missing key | prohibited entitlement/team mismatch |
| INSTALLATION | exact main/runner IDs, team, versions and mapping receipt present | trust developer profile if iOS requires it | upgrade missing/stale artifact, retry inventory | cross-team upgrade with no safe path |
| PAIRING | valid Lockdown relationship, RP record bound to peer, phone import receipt, authenticated RSD | re-trust after device reset | transfer again; explicit RP repair on rejection | peer mismatch not resolved by selected identity |
| VPN/TUNNEL | LocalDevVPN installed/approved, route active, endpoint reachable | approve/install VPN/profile | reconnect route/session | OS policy prevents tunnel |
| DEVELOPER SERVICES | exact DDI mounted, RSD map, DVT and TestManager endpoints responsive | Developer Mode action may bubble from DEVICE | remount correct DDI, reconnect RSD | no approved matching DDI |
| RUNTIME | runner launch, PID authorization, XCTest handshake/test plan and rich capability proof | launch/foreground app only if genuinely required | reconnect retained session/runner | incompatible runner/protocol |
| USER INTENT | latest intent generation is acknowledged | choose spoof/drive/pause/hold/clear | discard stale queued operations | never inferred from technical recovery |

The aggregate product state is the most specific blocking dependency for the requested action, not the “worst” state globally. An expired Apple session does not disable a currently running phone session; it blocks provisioning/renewal. A disconnected Mac does not invalidate a retained phone runtime.

ReadinessEngine.reconcile observes in dependency order, verifies before mutation, invokes at most one layer-local repair with bounded retries, and emits nextUserAction. Trust, passcode, Developer Mode/restart, Apple 2FA, iOS profile trust and VPN approvals are user actions. Network/USB/Apple 5xx/RSD reconnects are transient. Pairing failure never re-provisions; VPN failure never regenerates certificates; renewal never erases app data; uninstall is explicit. A durable clear intent generation prevents replay of stale drives.

Each observation has provenance: directProtocol, phoneReceipt, signedArtifact, keychainReference, journalOnly, or userReported. Journal-only evidence can resume a check but cannot produce READY. A repair records precondition snapshot, intended mutation, operation UUID, retry count and postcondition receipt.

## Setup Journal

Extend ConsumerProvisioningStateStore into a versioned per-device journal. Safe fields: workflow UUID; device binding/display alias; transport; bridge version/digest; each domain state/reason/time; team ID; signing certificate fingerprint/Keychain ref; profile UUID/expiry/digest; artifact bundle IDs/digests/versions; DDI build/digests/cache class; pairing Keychain ref/public fingerprint/protocol; import nonce/receipt hash; tunnel endpoint fingerprint; runtime stage; attempt counts/next retry; last mutation; user-action requirement; latest intent generation. Never password, 2FA, token/cookie, private key, full pairing bytes, SRP values or coordinates. Atomic 0600 journal in 0700 directory. Resume verifies actual state.

Journal identity is a schema-versioned opaque device binding, with raw UDID held locally only where required and hashed in exported support. Mutation records use states planned, started, externalSucceeded, verified and committed. If a crash occurs after externalSucceeded, resume observes the device before repeating the mutation. Append-only events are capped/rotated and each event is redacted at construction, not just export.

## Retry Budgets

Transport observations: three attempts with jitter inside 10 seconds. Apple HTTP: honor Retry-After, at most one automatic retry for idempotent init/lookup and no automatic password/2FA replay. Installation inventory: retain the existing bounded seven-read window but also enforce total deadline. Pairing creation: one attempt per explicit repair. RSD/runtime reconnect: bounded reconnect without launch/install until capability observation proves that is necessary. Retry counts persist so crashes cannot reset a storm.

## Onboarding

Open -> select -> unlock/trust -> Developer Mode/restart -> Apple sign-in/2FA -> sign/profile/install -> automatic pairing -> user-approved VPN/profile prompts -> runtime proof -> Spoof/Drive. Irreducible interactions are Apple trust, passcode, Developer Mode/restart, 2FA, developer-profile trust and VPN/network approval.

Interfaces: snapshot, reconcile(device), nextUserAction, repair(domain), cancel(workflow). IPC carries typed states and reasons. Tests inject crash, reboot, disconnect, network loss, auth 503, install interruption, pairing interruption, tunnel loss and clear intent; resume verifies and avoids duplicate/destructive work.

## Recovery Decision Table

| Failure | First action | Forbidden action |
|---|---|---|
| USB disconnect | wait/re-enumerate same DeviceToken | select another connected phone |
| lock during setup | pause and ask unlock | mark device unsupported |
| Apple 503/429 | classify, honor backoff | delete certificate/pairing |
| app inventory lag | bounded authoritative re-read | uninstall immediately |
| main launch profile-trust error | user profile trust checkpoint | re-sign with another team |
| pairing parse failure | quarantine record, selected-device check | overwrite all device records |
| LocalDevVPN route loss | reconnect route/session | reprovision apps |
| RSD/TestManager disconnect | reconnect retained developer session | replay drive samples |
| profile nearing expiry | renewal plan/upgrade | fresh install |
| user pressed Clear | persist new intent generation and clear writer | resume prior spoof/drive |
