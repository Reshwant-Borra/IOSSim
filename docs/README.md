# IOSSim Documentation Index

Current authoritative retest artifact: `.build/iossim/final-setup-payload-retest/IOSSim.app` (fresh Xcode 27.0 payload). Historical `.build/iossim/final-setup-retest/IOSSim.app` is stale and must not be used for setup validation.

## Authoritative current docs

- [IOSSim Current Engineering State](IOSSim_CURRENT_ENGINEERING_STATE.md) — current verdict, architecture, provenance, blockers, physical evidence, and next actions.
- [Build and Packaging](IOSSim_BUILD_AND_PACKAGING.md) — exact targets/schemes/commands, payload staging, capability guard, hashes, and build-machine versus consumer boundary.
- [First-Time Setup](IOSSim_FIRST_TIME_SETUP.md) — schema-4 setup state machine, recovery, conditional DDI, AppService, House Arrest, automatic pairing, and verified external LocalDevVPN readiness.
- [Native Device Stack](IOSSim_NATIVE_DEVICE_STACK.md) — pinned Rust/Swift/C ABI layers, ownership, typed errors, and DDI/TSS boundary.
- [iPhone Payload](IOSSim_IPHONE_PAYLOAD.md) — main/runner/test bundle identities, startup ingress, mapping, pairing Keychain/receipt, and stale incident.
- [Security Model](IOSSim_SECURITY_MODEL.md) — credential/key lifecycle, encrypted inbox, persistence, logs, redaction, and trust boundaries.
- [Physical Validation Matrix](IOSSim_PHYSICAL_VALIDATION_MATRIX.md) — evidence-scoped status for every gate through setup and later placeholders.
- [Troubleshooting](IOSSim_TROUBLESHOOTING.md) — typed setup errors and safe layer-specific recovery without consumer Xcode.
- [Engineering Handoff](IOSSim_ENGINEERING_HANDOFF.md) — repository warnings, frozen areas, exact continuation commands, and next task.
- [Handoff Snapshot — 2026-09-15](IOSSim_HANDOFF_SNAPSHOT_2026-09-15.md) — concise current decision record.
- [iPhone Setup Ingress Call Graph](../IPHONE_SETUP_INGRESS_CALL_GRAPH.md) — exact source-level startup, pairing, mapping, cleanup, and binary-evidence graph.
- [Final Payload Rebuild and Handoff Report](../FINAL_IPHONE_PAYLOAD_REBUILD_AND_HANDOFF_REPORT.md) — complete execution report and blocker disposition.
- [Current Worktree Snapshot](../CURRENT_WORKTREE_SNAPSHOT.md) — pre-task dirty-tree inventory and preservation boundary.

## Historical investigation and implementation docs

These files are retained as evidence and may describe superseded paths, schemas, artifacts, or connectivity:

- `../FINAL_NO_XCODE_SETUP_GAP_AUDIT.md`
- `../FINAL_NO_XCODE_SETUP_ARCHITECTURE.md`
- `../FINAL_NO_XCODE_SETUP_IMPLEMENTATION_REPORT.md`
- `../GPT_ASTRA_ARCHITECTURE_COMPLIANCE_AUDIT.md`
- `../NO_XCODE_APPSERVICE_DEVICE_NOT_FOUND_INVESTIGATION.md`
- `../NO_XCODE_DEVICE_DISCOVERY_INVESTIGATION.md`
- `../NO_XCODE_INSTALLATION_ROOT_CAUSE_INVESTIGATION.md`
- `../NO_XCODE_NATIVE_APP_LAUNCH_INVESTIGATION.md`
- `../SETUP_ENGINE_INVENTORY.md`
- `../SETUP_LEGACY_INTERFERENCE_INVESTIGATION.md`
- Existing documents such as `CURRENT_STATE.md`, `SETUP.md`, `PHYSICAL_VALIDATION.md`, `RELEASE_AND_DISTRIBUTION.md`, `AUTOMATIC_PAIRING.md`, `READINESS_RECOVERY.md`, and `docs/mac-host/*`.

Use the authoritative current docs above when historical statements conflict. Do not delete historical reports.

## Research docs

The final preimplementation research package is external and read-only:

`/Users/rishiborra/Desktop/VanishedResearch.mSgdHk/FINAL_PREIMPLEMENTATION/`

Primary design inputs are `05_AUTOMATIC_PAIRING_ARCHITECTURE.md`, `06_READINESS_RECOVERY_ARCHITECTURE.md`, `07_DDI_AND_DEVELOPER_SERVICES.md`, `10_TARGET_IOSSIM_ARCHITECTURE.md`, `11_SOURCE_CHANGE_BLUEPRINT.md`, `12_IMPLEMENTATION_PHASES_AND_GATES.md`, and `13_FINAL_PREIMPLEMENTATION_REPORT.md`. They guide implementation but do not override current physical evidence or current source.
