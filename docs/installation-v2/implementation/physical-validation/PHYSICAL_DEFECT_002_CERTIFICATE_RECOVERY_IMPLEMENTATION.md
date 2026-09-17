# PHYSICAL_DEFECT_002 — certificate recovery implementation record

Status: **IMPLEMENTED_SOFTWARE → RETEST_REQUIRED**

Not `PHYSICALLY_VERIFIED`. No certificate has been revoked, no Apple Account was
mutated, and no Apple Developer Services call was made by any test. The first
real revocation happens only during the physical Build-3 run.

Plan of record: [`PHYSICAL_DEFECT_002_CERTIFICATE_RECOVERY_PLAN.md`](PHYSICAL_DEFECT_002_CERTIFICATE_RECOVERY_PLAN.md)

## 1. Root cause implemented against

`MISSING_RECOVERY_CASE`, not an Apple provisioning regression.

Build 2's Defect 001 fix is correct and is preserved. Its scoped key lookup
deliberately makes a Build-1 login-Keychain key invisible, which is the right
behaviour — that key can never be used by `/usr/bin/codesign`. The gap was what
happened next:

```
IOSSimIdentityMetadataStore.load()      unscoped -> Build-1 metadata IS found
        v                               certificateSerial, certificateFingerprint,
                                        generatedByIOSSim all survive
lookupPrivateKey()                      scoped   -> Build-1 key deliberately invisible
        v
PRIVATE_KEY_MISSING -> MANAGED_IDENTITY_STALE
        v
availableQuantity == 0                  Personal Team holds its 2 certificates
        v
throw .certificateLimit                 ApplePersonalTeamLive.swift:1446 — terminal
```

The metadata record that proved the identity stale *also named the certificate
occupying the slot*, and nothing consumed that fact. Veya already held
deterministic proof of ownership over the very certificate blocking it.

## 2. Ownership invariant

Every certificate returned by `ios/listAllDevelopmentCerts` is classified by
`classifyDevelopmentCertificate`. Evaluation order is itself the safety property:

| rung | evidence | revocable |
|---|---|---|
| P3 `ACTIVE_USABLE` | a locally held key matches it **and** passes the codesign probe | **never** |
| P1 `OWNED_LOCAL_RECORD` | this installation's persisted serial or fingerprint names it, on a record with `generatedByIOSSim` and a canonical key tag | **yes** |
| P2 `OWNED_REMOTE_MARKER` | Apple reports its `machineId` as this installation's stable identifier | **yes** |
| P4 `VEYA_OTHER_INSTALL` | Veya's *structured* machine name with a different installation id | **never** |
| P5 `UNKNOWN` | Xcode, another tool, unattributable | **never** |

P1 is checked before P2 and P4 deliberately. This installation's own persisted
serial is the strongest evidence available, and it is the only rung a Build-1
certificate — which predates every remote marker — can reach. Without that
ordering the Intel Mac would be unrecoverable.

P4 is reachable *only* through the structured name `Veya (<short install id>)`.
Build 1 and Build 2 wrote the constant `"IOSSim"`, which parses to nil, so a
legacy certificate is never misattributed to another Mac.

Explicitly **not** ownership evidence, and absent from the ladder: team ID alone,
certificate name alone, "Apple Development", creation date alone, newest
certificate, and "this Mac cannot currently use it".

### Safety invariants, each with a test

1. Revoke only P1 or P2.
2. Never revoke a certificate backed by a key that can actually sign.
3. At most one revocation per recovery, and never a different serial than a prior
   attempt targeted.
4. Revoke only when `availableQuantity == 0` actually blocks progress.
5. No reclaimable certificate → fail closed, mutate nothing.
6. Never read, modify or delete anything in the login Keychain.

## 3. Recovery algorithm

`ensureCertificateCapacity` replaces all five terminal `availableQuantity != 0`
guards. Each call site keeps its original fail-safe error, so behaviour is
unchanged everywhere except the newly recoverable case.

```
capacity available            -> return, nothing happens
        v  exhausted
record CERTIFICATE_CAPACITY_EXHAUSTED
        v
reconcile any persisted recovery intent
    target already gone from Apple's listing
        -> CERTIFICATE_RECLAIM_RECONCILED, confirm capacity, clear intent, return
    attempts >= 2
        -> CERTIFICATE_RECLAIM_UNAVAILABLE, throw .certificateRevocationFailed
        v
classify every listed certificate      -> CERTIFICATE_OWNERSHIP_CLASSIFIED
        v
reclaimable = P1 or P2, serial present
    none -> CERTIFICATE_RECLAIM_UNAVAILABLE, throw the caller's fail-safe error
        v
select oldest by expiration, tie-broken by serial   (deterministic)
        v
CERTIFICATE_OWNERSHIP_PROVEN
persist recovery intent            <-- BEFORE the irreversible call
CERTIFICATE_RECLAIM_STARTED
        v
ios/revokeDevelopmentCert(teamId, serialNumber)
    failure -> CERTIFICATE_REVOCATION_FAILED, throw, no cascade
        v
CERTIFICATE_REVOKED, append to retiredCertificates
        v
re-read capacity, up to 3 bounded attempts
    released     -> CERTIFICATE_CAPACITY_RESTORED, clear intent, continue
    not released -> CERTIFICATE_CAPACITY_NOT_RELEASED, keep intent, recoverable error
        v
createManagedIdentity(recovering: true) -> profiles -> codesign proof -> promote
```

### The irreversible boundary

Apple refuses issuance into a full quota, so revocation must precede candidate
creation and cannot be rolled back. This is the one place the normal
"candidate first, promote after proof" shape is deliberately weakened.

It is made safe by invariant 2: Veya only ever revokes a certificate it has
**already proven it cannot sign with**. Nothing usable is at risk inside the
window. The recovery intent is persisted before the call, so a crash or restart
reconciles against Apple's real state rather than guessing — and on restart a
target that is already absent is recognised as a completed revocation, never as a
reason to revoke a second certificate.

## 4. Multi-Mac safety

A second Mac's certificate cannot reach P1, because its serial was never written
into *this* Mac's metadata. That holds even for legacy Build-1 certificates, which
carry no installation marker at all. Multi-Mac safety is therefore structural, not
advisory.

From Build 3 onward, `machineId` is a stable persisted installation identifier
instead of a fresh `UUID().uuidString` per request, and `machineName` is
`Veya (<short install id>)` instead of the constant `"IOSSim"`. That upgrades
another Mac's certificate from "unattributable" (P5) to "positively recognised as
someone else's" (P4) — both refuse revocation, but the second is evidence rather
than absence of evidence.

One certificate cannot be shared between Macs without exporting the private key,
which Build 2's architecture deliberately prevents. Each Mac needs its own
certificate, so the Personal Team limit of 2 caps supported Macs at two. A third
fails closed.

## 5. Apple revocation

Implemented through the existing typed `developerRequest` adapter, operation
`ios/revokeDevelopmentCert`, parameters `teamId` and `serialNumber`. No new
networking stack, no browser automation, no Xcode, no Developer Portal UI.

Apple's certificate-limit code `7460` is now detected explicitly alongside the
pre-existing `"maximum"`/`"limit"` substring match, which is retained as a
fallback for message drift.

**This endpoint has never been exercised against Apple.** Its parameter shape is
taken from the vendored upstream `isideload` reference. Parameter-shape rejection
is the most likely Build-3 surprise; see §10.

## 6. Propagation and retry

Bounded at `capacityConfirmationAttempts = 3` re-reads with a 2-second default
backoff, injectable and set to zero in tests so no suite sleeps. Exhausting the
window throws `certificateCapacityNotReleased`, **retains** the recovery intent,
and records `CERTIFICATE_CAPACITY_PROPAGATING` per attempt so the physical run
yields the real propagation timing. It never spins, and never revokes a second
certificate because the first has not propagated.

Apple's true propagation delay remains unmeasured. The physical run replaces this
estimate with evidence.

## 7. Profile regeneration

`prepareProvisioning` already re-runs `obtainProfiles` after `prepareIdentity`, so
the fresh path regenerates main and runner profiles correctly after a reclaim.

The gap was the cached-artifact fast path in
`SetupStore.runLiveProvisioningThroughProfiles`, which could reuse a
`NativeProvisioningArtifacts` whose embedded certificate had just been revoked.
It now compares the cached `certificateFingerprint` against the active identity's
fingerprint and forces a full re-prepare on any mismatch, including when no
fingerprint can be read.

App IDs, device registration and pairing records are untouched by a reclaim.

An installed app signed with a revoked certificate stops launching once the device
revalidates. Nothing is installed on the Intel Mac, so migration is unaffected;
renewal and upgrade cases require reinstall after a reclaim.

## 8. Defect 001 preservation

No file in the Defect 001 code path was modified. `VeyaSigningKeychain.swift`,
`VeyaSigningQualification.swift`, `IOSSimSigningKeyTestHelper/` and
`VeyaSigningKeychainRegressionTests.swift` are byte-identical to `dd259bd`.

Certificate recovery touches only Apple-side state over Developer Services. It
reads no Keychain password, performs no `SecKeychainItemSetAccess` on
login-Keychain items, and never widens the trusted-application list. The Veya-owned
Keychain, top-level `kSecAttrAccess`, least-privilege ACL, search-list append and
`verifySigningKeyUsable` proof are all unchanged.

### Known environment limitation on the development Mac

The Defect 001 **negative control**,
`testLoginKeychainKeyCreatedByAPackagedHelperIsBlockedByItsPartitionList`, no
longer reproduces on this development Mac. It expects exit 3 (blocked) and now
observes exit 0 (signed).

Evidence that this is host state, not a code regression:

* Every file in that test's code path is untouched by this change.
* Two consecutive identical invocations of the unmodified helper in one session
  returned `codesign blocked on a SecurityAgent prompt` and then
  `codesign signed with no prompt`.
* A helper copy re-signed with a **brand-new cdhash**, never previously seen, also
  signed with no prompt — so the grant is not per-binary. It is a login-Keychain
  grant to `/usr/bin/codesign`, consistent with a SecurityAgent prompt having been
  answered "Always Allow" on this Mac.

The positive test,
`testPackagedHelperCreatedKeyIsSignableByRealCodesignWithoutAnyPrompt`, still
passes. The control was **not** weakened or deleted to make it green. The Intel
test Mac is a different host on macOS 14.8.9 with no such grant, and is where the
Defect 001 fix is actually validated.

## 9. Files changed

Production — four files:

| file | change |
|---|---|
| `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift` | metadata schema v2; `RetiredCertificateRecord`; `CertificateRecoveryIntent`; `CertificateOwnership` + `classifyDevelopmentCertificate`; `ensureCertificateCapacity`; `confirmCapacityReleased`; `usableCertificateFingerprints`; `recordRetiredCertificate`; installation identifier and recovery-intent persistence; stable `machineId`/`machineName`; `certRequestId` capture; `7460` detection; `activeSigningCertificateFingerprint` |
| `macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamExperimental.swift` | 11 reclaim checkpoints; `certificateRevocationFailed` and `certificateCapacityNotReleased` errors with safe codes; `activeSigningCertificateFingerprint` protocol requirement with a conservative default; coordinator passthrough |
| `macos/Sources/IOSSimMacCore/SetupStore.swift` | cached-artifact fingerprint invalidation; rewritten consumer messages for the three certificate failures |
| `macos/Sources/IOSSimMacCore/Models/ConsumerProvisioning.swift` | three additive `ConsumerProvisioningErrorCode` cases |
| `macos/Sources/IOSSimMacCore/Services/VeyaDiagnostics.swift` | `VEYA-APPLE-020/023/024` taxonomy mappings |

Two files the plan listed that were deliberately **not** changed:

* `NativeProvisioningArtifactStore.swift` — the artifact already carries
  `certificateFingerprint`. The `SetupStore` equality check achieves the same
  invalidation with strictly less surface area, so no schema change was needed.
* `MacAssistedRenewal.swift` — a pure planner with no Apple call.
  `.recreateCertificate` already reaches the reclaim path through
  `prepareIdentity`. Changing it would have been speculative.

Config: `config/release.json` build number 2 → 3.

Tests:

| file | change |
|---|---|
| `macos/Tests/IOSSimMacCoreTests/CertificateCapacityRecoveryTests.swift` | new — 15 tests |
| `macos/Tests/IOSSimMacCoreTests/ApplePersonalTeamLiveTests.swift` | fixture keychain conforms to the extended protocol; certificate fixture accepts `machineId`/`machineName`; three shared fixtures made internal |
| `macos/Tests/IOSSimMacCoreTests/ApplePersonalTeamExperimentalTests.swift` | the pre-existing no-revoke invariant test **narrowed, not deleted** — renamed to `…ByRevokingUnownedCertificates`, assertion retained |

## 10. Test results

| suite | result |
|---|---|
| `CertificateCapacityRecoveryTests` | 15 executed, 0 failures |
| `ApplePersonalTeamExperimentalTests` | 29 executed, 0 failures |
| `VeyaSigningKeychainRegressionTests` (unit) | 6 executed, 3 skipped, 0 failures |
| `VeyaSigningKeychainRegressionTests` (`IOSSIM_RUN_KEYCHAIN_INTEGRATION=1`) | 6 executed, 5 pass, 1 environment failure — see §8 |
| **full `swift test`** | **377 executed, 12 skipped, 0 failures** (baseline 362 / 12) |
| `check_bundle_identifiers.py` | PASS |
| `check_no_xcode_consumer_runtime.py` | PASS |
| `check_no_xcode_install_routing.py` | PASS |
| `test_artifact_identity.py` | 6 tests, OK |

No test contacts Apple, revokes a real certificate, creates one, registers a
device, changes an App ID, or creates a real profile.

## 11. Remaining unknowns

* `ios/revokeDevelopmentCert` parameter shape is unverified against Apple.
* Apple's revocation propagation delay is unmeasured; the 3× bounded retry is an
  estimate.
* Whether revoking a Personal Team certificate affects apps already installed on a
  phone from the same team is not established by any local evidence, and Build 3
  will not answer it — nothing is installed on the test iPhone.
* The Build-2 support bundle `IOSSim-Support-1789611416.zip` is still absent, so
  the Build-2 timeline remains `INFERRED_FROM_SOURCE`.
* Whether Vanish binds a revoke, error or prompt policy at its certificate limit
  remains unknown; this design diverges deliberately toward silent recovery under
  proven ownership.
