# IOSSim Setup Engine Inventory

Audit baseline: branch `work/investigate-native-app-launch-v1`, HEAD `1259da507ecded222022cc86bf82863c15640db9`, dirty worktree preserved. This inventory describes the tree before the setup-architecture corrections in this task.

## Engine inventory

| Name | File | Entry point | Callers | Build variants | Consumer reachable? | Developer only? | Uses Xcode? | Uses devicectl? | Uses native bridge? | Status |
|---|---|---|---|---|---|---|---|---|---|---|
| `SetupStore` | `macos/Sources/IOSSimMacCore/SetupStore.swift` | `bootstrap`, `refresh`, `continueFromCurrentStatus`, `retryCurrentStep` | SwiftUI app and setup/dashboard views | All Mac GUI variants | Yes; current UI state machine | No | Indirectly when composed with `DevelopmentCLIEngine`; native bundled requests do not need it | Indirectly through legacy engines/backends only | Indirectly through bundled helper | **ACTIVE_CONSUMER; authoritative UI state machine, but not physically authoritative** |
| `BundledProvisioningEngine` | `macos/Sources/IOSSimMacCore/Services/BundledProvisioningEngine.swift` | `live()` | `IOSSimMacApp` under `IOSSIM_BUNDLED_ENGINE` | Packaged/bundled GUI | Yes | No | Its `build()` only runs `verify-artifacts`; its helper doctor probes Xcode only if an Xcode backend was selected | No on the explicitly native composition | Yes, via `IOSSimProvisioner` | **ACTIVE_CONSUMER** |
| `IOSSimProvisioner` helper | `macos/Sources/IOSSimProvisioner/main.swift` | CLI command dispatch; `consumerProvision(..., resume:)` | `BundledProvisioningEngine` | Bundled helper and direct developer invocation | Yes for allowlisted helper commands | Both | Legacy backend and conditional doctor branches contain Xcode paths | Legacy explicit backend exists; native consumer composition does not select it | Yes | **ACTIVE_CONSUMER composition root plus legacy command surface** |
| `ConsumerArtifactProvisioner` | `macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift` | `provision`, `resumeSetup` | `IOSSimProvisioner.nativeConsumerProvisioner` and tests | Helper/all core builds | Yes | No | Legacy `nativeArtifacts == nil` SigningShell branch invokes `xcrun xcodebuild` | Defaults are now native in the dirty tree; historical defaults were devicectl | Yes through injected app service | **ACTIVE_CONSUMER; stale checkpoint resume bug proven** |
| `DevelopmentCLIEngine` | `macos/Sources/IOSSimMacCore/Services/DevelopmentCLIEngine.swift` | `live()` | `IOSSimMacApp` only when `IOSSIM_BUNDLED_ENGINE` is absent | Unbundled developer GUI | Not in packaged app; reachable in a locally unbundled GUI | Yes | Yes: `./iossim setup`, `build`, and `device` paths | Yes in developer CLI device flows | Some CLI diagnostics use native bridge | **DEVELOPER_ONLY, compile-time separated** |
| `ConsumerOnboardingCoordinator` | `macos/Sources/IOSSimMacCore/Services/ConsumerOnboardingCoordinator.swift` | `run(selectedUDID:)` | Tests only | Core library | No production caller | Currently scaffold/test only | No | No | Yes | **DEAD/UNWIRED ASTRA SCAFFOLD** |
| `ReadinessCoordinator` | `macos/Sources/IOSSimMacCore/Services/ReadinessRecovery.swift` | `evaluate(using:)` | Tests only | Core library | No | Scaffold/test only | No | No | Probe-dependent | **UNWIRED ASTRA SCAFFOLD** |
| `SetupJournalStore` | same | `load`, `save` | `ConsumerOnboardingCoordinator`, tests | Core library | Its default file exists, but live `SetupStore` does not read it | Scaffold | No | No | No | **SECOND, NONAUTHORITATIVE STATE ROOT** |
| `RemotePairingCoordinator` | `macos/Sources/IOSSimMacCore/Services/RemotePairingLifecycle.swift` | `ensurePaired` lifecycle | Tests only | Core library | No | Scaffold/test only | No | No | Container delivery uses native app service | **UNWIRED ASTRA SCAFFOLD** |
| `DeveloperSupportCoordinator` | `macos/Sources/IOSSimMacCore/Services/DeveloperSupportCoordinator.swift` | developer support preparation | Tests only | Core library | No | Scaffold/test only | No runtime Xcode dependency intended | No | Intended pinned device services | **UNWIRED ASTRA SCAFFOLD** |
| `MacAssistedRenewalCoordinator` | `macos/Sources/IOSSimMacCore/Services/MacAssistedRenewal.swift` | `plan`, renewal service | Tests only | Core library | No | Scaffold/test only | No | No | Intended | **UNWIRED ASTRA SCAFFOLD** |
| `MockIOSSimSetupEngine` | `macos/Sources/IOSSimMacCore/Services/MockIOSSimSetupEngine.swift` | protocol methods | Tests/previews | Test/debug | No production composition | Yes | No | No | No | **TEST_ONLY** |
| `UnavailableIOSSimSetupEngine` | `macos/Sources/IOSSimMacCore/Services/IOSSimSetupEngine.swift` | failure implementation | App composition error fallback | All | Only when engine construction fails | No | No | No | No | **FAIL-CLOSED FALLBACK** |
| Python `./iossim` CLI | `iossim`, `scripts/bootstrap/iossim_cli.py` | `main`, `command_setup`, `command_build`, etc. | Shell/developer | Repository tooling | Not from bundled production engine except an unbundled `DevelopmentCLIEngine` | Yes | Yes for payload builds and dev device comparison | Yes in developer device paths | Yes for diagnostics | **BUILD_MACHINE_ONLY / DEVELOPER_ONLY** |

## Exact production composition

```text
IOSSimMacApp [IOSSIM_BUNDLED_ENGINE]
  -> BundledProvisioningEngine.live()
  -> SetupStore(engine:)
  -> bundled IOSSimProvisioner helper
  -> IOSSimProvisioner.nativeConsumerProvisioner(context:)
  -> shared NativeApplicationService
       -> NativeApplicationInventoryReader
       -> IdeviceProvisioningBackend
       -> NativeAppServiceLauncher
       -> native House Arrest/AFC container access
  -> DynamicNativeDeviceTransport
  -> iossim-device-bridge C ABI
  -> pinned Rust idevice
```

## Competing roots and reachability verdict

- There is one live packaged-GUI composition root, but more than one conceptual setup architecture in the source tree.
- The alternative `DevelopmentCLIEngine` is compile-time reachable only in an unbundled developer GUI. It is not the packaged product engine.
- The Astra onboarding/readiness/journal/pairing/developer-support/renewal coordinators are not integrated into the live GUI graph.
- `provisioning-state.json` is the live checkpoint source; `setup-journal.json` is a stale, separate, nonauthoritative file.
- Legacy Xcode/devicectl implementations may remain for explicit developer comparison, but consumer composition must fail closed against selecting them.

