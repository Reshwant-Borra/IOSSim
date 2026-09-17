# PHYSICAL RETEST 001 — corrected signing artifact

Test the **same Intel Mac** that failed (x86_64, macOS 14.8.9, build 23J631, no
Xcode). Using the same machine is deliberate: it isolates "old build fails / new
build passes" without changing any other variable.

## Artifact

`Veya-0.1.0-build2-dd259bd-local-test.dmg`
SHA-256 `a5cfa59e7355b9a89482280b1c9546ebf5a892c8c19071c0b8895333c19ab2e7`

Verify on the test Mac before opening it:

```
shasum -a 256 ~/Downloads/Veya-0.1.0-build2-dd259bd-local-test.dmg
```

## Before you start

Do **not** delete anything from the Keychain. Veya now owns its own signing
Keychain and supersedes its old state by itself; the point of this retest is to
prove that automatic recovery works. If it does not, that is a finding to
report, not something to work around by hand.

The old build's key is still in the login Keychain. Leave it there — it is
deliberately invisible to the new build, and the retest should confirm it is
never read, modified or deleted.

Quarantine handling is unchanged from the first test (the app is ad-hoc signed
and still not notarized). Clear it the same way you did before.

## Steps

1. Launch Veya and run setup exactly as before. Sign in to the same Apple
   Account and select the same iPhone.
2. Watch the stages you already saw pass — launch through `PROVISIONING_READY`.
   They are expected to pass again.
3. **Watch for Keychain dialogs.** The corrected build should show **none**. If
   any dialog appears, screenshot it and note which stage it interrupted before
   answering — that is the most important signal in this retest.
4. Let setup continue into installation and signing.
5. Continue until setup either reaches READY or hits its **next** first failure.
   Stop there and export a support bundle.

## What to record

* Whether any Keychain dialog appeared, and at which stage.
* Whether `SIGNING_KEY_ACCESS_DENIED` recurs.
* The first stage that fails, if any, and its exact error code.
* Whether `~/Library/Keychains/Veya-Signing.keychain-db` was created.
* Export the support bundle regardless of outcome.

## Expected behaviour

* No Keychain dialog at any point.
* New checkpoint `SIGNING_KEY_USABILITY_VERIFIED` appears in the support bundle
  at the `managedSigningIdentity` stage.
* The old login-Keychain key is not found by the new build, so the reuse path
  treats it as missing and issues a fresh Veya-owned key and certificate —
  visible as `MANAGED_IDENTITY_STALE` → `MANAGED_IDENTITY_RECOVERY_STARTED` →
  `KEYPAIR_CREATED`.
* Signing and installation proceed past the point where build1 stopped.

Note on the Apple account: a fresh key means a new Apple Development
certificate. The account already held two. If Apple reports the certificate
limit, setup will surface `certificateLimit` rather than a signing-access
failure — report that verbatim; it is a different problem with a different fix.

## What this retest does NOT establish

Everything after signing is still unproven on hardware: DDI personalization,
TSS/mount, native installation, RemotePairing, LocalDevVPN, AppService launch,
Rich XCUILocation runtime, reboot survival and renewal. Do not assume any of
them pass. If setup gets further and then fails, that is expected progress —
record the new first failure and stop.
