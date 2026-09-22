# Root-cause clustering

## Root-cause verdict

The answer is **I: multiple factors**, dominated by D, E, C, and B. Some physical discovery was unavoidable, but most sequential builds were avoidable as separate DMG discoveries.

| Factor | Evidence-weighted contribution across Builds 1-11 | Confidence | Explanation |
| --- | --- | --- | --- |
| A. unavoidable physical integration discovery | 2/11 builds materially | medium | Gatekeeper/process identity and Apple service/device behavior need physical proof. They did not require eleven serial artifacts. |
| B. inadequate test coverage | 9/11 cross-cutting | high | opt-in Keychain tests were skipped by default; fakes did not run production engine; no actual shipped signer harness; no packaged stage runner; no clean-Mac automation. |
| C. incorrect abstraction boundaries | 7/11 | high | setup orchestration, identity store, codesign process authorization, metadata, and certificate lifecycle are entangled; UI/helper/tests own parallel flows. |
| D. brittle Keychain/signing architecture | 7/11 | high | Builds 1, 7, 8, 9, 10, 11 and related retries involve key location, ACL, partition, identity formation, metadata or codesign access. |
| E. incomplete state-machine design | 6/11 | high | no single active/candidate transaction spans metadata/key/cert/profile/signing; READY and resume exist in overlapping representations. |
| F. IOSSim migration contamination | 5/11 | high | legacy service names, key labels/tags, Application Support roots and certificate markers are still active product contracts without one migration inventory. |
| G. development-Mac contamination | 5/11 | high | login-Keychain ACL history, Xcode, cached DDI, installed apps and successful Sep 15 state made local tests/flows pass non-clean paths. |
| H. packaging differences | 3/11 | medium | packaged process cdhash, helper path, ad-hoc signing and quarantine differ from `swift test`; clean release packaging is still unqualified. |

Counts overlap and are diagnostic, not percentages that sum to 100. Evidence for Builds 4-6 is weaker, so the counts intentionally use ranges of causation rather than claiming a precise statistical model.

## Cluster 1: process-authorized signing identity

Current signing readiness requires all of these to align:

```text
SecKey in Veya-Signing keychain
+ SecCertificate in same keychain
+ SecIdentity formation
+ keychain in user's global search list
+ Veya/helper trusted-application ACL
+ ChangeACL rights
+ apple-tool/apple/codesign partition list
+ /usr/bin/codesign sees identity by fingerprint
+ packaged process cdhash and execution context match expectations
```

Each patch changed one term. The next artifact exposed another. The central assumption, “a dedicated Keychain makes `/usr/bin/codesign` prompt-free,” is false without further conditions, and those conditions are implementation- and packaging-sensitive.

## Cluster 2: split identity truth

Identity truth is distributed among Apple certificate inventory, a SecKey, a certificate item, active metadata, candidate metadata, an installation ID, a recovery intent, profiles, cached native artifacts, and provisioning state. Different builds changed the visibility/storage of individual pieces. Missing metadata, missing key, stale certificate, and quota exhaustion are therefore not exceptional cases; they are ordinary Cartesian combinations the architecture must reconcile.

## Cluster 3: parallel orchestration and readiness

`SetupStore`, `ConsumerArtifactProvisioner`, `IOSSimSetupEngine`, `ConsumerProvisioningStateStore`, Apple diagnostics, `ConsumerOnboardingCoordinator`, and the qualification test harness encode overlapping stage order and recovery. No single transition contract forces UI, CLI, tests, and production to agree. The live matrix can say Build 3 while Build 11 is installed because it is an independent report generator rather than the engine's run ledger.

## Cluster 4: tests that prove local logic, not shipped behavior

The suite has valuable cryptographic parsing, API fixture, lifecycle, transport, and repair tests. Its weakest areas are exactly the physical failures:

- Real Keychain tests are opt-in and development-host contaminated.
- Packaged helper/app process identities are not reproduced by ordinary test processes.
- `HermeticInstallationHarnessTests` implements a private miniature engine rather than injecting faults into production transitions.
- Signing tests do not qualify the exact complete release path on a synthetic nested iOS app.
- The Python live harness runs baseline/device/hash/secret scan, not setup stages.
- Screenshots and manually named files are not correlated to a run ID/stage/event.

## Cluster 5: legacy and host contamination

The product is branded Veya but retains IOSSim bundle IDs, Application Support directories, key labels, tags, helper/executable names, payload IDs, diagnostics and script assumptions. Retention can be correct for compatibility; unclassified retention cannot. The development Mac also carries successful prior state, Xcode services and historical ACL decisions, so “works here” often means “reused something a clean consumer does not have.”

## Why failures arrived one at a time

1. The flow is gated. A failure at identity creation prevents profile signing, which prevents install, which prevents DDI/pairing/VPN/runtime validation.
2. Fixes were local and stateful. The next run inherited old Apple certificates, keys, metadata and pairing state, creating a different scenario rather than replaying a controlled one.
3. The abstraction boundary was misplaced. Veya tested `SecKey` creation and identity lookup while the actual contract was “the separately launched packaged codesign process can sign without UI.”
4. Tests used alternate implementations or mocks. Green tests proved their fixtures and local test process, not the packaged state machine.
5. Evidence was not run-correlated. `UNEXPECTED_ERROR`, stale matrices and misleading screenshots made the first failing operation uncertain.
6. Physical qualification was depth-first on one contaminated Mac. It never built a scenario matrix across clean, reinstall, upgrade, multi-Mac and expiration cases.

The sequential pattern was therefore not eleven unrelated surprises. It was a predictable consequence of a gated flow, brittle signing boundary, incomplete reconciliation model, and qualification system that did not exercise the shipped code stage-by-stage.

