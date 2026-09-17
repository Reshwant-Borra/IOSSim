# IOSSim Physical Validation Matrix

Status is evidence-scoped. Current observations are iPhone18,1 / iOS 26.6.2 on 2026-09-15 using `.build/iossim/final-setup-payload-retest/IOSSim.app`. The schema-4 refresh completed at `16:07:58Z` and is authoritative.

| Gate | Status | Last test device | Last test OS | Artifact/build | Evidence | Next action |
|---|---|---|---|---|---|---|
| Native device discovery | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | current helper/bridge | usbmux, Rust, C ABI, Swift, Lockdown all reached phone; Swift selected one stable UDID | Raw 2/end-user 1 count display is a later diagnostic cleanup |
| Lockdown metadata/trust | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | current bridge | product/OS inspected; paired/trusted | Preserve |
| Unlock | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | protected developer/container operations completed | Preserve |
| Developer Mode | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | phone UI + generation-5 readiness | user confirmed on; all live typed developer-service stages passed | Treat AMFI flag as advisory; typed live rejection remains authoritative |
| Saved Apple session reuse | PHYSICAL_PASS | current phone/account | 26.6.2 | generation 5 | valid saved session supported Personal Team refresh | Preserve session |
| Fresh Apple login from zero state after SRP fix | FINAL_CLEAN_INSTALL_RETEST_REQUIRED | — | — | — | no clean-state physical proof | Separate test after runtime regression |
| Personal Team provisioning | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | profiles/signing material refreshed for team `T8SL4SG87F` | Preserve |
| Fresh payload build | STATIC_PASS | — | iOS SDK 27.0 | current DeviceArtifacts | arm64, iOS 17.0, compiled capability markers and manifest hashes | Rebuild only when payload source changes |
| Native signing | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | fresh main and runner accepted for install | Preserve |
| Native AFC staging/install | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | fresh same-ID main and runner force-upgraded | Preserve native route |
| Installation Proxy inventory | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | exact derived main and runner present | Preserve |
| Physical reconciliation | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | current physical inventory drove schema-3 state | Preserve |
| Developer support/DDI | PHYSICAL_PASS (EXISTING IMAGE) | iPhone18,1 | 26.6.2 | readiness receipt | `ddiMounted=true`; no `DDI_REQUIRED`, acquisition, or mount attempted | Conditional path remains unexercised |
| CoreDeviceProxy | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `COREDEVICE_PROXY_READY` | Preserve typed stage |
| Software tunnel | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `SOFTWARE_TUNNEL_READY` | Preserve typed stage |
| RSD handshake/service map | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `RSD_READY` | Preserve typed stage |
| RemoteXPC | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `REMOTEXPC_READY` | Preserve typed stage |
| AppService availability | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `APPSERVICE_READY` | Preserve typed mapping |
| Native automatic main launch | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `MAIN_NATIVE_LAUNCH_SUCCEEDED` for exact installed derived main ID | Runtime not started |
| Visible automatic open | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | user confirmed IOSSim visibly opened without tapping its icon | Preserve |
| House Arrest container | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `HOUSE_ARREST_READY` | Preserve |
| Runtime mapping write | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `RUNTIME_CONFIGURATION_WRITTEN` | Preserve |
| Runtime mapping readback/semantic verify | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `RUNTIME_CONFIGURATION_VERIFIED` | Preserve schema 1 |
| Automatic RemotePairing create/reuse | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `PAIRING_CREATED` after strict semantic validation | Preserve Keychain contract |
| Pairing encrypted delivery | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `PAIRING_DELIVERY_SUCCEEDED` | Preserve redaction/cleanup |
| Phone pairing receipt | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | fresh payload/generation 5 | fresh inbox processed delivery and emitted receipt | Preserve |
| Receipt verification | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | generation 5 | `PAIRING_RECEIPT_VERIFIED` | Preserve binding checks |
| LocalDevVPN installed | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | schema-4 refresh | inventory/launch path found `com.jkcoxson.LocalDevVPN` | External prerequisite remains user-owned |
| LocalDevVPN automatic native launch | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | schema-4 refresh | `LOCALDEVVPN_LAUNCH_STARTED` then `LOCALDEVVPN_LAUNCH_SUCCEEDED` | Preserve AppService mechanism |
| LocalDevVPN functional readiness | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | schema-4 refresh | `LOCALDEVVPN_READY`; phone receipt proved TCP `10.7.0.1:49152` | Do not substitute interface visibility |
| `SETUP_READY_FOR_RUNTIME` | PHYSICAL_PASS | iPhone18,1 | 26.6.2 | schema 4/provisioner 4 | receipt at `2026-09-15T16:07:58Z`, followed by `COMPLETE` | STOP; next task is runtime regression |
| Runtime startup | OUT_OF_SCOPE | — | — | — | intentionally not started | Next task |
| Spoof | OUT_OF_SCOPE | — | — | — | not tested | Next task |
| Rich Drive | OUT_OF_SCOPE | — | — | — | not tested | Next task |
| Seven-day renewal | NOT_IMPLEMENTED live | — | — | planning/scaffold | no production physical proof | Later phase |
| Cellular/Mac-off qualification | OUT_OF_SCOPE | — | — | — | not tested | Later qualification |

## Current verdict

`FIRST_TIME_NO_XCODE_SETUP_PHYSICAL_PASS`. The physical chain now includes external LocalDevVPN launch plus functional endpoint verification before schema-4 `SETUP_READY_FOR_RUNTIME`. Setup stopped before TestManager/XCTest/location. The separate fresh-account zero-state test, runtime startup/Spoof/Rich Drive regression, renewal, and cellular qualification remain outstanding.
