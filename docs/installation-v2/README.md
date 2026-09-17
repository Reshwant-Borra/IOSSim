# Installation V2 research index

This directory is the frozen research, target architecture, and implementation plan for Veya Installation V2. It describes the dirty working tree at branch `work/final-no-xcode-setup-v1`, HEAD `1259da507ecded222022cc86bf82863c15640db9`, on 2026-09-15. It does not implement the design.

The evidence labels are defined by the task: `CONFIRMED_LOCAL_IOSSIM_CODE`, `CONFIRMED_LOCAL_IOSSIM_TEST`, `CONFIRMED_LOCAL_IOSSIM_ARTIFACT`, `CONFIRMED_LOCAL_IOSSIM_DOC`, `CONFIRMED_IOSSIM_GIT_HISTORY`, `CONFIRMED_VANISH_ARTIFACT`, `CONFIRMED_VANISH_STATIC_CODE`, `CONFIRMED_APPLE_DOCUMENTATION`, `CONFIRMED_OPEN_SOURCE_REFERENCE`, `EXPERIMENTALLY_VERIFIED_LOCAL`, `PHYSICAL_EVIDENCE_FROM_EXISTING_RECORD`, `STRONG_INFERENCE`, `WEAK_INFERENCE`, `UNRESOLVED`, `PRODUCT_DECISION_REQUIRED`, and `PHYSICAL_VALIDATION_REQUIRED`.

Read in order:

1. [00_EXECUTIVE_SUMMARY.md](00_EXECUTIVE_SUMMARY.md) gives the verdict.
2. [01_PRODUCT_INVARIANTS.md](01_PRODUCT_INVARIANTS.md) through [17_ZERO_XCODE_FEASIBILITY_AND_GAPS.md](17_ZERO_XCODE_FEASIBILITY_AND_GAPS.md) establish current reality and external boundaries.
3. [18_SETUP_ENGINE_V2_ARCHITECTURE.md](18_SETUP_ENGINE_V2_ARCHITECTURE.md) through [33_FUTURE_PHYSICAL_VALIDATION_REQUIREMENTS.md](33_FUTURE_PHYSICAL_VALIDATION_REQUIREMENTS.md) freeze the target.
4. [34_KEEP_REFACTOR_REPLACE_DELETE_MATRIX.md](34_KEEP_REFACTOR_REPLACE_DELETE_MATRIX.md) through [40_MASTER_IMPLEMENTATION_SPEC.md](40_MASTER_IMPLEMENTATION_SPEC.md) are the implementation handoff.

The follow-on [vanish-reference/](vanish-reference/README.md) set reconstructs the actual Vanish 3.2.1 consumer setup behavior and maps each responsibility to Veya's current components. Its document 20 is the execution-focused implementation plan and refines, rather than replaces, the evidence and invariants in 00–40.

Raw inventories and continuation records are under `evidence/`. The authoritative baseline is `evidence/source-baseline.json`; the ongoing audit trail is `evidence/RESEARCH_LEDGER.md`.

The architecture verdict is **ARCHITECTURE_NOT_READY**. Static inspection now proves that Vanish also requires DDI and uses bundled `pymobiledevice3` to download Apple DDI inputs from the doronz88 GitHub mirror before Apple TSS personalization. That proves a working technical pattern, not an approved Veya supply contract. The plan is actionable for independent work, but the product cannot claim fresh-machine zero-Xcode until a developer-support acquisition/distribution policy with accepted provenance, rights, integrity, and update ownership exists. See 17, 37 ADR-003, 39, and `vanish-reference/04`.
