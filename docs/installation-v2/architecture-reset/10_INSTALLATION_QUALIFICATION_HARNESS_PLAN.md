# Installation qualification harness plan

## Command surface

```text
veya-qualify inspect [--artifact APP] [--device ALIAS]
veya-qualify state [--scenario NAME] [--root PATH]
veya-qualify apple-auth [--fixture NAME|--live]
veya-qualify certificate [--fixture NAME|--live] [--allow-owned-revoke]
veya-qualify signing --fixture-app PATH [--identity-fixture NAME|--live]
veya-qualify device --device ALIAS [--read-only]
veya-qualify install --device ALIAS --signed-manifest PATH
veya-qualify developer-support --device ALIAS
veya-qualify pairing --device ALIAS [--proof-only]
veya-qualify vpn --device ALIAS [--proof-only]
veya-qualify appservice --device ALIAS
veya-qualify rich --device ALIAS --bounded-proof
veya-qualify full --scenario NAME
veya-qualify report --run RUN_ID
```

The live certificate command defaults to read-only. An ownership-proven revoke requires both a scenario contract and `--allow-owned-revoke`; the release qualification procedure must record this as an irreversible operation before execution.

## Architecture

`VeyaQualificationCLI` depends on `InstallationEngine`, `ApplePersonalTeamService`, `PayloadSigner`, `NativeDeviceService`, `PairingService`, `VPNService`, `RuntimeProofService`, and `OperationEventSink`. These are the same compositions used by the packaged app. CLI options choose fixture or live adapters; they do not select different business logic.

Each command supports:

- `--plan`: print safe operations and mutation classes.
- `--json`: JSONL operation events.
- `--run-id`: caller-provided correlation ID.
- `--root`: repo-contained isolated state root for tests.
- `--fault`: named deterministic injection point, fixture mode only by default.
- `--deadline`: whole-command budget, never an unbounded wait.
- `--device`: mandatory for any device mutation; no implicit first-device selection.

## Run artifact layout

All qualification artifacts stay under the repository:

```text
.build/iossim/qualification/<run-id>/
  run.json
  events.jsonl
  stage-results.json
  artifact-manifest.json
  environment.json
  junit.xml
  screenshots/          # only when deliberately captured
  support/              # redacted export
```

`run.json` records commit, dirty patch digest, executable hashes, architecture, OS, fixture/live mode, safe device alias, scenario, start/end and result. It never records credentials, tokens, private keys, raw UDIDs, raw profiles, pairing material or coordinates.

## Stage contract

Every command returns one of `PASS`, `USER_ACTION_REQUIRED`, `RETRYABLE_FAILURE`, `REPAIRABLE`, `BLOCKED`, or `INTERNAL_FAILURE`. Exit codes are stable by result class. A PASS includes proof type, proof digest/reference, expiry, selected device/team generation and exact production code version.

## Scenario catalog

Version the scenario definitions under `tools/qualification/scenarios/` as data. Each declares initial resources, injected failures, permitted mutations, expected first failure, expected final domains, retry ceilings and secret policy. Scenarios A-W from the reinstall model and all failure-injection rows are mandatory.

## Replacement plan

1. Extract the scenario vocabulary from `HermeticInstallationHarnessTests` into data.
2. Make the production engine accept ports, clock, UUID source and state root.
3. Implement a fixture composition around the production engine.
4. Add the CLI as a package executable and include it in the packaged app as a non-user-facing helper mode or share its library composition.
5. Port current Python baseline/redaction checks as report post-processing; remove hard-coded `startingBuild: 3` and fixed matrix values.
6. Add prompt sentinel and packaged-process test commands.
7. Require a successful run manifest before the release script is allowed to increment/build a DMG.

## Safety controls

- Live mode refuses Apple/device mutation without an exact device alias and scenario permission.
- No cleanup command performs broad Keychain, certificate, profile, pairing or app deletion.
- Fault injection cannot be enabled against live Apple endpoints unless the fault is purely local/read-only.
- A run interrupted after irreversible intent starts is resumed/reconciled by run ID before a new run may mutate the same team/device domain.
- Report generation is append-only per run and never rewrites historical results.

