# Testing architecture reset

## Principle

One production `InstallationEngine` exposes deterministic stage transitions behind injected ports. Tests substitute ports, clocks and storage roots, but never substitute the engine or reimplement its ordering. Release signing tests call the exact same signer library and bundle traversal used by the packaged helper.

## Layer 1: pure state-machine tests

- Table-test every state, allowed transition, user-action state, timeout, retry ceiling, interruption point and active/candidate promotion.
- Model-check invariants: unknown is not ready; selected device/team never changes implicitly; irreversible intent precedes mutation; an active resource survives candidate failure; READY requires all bound proofs.
- Generate transition coverage from `installation_state_machine.json`; fail CI if production states or error codes have no scenario.

Gate: 100% state/edge coverage, deterministic clocks, no network/filesystem/Keychain/device access.

## Layer 2: hermetic Apple API simulations

Record sanitized plist/JSON fixtures and implement a scripted fake server at the adapter boundary for valid/expired session, trusted/SMS 2FA, no Personal Team, paid+Personal ambiguity, available/full certificate capacity, CSR-time 7460, owned/other/unknown certs, delayed revocation propagation, expired/mismatched profile, rate limit, response drift and transport interruption.

Assert exact endpoint operation, request field names/types, idempotency token, team/device continuity, retry count, serial selected and redaction. No real credentials or network.

## Layer 3: real local secure-storage tests

Two suites:

1. New signer store: temporary 0700 root plus isolated temporary Keychain only for the wrapping secret. Test create/reopen/decrypt/sign, missing blob, missing wrapping item, corrupt ciphertext, wrong schema, concurrent access, restart, reinstall and deletion boundaries.
2. Legacy migration: temporary `Veya-Signing` Keychain fixtures for enumeration and classification only. Do not mutate the login Keychain. Test that ACL-inaccessible legacy keys lead to safe replacement, not SecurityAgent.

Use a GUI-session prompt monitor or SecurityAgent process/window sentinel with a hard timeout. Any prompt is a test failure. Tests must be runnable by default in a dedicated clean-Mac CI lane; developer-host skips do not count as qualification.

## Layer 4: actual signing integration

Maintain a synthetic minimal iOS fixture with:

- main app executable,
- nested framework/dylib,
- app extension where supported,
- XCTest runner/test bundle shape,
- known source identifiers and entitlements,
- fixture provisioning profiles/certificates/keys generated for tests.

Invoke the production signer. Independently verify every Mach-O and bundle, CodeResources, nested order, identifiers, DER/XML entitlements, embedded profile, certificate chain/team, device binding and tamper detection. Run on Intel and Apple Silicon. Maintain golden structural manifests, not golden signatures with nondeterministic bytes.

## Layer 5: native iPhone transport

Read-only or safely idempotent commands against an explicitly selected test phone:

- discovery and identity binding,
- lock/Trust status without resetting pairing,
- installed-app inventory,
- House Arrest read/write in Veya's own container,
- developer-service/DDI mount status,
- RemotePairing possession proof using current record,
- RSD/RemoteXPC/AppService reachability,
- bounded launch/runtime proof that clears its own test value.

Destructive operations require a named scenario and operator acknowledgement in the physical lane. Never erase pairing, profiles, apps, certs or phone state merely to make a test clean.

## Layer 6: installation scenario harness

`veya-qualify` links the production engine and exposes stage-scoped commands described in `10_INSTALLATION_QUALIFICATION_HARNESS_PLAN.md`. It accepts isolated roots and fixture ports, or explicit live ports. It emits the same operation envelope as the app. This replaces the current Python harness's five superficial checks and the test-local `HermeticInstallationEngine`.

## Layer 7: packaged integration

Assemble the app without creating a DMG for routine tests. Launch the packaged app/helper from a quarantine-like path, verify protocol/digests, run inspect/auth-store/signing fixture stages, and monitor for prompts. Then build a candidate DMG only when Layers 1-6 pass. Mount it, audit mounted bytes, copy to Applications, and run a bounded non-destructive scenario.

## Layer 8: clean-machine physical qualification

Use disposable Intel and Apple Silicon Mac accounts/machines with no Xcode, no prior Veya/IOSSim state, and a controlled physical iPhone/account scenario. Then run reinstall, upgrade, reboot, expiry and second-Mac lanes. Capture immutable run manifests and safe structured events. Development-Mac success never substitutes for this gate.

## Existing coverage assessment

| Existing asset | Keep | Problem to fix |
| --- | --- | --- |
| Apple API/parser and capacity tests | yes | bind fixtures to production engine scenarios |
| Keychain regression tests | migration-only value | opt-in, host-contaminated and based on architecture being retired |
| `HermeticInstallationHarnessTests` | scenario vocabulary | test-only engine can lie; replace with production engine injection |
| native application/pairing tests | yes | add actual bridge stage runner and physical receipts |
| `VeyaPhysicalQualification.py` | redaction/artifact baseline ideas | fixed Build 3 matrix; no stage execution; appends/rewrites reports without run identity |
| full Swift/Rust suites | yes | green suite is entry gate, never consumer proof |

## CI gates

1. Per-commit: Layers 1, 2 and most 4; schema/error coverage and secret scan.
2. macOS matrix: Layers 3 and 4 on Intel/Apple Silicon runners.
3. nightly lab: Layer 5 non-destructive selected-device probes.
4. release candidate: Layers 6-8 plus mounted-byte and clean-machine gates.

