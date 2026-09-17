# Vanish-to-Veya installation responsibility map

| Responsibility | Vanish implementation | Veya existing component/status | Parity | Action |
| --- | --- | --- | --- | --- |
| one consumer artifact | signed/notarized DMG with packaged resources | local DMG exists; provenance disagrees with binary | partial | HARDEN canonical artifact audit |
| packaged engine resolution | `process.resourcesPath` | `IOSSimMacApp` -> `BundledProvisioningEngine` -> embedded helper | high | KEEP; verify signed path/hash/schema |
| dependency health | bundled Python import/health | helper `doctor --json` | partial | HARDEN typed helper/integrity health; remove command-name UX |
| USB discovery | PMD/usbmux | `NativeDeviceBridge`/idevice usbmux | implemented | KEEP; fix duplicate connection selection |
| first computer Trust | PMD/Rust helper waits for Trust | idevice has `pair_once`; Veya ABI lacks wrapper | missing | ADD ABI v2 pair request/poll/validate |
| device inspect | PMD | native bridge inspect | implemented | KEEP |
| Developer Mode | PMD reveal/status and guidance | inspect/readiness errors | partial | HARDEN typed action/resume |
| DDI acquisition | PMD + doronz88 mirror/cache | `ExistingAppleCacheProvider` only | missing product provider | PRODUCT DECISION + provider |
| TSS personalization/mount | PMD MobileImageMounter | native idevice bridge mount | implemented | KEEP; exact provenance receipts |
| tunnel/RSD | PMD lockdown/remote tunnel | native CoreDeviceProxy/software tunnel/RSD | implemented | KEEP; physically qualify |
| Apple login/2FA | `VanishSideloader` | `ApplePersonalTeamLive` | substantial | KEEP behind versioned adapter |
| team/cert/device/App IDs/profiles | sideloader | Personal Team service + signing resolver | substantial | HARDEN renewal, limits, errors |
| payload ownership | bundled IPA | DeviceArtifacts main + XCTest runner | implemented | KEEP immutable inputs |
| signing | sideloader | `ConsumerArtifactProvisioner` + `/usr/bin/codesign` + Keychain identity | implemented | HARDEN probes/lifecycle |
| install/inventory | sideloader/PMD | `NativeApplicationManagement` AFC/InstallationProxy | implemented | KEEP; exact identity/staged upgrade |
| profile trust | user guidance | launch classification through AppService | partial | HARDEN dedicated state/action |
| pairing transfer/repair | helper place/repair | `RemotePairingLifecycle` + House Arrest + phone inbox | implemented but unsafe repair/proof | REFACTOR staged candidate/proof |
| LocalDevVPN | external relationship; acquisition unknown | explicit external bundle + coordinator/inbox | partial | HARDEN App Store/action/approval/readiness |
| runtime ready | RSD/location-ready behavior | current stored setup checkpoint; no Rich proof | missing proof | ADD bounded XCTest/XCUILocation proof |
| reconnect/repair | polling, retry, repair commands | reconcile/resume/checkpoints | partial | REFACTOR domain reconciler/journal |
| refresh/renewal | observable sideload lifecycle; schedule unknown | profile inspection present; full renewal incomplete | partial | ADD staged renewal policy |
| diagnostics | VAN codes/logs | rich internal stages but generic translations/leaky exporter | partial | stable namespaces + allowlist support schema |
| desktop update | Electron updater | no canonical published authority | missing | GitHub Release or chosen single authority |

Veya follows Vanish where the responsibility is consumer-facing. It deliberately diverges on implementation language, runtime, pairing proof, state durability, and release provenance.
