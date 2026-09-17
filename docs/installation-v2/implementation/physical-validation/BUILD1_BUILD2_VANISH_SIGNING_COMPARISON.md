# Build 1 vs Build 2 vs Vanish — signing and certificate lifecycle

Companion to [`PHYSICAL_DEFECT_002_CERTIFICATE_RECOVERY_PLAN.md`](PHYSICAL_DEFECT_002_CERTIFICATE_RECOVERY_PLAN.md).

Purpose: locate the **lifecycle** difference between the two builds and the
behavioural reference, not merely the line that threw the certificate-limit error.

No proprietary Vanish source is reproduced here. No credentials were reverse
engineered and no security control was bypassed. Every Vanish claim is tagged
OBSERVED, INFERRED or UNKNOWN, and the inferred claims come from a **vendored public
checkout of the upstream `isideload` crate**, which the research identified as the
library compiled into `VanishSideloader` — not from Vanish's own binary.

## Evidence provenance and its limits

| body of text | what it is | weight |
|---|---|---|
| `VanishedResearch.mSgdHk/REPORT.md`, `EVIDENCE.md`, `DOCUMENTATION/` | static analysis of Vanish v3.2.1 | **OBSERVED** for Vanish |
| `docs/installation-v2/vanish-reference/` | Veya's target architecture, *informed by* Vanish | Veya design, **not** Vanish evidence |
| `docs/installation-v2/23_`, `24_`, `27_` | Veya's own models | Veya design, **not** Vanish evidence |
| `VanishedResearch.mSgdHk/FINAL_PREIMPLEMENTATION/references/isideload/` | vendored public upstream crate | **INFERRED** for Vanish |

The vendored checkouts are commits `b6d1113` and `f6a4d5d`. The abbreviated commit
found in Vanish's binary is `3c1a008` — a **different** commit. `REPORT.md:144` warns
that "binary provenance may still include downstream modifications." Upstream source
therefore corroborates inference about Vanish; it does not observe Vanish.

`docs/installation-v2/evidence/RESEARCH_LEDGER.md:3` — "No device interaction, Apple
authentication, Keychain queries, source builds, or production edits were performed."

## Three-way comparison

| | Build 1 | Build 2 | Vanish |
|---|---|---|---|
| Apple auth | works (OBSERVED) | works (OBSERVED) | works (OBSERVED) |
| Team discovery | works | works | works |
| Device registration | works | not reached | works |
| App IDs | works | not reached | works |
| Profile creation | works, main + runner | not reached | works |
| Key generation | RSA 2048, `SecKeyCreateRandomKey` | same | RSA 2048, software |
| Key storage | **login Keychain** | **Veya-owned Keychain** | keychain generic-password blob (INFERRED) |
| Signing mechanism | `/usr/bin/codesign` + `SecIdentity` | same | **in-process** `apple-codesign` (INFERRED) |
| Keychain prompt | **yes, three times** | none by design | structurally impossible (INFERRED) |
| Certificate request | `ios/submitDevelopmentCSR` | same | `submitDevelopmentCSR` (OBSERVED) |
| Certificate reuse | by public-key match | by public-key match | by public-key match (INFERRED); policy UNKNOWN |
| Certificate ownership | fingerprint + serial, local only | fingerprint + serial, local only | `machineName`/`machineId` sent to Apple (INFERRED); local ledger UNKNOWN |
| Certificate-limit handling | not reached | **terminal throw** | `max_certs` event + user response (OBSERVED); outcome UNKNOWN |
| Revocation | none | none | upstream supports revoke-then-retry (INFERRED); Vanish behaviour UNKNOWN |
| Signing authorization | trusted-app ACL, futile | trusted-app ACL, no partition list | none required (INFERRED) |
| codesign usability proof | **none** | **yes, every identity and reuse** | not applicable |
| Repair | ACL repair — structurally futile | fresh candidate on probe failure | UNKNOWN |
| Upgrade | n/a | metadata readable across builds | UNKNOWN |
| Renewal | not reached | not reached | re-signs every seven days (OBSERVED) |

## Responsibility table

| responsibility | Vanish observed behaviour | evidence | Veya current behaviour | difference | relevance |
|---|---|---|---|---|---|
| Certificate creation | submits a CSR to Developer Services | `REPORT.md:223` STRONG_EVIDENCE | identical | none | none |
| Certificate reuse | reuse messages present; **policy UNKNOWN** | `REPORT.md:224` | reuse gated on public-key match | none observable | low |
| Certificate limit | emits a `max_certs` event and consumes a `max_certs_response` **from the UI** | `05_VANISH_APPLE_PROVISIONING_ANALYSIS.md:3`; `EVIDENCE.md:17` E09; `REPORT.md:225` | throws terminally | **Vanish has a control path; Veya has none** | **decisive — this defect** |
| Certificate revocation | **UNKNOWN** whether it occurs | `03_APPLE_AUTH_PROVISIONING_SIGNING.md:98` | none | cannot be compared | high |
| Certificate ownership ledger | **not established** | — | fingerprint + serial persisted locally | Veya may in fact be *ahead* here | medium |
| Signing-key persistence | Keychain generic-password imports | `EVIDENCE.md:15` E07; `REPORT.md:230` residency UNKNOWN | `SecKey` in a Veya-owned Keychain | **architectures differ fundamentally** | **high** |
| Signing execution | no Xcode signing subprocess found | `REPORT.md:229` | `/usr/bin/codesign` subprocess | **Vanish structurally avoids Defect 001** | **high** |
| Seven-day lifecycle | re-signs; does not defeat expiry | `03_APPLE_AUTH…:11` DISPROVEN | same intent | none | low |
| Multi-Mac, same Apple ID | **no evidence of any kind** | `REPORT.md:782`, `:768` | undefined before this plan | both undefined | **high** |
| User prompting | hidden except at the certificate limit | `06_UX…:57`; `01_VANISH_CONSUMER_SETUP_FLOW.md:35` | hidden; limit is a dead end | Veya lacks the one prompt Vanish has | medium |

## The lifecycle difference

Build 1 and Build 2 differ in **where the signing key lives**. That is a local
Keychain question and it is now settled.

Build 2 and Vanish differ in **how signing is executed** — `SecIdentity` plus
`/usr/bin/codesign` versus an in-process signer over a key blob. That single choice
determines whether Defect 001 is possible at all, and whether a key is portable
between Macs.

Build 2 and Vanish differ again in **whether the certificate limit has an exit**.
Vanish has a control path that reaches the user. Veya has a throw. That is Defect 002,
and it is independent of the signing-execution question.

The recommended architecture closes the third difference without reopening the first,
and records the second as a documented future option rather than Build 3 scope.

## What the Vanish research does not establish

Stated plainly, so no later reader mistakes inference for observation:

- Whether Vanish revokes certificates at all.
- Which certificate it would select.
- Whether its revocation succeeds, and what it does to installed apps.
- Vanish's `machine_name` value, and therefore whether two Macs produce
  distinguishable certificates.
- Whether Vanish keeps any certificate ownership record locally.
- Vanish's actual certificate count, reuse policy, or key export policy.
- **Anything at all about multi-Mac use on one Apple Account.**

A "PKCS#12 handling vocabulary" note in `REPORT.md:230` must not be read as evidence
that Vanish persists a `.p12` on disk. In upstream, the PKCS#12 path exists for
AltStore/SideStore interop, not for the crate's own key persistence.

Where evidence is insufficient, the plan does not borrow a Vanish behaviour. It falls
back to Veya's own ownership proof and fails safe.
