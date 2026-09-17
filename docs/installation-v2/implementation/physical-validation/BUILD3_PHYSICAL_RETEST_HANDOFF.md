# Build 3 — physical retest handoff

Purpose: prove that Veya recovers **automatically** from the exact state Build 1
and Build 2 left on your Mac, without a Keychain password prompt and without
touching any certificate it cannot prove it owns.

This run tests defect 002 (certificate recovery) and, in the same pass, finally
tests defect 001 (signing key access) — Build 2 never reached the signing step.

## Artifact

| | |
|---|---|
| file | `Veya-0.1.0-build3-2f87097-local-test.dmg` |
| SHA-256 | `0b8cb2616dbda203d4d97a30f97612b120c542dedcaecbe517630e9cead5619f` |
| size | 16,403,091 bytes |
| built from | `2f87097`, `dirty=false` |
| version / build | `0.1.0 (3)` |
| architectures | `arm64`, `x86_64` |
| class | `LOCAL_TEST_ONLY` — not notarized, not for distribution |

Verify before installing:

```
shasum -a 256 ~/Downloads/Veya-0.1.0-build3-2f87097-local-test.dmg
```

It must print the SHA-256 above. If it does not, stop.

The previous artifact was `Veya-0.1.0-build2-dd259bd-local-test.dmg`
(`a5cfa59e…`). Build 3 is a different file; do not reuse Build 2.

## Environment — do not clean anything

Use the **same Intel Mac**, the **same iPhone**, and the **same Apple Account**.

**Leave all existing Build-1 and Build-2 state exactly as it is.** That leftover
state *is* the test. Specifically, do **not**:

* delete or reset any Keychain,
* remove Veya's Application Support folder,
* delete certificates in the Apple Developer Portal,
* sign in with a different Apple Account,
* install Xcode,
* clear provisioning state.

Expected starting condition: macOS 14.8.9 (23J631), Intel x86_64, no Xcode,
Personal Team with **both** development certificate slots occupied — one of them
by Build 1's certificate.

## What Veya will do to your Apple Account

Veya will **revoke exactly one Apple Development certificate**: the one Build 1
created, identified by the serial number Veya itself recorded. It will then issue
a replacement.

It will not touch any other certificate. If it cannot prove a certificate is its
own and already unusable, it revokes nothing and stops with an explanation.

This is the first time Veya has ever called Apple's revoke endpoint.

## Procedure

1. Verify the SHA-256 above.
2. Mount the DMG, drag Veya to Applications, eject.
3. Launch Veya from Applications. If Gatekeeper blocks it, right-click → Open.
4. Connect and unlock the iPhone. Keep it unlocked and connected throughout.
5. Continue through Apple sign-in if prompted.
6. Let setup run without intervening. Do not click through anything unexpected —
   see "Stop conditions".
7. Note the wall-clock time between "Preparing Veya" appearing and the next
   visible progress. That interval is Apple's revocation propagation delay, which
   has never been measured.
8. When the run ends — success or failure — export a support report from Veya's
   Help menu.

## Expected sequence

```
Veya launches
   v   NO Keychain-password prompt at any point
iPhone discovered
   v
Apple session reused or re-authorized
   v
Personal Team discovered
   v
existing Build-1 identity inspected and recognised as stale
   v
Personal Team reports no free certificate slot
   v
Veya proves the Build-1 certificate is its own
   v
that one certificate is revoked -- nothing else
   v
brief pause while Apple releases the slot
   v
new key, CSR and certificate issued
   v
main and runner profiles regenerated
   v
signing proof passes
   v
payload signing proceeds  <-- past where BOTH Build 1 and Build 2 failed
   v
setup continues to READY, or to the next genuine failure
```

Reaching a *new* failure after signing is a **successful** defect-002 retest. The
next subsystem has simply never been physically validated.

## Stop conditions — stop, screenshot, export support report

Stop immediately and capture evidence if you see any of:

* **any Keychain password prompt** — defect 001 would not be fixed;
* a prompt asking you to choose a certificate — Veya must never ask;
* any warning about deleting or revoking something, other than silent progress;
* more than one certificate disappearing from your Apple account;
* `CERTIFICATE_RECLAIM_UNAVAILABLE`, `CERTIFICATE_REVOCATION_FAILED`, or
  `CERTIFICATE_CAPACITY_NOT_RELEASED` in the UI detail;
* the message "Veya couldn't free a development slot safely";
* setup hanging for more than about two minutes at one step.

For a hang, note the exact step text and how long it hung. Do not answer any
SecurityAgent dialog — its appearance is itself the finding.

## Success criteria

Defect 002 is `PHYSICALLY_VERIFIED` only if **all** of these hold:

1. No Keychain-password prompt occurred at any point.
2. The stale Build-1 identity was recognised.
3. Exactly one certificate was revoked, and its serial matches the one Veya
   recorded for Build 1.
4. No other certificate in the Personal Team was altered.
5. A replacement identity was created and proved it can sign.
6. Main and runner profiles were regenerated and validated.
7. Payload signing succeeded.
8. Setup advanced beyond the point where both Build 1 and Build 2 failed.

Defect 001 may also be promoted from `RETEST_REQUIRED` if 1, 5 and 7 hold.

A disappearing `certificateLimit` error is **not** sufficient on its own.

## Checkpoints to confirm in the support report

Present, in order:

```
MANAGED_IDENTITY_STALE
CERTIFICATE_CAPACITY_EXHAUSTED
CERTIFICATE_OWNERSHIP_CLASSIFIED
CERTIFICATE_OWNERSHIP_PROVEN
CERTIFICATE_RECLAIM_STARTED
CERTIFICATE_REVOKED
CERTIFICATE_CAPACITY_RESTORED
KEYPAIR_CREATED
CSR_CREATED
DEVELOPMENT_CERTIFICATE_CREATED
SIGNING_KEY_USABILITY_VERIFIED
MAIN_PROFILE_READY
RUNNER_PROFILE_READY
PROVISIONING_READY
```

`CERTIFICATE_OWNERSHIP_CLASSIFIED` carries counts of how many certificates fell
into each ownership rung. `reclaimableCount` must be exactly 1.

Must **not** appear: `SIGNING_KEY_ACCESS_DENIED`,
`CERTIFICATE_LIMIT_REACHED`, `CERTIFICATE_RECLAIM_UNAVAILABLE`.

`CERTIFICATE_CAPACITY_PROPAGATING` may appear once or twice — that is the bounded
wait working, not a fault.

## If Apple's revoke endpoint behaves unexpectedly

This is the highest-risk step and has never run against Apple. If the report shows
`CERTIFICATE_REVOCATION_FAILED`, capture the support report and stop. Do **not**
delete certificates manually to "help it along" — doing so destroys the evidence
needed to fix the call, and Veya is designed to recover without it.

Nothing is lost by a failed revocation: Veya only ever targets a certificate it
has already proven it cannot use.

## Afterwards

Send back the support report, the outcome against the eight success criteria, and
the propagation timing from step 7. Nothing below signing has been physically
validated, so treat any later failure as a new, expected finding rather than a
regression.
