# Blueprint Consistency Audit

## Resolved checks

| Concern | Resolution |
|---|---|
| Two setup engines | `VeyaReconciliationEngine` only; UI/CLI are provisioner clients |
| Two persistent truths | journal is product truth; event log diagnostic; external systems re-observed |
| Main/helper write ownership | packaged provisioner is sole journal/secret writer |
| Device abstraction duplication | one Swift `DeviceTransport` over one Rust ABI |
| Signer/key ownership | Swift key store and Rust signing core, plaintext only within provisioner process/FFI call |
| Candidate versus iOS replacement | journal promotion is logical; retain prior signed payload for compensating reinstall |
| Certificate ownership | SPKI control + account/team evidence; metadata alone never enough |
| Auth versus signing secrets | separate services/items/wrapping domains |
| Pairing service-name conflict | read both legacy names, write one v2 name |
| READY sources | only fresh full-chain `RuntimeReadinessEvidence` |
| Failure code conflicts | single registry in doc 19; codes never generated ad hoc |
| Test-only production logic | fakes at interfaces; harness calls production engine |
| Old signer fallback | expressly prohibited; readers only under migration |
| Build 12 ambiguity | separate human authorization after M0-M12 binary gates |
| Rust/Cargo contradiction | installed and passing by rustup path; PATH/rustfmt/pin remain M0 |
| DDI certainty | production source not claimed solved; enumerate supported builds/block gate |

## Source of truth hierarchy

1. Live external observation for Apple/device/runtime truth.
2. Valid journal for ownership, intent, generation, and recovery.
3. Immutable artifact manifests and cryptographic evidence.
4. Events/support reports for explanation only.
5. Legacy state as migration evidence only.

## Defined unknowns

| Unknown | Why it matters | Resolution | Can implementation begin? |
|---|---|---|---|
| Data-protection Keychain access across real signed upgrades/Intel | no-prompt key unwrap | M4 packaged clean/upgrade matrix | Yes through M3; M4 cannot exit without it |
| `isideload-apple-codesign` exact Veya nested bundle behavior | install acceptance | M5 golden + device install/launch | Yes; do not route production before proof |
| Production DDI source/SLA for future iOS builds | clean-Mac developer services | M9 provider decision/catalog qualification | Yes with explicit supported-build scope |
| Current Apple private API longevity | auth/provisioning reliability | hermetic schema drift + authorized live campaign | Yes; external ongoing risk |
| Intel clean-machine packaged behavior | architecture/release support | M11/M12 Intel host run | Yes; blocks Build 12 if Intel remains claimed |
| Second-Mac Apple capacity behavior in all account states | safe reuse/revocation | hermetic matrix then controlled physical case | Yes; unknown case fails safe |

## Audit verdict

No circular dependency, undefined secret owner, dual-write requirement, or old-signer fallback remains. The foundation is implementation-ready with named external/physical gates. Document 32 is authoritative if wording elsewhere is ambiguous.

