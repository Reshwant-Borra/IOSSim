# M3 Result

Status: **PASS** (AUTOMATED_PROVEN). Build remains `11`.

## Architecture

`VeyaQualify` and the future UI client (`ProvisionerEngineClient`) send one versioned `EngineRequest` to `IOSSimProvisioner engine --request <json>`. The helper composes `VeyaReconciliationEngine` exactly once (`EngineHost`) and prints one `QualificationResult`; its process exit equals the result's exit class (0/2/3/4/5/6/64/70). Mutating commands require a `CapabilityManifest`; without one the helper refuses (`VEYA-SEC-010`). `--stage` narrows the desired state to a domain and its prerequisites (`InstallationDomain.reconciliationOrder`).

Scenario fixtures describe only the simulated external world (observations, side effects, injected failures, crash points). Planning, journal, proof binding, promotion, READY, resume, and lease recovery are the production engine. Fixture worlds are compiled only under `VEYA_QUALIFICATION` (debug); release helpers refuse scenarios (`VEYA-SEC-011`). Fixture bytes are digest-bound (`VEYA-SEC-012`).

## Evidence

| Gate | Result |
|---|---|
| Scenarios through real helper process | 7/7 PASS (fresh+Trust user action, crash after certificate issue then resume adopts instead of re-issuing, dead run lease expiry, capability refusal, reconnect invalidates connection-bound proof, bounded retry, terminal first failure) |
| UI-client vs CLI scenario trace | byte-identical (`testScenarioTraceIsByteEquivalentForUIClientAndCLI`) |
| Deterministic JSON | identical bytes for identical requests on fresh state roots |
| Exit codes | usage 64, protocol 70, refusal 6, user action 2, product failure 5 asserted |
| Read-only commands | inspect/plan/verify create no journal, directory, or lock |
| Structural guard | client sources contain no engine/planner/journal/transition/promotion/codesign/SecIdentity references; engine constructed only in `ProvisionerProtocol.swift` |
| Secret-free output | scenario reports scanned for credential/key markers |
| Release helper | refuses scenario; no fixture-injection symbols in binary |
| Full Swift | 425 executed, 14 skipped (pre-existing classified), 0 failed |

## Limitations

- Production composition has no domain observers yet; results list each such domain under `skippedProofs`. Owning milestones add them.
- Packaged `.app` helper execution is exercised at M11 packaging; M3 used the built helper binary (release and debug).
- `tools/qualification/VeyaPhysicalQualification.py` has no orchestration logic (report collector only); converted to a `VeyaQualify` wrapper at M14.
