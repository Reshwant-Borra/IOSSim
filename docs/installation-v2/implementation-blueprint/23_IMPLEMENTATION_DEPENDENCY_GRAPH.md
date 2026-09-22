# Implementation Dependency Graph

```mermaid
flowchart TD
  M0[M0 environment] --> M1[M1 state, events, journal]
  M1 --> M2[M2 reconciliation engine]
  M2 --> M3[M3 production-driven harness]
  M1 --> M4[M4 signing key store]
  M0 --> M5[M5 in-process signer]
  M4 --> M6[M6 auth/team/certificate/profile reconciliation]
  M5 --> M7[M7 profile-sign-install transaction]
  M6 --> M7
  M2 --> M7
  M7 --> M8[M8 IOSSim migration and legacy disable]
  M3 --> M9[M9 device/DDI/pairing/VPN reconciliation]
  M2 --> M9
  M9 --> M10[M10 live runtime readiness]
  M7 --> M10
  M8 --> M11[M11 packaging and legacy removal gates]
  M10 --> M11
  M11 --> M12[M12 automated scenario campaign]
  M12 --> G[Build 12 entry gate]
  G --> M13[M13 create Build 12]
  M13 --> M14[M14 physical qualification]
```

Topological order: M0; M1; M2; M3 and M4/M5 may proceed in parallel; M6; M7; M8 and M9; M10; M11; M12; gate; M13; M14.

The signer does not depend on Apple APIs. Certificate reconciliation depends on the key-store public interface but not signing implementation. Device reconciliation does not depend on certificate internals. Runtime needs both installed candidate identity and device/VPN/pairing proof. Legacy deletion waits for migration plus packaged runtime proof.

