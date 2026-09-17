# Architecture decisions

## ADR-001 — Zero-Xcode target

**Context:** packaged native protocols are largely present; clean DDI supply is not. **Options:** require full Xcode; claim unconditional zero-Xcode; conditional zero-Xcode with blocker. **Evidence:** current bridge/code, pinned idevice, Apple component documentation, 17. **Decision:** `ZERO_XCODE_CONDITIONALLY_FEASIBLE`; customer runtime must not invoke Xcode, but marketing/shipment waits for ADR-003. **Rejected:** full-Xcode product goal regression; unconditional claim unsupported. **Consequences:** build infrastructure may use Xcode; setup exposes legitimate Apple prompts. **Risks:** Apple/private protocol changes. **Rollback:** distribute an explicitly Xcode-dependent developer edition, never silently change consumer requirements.

## ADR-002 — Initial device pairing

**Context:** current ABI consumes existing pair state; upstream pinned idevice exposes `pair_once` and usbmux persistence. **Options:** require Finder/Xcode pretrust; shell to another tool; add native ABI. **Evidence:** `CONFIRMED_OPEN_SOURCE_REFERENCE`. **Decision:** add USB-only typed Lockdown pair begin/poll/save/validate ABI and preserve Trust/passcode UI. **Rejected:** hidden bypass and external CLI. **Consequences:** fresh pairing becomes owned setup state. **Risks:** OS behavior/version changes and record persistence. **Rollback:** retain existing-record path and show a typed unsupported state; never fabricate trust.

## ADR-003 — Developer image acquisition

**Context:** mount/TSS exists; only cache readers exist. Actual Vanish 3.2.1 static code confirms a working clean-cache mechanism: bundled PMD `mounter auto-mount` downloads personalized DDI inputs from the doronz88 GitHub mirror, then uses Apple TSS and ImageMounter before RSD. **Options:** bundle/mirror assets; use that third-party mirror live; require existing Xcode cache; approved Apple-origin/authorized provider. **Evidence:** local code, Vanish bundle/ASAR and bundled PMD/DDI source, Apple additional-component docs/agreements. **Decision:** Vanish resolves technical feasibility but does not approve a production provider for Veya. Keep existing-cache support and block fresh zero-Xcode release until product/legal approves a provider with exact-build provenance, asset rights, integrity/revocation/update policy, and applicable code-license compliance. **Rejected:** adopting the public mirror by convenience; claiming GPL wrapper metadata grants rights to Apple bytes. **Consequences:** overall architecture remains `NOT_READY`. **Risks:** no acceptable provider may emerge. **Rollback:** product may explicitly require a user-provided authorized component, changing UX/marketing after review.

## ADR-004 — Native device backend

**Context:** current Rust bridge covers discovery through AppService/House Arrest. **Options:** PMD subprocess; libimobiledevice tools; Xcode CoreDevice/devicectl; retain bridge. **Evidence:** code and saved physical records. **Decision:** retain/pin native idevice bridge, add ABI v2 and exact mux selection. **Rejected:** Python/GPL bundle, Xcode runtime, tool subprocess fragmentation. **Consequences:** Veya owns compatibility and notices. **Risks:** pinned upstream changes/private protocols. **Rollback:** pin last qualified revision; no automatic fallback to Xcode.

## ADR-005 — Apple Personal Team private adapter

**Context:** implemented private GrandSlam/Developer Services flow is necessary for free Personal Team and version-bound. **Options:** remove Personal Team; expose implementation through SetupStore; versioned adapter. **Evidence:** current source and Apple public API limitations. **Decision:** stable `ApplePersonalTeamService` over a versioned private adapter with fixtures, typed errors, kill switch, and read-before-create. **Rejected:** describing it as supported public API or scattering constants. **Consequences:** compatibility maintenance is a product obligation. **Risks:** Apple service/terms changes. **Rollback:** disable mutations, preserve installed apps, require a supported alternative/account workflow.

## ADR-006 — Setup engine ownership

**Context:** current foundations work; duplicate historical paths confuse failure diagnosis. **Options:** rewrite engine; keep all selectors; consolidate existing engine. **Evidence:** call graph and checks. **Decision:** SetupStore/UI -> BundledProvisioningEngine -> one signed IOSSim/VeyaProvisioner -> domain reconciler. **Rejected:** second engine and repository CLI in product. **Consequences:** narrow migration, one mutation owner. **Risks:** large provisioner refactor. **Rollback:** compatibility adapter at protocol edge, not a second backend.

## ADR-007 — Cross-process state locking

**Context:** actors/generations are process-local and singleton files overwrite identities. **Options:** actor only; daemon; OS lock + journal/CAS. **Evidence:** current store code. **Decision:** per-SetupKey OS advisory lock/lease, append journal, atomic snapshot, generation CAS. **Rejected:** global singleton and new privileged daemon. **Consequences:** crash recovery is explicit. **Risks:** filesystem semantics/stale lease logic. **Rollback:** read-only/quarantine and physical reconciliation; never last-writer-wins.

## ADR-008 — Pairing lifecycle

**Context:** current import receipt/no-op proof and delete-first repair are unsafe. **Options:** keep; manual-only; staged replacement. **Evidence:** current Mac/phone code. **Decision:** request-bound AEAD, candidate slots, fresh possession proof, developer-service operational proof, two-sided promotion. **Rejected:** receipt-as-proof and delete-first. **Consequences:** wire schema 2 and migration proof. **Risks:** two-device consistency/crash edges. **Rollback:** retain active record and discard candidate.

## ADR-009 — LocalDevVPN architecture

**Context:** current product depends on external bundle and Apple VPN approval; Personal Team cannot assume packet-tunnel entitlement. **Options:** absorb/build VPN; remove phone-local flow; external App Store dependency. **Evidence:** source, App Store listing, Apple TN3134, prior entitlement failure record. **Decision:** external app with Veya-owned detection/version/request/launch/readiness contract; obtain publisher/support decision before shipment. **Rejected:** unauthorized rebundling and bypassing approval. **Consequences:** external update compatibility matrix. **Risks:** publisher/app removal/protocol change. **Rollback:** block phone-local READY and keep Mac-connected compatible mode only if product explicitly supports it.

## ADR-010 — Runtime-ready definition

**Context:** current setup-ready is stored-state verification. **Options:** keep checkpoint; AppService/VPN only; end-to-end Rich proof. **Evidence:** source and runtime invariants. **Decision:** READY requires current AppService runner launch, TestManager attach, and bounded Rich set/observe/clear proof on the selected identity. **Rejected:** configuration/import receipts. **Consequences:** readiness takes longer but is truthful. **Risks:** probe side effects/flakiness. **Rollback:** display CONFIGURED and owning failure, never READY.

## ADR-011 — Release artifact authority

**Context:** current sidecar lies about architectures/schema. **Options:** config/sidecar authority; pre-DMG app; mounted final artifact. **Evidence:** exact DMG comparison. **Decision:** signed manifest derived from mounted DMG bytes is authority; desired config is only an assertion. **Rejected:** copied sidecars and duplicated literals. **Consequences:** longer fail-closed audit. **Risks:** nondeterministic signing/metadata normalization. **Rollback:** withhold release and retain local diagnostic artifact.

## ADR-012 — IOSSim to Veya migration

**Context:** branding must not disrupt keys/pairing/bundle mappings. **Options:** immediate rename/new IDs; never rename; staged compatibility migration. **Evidence:** resource ownership. **Decision:** functional V2 under IOSSim first, then display/artifact rename with stable internal IDs; change bundle IDs only by separate approved dual-ID migration. **Rejected:** big-bang rename. **Consequences:** temporary “formerly IOSSim” period. **Risks:** Keychain designated requirement/update continuity. **Rollback:** last compatible IOSSim release and old state retained.

## ADR-013 — Legacy engine removal

**Context:** development/Xcode/devicectl code remains source-reachable. **Options:** leave indefinitely; delete immediately; disconnect, prove parity, delete. **Evidence:** call graph/source checks. **Decision:** compile out of production first, move to dev-only if needed, delete after native/diagnostic gates. **Rejected:** immediate risky deletion and selectable public fallback. **Consequences:** staged cleanup. **Risks:** hidden diagnostic dependency. **Rollback:** restore in developer target only.

## ADR-014 — Distribution authority

**Context:** repository has no GitHub Releases and no alternate canonical backend. **Options:** ad hoc file links; GitHub Releases; new service. **Evidence:** read-only empty release list. **Decision:** GitHub Releases is initial immutable artifact authority, augmented by Veya-signed manifest/update metadata and post-upload download verification. **Rejected:** filenames/local sidecars as authority and an unbuilt service. **Consequences:** operational release permissions/workflow required. **Risks:** account compromise/outage. **Rollback:** signed metadata can point to a reviewed alternate origin without changing artifact identity.

## ADR-015 — Mac architecture policy

**Context:** current sidecar claimed universal while output was arm64. **Options:** arm64-only; per-architecture DMGs; one universal DMG. **Evidence:** current release config/build capability and contradiction. **Decision:** one universal arm64+x86_64 DMG while macOS 13 Intel is supported; every executable/dylib must contain both slices. If Intel support is dropped, make it an explicit product/minimum-OS release decision and emit arm64 truth. **Rejected:** config-only universal claim and ambiguous parallel DMGs. **Consequences:** longer two-arch builds and Intel qualification. **Risks:** a dependency may lack x86_64 support. **Rollback:** delay release or publish a clearly new arm64-only support policy; never relabel an arm64 build.
