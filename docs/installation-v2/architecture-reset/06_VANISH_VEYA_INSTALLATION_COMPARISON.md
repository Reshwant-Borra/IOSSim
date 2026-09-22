# Vanish/Veya installation comparison

| Concern | Vanish evidence | Veya current | Target implication |
| --- | --- | --- | --- |
| distribution | **OBSERVED** signed/notarized arm64 Electron app with bundled helpers | universal local ad-hoc DMGs; production signing/notarization not qualified | retain universal goal; add clean packaging lane |
| toolchain | **OBSERVED** bundled Rust/Python/device stacks | Swift app/helper + bundled Rust bridge and device artifacts | keep native architecture; package every dependency |
| setup orchestration | **OBSERVED** command/event helper bridge and separate repair commands | multiple overlapping state machines plus UI-owned branches | one production reconciliation engine with stage API |
| Apple auth | **OBSERVED capability**, exact live behavior unknown | native Swift GrandSlam/SRP/2FA works in physical evidence | keep, isolate behind versioned adapter |
| password storage | **OBSERVED** optional safeStorage | Veya stores opaque session; no need for password default | do not copy default password persistence |
| private key | **INFERRED** software key blob loaded in process; open source verifies pattern | permanent SecKey in dedicated Keychain | replace with encrypted Veya-managed key material |
| signing | **INFERRED** in-process apple-codesign; source verifies | SecIdentity + global search list + `/usr/bin/codesign` | move production signing in process |
| certificate capacity | **OBSERVED** UI event; exact policy unknown; open source has 7460 modes | ownership-safe reclaim intent and bounded confirmation | keep Veya safety, add CSR-time signal/retry |
| profile | **OBSERVED capability**, policy unknown | strong explicit validation for main/runner | retain Veya validation |
| install | **INFERRED** AFC + InstallationProxy from capability/source | native AFC/InstallationProxy bridge with inventory | retain, expose stage command |
| DDI/RSD | **OBSERVED** bundled pmd3/Python helpers | Rust native bridge, DDI/TSS/mount coordinators | retain Veya path, resolve lawful production DDI source |
| pairing | **OBSERVED** create/place/repair/export | stronger active/candidate receipt and proof model | retain Veya proof model and automate UX |
| LocalDevVPN | **OBSERVED relationship**, ownership unknown | explicit coordinator and inbox | keep explicit dependency/user approval model |
| runtime | **OBSERVED** DVT coordinate path; Rich metadata unknown | XCTest/XCUILocation Rich runtime target | do not downgrade to coordinate-only architecture |
| restart | **OBSERVED** bounded helper restart/replay guards | broad retry logic split across owners | adopt scoped stage restart in one journal |
| reinstall/multi-Mac | **UNKNOWN** | underdesigned and contaminated by IOSSim | define explicit matrix and fail-safe ownership |
| seven-day lifecycle | **OBSERVED** refresh/re-sign model, success unknown | refresh models exist; full renewal unqualified | proactive candidate renew/install/prove/promote |

## Adopt

1. In-process iOS signing over Veya-managed software key material.
2. Public-key matching as the cryptographic identity join.
3. Apple 7460 as an authoritative capacity signal with bounded retry.
4. A stage-oriented helper/CLI so provisioning, signing, install and pairing can be exercised independently.
5. Bundled, versioned dependencies and explicit helper-lost/restart behavior.
6. Consumer-facing domain errors and hidden implementation detail.
7. Treat seven-day expiry as a lifecycle, not a one-time install.

## Do not adopt blindly

1. Open-source `MaxCertsBehavior::Revoke` because it may revoke an unrelated or other-Mac certificate.
2. A consumer certificate-picker prompt. Veya should prove ownership automatically or fail safe.
3. Optional Apple password persistence as the default.
4. A remote anisette dependency without product, privacy, security and availability review.
5. Vanish's arm64-only packaging limitation.
6. Coordinate-only DVT runtime if Veya's Rich runtime remains viable.
7. Any inferred Vanish behavior as if it were observed.

## Bottom line

Vanish does not prove every recovery scenario. It does prove that consumer packaging can separate provisioning/signing from developer-service plumbing and strongly suggests a signing design that avoids Veya's dominant Keychain ACL class. Veya should retain its stronger resource ownership, active/candidate recovery and Rich runtime concepts while replacing the brittle signing execution boundary.

