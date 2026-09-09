# Physical install state stabilization

Scope: same-Mac/same-iPhone local RC after the `e43aa18` Personal Team signing proof. This pass does not change authentication, provisioning, signing, installation backend, or runtime-location architecture.

## Root-cause map

| Physical observation | Diagnostic evidence | Function and old transition | Defect | Stabilized transition |
| --- | --- | --- | --- | --- |
| App and runner installed, but first verification reported failure; Try Again later succeeded | `2026-09-08T23:17:59Z`: `VERIFYING_INSTALLATION/MAIN_INSTALL_FAILURE`, detail `Refresh requested but prior main installation was not detected`; the post-install exact checks immediately before this guard had succeeded | `ConsumerArtifactProvisioner.installAndVerify`; one pre-install lookup set `installedBefore=false`, both installs and post-install lookups succeeded, then the refresh guard threw because of the stale pre-install value | A single eventually-consistent pre-install inventory miss overruled newer authoritative post-install evidence | Both install command successes are persisted; one full selected-device inventory is refreshed with cancellable bounded backoff; exact current main+runner presence is the sole install-success result; the obsolete pre-install guard is removed |
| Installed app could not open until its developer profile was trusted | `2026-09-08T21:18:41Z`: CoreDevice 10002 → FBS service error 1 → `FBSOpenApplicationErrorDomain` 3, `BSErrorCodeDescription=Security`, explicit `profile has not been explicitly trusted by the user` | `ConsumerArtifactProvisioner.launchMain`; every non-disconnect launch error became `RUNTIME_VERIFICATION_FAILED` at `VERIFYING_RUNTIME_CONFIGURATION` | Expected Apple developer-profile trust was conflated with installation/runtime failure | Strict signature/profile and exact inventory checks complete first; the structured CoreDevice/FBS chain maps to persisted `DEVELOPER_PROFILE_TRUST_REQUIRED`; Continue retries only launch, then runtime mapping readback |
| Retry could re-enter `CROSS_TEAM_UPGRADE_BLOCKED` for historical `5337SALD55` after current `T8SL4SG87F` artifacts had installed | Trust failure occurred before `provisioning-state.json` was written, leaving the historical manifest in place; `validateExistingState` checked it before current device inventory | `ConsumerArtifactProvisioner.validateExistingState` | Stale local metadata won before authoritative current-device evidence was considered | Current exact main+runner inventory for the selected device/team wins safely; checkpoints are saved before trust verification; stale metadata is diagnosed without triggering Fresh Install |

## Post-install inventory policy

The policy performs one immediate authoritative `devicectl device info apps` refresh for the exact selected device, followed by delays of 0.2, 0.4, 0.8, 1.2, 1.6, and 2.0 seconds. It is bounded to seven reads and 6.2 seconds of scheduled delay. Every delay is `Task.sleep`, so cancellation prevents later publication. Device unavailable, locked, computer-trust, and Developer Mode conditions stop polling and route to their own recoverable classifications.

The authoritative result records selected-device match, inventory availability, exact main and runner presence, current-team context, stale IOSSim artifact presence, retry count, elapsed time, and a safe reason. Canonical, Witness, old-team, or otherwise stale bundle identifiers never satisfy the current main/runner fields.

## Persisted resume checkpoints

- `INSTALL_COMMANDS_SUCCEEDED`: retry inventory only.
- `INSTALLATION_VERIFIED`: retry trust/launch only.
- `DEVELOPER_PROFILE_TRUST_REQUIRED`: remain on the Apple trust instructions; Continue retries launch only.
- `RUNTIME_CONFIGURATION_WRITTEN`: retry readback only.
- `RUNTIME_CONFIGURATION_VERIFIED`: proceed to the existing runtime-setup confirmation.
- `COMPLETE`: no setup replay.

Legacy schema-v1 manifests are compatible. They were only written after runtime mapping readback, so they resume from runtime-configuration verified (or complete when runtime setup was already confirmed).
