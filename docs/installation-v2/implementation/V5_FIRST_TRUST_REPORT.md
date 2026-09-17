# V5 first-time Trust and native Lockdown pairing report

Verdict: `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED`

## Implemented

- Raised the bundled native device bridge ABI to 2 and added a versioned `iossim_bridge_pair_lockdown_once` operation. Its public result is a secret-free pairing receipt; the ABI never returns a pairing record, private key, certificate body, or escrow material.
- Bound native device handles to exact UDID, usbmux connection ID, and connection type. Legacy UDID-only opening remains compatible only when there is exactly one matching connection. Duplicate identities fail closed instead of selecting enumeration order.
- Made GUI-side duplicate resolution deterministic for presentation: USB before wireless before unknown, then lowest mux ID. The exact selected identity is still passed to the native bridge and revalidated there.
- Added the required state vocabulary: `NO_PAIR_RECORD`, `PAIR_REQUESTED`, `WAITING_FOR_UNLOCK`, `WAITING_FOR_USER_TRUST`, `PAIR_RECORD_CREATED`, `PAIR_RECORD_PERSISTED`, and `LOCKDOWN_SESSION_VALIDATED`.
- Implemented one legitimate USB Lockdown pair request through the pinned Rust device stack. An existing record is validated and reused. A new record is validated before usbmux persistence, re-read, and followed by a fresh Lockdown session check. If post-save validation fails, only the newly created record is removed.
- Preserved Apple's device security interactions. Veya can request pairing, detect locked/pending/denied/disconnected outcomes, guide the user to unlock and tap Trust, wait, and retry. It cannot approve Trust or enter/bypass the device passcode.
- Added `pair-device` to the packaged helper protocol and routed the pre-authorization mutation through the V4 keyed cross-process lease. The command requires an exact connected USB descriptor and emits the typed receipt as JSON.
- Added Setup Engine, SetupStore, and SetupWizard routing for the first-Trust action. The user-facing copy no longer describes a generic setup retry; it explicitly asks the user to unlock the iPhone and respond to Apple's Trust prompt.
- Bumped the helper schema from 1 to 2 so an old packaged helper cannot be used with the new ABI/command contract.
- Corrected a gate-discovered macOS persistence defect: current Foundation rejects the iOS-only `.completeFileProtection` write option with `EPERM`. Apple diagnostics, preserved native profiles, and profile copies now use atomic macOS writes with existing `0700` directory and `0600` file permissions.

## Safety and ownership

- Pairing is USB-only for first Trust.
- Pair-record persistence remains owned by usbmuxd through the pinned native stack; Veya does not invent or export a manual pairing file.
- The existing record is never deleted during reuse or ordinary failure. Cleanup is restricted to a record created by the current operation when its mandatory post-persistence validation fails.
- Stable Host/System BUID values come from usbmuxd; no random host identity is substituted on each attempt.
- Receipt fields bind schema, UDID, mux ID, connection type, generation, terminal state, reuse status, and timestamp. They contain no raw authentication material.
- Logs and UI errors are redacted and classify Trust pending, denial, lock, disconnect, identity mismatch, and protocol failure separately.

## Acceptance evidence

- Rust bridge tests prove ABI 2, deterministic exact selection, USB/wireless distinction, ambiguity rejection, and pairing status mapping: 10/10 passed.
- Export inspection proves the release dylib contains ABI, exact-open, pairing, and result-free symbols; direct ABI invocation returned 2.
- Swift unit tests cover successful validation, pending Trust, locked device, denial, disconnect, unexpected protocol failure, wireless refusal without service invocation, and receipt encoding without secret-shaped fields.
- Device bridge tests cover exact connection binding and stable duplicate USB selection.
- SetupStore test proves a Trust action requests native pairing once and remains in the user-action state while Trust is pending.
- The packaged helper command without a connected exact device fails safely with `VEYA-DEVICE-001`; it does not mutate an account, Keychain identity, or phone.
- Broad safe Swift regression after the macOS persistence correction: 305 executed, 2 opt-in tests skipped, zero failures, zero unexpected.
- `git diff --check` passed.

Broad regression log: `.build/iossim/logs/v5-safe-swift-test-rerun.log`.

## Known limitations and physical deferral

- No never-paired physical iPhone was used. Creation and persistence of a real Lockdown record, the on-device Trust prompt, denial behavior, disconnect/reconnect, and fresh session validation remain `PHYSICAL_DEVICE` evidence for V19.
- The C ABI is source-level versioned and symbol-checked. Cross-architecture packaging remains governed by artifact truth and V17 qualification.
- This milestone does not alter RemotePairing/RSD pairing; transactional RemotePairing replacement is V10.
- The development machine has Xcode installed, but the packaged Trust route itself invokes neither Xcode, `devicectl`, nor repository tooling.

## Gate

The native path is implemented, exact-connection selection is deterministic, Apple's Trust boundary is preserved, existing enumeration remains compatible, and all safe automated gates pass. V5 may advance under the master plan's explicit `PASS_WITH_PHYSICAL_VALIDATION_REQUIRED` allowance; no physical pass is claimed.
