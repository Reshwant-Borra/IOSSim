# PHYSICAL DEFECT 001 — clean-Mac `SIGNING_KEY_ACCESS_DENIED`

Status: **FIXED_SOFTWARE / RETEST_REQUIRED**
(Not `PHYSICALLY_VERIFIED`. The corrected artifact has not yet been run on the
failing Mac.)

---

## ENVIRONMENT

| | |
|---|---|
| Architecture | x86_64 Intel Mac |
| macOS | 14.8.9 (build 23J631) |
| Xcode | not installed — zero-Xcode consumer test |
| Setup engine | `BUNDLED_PROVISIONING_ENGINE` |
| Running executable | `BUNDLED_APP_HELPER` — `Veya.app/Contents/MacOS/IOSSimProvisioner` |
| Signature class | ad-hoc (`LOCAL_TEST_ONLY`) |

## ARTIFACT

| | |
|---|---|
| Filename | `Veya-0.1.0-build1-1259da5-local-test.dmg` |
| SHA-256 | `0bbc112d7ef191190da2afce0067012392e6ec31719330d9e85a8aa7633d4a72` |

## PHYSICAL RESULT

### LAST SUCCESSFUL STAGE

`PROVISIONING_READY` at 20:56:22Z. Everything before it passed: launch, Intel
execution, no-Xcode routing, native iPhone discovery, Apple Account
authentication, session, Personal Team discovery, device registration, derived
App IDs, and both provisioning profiles.

### FIRST FAILED STAGE

`installing` → `SIGNING_KEY_ACCESS_DENIED` at 20:56:34Z.

## SUPPORT-BUNDLE EVIDENCE

Primary evidence: `IOSSim-Support-1789592208.zip`, copied to
`evidence/` in this directory. No secrets are reproduced below.

The five questions that had to be answered before touching production code:

**1. Which process attempted to access the key?**
`/usr/bin/codesign`, spawned by the packaged helper `IOSSimProvisioner`.
Payload signing in `ConsumerArtifactProvisioner.codesign(_:identity:entitlements:)`
and the resolver's probe in `NativeSigningIdentityResolver` are both
out-of-process `/usr/bin/codesign` invocations. `IOSSimProvisioner` never signs
through Security.framework directly, so codesign — not Veya — is the process
that must be authorized for the key.

**2. Which Keychain contained the key?**
The login Keychain. `createPrivateKey` passed `kSecUseKeychain:
SecKeychainCopyDefault()` explicitly, and `SecKeychainItemCopyFromPersistentReference`
succeeded during the run, which only works for legacy-Keychain items. The
earlier "explicit Keychain destination" fix was working as designed — it was
simply aimed at the wrong Keychain.

**3. Which authorization state was present?**
Reproduced exactly (see `repro/EVIDENCE_MATRIX.md`):

* Sign ACL trusted applications: **the creating process only**.
  `/usr/bin/codesign` was absent, because `SecKeyCreateRandomKey` silently
  discards a `kSecAttrAccess` nested inside `kSecPrivateKeyAttrs` — the exact
  shape the previous fix introduced. The resulting ACL is byte-identical to
  passing no `SecAccess` at all.
* Partition list: `Partitions = [cdhash:<creating binary>]`, injected by
  `securityd` at item-store time.
* `ChangeACL`: empty trusted-application list, i.e. always prompts.

**4. Which exact operation was denied?**
`/usr/bin/codesign`'s use of the private key for `ACLAuthorizationSign`, during
install-phase signing. It was classified by
`NativeSigningIdentityResolver.codesignAccessDenied(_:)` into
`.signingKeyAccessDenied`. The classification was **correct** — key lookup,
certificate lookup, SecIdentity resolution and the public-key match had all
already succeeded (`certificatePublicKeyMatchesPrivateKey: true` at generations
1, 2 and 3).

**5. Why did the existing repair/probe logic not prevent it?**
`authorizePrivateKeyForSigning` re-applied the same `SecAccess` through
`SecKeychainItemSetAccess`. That call needs `ChangeACL`, which nothing held, so
it raised a dialog — visible in the bundle as a **14-second** gap between
`PRIVATE_KEY_LOOKUP_STARTED` (20:55:40) and `PRIVATE_KEY_FOUND` (20:55:54), and
a **6-second** gap at generation 3 (20:56:15 → 20:56:21). Those are the consumer
answering prompts. Even when allowed, the repair only rewrote the
trusted-application ACL; it could not touch the partition list, which is the
gate that actually blocks codesign. A further **9-second** gap precedes the
failure at 20:56:34 — the third dialog, which ended in denial.

## ROOT CAUSE

**A signing key that `/usr/bin/codesign` is structurally incapable of using was
being created in the login Keychain, and nothing proved otherwise before
provisioning reported ready.**

Two defects, in order of decisiveness:

### 1. Wrong Keychain (decisive)

`securityd` stamps every login-Keychain key with a partition list derived from
the **creating process's code identity**. A packaged Veya build is ad-hoc
signed, so its keys are stamped `Partitions = [cdhash:<Veya>]`.
`/usr/bin/codesign` is a different binary with a different code identity and can
never match that partition.

The partition list is checked **independently of, and in addition to, the
trusted-application ACL**. The control experiment settles it: a login-Keychain
key whose Sign ACL trusts *every application on the Mac* is still blocked. No
ACL repair could ever have fixed this.

Nor can the partition list be repaired in-process: rewriting it requires the
login Keychain password (`SecKeychainItemSetAccess` returns `-25293
errSecAuthFailed`), which a consumer installer must not ask for.

### 2. ACL silently discarded (real, but not sufficient)

The previous fix moved `kSecAttrAccess` *into* `kSecPrivateKeyAttrs` on the
theory that top-level placement "made it dependent on Security.framework
implementation details". It is the reverse: `SecKeyCreateRandomKey` honours
`kSecAttrAccess` only at the top level and drops it from the nested dictionary
without error. So the ACL naming `/usr/bin/codesign` was never applied at all.

Fixing only #2 does not fix the defect — #1 still blocks. Both are corrected.

## WHY THE CLEAN INTEL MAC EXPOSED IT

It did not expose it *because* it was Intel, or *because* it was 14.8.9. It
exposed it because it was the first time the **packaged, ad-hoc-signed Veya
binary** created the signing key. On the development Mac the key had always been
created either by `xctest` or by a build whose partition happened to be
satisfiable, and existing developer Keychain state masked the rest.

Being clean also removed the second mask: a developer Mac usually already holds
a usable Apple Development identity, so the reuse path had material that
happened to work.

## WHY AUTOMATED TESTS MISSED IT

Proved, not guessed. Two independent gaps:

### Gap A — the only real Keychain tests were skipped

`NativeSigningIdentityIntegrationTests` is gated behind
`IOSSIM_RUN_KEYCHAIN_INTEGRATION=1` and is skipped by plain `swift test`. Those
skips are part of V19's "9 intentional skips". The suite that qualified the
release contained **no** execution of real Security.framework key creation or
real `/usr/bin/codesign` authorization.

Running that gated suite on the development Mac during this investigation does
not pass — it **hangs**. Process capture while hung:

```
/usr/bin/codesign --force --sign <sha1> --timestamp=none .../IOSSimIdentityProbe.app   (blocked)
.../SecurityAgent.bundle/Contents/MacOS/SecurityAgent                                  (prompting)
```

The test literally named
`testCleanConsumerMacIOSSimOwnedKeyIsUsableFromPackagedHelperWithoutInteraction`
reproduces the physical defect — it was just never run.

### Gap B — the test process identity is not the shipped process identity

This is the deeper gap, and it means Gap A alone would not have been enough.

`xctest` is an **Apple-signed** binary. Keys it creates in the login Keychain
receive a partition `/usr/bin/codesign` *can* match, so the defect is invisible
from inside a test process. Measured on this Mac:

| creating process | signature | partition stamped | codesign result |
|---|---|---|---|
| `xctest` | Apple | matchable | signs, no prompt |
| ad-hoc SwiftPM executable | ad-hoc | `cdhash:<creator>` | **blocked on prompt** |

A key created inside `xctest` therefore cannot reproduce the consumer's
conditions no matter how thorough the assertions are. The regression had to be
moved out of the test process entirely.

## FILES CHANGED

| file | change |
|---|---|
| `macos/Sources/IOSSimMacCore/Services/VeyaSigningKeychain.swift` | **new** — the Veya-owned signing Keychain: creation, password, unlock, search-list registration |
| `macos/Sources/IOSSimMacCore/Services/VeyaSigningQualification.swift` | **new** — clean-consumer signing qualification, runnable from a non-Apple-signed process |
| `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift` | key creation targets the Veya Keychain; `kSecAttrAccess` moved to the top level; `ChangeACL` granted to Veya's own executables; key/persistent-ref/ACL-repair lookups and certificate storage scoped to the Veya Keychain; `verifySigningKeyUsable` added; usability proof wired into the identity lifecycle |
| `macos/Sources/IOSSimMacCore/Services/NativeSigningIdentityResolver.swift` | certificate, key and identity lookups scoped to the Veya Keychain; search-list registration; probe failure no longer misreported as a sign-operation failure |
| `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamExperimental.swift` | `SIGNING_KEY_USABILITY_VERIFIED` / `SIGNING_KEY_USABILITY_FAILED` checkpoints |
| `macos/Sources/IOSSimMacCore/Models/ConsumerProvisioning.swift` | `SIGNING_KEYCHAIN_UNAVAILABLE`, `SIGNING_ACL_REPAIR_FAILED`, `SIGNING_PROBE_FAILED` |
| `macos/Sources/IOSSimMacCore/Services/VeyaDiagnostics.swift` | stable `VEYA-SIGNING-006/007/008` codes for the above |
| `macos/Sources/IOSSimSigningKeyTestHelper/main.swift` | `qualify-signing [veya\|login]` subcommand |
| `macos/Package.swift` | helper depends on `IOSSimMacCore` |
| `macos/Tests/IOSSimMacCoreTests/VeyaSigningKeychainRegressionTests.swift` | **new** — UNIT + LOCAL_SYSTEM regression |
| `macos/Tests/IOSSimMacCoreTests/ApplePersonalTeamLiveTests.swift` | fixture keychain conforms to the extended protocol |

## FIX

1. **Keychain destination.** The Personal Team signing key and its Apple
   certificate are created in `~/Library/Keychains/Veya-Signing.keychain-db`,
   which Veya creates on first use with a per-installation random password
   stored 0600 in Veya's own Application Support directory. Keys there receive
   **no** partition ACL, so the trusted-application ACL governs.
2. **ACL placement.** `kSecAttrAccess` is passed at the top level of the
   `SecKeyCreateRandomKey` attributes, where it is actually honoured.
3. **ACL contents.** `/usr/bin/codesign`, `Veya.app/Contents/MacOS/IOSSim` and
   `Veya.app/Contents/MacOS/IOSSimProvisioner` — and nothing else.
4. **Silent repair.** `ChangeACL` is granted to those same executables at
   creation, so Veya can repair its own key without a dialog. Previously
   `SecAccessCreate` left it empty, which is what prompted the consumer three
   times during the physical run.
5. **Search list.** Veya's Keychain is appended — never substituted — to the
   user's Keychain search list, because `/usr/bin/codesign` resolves identities
   through it. `--keychain` alone is not sufficient.
6. **Usability invariant.** `verifySigningKeyUsable` runs a real
   `/usr/bin/codesign` signature against a disposable bundle, verifies it and
   deletes it. It runs on every completed identity and on every reuse. An
   identity that fails it is never reported signing-ready.
7. **Automatic recovery.** A reused key that fails the invariant is replaced
   with a fresh Veya-owned candidate. Keys left in the login Keychain by the
   previous build are invisible to the scoped lookups, so they are treated as
   missing and superseded — never read, modified or deleted.

## SECURITY IMPACT

Access was **narrowed**, not broadened:

* The key now lives in a Keychain used for nothing else, instead of alongside
  the consumer's own credentials in the login Keychain.
* The ACL lists three executables. Earlier behaviour was effectively "the
  creating process only, plus whatever the consumer clicked Allow on" — and
  clicking *Always Allow* on a login-Keychain dialog is a broader, and
  permanent, grant than what is configured here.
* No unrelated key, certificate or Keychain item is read, modified or deleted.
  The search list is only ever appended to.
* Nothing asks for, stores or logs the login Keychain password.

Residual tradeoff, stated plainly: the Veya Keychain's password sits in a 0600
file in the user's home directory rather than being protected by the login
Keychain. That is weaker than login-Keychain protection against an attacker who
can already read arbitrary files as this user. It is proportionate — the
material is a seven-day Apple Development Personal Team key scoped to this
user's own devices — and it is the only arrangement that lets `codesign` use the
key without prompting, since the login Keychain cannot host a codesign-usable
key created by a non-Apple-signed process at all.

## REGRESSION TEST

`macos/Tests/IOSSimMacCoreTests/VeyaSigningKeychainRegressionTests.swift`

| test | class | what it catches |
|---|---|---|
| `testSigningKeyAttributesCarryAccessAtTheTopLevelAndTargetTheVeyaKeychain` | UNIT | `kSecAttrAccess` regressing back into `kSecPrivateKeyAttrs`; implicit Keychain destination |
| `testSigningAccessPolicyGrantsOnlyCodesignAndThePackagedVeyaExecutables` | UNIT | ACL widening beyond least privilege |
| `testSigningKeychainPasswordIsRandomPerInstallationAndStoredPrivately` | UNIT | a hardcoded/shared password, or 0600 being lost |
| `testPackagedHelperCreatedKeyIsSignableByRealCodesignWithoutAnyPrompt` | LOCAL_SYSTEM | **the defect** — real codesign, real Keychain, from an ad-hoc-signed process |
| `testLoginKeychainKeyCreatedByAPackagedHelperIsBlockedByItsPartitionList` | LOCAL_SYSTEM | proves the gate *discriminates* rather than merely passing |
| `testSigningQualificationLeavesTheUserKeychainSearchListIntact` | LOCAL_SYSTEM | collateral damage to the user's Keychain configuration |

The LOCAL_SYSTEM tests drive `IOSSimSigningKeyTestHelper qualify-signing`, a
separate ad-hoc-signed executable, precisely because running the same code
inside `xctest` cannot reproduce the defect (Gap B above).

Run them with:

```
cd macos && IOSSIM_RUN_KEYCHAIN_INTEGRATION=1 swift test --filter VeyaSigningKeychainRegressionTests
```

## TEST RESULTS

See `PHYSICAL_DEFECT_001_TEST_RESULTS.md` in this directory.

## NEW ARTIFACT

See `PHYSICAL_DEFECT_001_ARTIFACT.md` in this directory.

## RETEST INSTRUCTIONS

See `PHYSICAL_RETEST_001.md` in this directory.

## UNVALIDATED LATER STAGES

Everything after signing remains **unproven on physical hardware**. This fix
makes no claim about any of it:

* DDI personalization
* TSS / DDI mount
* native installation (`install app`, house arrest, AFC)
* RemotePairing / automatic pairing delivery
* LocalDevVPN / software tunnel / RSD / RemoteXPC
* AppService launch
* Rich XCUILocation runtime and runtime-configuration verification
* reboot survival and profile renewal
* Gatekeeper / notarization for public distribution (explicitly out of scope
  here; the quarantine error seen on the first transfer is a separate
  distribution-policy issue with no evidence of causal connection to this defect)
