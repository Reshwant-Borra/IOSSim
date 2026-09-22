# Build 12 Entry Gate Evaluation (2026-09-21)

Verdict: **NOT AUTHORIZED**. Build remains `11`. No Build 12 artifact was created.

| Gate item | Status |
|---|---|
| M0-M12 exit gates complete | FAIL: M4 blocked; M5/M7/M9/M10 physical items blocked; M11 legacy removal pending |
| Baseline Swift/Rust pass, no unexpected skips | FAIL: 1 required failure (M4 gate); 9 legacy skips pending deletion (continuation: 497 run, all other suites pass) |
| Campaigns (model, journal, Apple, key store, signer, cert, profile, install, migration, failure injection) | PASS except real key store (M4) |
| `veya-qualify` on packaged helper + universal bridge | NOT_RUN on a new packaged candidate |
| Exact payload signed by new path, installed and launched on the iPhone | BLOCKED_HUMAN (signed + independently verified locally with a synthetic identity only) |
| Real packaged key-store create/reopen/upgrade without SecurityAgent | **FAIL: requires a team identity + provisioning profile (M4)** |
| Active survives named failures | PASS (simulated) |
| Universal / load-command / SBOM / license / secret audits | PARTIAL (guards added; no mounted DMG) |
| Clean-host no-toolchain runtime | NOT_RUN |
| No legacy codesign/SecIdentity/search-list/ACL routes | FAIL: 16 findings in 8 files, all on the still-shipping legacy route; the v2 route cannot reach them (`RetiredLegacyIdentityKeychain`, v2 guard incl. subprocess rule = 0) |
| No known P0/P1 | Fixed: auth v1 plaintext-equivalent storage (P1), renewal lost-response false success (P1); continuation: certificate budget reset on engine retry (P1), single-bundle payload / missing per-team rewrite / wildcard entitlement request (P1 functional). Open: legacy signing keychain plaintext-equivalent and legacy pairing store prompt-on-upgrade (both legacy route only, retired by removal) |
| Production DDI supported builds enumerated | DONE: none (unsupported is displayed) |
| UI routed to the canonical engine | NOT DONE: blocked on M4 (the new route fails closed at `.signingKey` on every current build) |
| Human `BUILD_12_AUTHORIZED` | absent |
