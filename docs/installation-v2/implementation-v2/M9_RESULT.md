# M9 Result — Device / DDI / Pairing / VPN Reconciliation

Status: **SOFTWARE_GATE_PASS (engine integration, scripted device) / PHYSICAL_BLOCKED_HUMAN / PRODUCTION_DDI_BLOCKED_EXTERNAL**.

## Implemented (`Installation/DeviceDomains.swift`)

The existing coordinators (`DeveloperSupportCoordinator`, `RemotePairingLifecycle`, `LocalDevVPNSetupCoordinator`)
are kept, not rewritten. They are integrated into the engine through:

- `DeviceDomainMapping`: exhaustive, compiler-checked maps from every native state to engine semantics. Only `mounted`/`notNeeded` (DDI, reported after RSD verification), `operational` (pairing), and `runtimeEndpointReachable` (VPN) are `.satisfied`. `running`, `configured`, `stored`, `validating`, and similar states are incomplete and never satisfy. Developer Mode off and VPN permission map to `waitingForUser` with an exact instruction and no retry. DDI `noApprovedSource`/`wrongBuildIdentity`/`incompatible` map to `VEYA-DDI-030` ("not approved for this iOS build").
- `CoordinatedDeviceDomain`: one connection-bound adapter (read-only `observe`, mutating `prepare`). Candidate identity binds domain, device hash, and connection generation. Proof is a **fresh** read-only observation, never `prepare`'s return value. A reconnect makes the active record stale and forces re-proof.

## Tests (`DeviceDomainsTests` 6/0)

DDI mount, prove, idempotency, and re-proof after reconnect; Developer Mode user action with zero prepare
calls; incompatible build typed and blocked; VPN `running` without endpoint challenge never promoted;
VPN permission as a user action; pairing incomplete → operational, and failed → retryable; exhaustive
state tables (11 DDI, 13 pairing, 7 VPN states) with only the proven states satisfied.

## Production DDI supported builds (gate item)

**Enumerated: none.** `config/release.json` has `developerSupportProviderClassification =
UNRESOLVED_PRODUCTION_PROVIDER`. The clean-Mac physical run never reached DDI ("NOT REACHED",
`PHYSICAL_VALIDATION_LEDGER.md`). Every build is therefore displayed as unsupported (`VEYA-DDI-030`) under
the production policy. The development mirror provider stays debug/qualification-only. This is
BLOCKED_EXTERNAL (licensed exact-build catalog), not a software defect.

## Production integration (continuation)

Seam found: the M9 DDI mapping targeted `DeveloperSupportCoordinator`, which **no production path uses**; the
shipping helper uses `NativeDeveloperServicesCoordinator`. `Installation/DeviceProductionAdapters.swift` now wires the
coordinators the helper actually uses:

- `.developerSupport`: observe = read-only inspect + CoreDevice/RSD/AppService readiness probe; prepare =
  `NativeDeveloperServicesCoordinator.prepare` (DDI mount if needed + runner launch). `ddiRequired` → missing,
  Developer Mode / lock / trust → exact user action, `noApprovedSource`/`wrongBuildIdentity` → `VEYA-DDI-030`.
- `.pairing`: observe = the Mac-side record for device/team validated against the device (read-only); prepare =
  `RemotePairingCoordinator.reconcileAutomatically`.
- `.vpn`: observe = the phone's last LocalDevVPN receipt read from the app container (no write, no launch); only a
  fresh (≤10 min), device/team/payload-bound `runtimeEndpointReachable` receipt with `endpointReachable` satisfies;
  prepare = `LocalDevVPNSetupCoordinator.prepare`.
- Pairing and VPN identities include the active `.application` record (`dependsOn`): a reinstalled app has an empty
  container, so its pairing/VPN state is stale and is re-delivered.

Security defect found: `KeychainRemotePairingStore` (RemotePairing secrets) uses the login Keychain without
`kSecUseAuthenticationUIFail`; per the M4 root cause, reads after a Veya upgrade (new cdhash) can raise SecurityAgent.
The v2 composition uses `KeychainRemotePairingStore.installationV2()` (service `com.veya.remote-pairing.v2`, the M4
backend: DP Keychain without UI, `unavailable` → `VEYA-PAIR-031`, never a prompt, never treated as a corrupt record).
The Build 1–11 store is unchanged for the legacy route, which is retired with it.

Tests: `ProductionWiringTests` 6/0 (DDI probe mapping; pairing never proven without the engine and stale after an
app reinstall; VPN observation read-only — 0 writes, 0 launches — and rejecting other-device / other-payload /
old / not-reachable receipts; v2 pairing store fails closed; retired legacy identity store refuses; full production
composition observes all 13 domains and fails closed at the key store).

## Not done

- The connection generation is client-assigned (the bridge echoes it); the UI must bump it on every attach/detach.
- Physical DDI/pairing/VPN proof: BLOCKED_HUMAN (iPhone connected, unlocked, Trust, Developer Mode, VPN approval).
