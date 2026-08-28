# iPhone On-Device DVT Research

Research date: 2026-08-26

This folder prepares a future IOSSim proof of concept for an architecture where a Mac is used only once for trust/pairing/provisioning, then the stock non-jailbroken iPhone runs the location simulation path itself.

Target runtime:

```text
Mac: powered off

iPhone
  -> IOSSim iOS component
  -> local virtual network path
  -> authenticated RemotePairing developer tunnel
  -> RSD / DVT
  -> com.apple.instruments.server.services.LocationSimulation
  -> system Core Location
```

Key verdict: GO WITH RISKS for a narrow Mac-once, Wi-Fi cold-start POC. Static simulation is physically demonstrated, and the basic experimental on-device Drive POC is now physically demonstrated in foreground testing. Drive cadence, speed reporting, background behavior, long-duration locked-screen execution, and cellular scenarios remain under investigation.

Documents:

- [ARCHITECTURE.md](ARCHITECTURE.md) - canonical architecture overview and current physical validation status
- [00_GOAL_AND_ACCEPTANCE_CRITERIA.md](00_GOAL_AND_ACCEPTANCE_CRITERIA.md)
- [01_CURRENT_IOSSIM_BASELINE.md](01_CURRENT_IOSSIM_BASELINE.md)
- [02_PRIOR_FINDINGS.md](02_PRIOR_FINDINGS.md)
- [03_APPLE_PROTOCOL_STACK.md](03_APPLE_PROTOCOL_STACK.md)
- [04_RPPAIRING_RESEARCH.md](04_RPPAIRING_RESEARCH.md)
- [05_LOCALDEVVPN_RESEARCH.md](05_LOCALDEVVPN_RESEARCH.md)
- [06_LOCUS_AUDIT.md](06_LOCUS_AUDIT.md)
- [07_MIRAGE_AUDIT.md](07_MIRAGE_AUDIT.md)
- [08_OTHER_OPEN_SOURCE_PROJECTS.md](08_OTHER_OPEN_SOURCE_PROJECTS.md)
- [09_COMMERCIAL_ARCHITECTURE_EVIDENCE.md](09_COMMERCIAL_ARCHITECTURE_EVIDENCE.md)
- [10_CELLULAR_COLD_START.md](10_CELLULAR_COLD_START.md)
- [11_PERSISTENCE_AND_REBOOT.md](11_PERSISTENCE_AND_REBOOT.md)
- [12_SECURITY_AND_ENTITLEMENTS.md](12_SECURITY_AND_ENTITLEMENTS.md)
- [13_ALTERNATIVE_ARCHITECTURES.md](13_ALTERNATIVE_ARCHITECTURES.md)
- [14_EXPERIMENT_PLAN.md](14_EXPERIMENT_PLAN.md)
- [15_IMPLEMENTATION_OPTIONS.md](15_IMPLEMENTATION_OPTIONS.md)
- [16_RISK_REGISTER.md](16_RISK_REGISTER.md)
- [17_SOURCE_LEDGER.md](17_SOURCE_LEDGER.md)
- [18_OPEN_QUESTIONS.md](18_OPEN_QUESTIONS.md)
- [19_RECOMMENDED_POC.md](19_RECOMMENDED_POC.md)
- [20_POC_IMPLEMENTATION_NOTES.md](20_POC_IMPLEMENTATION_NOTES.md)
- [21_POC_TEST_RESULTS.md](21_POC_TEST_RESULTS.md)
- [22_CELLULAR_COLD_START_FINDINGS.md](22_CELLULAR_COLD_START_FINDINGS.md)
- [23_E1_PHYSICAL_TEST_PROCEDURE.md](23_E1_PHYSICAL_TEST_PROCEDURE.md)
- [24_IDEVICE_IOS_BUILD_NOTES.md](24_IDEVICE_IOS_BUILD_NOTES.md)
- [25_SESSION_PERSISTENCE_FINDINGS.md](25_SESSION_PERSISTENCE_FINDINGS.md)
- [26_DIAGNOSTIC_RECORDER.md](26_DIAGNOSTIC_RECORDER.md)
- [DRIVE_MODE_IMPLEMENTATION.md](DRIVE_MODE_IMPLEMENTATION.md) - experimental on-device Drive Mode implementation, diagnostics, and physical test procedure

Do not place real pairing records in this folder. The folder-local `.gitignore` blocks the known file names and extensions observed in Locus, Mirage, and RPPairing tools, but future POC code must add ignores at its own artifact paths before generating secrets.
