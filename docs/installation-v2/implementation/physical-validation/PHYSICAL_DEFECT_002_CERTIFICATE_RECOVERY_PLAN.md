# PHYSICAL_DEFECT_002 — Personal Team certificate recovery

Status: **INVESTIGATED_PLAN_READY**

Not `FIXED`. Not `PHYSICALLY_VERIFIED`. No production source was changed by this
pass, no certificate was revoked, and the Apple Account was not mutated.

Found on: Intel x86_64, macOS 14.8.9 (23J631), no Xcode, Personal Team
`5337SALD55`, same iPhone, `Veya-0.1.0-build2-dd259bd-local-test.dmg`, run
against intact Build 1 state.

---

## 1. Investigation verdict

`MISSING_RECOVERY_CASE` — **not** a regression of Apple provisioning.

Apple authorization, team discovery, device registration, App ID management and
profile issuance are all still correct in Build 2. They are simply never reached,
because `prepareIdentity` throws first. The defect is that
`ApplePersonalTeamLive.swift:1446` treats "no free certificate slot" as terminal,
at a moment when Veya is holding persisted proof that one of the occupied slots is
its own dead certificate.

For a consumer installer, inability to recover from Veya's own previous certificate
is a product defect, not expected Apple behaviour.

Implementation readiness: **READY_TO_IMPLEMENT**.

## 2. Build 1 timeline — OBSERVED

Source: `evidence/IOSSim-Support-1789592208.zip`. Three provisioning generations,
all three reaching `PROVISIONING_READY`.

| time (Z) | event |
|---|---|
| 20:55:15–17 | `APPLE_AUTH_STARTED` → SRP s2k → `APPLE_SESSION_READY` → `PERSONAL_TEAM_FOUND` |
| 20:55:18 | `MANAGED_IDENTITY_METADATA_MISSING` → `KEYPAIR_CREATED` → `CSR_CREATED` |
| 20:55:19 | `DEVELOPMENT_CERTIFICATE_CREATED`, `certificatePublicKeyMatchesPrivateKey: true` |
| 20:55:19 | `DEVICE_REGISTRATION_REQUIRED` → `DEVICE_REGISTERED` → `PROVISIONING_DEVICE_READY` |
| 20:55:20–22 | `MAIN_ID_READY`, `UITEST_ID_READY`, `RUNNER_ID_READY`, both profiles, `PROVISIONING_READY` |
| 20:55:40 → 20:55:54 | gen 2 `PRIVATE_KEY_LOOKUP_STARTED` → `PRIVATE_KEY_FOUND` — **14 s gap = SecurityAgent dialog** |
| 20:56:15 → 20:56:21 | gen 3, same path — **6 s gap = second dialog** |
| 20:56:22 | `PROVISIONING_READY`, reported with no key-usability proof |
| 20:56:25 → 20:56:34 | `installing` → `SIGNING_KEY_ACCESS_DENIED` — **9 s gap = third dialog, denied** |

The key, the CSR, the Apple certificate and their association were all correct.
Only *use* of the key was denied.

State persisted at the end of Build 1, and still present on the Mac:
`certificateFingerprint`, `certificateSerial`, `certificateExpiration`,
`keyApplicationTag` (canonical), `generatedByIOSSim: true`.
**Ownership proof for the Build-1 certificate survives.**

## 3. Build 2 timeline — INFERRED_FROM_SOURCE

`IOSSim-Support-1789611416.zip` is not present in this workspace. The sequence below
is reconstructed from current source and is labelled inferred until that bundle is
archived under `evidence/`.

1. Auth → team discovery → `SIGNING_IDENTITY_LOOKUP_STARTED` — unchanged from Build 1.
2. `ios/listAllDevelopmentCerts` returns the team certificates and
   `availableQuantity: 0`.
3. `MANAGED_IDENTITY_METADATA_FOUND`. Build 1's metadata **is** still readable:
   `IOSSimIdentityMetadataStore.load()` (`ApplePersonalTeamLive.swift:968-984`) is
   *not* scoped to the Veya keychain. Only key lookups are.
4. `PRIVATE_KEY_LOOKUP_STARTED`. `lookupPrivateKey` **is** scoped
   (`scopedToSigningKeychain`, L953-958), so Build 1's login-Keychain key is
   deliberately invisible → `errSecItemNotFound`.
5. `PRIVATE_KEY_MISSING` → `MANAGED_IDENTITY_STALE`.
6. `guard availableQuantity != 0 else { throw .certificateLimit }` — **L1446** — throws.
7. `SetupStore.experimentalProvisioningError` (L1051-1073) renders
   `CERTIFICATE_LIMIT_REACHED` beneath "Apple authorization succeeded, but Veya
   couldn't prepare Personal Team provisioning."

Device registration, App IDs and profiles are never attempted in this run.

## 4. Exact Build 2 failure

`macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift:1446`.

This is not a bug in the Defect 001 fix. The fix behaves exactly as designed —
it refuses to resurrect a key `/usr/bin/codesign` can never use. The gap is that
the *same metadata record* that proved the identity stale also names the certificate
occupying the slot, and nothing consumes that fact.

Two sibling guards at L1412 and L1436 have the identical gap.

## 5. Regression vs missing recovery

| functionality | classification |
|---|---|
| Apple authorization, session, team discovery | **not regressed** — works, proven in both builds |
| Device registration, App IDs, profile issuance | **not regressed** — not reached in Build 2 |
| Login-Keychain signing key | **intentionally changed** by `dd259bd`; correct |
| Rejecting an unusable identity | **intentionally added** by `dd259bd`; correct |
| Recovery from Veya's own obsolete certificate | **missing — this defect** |
| Certificate-limit handling | **missing** — terminal throw, no reclaim |

Pre-existing Apple account state contributed (the team already held two
certificates), but the product defect is Veya's, not Apple's.

## 6. Apple certificate lifecycle findings

Established from the preserved research, which vendors the upstream `isideload`
crate — the library the research identified as compiled into `VanishSideloader`
(`VanishedResearch.mSgdHk/FINAL_PREIMPLEMENTATION/references/isideload/`). No live
Apple call was made to obtain any of this.

- The limit is Apple developer error **`7460`**, "Maximum number of certificates
  reached". Veya today detects the limit only by `"maximum"`/`"limit"` substring
  match plus the `availableQuantity` precheck; `7460` appears nowhere in this repo.
- Certificates are enumerable: `ios/listAllDevelopmentCerts` returns the certificate
  list plus a team-wide `availableQuantity`, and per-certificate `machineName` and
  `machineId`.
- Revocation is `ios/revokeDevelopmentCert` keyed on **serial number** — which Veya
  already persists (`cert_identity.rs:319-351`, `revoke_development_cert(team, &serial, None)`).
- Apple refuses issuance while the quota is full, so **revocation must precede
  candidate creation**. Upstream wraps the CSR in a bounded retry (4 attempts) around
  revocation for exactly this reason.
- The Personal Team development-certificate limit is 2.
- `ios/downloadTeamProvisioningProfile` returns a profile embedding the team's
  certificates, so **profiles must be re-downloaded** after any revoke-and-reissue.

Unmeasured: revocation propagation delay, and whether revocation affects apps already
installed on a phone from the same Personal Team.

## 7. Current Veya ownership model

`IOSSimIdentityMetadata` (`ApplePersonalTeamLive.swift:871-879`) persists
`teamIdentifier`, `certificateFingerprint`, `certificateSerial`,
`certificateExpiration`, `keyApplicationTag`, `createdAt`, `generatedByIOSSim`, as a
generic-password item under service `com.iossim.mac.personal-team-signing`, account =
team ID; candidates under `<TEAM>.candidate`.

**Veya can prove it owns the Build-1 certificate on this Intel Mac.** Serial and
fingerprint are recorded, `generatedByIOSSim` is true, the key tag is canonical, and
the record is readable by Build 2 because metadata lookups are unscoped.

What is missing:

- `machineId` is `UUID().uuidString` regenerated per request (**L1496**) — a
  discarded ownership marker that is never persisted.
- `machineName` is the constant `"IOSSim"` (**L1497**) — cannot distinguish
  installations, so two Macs produce identically-named certificates.
- Apple's `certRequestId` is read for validation (L1503) then discarded.
- No per-installation identifier exists anywhere.
- No record of *superseded* Veya certificates that still occupy slots.

Documentation gaps found:

- `23_RESOURCE_OWNERSHIP_MODEL.md` scopes certificate ownership to "team/key" and
  validates by "exact key match" — which fails the moment the key is out of scope.
- `24_KEYCHAIN_AND_CREDENTIAL_MODEL.md` still documents the **login Keychain** as
  current implementation, `CONFIRMED_LOCAL_IOSSIM_CODE`. Stale since `dd259bd`.
- `20_REPAIR_AND_RESUME_SPEC.md` has **no row** for certificate limit, stale
  certificate, or unusable signing key.
- `19_SETUP_STATE_MACHINE.md` says "limits do not auto-delete" with no specified exit.
- `21_ERROR_TAXONOMY.md` `VEYA-APPLE-020` (certificate limit) is a dead end.

## 8. Vanish findings

Separated strictly. See `BUILD1_BUILD2_VANISH_SIGNING_COMPARISON.md` for the full
responsibility table.

**OBSERVED**

- A distinct `max_certs_response` command flows from the Electron UI **back into** the
  Rust helper (`vanish-reference/05_VANISH_APPLE_PROVISIONING_ANALYSIS.md:3`;
  `VanishedResearch.mSgdHk/EVIDENCE.md:17` E09). A response command is only required
  for a *prompt*; a fixed revoke-or-error policy needs no round-trip.
- `REPORT.md:225` — "Certificate limit | Explicit max_certs event and user response |
  CONFIRMED control path; selection/revocation results UNKNOWN".
- Certificates are otherwise entirely hidden from the user
  (`DOCUMENTATION/06_UX_AUTOMATION_AND_RECOVERY.md:57`).
- The Vanish binary imports Keychain **generic-password** functions
  (`EVIDENCE.md:15` E07) — not SecIdentity/ACL APIs.
- Vanish does **not** avoid the seven-day lifecycle; it re-signs
  (`DOCUMENTATION/03_APPLE_AUTH_PROVISIONING_SIGNING.md:11`, `DISPROVEN`).

**INFERRED** — from vendored upstream `isideload`, not from Vanish's binary. The
research explicitly notes the vendored checkouts are *different commits* than the
`3c1a008` found in Vanish, and that "binary provenance may still include downstream
modifications" (`REPORT.md:144`).

- Key persistence is a PKCS#8 DER blob stored as a keychain *password* string keyed
  by `sha256(apple_email)`, and signing is **in-process** via `apple-codesign` — no
  `/usr/bin/codesign`, no `SecIdentity`, no ACL, no partition list. This is why Vanish
  structurally cannot experience Defect 001.
- Certificate reuse is gated on the local private key matching the certificate public
  key, so an Xcode certificate or another Mac's certificate is never reused.
- One certificate per (Apple ID × machine_name × local key) — not per install.

**UNKNOWN / NOT ESTABLISHED**

- Whether Vanish binds `MaxCertsBehavior::Prompt`, `::Revoke` or `::Error`.
- Which certificate Vanish selects, and whether its revocation succeeds.
- Vanish's actual `machine_name` value.
- Whether Vanish keeps any local certificate ownership ledger.
- **Multi-Mac / same-Apple-ID behaviour — no evidence of any kind.**
- Actual certificate count, reuse policy, key export policy.

The research's own standing guidance is that revocation or destructive replacement
needs explicit choice (`REPORT.md:697`, `:768`). The design below therefore permits
silent revocation *only* under deterministic ownership proof, and forbids it in every
other case.

## 9. Recommended architecture

Keep Build 2's Veya-owned Keychain and the `/usr/bin/codesign` path **unchanged**.
Add a certificate ownership ledger and a bounded, fail-safe capacity-reclaim
transaction.

In-process signing — Vanish's approach — is recorded as a **documented future
option**, not Build 3 scope. It would eliminate Defect 001 at the root and make keys
portable across Macs, but it rewrites signing, install and renewal simultaneously and
would delay physical validation of a lifecycle that is otherwise ready. Evaluate
separately, as its own physically-validated change.

### Ownership ladder

Every certificate returned by `ios/listAllDevelopmentCerts` is classified:

| level | evidence | revocable |
|---|---|---|
| **P1 OWNED_LOCAL_RECORD** | persisted `certificateSerial` or `certificateFingerprint` matches, and the record has `generatedByIOSSim == true` and a canonical key tag | **yes** |
| **P2 OWNED_REMOTE_MARKER** | certificate's `machineId` equals this installation's persisted `installationIdentifier` | **yes** |
| **P3 ACTIVE_USABLE** | a private key is held whose public key matches, and it passes the codesign probe | **never** |
| **P4 VEYA_OTHER_INSTALL** | `machineName` carries the Veya prefix but a different installation id | **never** |
| **P5 UNKNOWN** | anything else — Xcode, another tool, another account | **never** |

Team ID alone, certificate name alone, "Apple Development", creation date alone, and
"newest certificate" are explicitly **not** ownership evidence and appear nowhere in
the ladder.

The Intel Mac's Build-1 certificate classifies **P1**.

### Safety invariants

1. Revoke only P1 or P2.
2. **Never** revoke a certificate whose private key is present and passes the codesign
   probe — re-checked immediately before the revoke call.
3. Revoke at most **one** certificate per provisioning attempt.
4. Revoke only when `availableQuantity == 0` is actually blocking progress.
5. If no P1/P2 certificate exists, **fail safe** — never widen the search.
6. Never read, modify or delete anything in the login Keychain.

Each invariant gets a dedicated test (§12).

## 10. Certificate-limit recovery algorithm

```
prepareIdentity(team):
  certs, availableQuantity  <- ios/listAllDevelopmentCerts
  owned                     <- active metadata ?? candidate metadata

  if identity usable (key found, ACL ok, cert matches, codesign probe passes):
      reuse -> done                                   # unchanged

  # identity is stale
  if availableQuantity != 0:
      createManagedIdentity(recovering: true)         # unchanged
  else:
      CERTIFICATE_CAPACITY_RECOVERY:
        record CERTIFICATE_CAPACITY_EXHAUSTED
        ladder      <- classify(certs)
        reclaimable <- ladder where level in {P1, P2}
        if reclaimable is empty:
            record CERTIFICATE_RECLAIM_UNAVAILABLE
            throw .certificateLimit                   # fail safe
        victim <- oldest(reclaimable) by expiration, tie-broken by serial
        assert victim is not P3                       # invariant 2
        record CERTIFICATE_OWNERSHIP_PROVEN
        record CERTIFICATE_RECLAIM_STARTED
        ios/revokeDevelopmentCert(teamId, serialNumber: victim.serial)
        record CERTIFICATE_REVOKED
        re-list up to 3x with backoff until availableQuantity > 0
        record CERTIFICATE_CAPACITY_RESTORED
        append victim to retiredCertificates
        createManagedIdentity(recovering: true)
```

The existing path then continues unchanged: device → App IDs → **profiles
re-downloaded** → `verifySigningKeyUsable` → promote candidate.

**Unavoidable Apple constraint.** Apple will not issue into a full quota, so
revocation must precede candidate creation and cannot be rolled back. This is made
safe by invariant 2: Veya only ever revokes a certificate it has *already proven it
cannot sign with*. Nothing usable is at risk inside the window. This is an explicit,
deliberate weakening of the normal "candidate first, promote after proof" shape, and
it is confined to this one transition.

## 11. Case matrix

| case | behaviour |
|---|---|
| A fresh user, capacity available | unchanged — key, CSR, certificate |
| B existing valid Veya identity | unchanged — reuse, probe, done |
| C stale identity, capacity available | unchanged — fresh candidate |
| D stale identity, no capacity, P1/P2 certificate exists | **new** — reclaim one, reissue. *This is the Intel Mac.* |
| E capacity exhausted by unknown certificates only | fail safe; message names what Veya can and cannot act on |
| F candidate created, crash before promotion | candidate record found next run; key matches certificate → promoted after probe |
| G certificate created, profile creation fails | candidate retained; retry re-downloads profiles; no revoke — capacity is non-zero |
| H certificate created, codesign probe fails | candidate marked stale; next run classifies its certificate P1 and can reclaim it |
| I seven-day renewal | profiles re-downloaded; certificate untouched unless expired or revoked |
| J Veya upgrade | metadata schema v1 → v2 migration, additive, no reissue |
| K multiple Macs, same Apple ID | each Mac holds its own certificate; the other Mac's is P4/P5 → never revoked. A third Mac fails safe naming the 2-certificate limit |
| L Xcode or another tool on the same team | its certificates are P5 → never revoked |

## 12. Multi-Mac model

A second Mac's certificate is **P4 or P5 from here**, because its serial was never
written into *this* Mac's metadata. Multi-Mac safety therefore holds by construction,
including for legacy Build-1 certificates that predate any installation identifier.

Adding `installationIdentifier` (persisted, sent as Apple `machineId`, echoed into
`machineName`) upgrades this from "safe by accident" to "safe by evidence": a Build 3+
certificate from another Mac is positively identifiable as P4 rather than falling
through to P5.

One certificate cannot be shared between Macs without exporting the private key, which
Build 2's architecture deliberately prevents. Each Mac therefore requires its own
certificate, and the Personal Team limit of 2 caps supported Macs at two. A third Mac
fails safe with a message naming that limit — it does not revoke to make room.

Automatic revocation on one Mac can never break another Veya installation under this
ladder, because no cross-Mac certificate can reach P1 or P2.

## 13. Profile regeneration consequences

Revoking or replacing a certificate invalidates every profile embedding it.

- `prepareProvisioning` already re-runs `obtainProfiles` after `prepareIdentity`, so
  the fresh path is correct as written.
- **Must fix:** the cached-artifact fast path in
  `SetupStore.runLiveProvisioningThroughProfiles` (L515-533) can reuse
  `NativeProvisioningArtifacts` whose `certificateFingerprint` no longer matches the
  active identity. Add an explicit fingerprint equality check and force a full
  re-prepare on mismatch.
- Main and runner profiles must both be regenerated after a reclaim. Witness profile:
  not applicable — `obtainProfiles` issues exactly main and runner.
- An installed main app or runner signed with a revoked certificate stops launching
  once the device revalidates. Nothing is installed on the Intel Mac, so migration is
  unaffected; cases I and J require reinstall after a reclaim.
- Device registration, App IDs and pairing records are **not** invalidated.

## 14. Transaction and rollback semantics

| step | rollback |
|---|---|
| classify certificates | read-only |
| prove ownership | read-only |
| **revoke** | **irreversible** — bounded by invariant 2 |
| create key + CSR + certificate | candidate; discardable |
| regenerate profiles | candidate; discardable |
| codesign probe | read-only |
| promote candidate | atomic, after proof |

Nothing usable is destroyed at any step. The active identity is retired only after a
replacement proves it can sign.

## 15. Security model

Revocation is destructive, account-visible and irreversible. It is gated on the
ownership ladder and the six invariants, and fail-safe is the default at every branch.
Serial numbers and fingerprints are non-secret and already redacted in support
bundles; no new secret is persisted. `installationIdentifier` is a random UUID with no
device or user linkage, transmitted in the `machineId` field the protocol already
carries. Residual risk is unchanged from Defect 001: the Veya Keychain password sits
in a 0600 file in the user's home directory.

## 16. Keychain relationship — why both must hold at once

- **Build 1 prompted** because `securityd` stamps login-Keychain keys with
  `Partitions = [cdhash:<creator>]`, and the partition check is independent of the
  trusted-application ACL. Control V6 in `repro/EVIDENCE_MATRIX.md` settles it: an ACL
  trusting *every* application on the Mac still prompted.
- **Build 2 eliminates the prompt** by creating keys in a Veya-owned Keychain, which
  receives no partition ACL at all, so the trusted-application ACL governs (V7: signed,
  no prompt).
- **Build 2's certificate-limit error is a different failure** — Apple-side quota, not
  local key access. It occurs *before* any key is used.
- **Certificate recovery cannot reintroduce Defect 001** because it touches only
  Apple-side state over Developer Services. It reads no Keychain password, performs no
  `SecKeychainItemSetAccess` on login-Keychain items, and never widens the trusted
  application list.

## 17. Consumer UX

Happy path and case D are fully silent — the consumer never learns a certificate
exists. Only case E surfaces anything.

The current case-E text must be rewritten. "Remove an unused Apple Development
certificate from your Personal Team, then try again" asks a consumer to understand
Developer Portal certificate management, which violates the product invariant. The
replacement states that Veya found no certificate it can safely replace, names how
many slots the Personal Team has, and offers a support-bundle action — with no
instruction to operate the Developer Portal.

## 18. File-level implementation plan

**`macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamLive.swift`** — primary

- `IOSSimIdentityMetadata` (L871-879) → schema v2. All new fields `Optional` so
  existing Build-1/Build-2 records decode unchanged: `schemaVersion`,
  `installationIdentifier`, `certificateRequestIdentifier`, `publicKeyFingerprint`,
  `retiredCertificates`.
- New `CertificateOwnership` enum and `classifyCertificates(_:metadata:)`, built on the
  existing `rememberedCertificate` (L2092-2105), `certificateFingerprint` (L2164) and
  `matchingCertificate` (L2123) helpers. Do not write new matching logic.
- New `revokeDevelopmentCertificate(serial:team:)` over the existing `developerRequest`
  plumbing, operation `ios/revokeDevelopmentCert`.
- New `reclaimCertificateCapacity(...)` implementing §10, called from the three
  `availableQuantity != 0` guards at **L1412, L1436, L1446** in place of the throw.
- L1496-1497: `machineId` → persisted `installationIdentifier`, not a fresh UUID;
  `machineName` → `"Veya (<short install id>)"`.
- Capture Apple's `certRequestId` in `MatchedDevelopmentCertificate` (L2085-2091) and
  persist it in `finishManagedIdentity` (L1606-1614).
- L3200-3224: explicit `resultCode == 7460` detection alongside the substring match.
- `IOSSimIdentityMetadataStore`: persist the installation identifier; add
  `recordRetiredCertificate`.

**`macos/Sources/IOSSimMacCore/Services/ApplePersonalTeamExperimental.swift`**

- New checkpoints in the L503-553 enum: `CERTIFICATE_CAPACITY_EXHAUSTED`,
  `CERTIFICATE_OWNERSHIP_PROVEN`, `CERTIFICATE_RECLAIM_STARTED`, `CERTIFICATE_REVOKED`,
  `CERTIFICATE_RECLAIM_UNAVAILABLE`, `CERTIFICATE_CAPACITY_RESTORED`.
- Protocol addition for the reclaim entry point; mirror in `ExperimentalBackendMock`.

**`macos/Sources/IOSSimMacCore/SetupStore.swift`**

- `experimentalProvisioningError` (L1051-1073): rewrite `.certificateLimit` recovery
  text per §17.
- `runLiveProvisioningThroughProfiles` (L515-533): certificate-fingerprint equality
  check before reusing cached artifacts.

**`macos/Sources/IOSSimMacCore/Services/NativeProvisioningArtifactStore.swift`**

- Bind artifacts to the identity generation so a reclaim invalidates them.

**`macos/Sources/IOSSimMacCore/Services/MacAssistedRenewal.swift`**

- `.recreateCertificate` (L51) routes through the reclaim path rather than assuming
  capacity.

**`macos/Sources/IOSSimMacCore/Services/VeyaDiagnostics.swift`**

- Descriptor for `VEYA-APPLE-020` carrying the reclaim outcome.

**Documentation corrections**

- `23_RESOURCE_OWNERSHIP_MODEL.md` — add the certificate ownership ladder.
- `24_KEYCHAIN_AND_CREDENTIAL_MODEL.md` — replace the login-Keychain "current
  implementation" section, stale since `dd259bd`.
- `20_REPAIR_AND_RESUME_SPEC.md` — add rows for unusable signing key, stale
  certificate, certificate limit.
- `21_ERROR_TAXONOMY.md` — give `VEYA-APPLE-020` a specified exit.
- `19_SETUP_STATE_MACHINE.md` — add key-store change → certificate invalidation edge.

## 19. Test plan

**Narrow, do not delete**: `ApplePersonalTeamExperimentalTests.swift:160-175`
`testCertificateLimitAndMissingPrivateKeyAreNotRecoveredByRevokingOthers` encodes a
real safety invariant. Rename to `…ByRevokingUnownedCertificates` and keep its
`XCTAssertFalse(events.contains("revoke"))` assertion for the unproven-ownership case.

New unit tests, deterministic and fixture-backed:

1. P1 proof present + `availableQuantity == 0` → exactly one revoke, of exactly the
   recorded serial, then reissue.
2. Only P5 certificates → zero revokes, `.certificateLimit` thrown.
3. P4 (Veya, different installation id) → zero revokes, fail safe.
4. Invariant 2 — a certificate with a usable private key is never selected, even at P1.
5. Exactly one revoke per attempt, never two.
6. Revoke precedes CSR submission — ordering assertion.
7. Post-revoke re-list retry/backoff terminates and does not storm.
8. Schema v1 metadata with no installation id decodes and still classifies P1.
9. `machineId` is stable across two CSR submissions from one installation.
10. Cached artifacts with a mismatched certificate fingerprint force a full re-prepare.
11. Profiles are re-downloaded after a reclaim.
12. Crash-before-promotion (case F) leaves a promotable candidate.

Regression: the six `VeyaSigningKeychainRegressionTests` must pass unchanged. Defect
001 is not re-opened by this work.

## 20. New physical-test scenarios

- **PT-002-D** — the Intel Mac, Build 1 + Build 2 state intact. The acceptance run.
- **PT-002-E** — an account whose slots are filled by non-Veya certificates. Expect
  fail safe and the rewritten message. Requires a second account; may be deferred.
- **PT-002-K** — a second Mac on the same Apple Account. Expect its own certificate,
  and expect the first Mac's certificate untouched.
- **PT-002-I** — seven-day renewal after a reclaim, verifying profile regeneration.

## 21. Build 3 acceptance gates

Software gates are necessary and never sufficient: full Swift suite green with no new
skips; the six signing regressions unchanged; all twelve new tests passing;
`IOSSIM_RUN_KEYCHAIN_INTEGRATION=1` qualification `veya` → exit 0 and `login` → exit 3;
mounted-DMG audit PASS.

Physical, on the **same Intel Mac, with Build 1 and Build 2 state left intact**:

1. Veya launches; **zero Keychain-password dialogs** at any point.
2. Existing state inspected; `MANAGED_IDENTITY_STALE` recorded.
3. `CERTIFICATE_CAPACITY_EXHAUSTED` → `CERTIFICATE_OWNERSHIP_PROVEN` →
   `CERTIFICATE_RECLAIM_STARTED` → `CERTIFICATE_REVOKED` →
   `CERTIFICATE_CAPACITY_RESTORED`.
4. Exactly one certificate revoked, and its serial equals the Build-1 serial recorded
   in `evidence/IOSSim-Support-1789592208.zip`. No other certificate altered.
5. New keypair, CSR and certificate issued; `SIGNING_KEY_USABILITY_VERIFIED`.
6. Main and runner profiles regenerated and valid.
7. `PROVISIONING_READY`, then payload signing **succeeds** — past the point where both
   Build 1 and Build 2 failed.
8. Support bundle captured and archived under `evidence/`.

Only then does defect 002 move to `PHYSICALLY_VERIFIED`, and only then does physical
validation continue to DDI, TSS, developer-support mount, RemotePairing, LocalDevVPN,
software tunnel, RSD, RemoteXPC, AppService, XCTest/TestManager, Rich XCUILocation,
Spoof and Drive — none of which this work touches.

## 22. Risks and open questions

- **Revocation is irreversible and account-visible.** Mitigated by invariant 2, but it
  remains the highest-risk operation Veya performs.
- **`ios/revokeDevelopmentCert` is not exercised anywhere in Veya today.** Its exact
  parameter shape comes from upstream `isideload`; the first physical run is also the
  first real call. Parameter-shape failure is the most likely Build 3 surprise.
- **Revocation propagation delay is unmeasured.** The 3× backoff re-list is an
  estimate; the physical run must record actual timing.
- **Whether revoking a Personal Team certificate affects other installed apps** is not
  established by any local evidence. No app is installed on the test iPhone, so Build 3
  will not answer it either.
- **Vanish's actual `MaxCertsBehavior` binding is unknown.** This design deliberately
  diverges toward silent recovery under proven ownership.
- **Build 2's support bundle is missing.** Retrieving `IOSSim-Support-1789611416.zip`
  upgrades §3 from inferred to observed.
- **`dd259bd` is a 425-file mixed commit** — a repo reorg, the full `docs/installation-v2`
  set, three self-contained app trees and several large subsystems, alongside the
  11-file signing fix. Build 2's behaviour is therefore not attributable to the signing
  fix alone. Keep Build 3 narrow and reviewable by contrast.

## 23. Implementation readiness

**READY_TO_IMPLEMENT**

## 24. Next session scope

Implement §18 and §19 only. Do not build or ship a Build 3 artifact, do not revoke any
certificate, do not mutate the Apple Account, and do not modify DDI, TSS,
RemotePairing, LocalDevVPN, RSD, RemoteXPC, AppService, XCTest, XCUILocation, Spoof or
Drive.
