# Automatic Pairing Architecture

USB Lockdown pairing is the Trust This Computer relationship. RemotePairing/RPPairing is the developer-service cryptographic record used by LocalDevVPN/RSD. App delivery is the transfer of a setup envelope. Keep them as separate types.

## Lifecycle

Select immutable DeviceIdentity; observe unlocked/trusted state; pause for Trust This Computer or passcode; read and validate existing RemotePairing; create it through trusted USB RemotePairing lockdown when missing/stale; store protected Mac record; install/upgrade signed app; bootstrap app and obtain import key/nonce; write encrypted one-time envelope to app-private House Arrest VendContainer inbox; first launch validates/imports/deletes and returns receipt; Mac validates authenticated pair/RSD and TestManager/XCTest; mark READY.

The Mac Rust DeviceBridge creates and validates RemotePairing. Swift PairingCoordinator owns policy, Keychain, transfer and journal. The phone remains owner of its Keychain RPPairingStore.

## Storage and Binding

Mac Keychain stores the pairing record in a dedicated access-controlled generic password item. Journal stores only Keychain reference, protocol version, public fingerprint, binding fingerprint and dates. Key is verified physical UniqueDeviceID plus host/team scope and protocol version; bind to RSD peer identity observed at creation. Do not use numeric usbmux ID, CoreDevice UUID, hostname or RP identifier alone. Multiple connected phones always have separate records.

## Delivery

Normal path is House Arrest VendContainer plus AFC to app-private Library/Application Support/IOSSim/SetupInbox. Do not use preferences or user Documents in normal UX. Preferred first build uses a two-step bootstrap: install/upgrade and launch without pairing secret; phone creates an import key and nonce and returns a short-lived receipt; Mac encrypts and writes envelope; app imports and acknowledges. Before-first-launch staging is technically possible but deferred until tested and never advertised as the default.

Semantic validity: schema/version, bundle/team/app binding, device fingerprint, key lengths (public/private 32 bytes), identifier, expiry/nonce/replay, canonical encoding, allowlisted fields. Cryptographic validity: Lockdown session and device match, pair-verify/validate, authenticated RSD handshake, LocalDevVPN reachability and TestManager/XCTest proof. Accepted import alone is not READY.

## Repair

Missing -> create. Parse failure -> quarantine and recreate only after identity recheck. Pair-verify rejection -> one explicit stale repair, not generic regeneration. Device reset -> trust and recreate that device only. iOS update -> preserve and revalidate, remount DDI if required. Mac reboot/reinstall -> Keychain/journal migration and validation. Two phones -> selected token on every operation, abort mismatch. Manual plist export/import only advanced diagnostics.

Receipt contains nonce, timestamp, public fingerprint, app build and accepted/rejected/already-consumed; never private material. Complete transfer and first-launch behavior require physical validation.

## Direct Answers

1. RemotePairing is created by the macOS native DeviceBridge, under PairingCoordinator policy, while the selected phone is connected and trusted over USB.
2. The pinned Rust idevice RemotePairing/RemotePairing-lockdown and RSD modules perform it. IOSSim wraps explicit pair, pair-verify and validation; it does not call a convenience method that silently regenerates after any error.
3. Host pairing secret material is stored as a dedicated Mac Keychain generic-password item. Non-secret receipt metadata lives in the per-device setup journal.
4. Keychain stores the secret directly. Encrypting an Application Support plist with a Keychain wrapping key adds file lifecycle and backup exposure without a benefit for this record size. Application Support contains no recoverable private pairing material.
5. Records are keyed by IOSSim schema/protocol version, verified Lockdown UniqueDeviceID and host identity scope, with the RSD peer fingerprint recorded after successful pairing.
6. Stable binding uses the physical UniqueDeviceID observed from trusted Lockdown and the verified RSD peer public identity. usbmux numeric device ID, Bonjour address, RSD/CoreDevice UUID and RP host identifier are secondary locators and never sufficient alone.
7. Delivery uses House Arrest VendContainer plus AFC to an IOSSim-owned private setup inbox. Preferences are rejected as transport; Documents/VendDocuments and manual export are diagnostics only. An explicit phone import endpoint may signal/acknowledge but does not expose a general file server.
8. House Arrest can stage into an installed app container before ordinary UI use, but the preferred encrypted bootstrap needs one first launch to create the phone import key/nonce. Pre-first-launch delivery is not a first-release requirement and must be physically qualified before use.
9. App sandboxing prevents the app from reading arbitrary host/AFC paths. House Arrest vends only its container; the bridge uses an allowlisted Application Support path. The app applies iOS file protection to imported state and deletes the envelope.
10. The phone acknowledges with a signed/authenticated one-time receipt bound to envelope nonce, app build, public fingerprint and result. The Mac then verifies the receipt through the device session.
11. Semantic validity includes schema, canonical plist encoding, expected fields/types, 32-byte public/private keys, nonempty identifier, optional alt_irk length, app/team/device binding, nonce, expiry and single-use status.
12. Actual validity requires a trusted Lockdown session, RP pair-verify, authenticated RSD peer, LocalDevVPN reachability and TestManager/XCTest capability. Parsing alone is insufficient.
13. Pairing is stale when semantic binding differs, peer pair-verify rejects, authenticated RSD identifies a different peer, or repeated RSD authentication fails while tunnel/service health is otherwise proven. A timeout alone is transient, not stale.
14. Repair after one classified stale/rejected result on the selected device, or explicit user Repair. Retry transfer without regenerating if only app import/receipt failed.
15. Regenerate only when no record exists, device reset invalidated trust/pairing, private material is corrupt/missing, or explicit pair-verify proves rejection. Never regenerate for VPN, DDI, network or generic timeout failures.
16. Mac reboot preserves Keychain record, setup journal and DDI cache. Live USB/RSD handles do not survive and are re-observed.
17. Mac app reinstall preserves Keychain records only if signing identity/access-group continuity allows it. A migrated/new journal discovers and verifies them. If inaccessible, repair that phone without asking the user for a plist.
18. Phone reset invalidates app data, trust and likely pairing. Reinstall app, redo user trust/Developer Mode approvals, create/deliver a new record and leave other phones untouched.
19. After iOS update, first validate existing Lockdown/RP state, acquire/mount a matching DDI if required, and reconnect. Regenerate pairing only on explicit rejection.
20. With two phones, show both, require an explicit selected DeviceToken and bind every operation/receipt to it. Disconnect/reconnect cannot silently change selection; ambiguity is BLOCKED until selection is unambiguous.

## Advanced Fallback

Manual export/import is excluded from normal setup. If retained for support, require an explicit advanced-mode warning, encrypt the export with a one-time recovery secret, expire it, omit it from support bundles and provide immediate deletion instructions. It is never used to satisfy the consumer PAIRING GATE.
