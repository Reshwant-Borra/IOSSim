# Installation Failure and Recovery Model (checkpoint `8155901`)

How a failure travels: **native (idevice / Apple) → bridge `Status` → Swift
`NativeDeviceBridgeError` (or coordinator error) → `DeviceFailureMapping` / domain mapping →
`DomainObservation` state or thrown `VeyaFailure` → planner disposition → `EngineHost` result →
`DevelopmentInstallationStage` → UI.**

Classification kinds used below:

- **typed**: decided from an enum or error discriminant.
- **structured**: decided from a parsed structure, such as the launch-rejection chain.
- **conditional**: a typed or structured signal accepted only when independent evidence holds.
- **text-derived**: decided by substring matching on a message.
- **generic fallback**: an unrecognized error flattened into a catch-all.

## Taxonomy

| Family | Native origin | Bridge status | Swift error | Domain effect | `VEYA-*` | User action (exact source) | Stage | Recovery | Kind |
|---|---|---|---|---|---|---|---|---|---|
| Device disconnected | idevice error text "disconnect"/"broken pipe", or a stage error | 4 | `.deviceDisconnected` | Device domains: `DeviceFailureMapping.map` default → `retryableFailure`. `application` inventory → `retryableFailure`. VPN → `transportUnavailable`. | `VEYA-DEVICE-030` / `VEYA-INSTALL-024` / `VEYA-VPN-037` | VPN-037: "Reconnect and unlock the iPhone, then try Continue again." None for DEVICE-030/INSTALL-024. | preparingApp (connectLocalDevVPN for VPN) | Reconnect → refresh → new connection generation → device domains re-prove | text-derived (classify_error) → generic fallback |
| Device not found | `IdeviceError::DeviceNotFound`; selector miss (`find_selected_device` None); `select_exact_device` miss | 3 (12 `DeviceResolutionFailed` in staged calls) | `.deviceNotFound` / `.deviceResolutionFailed` | as above | as above | as above | preparingApp | as above. Gate: "Veya could not reach the same iPhone: it is not connected." | typed → generic fallback |
| Trust This Computer missing | lockdown `PairingDialogResponsePending`, `UserDeniedPairing`/`CanceledByUser`, text "pair"/"trust" | 25 / 26 / 6 | `.trustPromptPending` / `.trustDenied` / `.trustRequired` | `.user(trust)` → `waitingForUser` (or thrown `VEYA-DEVICE-031` from a transition) | `VEYA-DEVICE-031` when thrown | "Tap Trust on your iPhone and enter its passcode, then continue in Veya." (`DeviceFailureMapping.trust`) | preparingApp | **Trust / Pair** (USB only) → `pairLockdownOnce` | typed (25/26) + text-derived (6) |
| Device locked | `DeviceLocked`, `PasswordProtected`, text "locked" | 5 | `.deviceLocked` | `.user(unlock)` | `VEYA-DEVICE-031` when thrown | "Unlock your iPhone and keep it unlocked, then continue in Veya." | preparingApp | Unlock → Continue | typed + text-derived |
| Developer Mode disabled (pre-install) | lockdown `DeveloperModeStatus = false` (AMFI action 3 fallback) | inspection field | `DeveloperModeReadiness.disabled` | Gate `reveal`/`enable` | — | `DeveloperModeGateCoordinator.enableInstruction` | revealDeveloperMode / enableDeveloperMode | Reveal → user enables and restarts → Continue (`verify`) | typed |
| Developer Mode disabled (post-gate) | `DeveloperModeNotEnabled` (install/launch/mount), or chain failure while inspection says disabled | 7, or 13–18/10 re-read | `.developerModeRequired` (direct or via `developerModeRecovery`) | `.user(developerMode)`; `DeveloperSupportFailure.developerModeDisabled`; `RemotePairingFailure.developerModeRequired`; `LocalDevVPNSetupFailure.developerModeRequired` | `VEYA-DEVICE-031` when thrown | `DeviceFailureMapping.developerMode` | enableDeveloperMode (gate `invalidate`) | Re-enter the gate | typed / **conditional** (re-read only if inspection = disabled) |
| Developer Mode unknown | lockdown and AMFI both unanswered | inspection `unknown` | `.unknown` | Gate `undetermined` | — | `DeveloperModeGateCoordinator.unreadable` | checkDeveloperMode | Continue to re-check. Never treated as off. | typed |
| DDI / developer support unavailable | image not mounted; no approved provider; TSS/HTTP; mount rejected | 20; 10 | `.ddiRequired`; `DeveloperSupportFailure.*` | `missing` (then transition); `noApprovedSource`/`wrongBuildIdentity` → terminal; others retryable | `VEYA-DDI-030` (terminal) / `VEYA-DDI-031` (retryable) | none | preparingApp | Continue (network needed for mirror/TSS) | typed; `mapMountFailure`: "http"/"tss" text → `tssUnavailable` (text-derived), else `mountRejected` (generic) |
| AppService / RSD chain failure | CoreDeviceProxy, tunnel, RSD, RemoteXPC, feature | 13–18 | stage errors | `DeviceFailureMapping.map` default | `VEYA-DEVICE-030` | none | preparingApp | Continue | typed stage → generic fallback |
| Application missing (inventory) | installation_proxy lacks the bundle | — | — | `application` `missing`/`invalid` | `VEYA-INSTALL-025` (invalid) | none | preparingApp | Engine reinstalls | typed |
| Application inventory unavailable | any inventory error (not found, locked, disconnected, …) | any | any | `retryableFailure` | `VEYA-INSTALL-024` | none | preparingApp | Continue | **generic fallback**: the cause is discarded. This is how the USB/Wi-Fi defect showed up. |
| Installation failure | installation_proxy install/upgrade error, ownership conflict, post-install inventory mismatch | any | `NativeDeviceBridgeError` / `NativeApplicationManagementError` | transition throws a non-`VeyaFailure` | **`VEYA-STATE-099` "Unexpected engine failure."** (`EngineHost.failureResult` default) | none | preparingApp | Continue | **generic fallback** |
| Launch: app not found | AppService `NotFound` | 19 | `.applicationNotFound` | map default | `VEYA-DEVICE-030` | none | preparingApp | Continue (reinstall happens if inventory disagrees) | typed → generic fallback |
| Developer Trust required | AppService error envelope; chain ends `FBSOpenApplicationErrorDomain 3 Security` | 22 + schema-1 payload | `.launchRejectedStructured` | `.user(developerTrust)` **only if** `isStructurallyUsable && isOpenApplicationSecurityDenial && prerequisites.allProven` | `VEYA-DEVICE-031` (thrown from developerSupport prepare, `safeMessage == userAction`) | `DeviceFailureMapping.developerTrust` | trustDeveloper | User trusts in Settings > General > VPN & Device Management → Continue → launch retried | **conditional + structured** |
| Launch rejected, not proven trust | any other status-22 shape | 22 | `.launchRejected[Structured]` | `.failed(launchRejected)` | `VEYA-DDI-032` (retryable, chain constants in the message) | none | preparingApp | Continue | structured / typed |
| Launch rejected via legacy text | status 22 whose payload fails to decode (older bridge) | 22 | `.launchRejected(String)` | `.user(developerTrust)` if `isDeveloperProfileTrustRejection(text)` | as above | as above | trustDeveloper | as above | **text-derived; does not check the prerequisites** |
| Profile invalid | Apple profile fails offline validation | — | `ExperimentalBackendError.invalidProfile` | transition throws | `VEYA-PROFILE-035` | none | preparingApp | Continue | typed |
| Device/App ID limits | Apple Developer Services | — | `.deviceLimit`/`.appIDLimit` | throws | `VEYA-PROFILE-030` / `032` (message tells the user what to do) | message only | preparingApp | User frees capacity | typed; **the device-registration category is partly text-derived** from Apple's message (`ApplePersonalTeamLive.swift` ~`:2740`) |
| Certificate invalid / mismatch / capacity | inventory contradiction, issued SPKI mismatch, capacity | — | `CertificateFailure.*` | throws | `VEYA-CERT-040/042/043/046/047`, `044/045` | CERT-046 message: "Revoke an unused certificate in your Apple Account, then retry." | preparingApp | Automatic owned reclaim (≤ 1) or user action | typed |
| Team mismatch | `authorizedTeamIdentifier != teamID` in backend guards; `ProfileDomain` team ≠ certificate team; Apple addDevice message text containing "team" + invalid/not found/access | — | `.invalidTeam` / `AppleDomainFailure.teamChanged` | `team` observe `terminalFailure`, or transition throws | **`VEYA-TEAM-032`** | none (terminal) | preparingApp | **Unresolved. See Known issue.** | typed (guards) + **text-derived** (Apple message category) |
| Apple authentication | session expired, bad password, SRP/2FA rejected | — | `ExperimentalBackendError.*` | `authorization`/`team` `waitingForUser`; in transitions → `sessionExpired` | `VEYA-AUTH-030` (thrown) | "Sign in to your Apple Account in Veya, then continue in Veya." | preparingApp | Sign In | typed |
| Apple unreachable / rate limited / protocol changed | network, 5xx, 429, response drift | — | as named | retryable / terminal | `VEYA-AUTH-031` / `033` / `032` | none | preparingApp | Continue, or update Veya | typed |
| Signing key unusable | wrapping store unavailable, interaction required, Keychain error, corrupt envelope | — | `SigningKeyFailure.*` | terminal (001/002), retryable (010), invalid → replace | `VEYA-KEY-001…012` | none | preparingApp | Replace, or fix build signing (M4) | typed |
| Signing failed | signer category | — | `InProcessSignerFailure` | throws | `VEYA-SIGN-021` (subsystem `veya-signing-core/<category>`), `022`, `026` | none | preparingApp | Continue | typed (category constant only) |
| VPN | LocalDevVPN missing, unsupported, permission, not running, endpoint, receipt, transport | varies | `LocalDevVPNSetupFailure.*` | actionable / failed | `VEYA-VPN-030…037` | see `DeviceDomainFailure` VPN actions | connectLocalDevVPN | Follow the action, then Continue | typed; transport collapse is generic (below) |
| Pairing | RPPairing create/validate/deliver | 24 etc. | `RemotePairingFailure.*` | incomplete / failed | `VEYA-PAIR-030` (retryable), `031` | none | preparingPairing | Continue | typed |
| Runtime: Run Setup not tapped | no receipt | — | `RunSetupFailure.notTapped` | thrown | `VEYA-RUNTIME-011` (retryable + action) | "Tap Run Setup on your iPhone, then continue in Veya." | readyForSetup (if the request was just issued) | User taps Run Setup → Continue / Verify Setup | typed |
| Runtime: phone reported failure | receipt with error | — | `.reportedOnPhone(code,message)` | thrown | `VEYA-RUNTIME-012` (message includes phone text ≤ 320 chars, control characters removed) | "Fix what the iPhone reports, tap Run Setup again, then continue in Veya." | preparingApp | as stated | typed (phone-supplied text displayed, not classified) |
| Runtime: proof incomplete | `RichRuntimeProofFailure.proofFailed/receiptUnavailable` | — | — | thrown | `VEYA-RUNTIME-010` | "If the iPhone asked to allow automation or location access…" | preparingApp → Continue / Verify Setup | as stated | typed |
| Runtime: other | `RunSetupFailure.requestInvalid`, `RichRuntimeProofFailure.receiptInvalid`, bridge errors during the runtime proof | — | non-`VeyaFailure` | thrown | **`VEYA-STATE-099`** | none | preparingApp | Continue | **generic fallback** |
| Journal / state | lease, lock, stale generation, proof binding mismatch | — | `InstallationStateFailure` | thrown | `VEYA-STATE-001…016`, `VEYA-SEC-003` | "Installation state operation failed." | preparingApp | Retry; recovery at the next run | typed code, generic message |

## Where error information is flattened

Numbered so they can be referenced later. **None of these were changed in this checkpoint.**

1. **`classify_error` text fallback** (`native/iossim-device-bridge/src/lib.rs:830`): after the typed
   cases, substring rules pick DeviceLocked / TrustRequired / DeviceDisconnected. Everything else becomes
   `ProtocolError`.
2. **`clean_diagnostic`** (`lib.rs:426`): truncates to 512 characters. If any secret marker appears, the
   **entire** diagnostic is replaced with "device service returned a redacted error".
3. **Error results carry no payload** except launch rejection: all other structured detail is lost at
   the ABI.
4. **Swift status default** (`NativeDeviceBridge.swift:1162`): unknown status → `.internalFailure`.
5. **`DeviceFailureMapping.map` default** (`DeviceProductionAdapters.swift:165`): every unlisted
   `NativeDeviceBridgeError` (not found, disconnected, timeouts, protocol, CoreDevice stages when
   Developer Mode is not reported disabled, application not found) and every unknown error type
   → `VEYA-DEVICE-030` "The device could not be observed."
6. **`CoordinatedDeviceDomain.observe`**: any error from `observeNative` → `VEYA-DEVICE-030`.
7. **`DeviceFailureMapping.prepare`**: a user-action mapping without its own failure becomes
   `VEYA-DEVICE-031` whose safe message *is* the user action string.
8. **`ApplicationDomain.observe`/`prove`**: every inventory error → `VEYA-INSTALL-024`. The USB/Wi-Fi
   defect was hidden behind this.
9. **Non-`VeyaFailure` transition errors** → `EngineHost.failureResult` → `VEYA-STATE-099`
   "Unexpected engine failure." (install/upgrade errors from `NativeApplicationManager`, runtime-proof
   errors other than `notTapped`/`reportedOnPhone`/`proofFailed`/`receiptUnavailable`).
10. **`LocalDevVPNSetupCoordinator.mapTransport`** (`LocalDevVPNSetupCoordinator.swift:484`): not found,
    resolution, disconnected, timeout, locked, trust-required and "other" all become
    `transportUnavailable` → `VEYA-VPN-037`. Developer Trust is recognized **only** through the legacy
    text path. A structured denial during the VPN step becomes `VEYA-VPN-037`. (In the engine order,
    `developerSupport` has already launched the app successfully before `vpn` runs.)
11. **`RemotePairingFailure` mapping** (`RemotePairingLifecycle.swift:96`): trust recognized through the
    legacy text path only.
12. **Legacy trust text path** (`NativeDeviceBridgeError.isDeveloperTrustRejection`,
    `ConsumerProvisioning.swift:956`): substring classification that **does not require the
    prerequisites**. It is reachable from the current bridge only if a status-22 payload fails to decode.
13. **`NativeDeveloperServicesCoordinator.mapMountFailure`**: "http"/"tss" substring → `tssUnavailable`;
    any other untyped error → `mountRejected`.
14. **Apple device-registration category**: Apple's `addDevice` message text is scanned for
    "team" + "invalid"/"not found"/"access" → `.invalidTeam` → `VEYA-TEAM-032`.
15. **`InstallationStateFailure`** in results: code kept, message is always "Installation state
    operation failed."
16. **UI `perform` catch** (`DevelopmentInstallationView.swift`): outside the engine (refresh, pair,
    authorize), a non-`VeyaFailure` error is shown as `String(describing: error)`, i.e. the enum case
    and its redacted diagnostic.
17. **Stage resolution by string equality** (`DevelopmentInstallationStage.resolve`): stages are chosen
    by comparing `userAction` with Veya's own constants (`DeviceFailureMapping.developerMode`,
    `.developerTrust`) or `contains("LocalDevVPN")`. These are internal constants, not device text, but
    any rewording of those constants changes the stage mapping.

## Recovery rules (engine-wide)

- The user's tap or click is never evidence. Every Continue re-observes.
- A connection-generation change voids every connection-bound observation and proof.
- Irreversible external effects are never rolled back. They are reconciled by re-observing Apple or
  device inventory.
- A Veya-local candidate left by an interrupted run is discarded, and the discard is recorded in
  `journal.recovery`.
- Terminal failures stop the run. Retryable failures stop the run with `retryableWait`, and the user
  presses Continue again.
