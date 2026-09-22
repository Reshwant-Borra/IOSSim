# M4 Resolution Pass — Signing-Key Persistence Under Veya's Distribution Model

Status: **ROOT CAUSE PROVEN / ARCHITECTURE CONFIRMED / FINAL PROOF BLOCKED_HUMAN (signing assets)**.
M4 is **not PASS**. Veya is **not production-ready** while this remains open. Build stays `11`.

## 1. What causes OSStatus -34018 (proven, 2026-09-21)

Controlled matrix (`repro/m4-entitlement-matrix/run.sh`, log `evidence/m4-entitlement-matrix.log`). Every case
is a real `.app` launched through LaunchServices, runs create/read/delete against the Data Protection
Keychain, and records the embedded entitlements, AMFI/securityd log lines, and SecurityAgent state.

| Case | Signature | Entitlements (as embedded) | Outcome |
|---|---|---|---|
| A | Apple Development, team `T8SL4SG87F`, hardened | none | create/delete `-34018`; read `-25300` |
| B | same team | `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups` — **no provisioning profile** | **process never runs**: `amfid: Restricted entitlements not validated, bailing out … Code=-413 "No matching profile found"` |
| C | ad-hoc | same restricted set | **process never runs**: `amfid: Adhoc signed app with restricted entitlements detected … Code=-427` |
| D | same team | `com.apple.security.app-sandbox` | `-34018` |
| E | same team | sandbox + `com.apple.security.application-groups` | `-34018` |

SecurityAgent: absent before, during, and after every case.

**Causal chain:**
1. The Data Protection Keychain on macOS needs the caller to belong to a keychain access group, which comes only from `keychain-access-groups` / `com.apple.application-identifier` (A, D, E: team signing, the sandbox, and app groups are all insufficient, giving `-34018`).
2. Those are **restricted entitlements**. AMFI launches a process carrying them only when an embedded provisioning profile from the same team authorizes them (B). Ad-hoc code can never carry them (C).
3. So every profile-less artifact (all ad-hoc/LOCAL_TEST builds, including Builds 1-11) gets `-34018`. Veya's Keychain parameters are not the cause, and no API change can make it succeed. **Faking entitlements is impossible**: AMFI refuses to launch.

## 2. Is the Data Protection Keychain suitable? — Yes (not the fallback case)

The same mechanism supplies the security properties M4 needs:
- **Isolation (criterion 4):** code without a profile from Veya's team cannot run while claiming Veya's access group (B, C), and code without the group cannot reach the item (A, D, E). Same-team apps with a different App ID have a different access group, so the DP Keychain does not return Veya's item. That negative case is wired into the gate (`VEYA_M4_UNRELATED_PROFILE`).
- **No UI (criterion 5):** the DP Keychain never raises the legacy ACL/partition SecurityAgent dialog. Veya additionally uses `LAContext.interactionNotAllowed`.
- **Upgrade (criterion 3):** access follows team + access group, not cdhash. A re-signed upgrade with the same team, App ID, and profile-authorized group keeps access. This is the property the login Keychain failed (creator-cdhash partition).

So the fallback rule (produce a replacement architecture) is **not triggered**. The architecture stands:
encrypted PKCS#8 file + 32-byte wrapping secret in the DP Keychain + in-memory unwrap into the in-process
signer.

## 3. Required production configuration (exact)

| Item | Requirement |
|---|---|
| Certificate | **Developer ID Application** (public distribution; paid Apple Developer Program team). Local qualification may use Apple Development + a Mac Development profile that includes the test Mac. |
| App ID | Explicit macOS App ID `<TEAM>.<Veya bundle ID>` with the **Keychain Sharing** capability |
| Provisioning profile | Developer ID (or Mac Development) profile for that App ID, embedded as `Contents/embedded.provisionprofile` of the bundle whose main executable touches the Keychain |
| Entitlements | `com.apple.application-identifier = <TEAM>.<bundle>`, `com.apple.developer.team-identifier = <TEAM>`, `keychain-access-groups = [<TEAM>.<bundle>]` (first group = default group; must stay identical across releases) |
| Keychain API | `kSecUseDataProtectionKeychain = true`, `kSecAttrSynchronizable = false`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `LAContext.interactionNotAllowed = true`. This is the current `KeychainWrappingSecretStore`; no change is needed. |
| Hardened runtime + notarization | Required for Developer ID distribution; orthogonal to Keychain access |

**Packaging consequence (must be proven with the profile):** AMFI authorizes restricted entitlements per
code bundle with an embedded profile. Today the Keychain-accessing code is `IOSSimProvisioner`, a bare
executable in `Contents/MacOS` of `Veya.app`. It must either be the main executable of a bundle carrying the
profile, or be wrapped as its own app-like bundle (for example `Contents/Helpers/VeyaProvisioner.app` with
its own `embedded.provisionprofile` and the same access group). The gate test already runs the helper as
the main executable of a profile-carrying bundle, which is the configuration to adopt.

## 4. Development environment limits (why the final proof is not here)

This Mac has only Apple Development identities (team `T8SL4SG87F`), **no provisioning profiles**
(`~/Library/MobileDevice/Provisioning Profiles` and the Xcode profile directory are empty), and no
Developer ID identity. A profile cannot be produced without an Apple Developer portal/account action.
Producing one is a human action, and it may need a paid membership for Developer ID.

## 5. The proof, ready to run

`SigningKeyStoreTests.testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction` is the M4 gate. It
uses the **real** production key-store path (`WrappingSecretBackendKind.forRunningCode()` → DP Keychain)
in the real packaged helper, launched through LaunchServices: create → reopen (new process) → upgrade
(Build "12", distinct cdhash) verify → steady-state reuse with 0 transitions → SecurityAgent unchanged →
optional unrelated-App-ID negative. With no signing assets it runs ad-hoc and fails closed (`VEYA-KEY-001`,
no prompt), as observed today.

```sh
VEYA_M4_SIGN_IDENTITY="<SHA-1 of Developer ID Application or Apple Development identity>" \
VEYA_M4_PROFILE="/path/Veya.provisionprofile" \
VEYA_M4_UNRELATED_PROFILE="/path/OtherAppID.provisionprofile" \
swift test --package-path macos --filter SigningKeyStoreTests/testPackagedHelperCreateReopenAndUpgradeWithoutUserInteraction
```

Profile requirements: an explicit (non-wildcard) macOS App ID with Keychain Sharing. For Mac Development, the
profile must include this Mac's provisioning UDID. The unrelated profile is a second App ID in the same team.

## 6. M4 criteria status

| # | Criterion | Status |
|---|---|---|
| 1 | Never plaintext at rest | UNIT_PROVEN (AES-256-GCM envelope, plaintext scan test); the wrapping secret is only in the Keychain |
| 2 | Recover after restart | UNIT_PROVEN in process; packaged proof BLOCKED_HUMAN (profile) |
| 3 | Recover after legitimate upgrade | BLOCKED_HUMAN (profile); mechanism established (§2) |
| 4 | Unrelated apps cannot retrieve | LOCAL_SYSTEM_PROVEN for unentitled/ad-hoc/profile-less code (A-E); same-team different-group case BLOCKED_HUMAN |
| 5 | No unexpected prompts | LOCAL_SYSTEM_PROVEN for every case run (no SecurityAgent); final packaged proof BLOCKED_HUMAN |
| 6 | Failure fails closed | LOCAL_SYSTEM_PROVEN: backend `unavailable` → `VEYA-KEY-001` with no Keychain call; corrupt/missing/tampered states typed (10 unit tests) |
| 7 | Plaintext memory-scoped and cleared | UNIT_PROVEN, best effort (closure-scoped `Data`, cleared in place; Rust `Zeroizing`; core dumps disabled in the signing FFI scope) |
| 8 | Works under the intended distribution model | BLOCKED_HUMAN: needs a Developer ID profile-signed artifact |

## 7. Smallest human action

Provide, for the Veya team: (a) a signing identity in this Mac's login keychain (Developer ID Application
preferred; Apple Development acceptable for the local proof), and (b) a macOS provisioning profile for an
explicit Veya App ID with Keychain Sharing (plus, optionally, a second App ID's profile for the isolation
negative). Then reply with the two paths and the identity hash. The test command in §5 runs the proof.
