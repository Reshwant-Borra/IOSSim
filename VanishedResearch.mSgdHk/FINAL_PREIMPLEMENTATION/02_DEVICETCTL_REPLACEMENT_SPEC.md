# Complete devicectl Replacement Specification

This is the consumer-operation inventory. The source search appendix contains every lexical hit; this table distinguishes consumer runtime from build, diagnostics, tests and legacy paths. Candidate means the implementation target, not a physical qualification claim.

## Definitive Matrix

| IOSSim Operation | Current Implementation | Apple/Xcode Dependency | Required Replacement | Candidate Protocol | Candidate Library | Confidence | Risk |
|---|---|---|---|---|---|---|---|
| USB iPhone discovery | RuntimeProvisioningSupport Devicectl backend; native placeholder uses system_profiler | devicectl/CoreDevice for authoritative identity | enumerate usbmux then open Lockdown and read properties | usbmuxd ListDevices/Listen, Lockdown GetValue | Rust idevice usbmuxd/lockdown | CONFIRMED source | usbmux daemon/USB reconnect behavior |
| Wireless discovery | CoreDevice state and Python development probes | Xcode CoreDevice for consumer | discover paired RP endpoints, authenticate and identify before showing ready | Bonjour/mDNS, RemotePairing, RSD | idevice mdns/remote_pairing/rsd | STRONG_EVIDENCE | network interfaces, stale advertisements |
| Device properties | devicectl JSON | CoreDevice schema | ProductType, ProductVersion, BuildVersion, DeviceName, UniqueDeviceID from Lockdown; RSD secondary | Lockdown GetValue/RSD properties | idevice | CONFIRMED | field availability by OS |
| Identity normalization | repeated raw/signing selector conversion | CoreDevice UUID mapping | one DeviceIdentity retaining distinct physical UDID, usbmux ID, RSD/CoreDevice IDs and transport | Lockdown identity plus connection generation | IOSSim Swift model + idevice | CONFIRMED | wrong-device mutation |
| Connection type | CoreDevice JSON | devicectl | explicit USB, network, phone-local/unknown enum from the active session | usbmux connection type, Bonjour/RP | idevice | LIKELY | concurrent transports |
| Lock status | devicectl info lockState | devicectl | tri-state Lockdown observation and service-open errors | Lockdown session/value | idevice | STRONG_EVIDENCE | no single universal lock flag |
| Trust status | paired property | CoreDevice | pair-record lookup plus successful Lockdown session validation | usbmux pair record, Lockdown StartSession/Pair | idevice | CONFIRMED | user prompt/reboot |
| Developer Mode | devicectl property/error | CoreDevice/AMFI hidden by tool | query AMFI/mounter status; model restart-required separately | com.apple.amfi.lockdown, Mobile Image Mounter | idevice amfi/mounter | CONFIRMED | user must enable and reboot |
| Developer image lookup | implicit CoreDevice | Xcode DDI assets | exact-build cache/provider resolution | local content-addressed assets | IOSSim DDIProvider | LIKELY architecture | redistribution/source rights |
| DDI personalization | implicit CoreDevice | Xcode/CoreDevice/TSS | query identifiers/nonce, choose BuildIdentity, obtain ticket | Mobile Image Mounter + Apple TSS | idevice mounter/tss | CONFIRMED source | Apple protocol/build change |
| DDI upload/mount/trust cache | implicit | CoreDevice | upload personalized image and mount with ticket/trustcache, then verify | mobile_image_mounter UploadImage/MountImage | idevice | CONFIRMED | stale/wrong image |
| RSD tunnel | CoreDevice tunnel state | CoreDevice/devicectl | userspace CoreDeviceProxy connection and retained RSD handshake | CoreDeviceProxy, RemoteXPC/RSD | idevice | STRONG_EVIDENCE | iOS point-release compatibility |
| Install | devicectl device install app | devicectl | stage package to PublicStaging, issue Install and consume progress/status | AFC + com.apple.mobile.installation_proxy | idevice installation utilities | CONFIRMED | signing/package format errors |
| Upgrade | generic install behavior | devicectl | explicit Upgrade with data-preservation receipt | Installation Proxy Upgrade | idevice | STRONG_EVIDENCE | bundle/team/entitlement mismatch |
| Uninstall | direct devicectl | devicectl | exact-bundle Uninstall only after explicit fresh-install policy | Installation Proxy Uninstall | idevice | CONFIRMED | destructive data loss |
| Enumerate apps/exact IDs | devicectl info apps in two implementations | devicectl | Lookup/Browse in same selected DeviceSession | Installation Proxy Lookup/Browse | idevice; AppService optional cross-check | CONFIRMED | result schema/filtering |
| Launch | direct devicectl process launch | CoreDevice | AppService LaunchApplication; DVT ProcessControl fallback | RSD CoreDevice AppService/DVT | idevice | STRONG_EVIDENCE | profile trust/service auth |
| Terminate | absent | none now | only when required, via process-control signal/kill | DVT ProcessControl/AppService signal | idevice | LIKELY | disrupting user/runtime |
| App container readback | direct devicectl copy from | devicectl | VendContainer then AFC read exact app-owned receipt/preferences file | House Arrest + AFC | idevice | CONFIRMED | sandbox/path semantics |
| App container configuration write | signed mapping/first-launch; no complete generic API | implicit devicectl path | VendContainer then AFC write one-time setup envelope | House Arrest + AFC | idevice | LIKELY | first-launch timing/replay |
| Documents transfer | no normal consumer operation | none | VendDocuments only advanced diagnostics | House Arrest + AFC | idevice | CONFIRMED | user-visible secret exposure |
| USB Lockdown pairing | implicit trust | Apple USB trust | ordinary Pair and StartSession, user approves prompt | Lockdown pairing | idevice | CONFIRMED | cannot automate approval |
| RemotePairing create/reuse | manual phone import; incomplete host helper | CoreDevice/manual material | explicit pair/verify/validate bound to selected device | RP lockdown/RSD RemotePairing | idevice | STRONG_EVIDENCE | convenience regeneration behavior |
| Pairing deletion/repair | manual replacement | manual | quarantine/delete exact Keychain item only after classified rejection | RP unpair/re-pair, Keychain | idevice + PairingCoordinator | LIKELY | loss of valid record |
| RemoteXPC/DVT/TestManager | CoreDevice for host prep; phone runtime already native | Xcode tooling for host | host capability through RSD; preserve phone retained implementation | RSD/RemoteXPC/DVT/TestManager | idevice host + frozen phone FFI | STRONG_EVIDENCE | protocol churn/regression |
| Doctor/device diagnostics | xcodebuild/xcrun/devicectl | full Xcode checks | structured ReadinessEngine/helper-integrity observations | all above | Swift + Rust bridge | CONFIRMED target | false ready if evidence stale |
| Support metadata | xcodebuild version | Xcode command | bridge/app/macOS/protocol versions and hashes | local signed metadata | Diagnostics | CONFIRMED target | secret overcollection |

## Direct Sites to Remove

RuntimeProvisioningSupport has discovery, selected identity, app inventory, install and lock calls. InstallationInventory has a direct apps query. ConsumerArtifactProvisioner has direct uninstall, launch and copy-from, and an xcodebuild signing-shell fallback. SupportBundleExporter probes xcodebuild. IOSSimProvisioner doctor probes xcodebuild/xcrun. scripts/bootstrap uses Xcode for build, SDK and notarization; that remains development/release-only. Python wireless and debug probes remain non-consumer.

## Current Direct-Action Contracts

| Source/action | Required input now | Output/errors relied on now | Run context | Independent implementation contract |
|---|---|---|---|---|
| RuntimeProvisioningSupport discover: devicectl list devices JSON | temporary JSON path, timeout 8 | CoreDevice identifier, hardware UDID, name/model/OS, pairing/developer/tunnel strings; parse/empty failures | setup, doctor, selection | discover once through usbmux/Lockdown; return devices even when lock is unknown |
| rawDeviceIdentifier: repeat list devices | optional selector | exact single CoreDevice identifier only when paired, Developer Mode enabled and unlocked; nil otherwise | setup/install | resolve selection without requiring later readiness; inspect layers separately |
| signingDeviceIdentifier: repeat list devices | CoreDevice selector | hardware UDID or nil | provisioning registration | trusted Lockdown UniqueDeviceID in same session |
| installedAppCount: devicectl device info apps | raw selector, bundle ID, 10-second command | integer count or nil; exact identifier | setup status and post-install | Installation Proxy exact lookup with available/absent/error tri-state |
| install: devicectl device install app | raw selector, .app URL, 60 seconds | ProcessResult exit/stdout/stderr; downstream string error classification | normal install/upgrade | typed install/upgrade callback, final Complete and inventory receipt |
| deviceLockState: devicectl device info lockState | raw selector, 5 seconds | passcodeRequired Boolean or nil | discovery/readiness | DeviceInspection.lockState with unknown preserved |
| InstallationInventory reader: direct info apps | raw selector, JSON temp path | selectedDeviceMatches, set of IDs, typed failure mapping; seven reads | authoritative post-install | same DeviceSession listApplications; retain bounded retry/total deadline |
| ConsumerArtifactProvisioner uninstall | selected raw ID, exact owned bundle IDs | not-installed tolerated; other errors classified; user chose fresh install | explicit recovery | Installation Proxy Uninstall with destructive authorization token/audit |
| ConsumerArtifactProvisioner launch | selected raw ID, main bundle ID, timeout 15 | parses CoreDevice/FBS profile-trust, locked/trust/device errors | runtime mapping setup | AppService launch receipt and typed profile-trust error |
| ConsumerArtifactProvisioner copy from | selected raw ID, main bundle dataContainer, Library/Preferences, temp destination | retries 3; reads first plist and checks IOSSimGate3RunnerBundleIdentifier | post-launch readback | exact filename/versioned IOSSim setup receipt through VendContainer/AFC |
| IOSSimProvisioner doctor | xcodebuild -version and xcrun --find devicectl | decides appleToolingReady and user action | normal doctor | helper signature/version plus native capability snapshot |
| SupportBundleExporter | xcodebuild -version | diagnostic text only | diagnostics | record packaged bridge/source commit and OS, no tool invocation |
| scripts bootstrap device command | xcrun devicectl list/install | developer CLI output | development/manual release | may remain explicitly development-only; cannot be packaged fallback |

Existing error strings such as CoreDevice/FBS code 10002, security error 3, “passcode”, “trust” and “Developer Mode” should become fixture inputs for the new typed translator during migration. Production policy must stop depending on English text once native service codes are available.

## Required Errors

Return stable errors: noDevice, wrongDevice, locked, trustRequired, developerModeDisabled, developerModeRestartRequired, pairingStale, ddiUnavailable, tunnelUnavailable, rsdUnavailable, serviceUnauthorized, installRejected, upgradeRejected, containerUnavailable, transientTransport, unsupported, identityMismatch. Keep raw protocol details only redacted diagnostics. A 503 from Apple auth is never a device error.

## Exact Policy

The bridge uses one DeviceSession per selected identity and all operations carry that identity. No repeated command invocation may silently select another phone. Unknown lock/trust state is not unlocked. Upgrade is default; uninstall is explicit and journaled. Install verification is authoritative inventory plus receipt/readback, not process exit code.
