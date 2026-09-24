# Persistence, Identity Scoping and Evidence (checkpoint `8155901`)

This is the map of persisted state that the `VEYA-TEAM-032` investigation has to start from.
**Nothing here was changed.** Observations are marked as observations. Anything relevant to
multi-account behavior is flagged **[TEAM-032]**.

## State roots

| Build | Root | Chosen by |
|---|---|---|
| Development session (the physically validated artifact) | `~/Library/Application Support/Veya/development-session/` | `DevelopmentInstallationSession.init` (`DevelopmentInstallationSession.swift:33`) |
| Packaged/consumer composition | `~/Library/Application Support/Veya/` (journal in `installation/`) | `InstallationJournalRepository.defaultRootURL()` (`InstallationJournalRepository.swift:24`) |
| Legacy IOSSim (read-only migration input) | `~/Library/Application Support/IOSSim/…`, `~/Library/Application Support/IOSSimMac/…` | `LocalLegacyInventoryReader` |

**There is exactly one journal per state root, identified by `installationID` (UUID).** The journal
has no Apple Account, Team ID or device key at its top level.

## Persistence / scoping matrix

Legend: ✔ = part of the record's key or identity; (m) = stored as metadata only (not a key);
— = not scoped by this.

| Record | Location | Installation | Device UDID | Connection gen. | Apple Account | Team ID | Certificate | Signing key | Profile | App / bundle | Lifetime / invalidation |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Journal envelope | `installation/journal-v1.json` (+ `.previous.json`, `.lock`) | ✔ `installationID` | — | — | — | — | — | — | — | — | Permanent; revision/generation monotonic |
| `active/candidates/retiring["signingKey"]` | journal | ✔ | — | — | — | — | — | ✔ keyID + SPKI | — | — | Retiring kept **forever** |
| Encrypted signing key | `secrets/signing-keys/<keyID>.vkey` (0600) | ✔ (AAD binds installationID) | — | — | — | — | — | ✔ | — | — | Replaced when invalid. `VeyaSigningKeyStore.retire(keyID:)` exists but has **no production caller**, so key files accumulate (24 on disk at the checkpoint) |
| Wrapping secret | Keychain generic password, account = `installationID` (prod); **process memory** (dev session) | ✔ | — | — | — | — | — | — | — | — | Dev: **lost on relaunch** → every key becomes `invalid` → new key |
| `active["certificate"]` | journal; DER at `certificates/<derSHA>.cer` | ✔ | — | — | **—** | (m) `teamIdentifier` | ✔ serial + DER digest | (m) `spkiSHA256` | — | — | `stale` when the SPKI ≠ signing key SPKI or < 72 h left; proof valid ≤ 24 h |
| `active["profile"]` | journal; `profiles/<gen>/{main,runner}.mobileprovision` | ✔ | (m) `device = sha256("device|udid")` | — | **—** | (m) `teamIdentifier` | (m) `certificate` digest | — | ✔ digest of bundle=sha | (m) `bundle.main/runner` | `stale` on a different certificate or device, or < 48 h left |
| `active["payload"]` | journal; `staging/<gen>/<App>.app` | ✔ | — | — | — | (m) `teamIdentifier` | via `binding` | via `binding` (keyID) | via `binding` | ✔ main bundle id | `stale` when `binding` changes |
| `active["application"]` | journal | ✔ | implicit (the selected device at proof time) | evidence ✔ | — | (m) | — | — | — | ✔ | `stale` when the payload digest changes; `invalid` if the device lost it |
| `active["developerSupport"]`, `["vpn"]`, `["pairing"]` | journal | ✔ | ✔ (`selectedDeviceIDHash` in digest) | ✔ (in digest) | — | via application identity | — | — | — | ✔ via `application=` in digest | Any reconnect or reinstall → `stale` |
| `active["runtime"]` | journal | ✔ | ✔ | ✔ | — | via upstream | — | — | — | via upstream | 600 s TTL; any upstream change → `stale` |
| `active["migration"]`, `migration` ledger | journal | ✔ | — | — | — | — | — | — | — | — | One-time inventory |
| Evidence list | journal `evidence[]` | ✔ | via subject | ✔ for connection-bound kinds | — | — | via subject | via subject | via subject | via subject | Pruned when no retained record references it; ≤ 4 retiring records per non-key domain |
| Apple session | `apple-session/authorization-session.v2.enc` + Keychain wrap `com.veya.authorization-wrap.v1`, fixed account UUID | — | — | — | **single per macOS user; not keyed by account** | — | — | — | — | — | Dev: **not persisted** (`persistsAcrossLaunches == false`) |
| `authorizedTeamIdentifier` | `LiveApplePersonalTeamBackend` memory | — | — | — | implied by the current session | ✔ | — | — | — | — | Reset on invalidation or a failed resume; set by `listTeams` |
| `AppleAccountContext.cached` team | memory, per composition | — | — | — | — | ✔ | — | — | — | — | One button press |
| RemotePairing record (Mac) | Keychain `com.veya.remote-pairing.v2`, account `"<TEAM>:<UDID>"` (prod); `InMemoryRemotePairingStore` (dev) | — | ✔ | — | — | ✔ | — | — | — | — | Dev: lost on relaunch → pairing recreated |
| RPPairing record (iPhone) | iPhone Keychain, `AfterFirstUnlockThisDeviceOnly` | — | ✔ | — | — | via app | — | — | — | ✔ app container | Removed with the app |
| usbmuxd lockdown pair record | macOS system pair-record store, per UDID | — | ✔ | — | — | — | — | — | — | — | Until the user or iOS resets trust |
| DDI cache | `~/Library/Application Support/IOSSim/DeveloperSupport/<build>/<identity>/` | — | — | — | — | — | — | — | — | — | Per iOS build; integrity-checked on use |
| Run Setup pending request | `run-setup/` under the state root, and `…/SetupInbox/run-setup.request` in the phone container | — | ✔ | — | — | ✔ | — | — | — | ✔ + releaseIdentity | 15 min |
| LocalDevVPN request/receipt | phone container `…/SetupInbox/localdevvpn.{request,receipt}` | — | ✔ | — | — | ✔ | — | — | — | ✔ + releaseIdentity | Receipt accepted ≤ 60 s |
| Apple diagnostics | `apple-diagnostics.json` (structural, secret-free; last 200 events) | — | — | — | — | (m) last `teamIdentifier` | — | — | — | (m) derived bundle IDs | Rolling |
| LocalDevVPN trace | `localdevvpn-transition-trace.jsonl` (binding hashes only) | — | hashed | — | — | hashed | — | — | — | hashed | Append-only |

`releaseIdentity` = `"veya-v2:" + first 16 hex of the active application digest`
(`InstalledPayloadIdentity`, `DeviceProductionAdapters.swift`).

## Evidence kinds

| Kind | Provenance | Produced by | Connection-bound | `validUntil` |
|---|---|---|---|---|
| `legacyInventorySnapshot` | `veya-migration-reader` | MigrationDomain | no | — |
| `signingKeySignVerifyProbe` | `veya-signing-key-store` | SigningKeyDomain.prove | no | — |
| `appleInventorySPKIMatch` | `apple-developer-services` | CertificateDomain.prove | no | min(now+24 h, expiry−72 h) |
| `profileCMSBindingValidation` | `cms-offline-validation` | ProfileDomain.prove | no | expiry−48 h |
| `payloadIndependentVerification` | `veya-signing-core` | PayloadDomain.prove | no | — |
| `deviceInventoryAfterInstall` | `installation-proxy-inventory` | ApplicationDomain.prove | yes | — |
| `developerSupportFreshObservation` / `vpnFreshObservation` / `pairingFreshObservation` | `device-coordinator` | CoordinatedDeviceDomain.prove | yes | — |
| `runtimeFullChainProof` | `rich-runtime-inbox` | RuntimeReadinessDomain.prove | yes | completedAt+600 s |

Rules enforced by the engine and repository: evidence must match the candidate's generation and
subject. Promotion requires evidence at the candidate's generation. Evidence IDs are SHA-256
digests. Attribute keys containing `password, privatekey, private_key, token, cookie, escrowbag, 2fa`
are rejected (`InstallationSafeValue`).

## Observed state at the checkpoint (final journal, revision 1895, generation 155)

Team `T8SL4SG87F`, one physical device. Active: signingKey gen 147, certificate 148, profile 149,
payload 150, application 151, developerSupport 152, vpn 153, pairing 154, runtime 155, migration 1.
There are 19 retiring signing keys (kept forever) and 4 retiring records in each other domain.
`recovery.reason = blockingCandidateDiscarded:runtime`. On disk: 6 certificate files, 6 profile directories and 6 staging directories. 5 of each are
referenced by active or retiring records, and one of each is left over from an earlier generation.
`StateContentFiles.collectUnreferenced` removes those only on that domain's next transition. There
are 24 encrypted key files.

## Relevant to `VEYA-TEAM-032` (flagged, not investigated)

These are facts of the current design, recorded so the next task can start from code rather than
guesses. **None is asserted to be the cause.**

1. **The journal is scoped only by installation.** Nothing at the journal, signing-key, certificate,
   payload or application level is keyed by Apple Account. Team appears only as record metadata.
2. **`CertificateDomain.observe` does not compare the certificate's team with the signed-in team.**
   An active certificate stays `satisfied` while its DER, SPKI and 72 h window hold, whichever account
   is signed in. Its proof expires after at most 24 h. Before then the planner does not re-prove it
   against the new account's inventory.
3. **`ProfileDomain.execute` throws `VEYA-TEAM-032` when `account.team().id` ≠ the active certificate's
   `teamIdentifier`** (`AppleDomains.swift:505`). With a different account signed in and the previous
   account's certificate still `satisfied`, this is a direct path to the observed message.
4. **Backend guards throw `.invalidTeam` → `VEYA-TEAM-032`** whenever the requested team differs from
   `authorizedTeamIdentifier` (listDevices, addDevice, registerIdentifiers, profile creation, download),
   and Apple `addDevice` message text can also be classified as `.invalidTeam` (text-derived).
5. **The Apple session store is single-slot per macOS user** (fixed Keychain account UUID). It is not
   keyed by account.
6. **Signing keys are scoped by installation, not by account.** A key's certificate belongs to whichever
   team issued it. In the development session the key rotates on every relaunch (in-memory wrapping
   secret), which then makes the certificate `stale` (SPKI mismatch) and forces issuance under the
   **current** account. This means the dev-session relaunch path and the same-process account-switch
   path can behave differently. That difference should be checked explicitly.
7. **Certificate ownership for revocation is SPKI-only and team-agnostic.** Retired keys from one
   account's era stay in the journal forever. The reclaim logic only lists and revokes within the
   current team's inventory (`TeamCertificateService`, `teamID: team.id`).
8. **Pairing records are keyed `(team, udid)`.** A new team leads to a new pairing record, while the old
   one remains (prod Keychain).
9. **Profiles, payload and application carry team metadata and derive bundle IDs from the Team ID**
   (`PersonalTeamBundleIdentifierSet`). A new team means new bundle IDs and therefore a second
   installed app on the phone.
10. **Device registration is per team on Apple's side.** Apple diagnostics show `DEVICE_REGISTRATION_REQUIRED`
    → `addDevice` at 13:09:51 (the fresh-account/device test period) and `APPLE_AUTH_REJECTED` at 13:09:58.
    The journal has no per-account record of which devices were registered where.

Questions the investigation must answer, without weakening any check: which of these records should
be scoped by Apple Account, by Team ID, by certificate identity or by device; which should be rotated
or invalidated on an intentional account switch; and which may safely be reused.
