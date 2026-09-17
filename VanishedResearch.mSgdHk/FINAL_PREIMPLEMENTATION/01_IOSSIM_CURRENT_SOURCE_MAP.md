# IOSSim Current Source Map

Status: CONFIRMED from HEAD 0a18e986f40fd877a1aab1e91e4c6a87217c7c81 on 2026-09-14. Relative paths in this document are rooted at /Users/rishiborra/Desktop/IOSSim. Revision and external citations: [source register](SOURCE_REGISTER.md).

## Repository State

| Item | Observed |
| --- | --- |
| Branch | work/fix-apple-srp-503 |
| HEAD | 0a18e986f40fd877a1aab1e91e4c6a87217c7c81 |
| HEAD subject | Fix Apple GrandSlam SRP 503 rejection |
| Local origin/main | ed233af070f5b751c22f6d8b9f86f4fc01885ce7 |
| Tracked status | Clean |
| Untracked | VanishSetup.dmg; tools/ |
| Worktrees | Only /Users/rishiborra/Desktop/IOSSim |
| Research mutation | None in IOSSim; output is outside repository |

The old branch/commit in docs/CURRENT_STATE.md is historical, not the current checkout. Do not adopt it as the implementation base. Do not use tools/iossim-pairing-helper/target binaries as a dependency: no corresponding helper source is present outside target.

## Existing Boundaries

SwiftUI SetupStore -> IOSSimSetupEngine -> BundledProvisioningEngine -> signed IOSSimProvisioner -> native Apple auth / signing / device operations. A separate DevelopmentCLIEngine reaches the Python bootstrap workflow. Consumer auth backend selection and device backend selection are separate: selecting consumer-native auth does NOT select a functional native device backend.

The device protocol is already named DeviceProvisioningBackend. Extend it and implement IdeviceProvisioningBackend; do not introduce a second competing DeviceBridge API. AppleDeviceTool is currently a static facade. DeviceApplicationInventoryReading is a separate injected inventory interface which should become an adapter over the same native backend.

## Host Device Source Map

| Feature | File | Type / function / anchor | Current dependency | Desired abstraction |
| --- | --- | --- | --- | --- |
| Backend selection | macos/Sources/IOSSimMacCore/Services/RuntimeProvisioningSupport.swift | ProvisioningBackendKind.selected, line 86; factory 125 | defaults devicectl | native-only consumer selection |
| Device interface | same | DeviceProvisioningBackend, 106 | discover, ID mapping, count/install only | typed full device session operations |
| Native placeholder | same | IdeviceProvisioningBackend, 137 | system_profiler USB JSON; install exits 78 | Rust usbmux/lockdown backend |
| USB/wireless enumeration | same | DevicectlProvisioningBackend.discoverDevices, 257 | devicectl list devices | usbmux list/listen; paired Bonjour discovery |
| Selected identifier -> connection selector | same | rawDeviceIdentifier, 330 | repeat devicectl list + readiness filter | DeviceIdentity + verified DeviceSession |
| Selector -> signing UDID | same | signingDeviceIdentifier, 385 | repeat devicectl list | lockdown UniqueDeviceID |
| Device lock | same | deviceLockState, 497 | devicectl info lockState | lockdown PasswordProtected / service errors, tri-state |
| Trust / Developer Mode | same | discoverDevices, rawDeviceIdentifier | devicectl property strings | lockdown session validation; AMFI query |
| Model / OS / connection | same | discovery parsers | CoreDevice JSON hardware/properties | lockdown ProductType/ProductVersion/BuildVersion + usbmux transport |
| Installed count | same | installedAppCount, 422 | devicectl info apps | installation_proxy Lookup/Browse |
| Install | same | install, 470 | devicectl install app | AFC staging + installation_proxy |
| Authoritative inventory | macos/Sources/IOSSimMacCore/Services/InstallationInventory.swift | DevicectlApplicationInventoryReader.read, 54 | direct devicectl, not AppleDeviceTool | same bridge, exact bundle IDs and selected device |
| Fresh install removal | macos/Sources/IOSSimMacCore/Services/ConsumerArtifactProvisioner.swift | uninstallExistingConsumerApps, vicinity 517 | direct devicectl uninstall | installation_proxy Uninstall, explicit destructive consent |
| Install pipeline | same | installArtifacts 945; install 1052 | AppleDeviceTool plus inventory reader | install/upgrade result plus authoritative verification |
| Main app launch | same | launchMainForRuntimeConfiguration 1111 | direct devicectl process launch | CoreDevice AppService over RSD |
| Container readback | same | verifyPersistedRunnerMapping 1204 | direct devicectl copy from Library/Preferences | House Arrest VendContainer + AFC exact plist |
| Mapping production | same | bundleInfo 1275, runner mapping packaging | signed Info.plist, app first launch | keep mapping; add versioned app acknowledgment |
| DDI / AMFI / RemotePairing | native consumer host | No complete implementation | delegated to Apple's tooling or manual setup | explicit host developer-support/pairing services |
| Device diagnostics | macos/Sources/IOSSimProvisioner/main.swift | doctor 233; --find devicectl 263 | Xcode probes + AppleDeviceTool | structured ReadinessEngine snapshot |
| Selection policy | macos/Sources/IOSSimMacCore/DeviceSelectionPolicy.swift | DeviceSelectionPolicy | CoreDevice-derived DetectedDevice | migrate selection token without changing UX unnecessarily |

Unknown lock state currently can remove a device from discovery. In doctor, nil lock can be displayed as unlocked. Both must change: retain discovered devices and show UNKNOWN until a reliable observation exists. UDID, CoreDevice UUID, RSD UUID, usbmux numeric ID and RP host identifier are not interchangeable.

## Apple Provisioning Source Map

| Feature | File | Type / function | Current dependency | Desired abstraction |
| --- | --- | --- | --- | --- |
| Consumer backend selection | Services/ConsumerProvisioningBackend.swift | policy / resolver | native versus invisible/fallback Xcode | native consumer, development compatibility explicitly separate |
| Authorization coordinator | Services/ApplePersonalTeamLive.swift | LiveApplePersonalTeamBackend, 2162 | local GSA and Developer Services | keep, bounded adapter corrections |
| HTTP | same | BoundedAppleHTTPTransport, 285 | URLSession ephemeral, host allowlist | keep TLS; explicit endpoint/header policy and safe diagnostics |
| Machine metadata | same | LocalMacAppleMachineIdentityProvider, 422 | AOSKit then AuthKit private system frameworks | normalize both outputs at final request boundary |
| SRP primitives | same | AppleSRPClient, 611 | BigInt, CryptoKit/CommonCrypto | preserve until differential vectors establish changes |
| Account normalization | same | beginAuthorization, 2248 | trim + lowercase | make reference parity explicit; do not log account |
| SRP init diagnostic | same | diagnoseSRPInitialization, 2331 | real init without password | extend existing harness, never run automatically |
| Init/complete/SPD | same | authenticate, 2372 | GSA plist/SRP | keep; adapter tests and proof vectors |
| 2FA | same | trusted-device request / validateVerification | fixed endpoints, POST validation | URL bag; GET trusted-device validation; explicit SMS handling |
| App token | same | appTokens, 2663 | encrypted xcode audience token | keep local; no token in JSON IPC |
| Team/account session | same | resumeSession 2217, listTeams / developerRequest 2769 | Keychain + developerservices2 | preserve valid session on transient errors |
| Device registration | same | registerDevice 1324, listRegisteredDevices 1485 | Developer Services | reuse exact UDID/team, idempotent reconciliation |
| Signing identity | same | prepareIdentity 1028; createManagedIdentity 1157; requestDevelopmentIdentity 1185 | Security Keychain, CSR, certificate API | reuse valid managed key/cert |
| CSR | same | CSR construction near 1860 | Security RSA signing / DER | keep; test CSR and certificate-key match |
| App IDs / profiles | same | registerIdentifiers 1520; obtainProfiles 1561 | Developer Services | keep deterministic IDs and entitlement checks |
| Protocol constants | Services/ApplePersonalTeamExperimental.swift | PrivateAppleProtocolAdapter, 846 | research-2026-09-akd; GSA / QH65B2 | versioned adapter, final header validation |
| Session persistence | Services/ApplePersonalTeamLive.swift | keychain-backed opaque session | dsid/token/expiry | keep Keychain only, typed invalidation |
| Identity resolver | Services/NativeSigningIdentityResolver.swift | NativeSigningIdentityResolver | Security private-key reference | keep, no general export |
| Artifact persistence | Services/NativeProvisioningArtifactStore.swift | artifact store | local profiles/metadata | integrate journal, preserve valid artifacts |
| Compatibility discovery | Services/ApplePersonalTeamDiscovery.swift | local identity/profile discovery | Keychain; Library/MobileDevice/Provisioning Profiles | development-only fallback, not required consumer state |
| Actual signing | Services/ConsumerArtifactProvisioner.swift | prepareArtifacts 571; signMain/signRunner/signBundle 800-840 | /usr/bin/codesign, security cms | keep macOS built-ins; remove signing-shell Xcode fallback |
| Old signing shell | same | buildSigningShell 772; SigningShellBuildArguments 1763 | xcrun xcodebuild automatic signing | deprecate from consumer target |

Services/ paths above are under macos/Sources/IOSSimMacCore/. ApplePersonalTeamLive's signArtifacts/installArtifacts facade methods are not substitutes for ConsumerArtifactProvisioner's real installation/signing workflow. Audit implementation reachability, not just method names.

## State / IPC / UX

| Feature | File | Existing role | Target |
| --- | --- | --- | --- |
| Consumer orchestration | macos/Sources/IOSSimMacCore/SetupStore.swift | UI progress/actions and string error interpretation | UI adapter over health/recovery, retain observable model |
| Process boundary | Services/BundledProvisioningEngine.swift | controlled IOSSimProvisioner requests | preserve; version capabilities and streaming safe events |
| Engine contract | Services/IOSSimSetupEngine.swift | doctor/setup/install/resume/status/confirm runtime | extend for pairing, observation, renewal; no manual READY assertion |
| Persistence | Services/ConsumerProvisioningStateStore.swift | manifest JSON, event JSONL | migrate to versioned per-device setup journal |
| Refresh serialization | same | ConsumerRefreshCoordinator.begin/end | extend with renewal actor and per-device workflow lock |
| Consumer domain models | Models/ConsumerProvisioning.swift | checkpoints, errors, manifest | typed per-layer evidence and safe error mapping |
| Doctor models | Models/DoctorStatus.swift | PASS/action checks; tooling text classification | project structured health without treating nil as ready |
| Artifact contract | Models/ArtifactManifest.swift | payload roles/digests/IDs | add bridge/receipt schema compatibility; keep signing contract |
| Support | Services/SupportBundleExporter.swift; Redactor.swift | log export and xcodebuild diagnostic | allowlisted safe facts; no raw protocol dumps |
| Fault injection/tests | Services/ConsumerProvisioningFaultInjection.swift; macos/Tests/IOSSimMacCoreTests | synthetic errors and regression tests | extend rather than discard |

## Frozen iPhone Runtime Map

Root: ios/Sources/IOSSimOnDeviceDVTPOC/.

| Feature | File / function | Current dependency | Allowed change |
| --- | --- | --- | --- |
| External VPN prerequisite | ios/DEPENDENCIES.md; DeveloperRouteProbe.swift; BackgroundSessionKeeper.swift | separately installed LocalDevVPN, not bundled by IOSSim | readiness observation only |
| Pairing storage | PairingStore.swift: KeychainRPPairingStore; RPPairingUpdatePersistence | Keychain AfterFirstUnlockThisDeviceOnly, primary account | add ingress coordinator; retain storage/update semantics |
| Pairing parse | RPPairingValidator.swift | 32-byte public/private keys, nonempty identifier, optional 16-byte alt_irk | strengthen ingress validation without changing runtime format |
| Tunnel/RSD/DVT | DvtLocationClient.swift: IdeviceOnDeviceTunnelClient.connect / connectWithIdevice | pinned idevice FFI; LocalDevVPN | frozen |
| XCTest setup | same: startGate3OnDeviceXCTest / startRichDriveOnDeviceXCTest / startOnDeviceXCTest | retained RSD/TestManager, patched FFI | frozen |
| Runner mapping | same: RunnerBundleIdentifierResolver | IOSSimGate3RunnerBundleIdentifier in Info/UserDefaults | preserve; verify via setup receipt |
| Writer ownership | LocationCoordinator.swift | actor + connection/session generations | frozen |
| Rich transport/fallback | DriveLocationTransport.swift | XCTest rich transport, bounded latest sample, DVT fallback | frozen |
| Drive intent | DriveSessionController.swift | start/pause/resume/hold/stop/destination hold | frozen |
| Timing | DriveScheduler.swift; DriveTiming.swift | default smooth2Hz, 0.5s period, cadence fallback | frozen |
| Rich sample semantics | RichDriveLocation.swift; RouteResampler.swift | speed/course/heading, route interpolation | frozen |
| Runner | ios/Tests/LocationControl/AppleXCUILocationControlUITests.swift | XCUILocation(location:).simulate() | frozen |
| Native dependency | ios/Vendor/idevice; ios/scripts/build_idevice_ios.sh | c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5 + 0001-gate2-supplied-rsd-xctest-ffi.patch | freeze pin, patch and C ABI |
| Phone setup UI | ios/App/POCViewModel.swift; SetupView.swift; SettingsView.swift; app entry | manual file import | change only onboarding/import composition |

The existing iOS deployment target is 17.0; it is not proof every supported protocol works on 17.0. Proposed first native-host product floor is iOS 17.4, with iOS 18 and 26 qualification cells; do not change runtime algorithms or silently claim all point releases supported.

## Development-Only Architecture

backend/device_manager.py, location_service.py, wireless_location/{discovery,session,controller,store}.py use Python/pymobiledevice3 for older host experiments. backend/debug and wireless_testing are diagnostic/research paths, not the frozen phone runtime. scripts/bootstrap/iossim_cli.py builds iPhone payloads, Mac universal products and release/notarization artifacts. Their build-time Xcode use is legitimate. Do not package them as consumer fallbacks.

The exhaustive lexical search is in [DEPENDENCY_SEARCH_APPENDIX.txt](DEPENDENCY_SEARCH_APPENDIX.txt); the operation-level inventory follows in [02](02_DEVICETCTL_REPLACEMENT_SPEC.md).

