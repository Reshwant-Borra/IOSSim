# 08 External GPS Accessories

## Summary

External GPS hardware is the only plausible “no Mac after setup” stock-iOS category that can affect system location without using DVT. It is not the same architecture as IOSSim. It replaces or augments Core Location input through accessory hardware rather than Apple developer services.

## MFi vs BLE

| Path | System-wide CoreLocation? | App-specific only? | MFi / licensed protocol | DIY feasible? |
|---|---:|---:|---:|---:|
| MFi / iAP2 / supported external GNSS | Yes, if iOS accepts it as an external location accessory | No | Yes for licensed tech | No, not without MFi/authentication hardware/spec access |
| BLE GATT Location and Navigation Service | No general system override | Yes | BLE-only outside MFi | Yes, but only for apps that explicitly read it |
| NMEA over app SDK | No general system override | Yes | Depends on accessory/protocol | Sometimes for custom apps |
| Commercial GPS-spoof hardware | Claims system-wide spoofing | No | Likely accessory-class hardware | Product-specific, proprietary |

Sources: Apple [MFi FAQ](https://mfi.apple.com/en/faqs.html), Apple [ExternalAccessory](https://developer.apple.com/documentation/externalaccessory/), Apple [CLLocationSourceInformation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation), Eos GNSS external receiver article, Bad Elf GPS SDK.

## Required answers

| Question | Answer |
|---|---|
| Can iOS accept external GPS as a system location source? | Yes for supported external GNSS/MFi-style accessories. |
| Does it affect all apps? | If accepted by Core Location system-wide, yes. BLE app-level GPS does not. |
| Does it require MFi? | For licensed iAP/ExternalAccessory-style system integration, yes or equivalent commercial licensed accessory path. BLE-only does not require MFi but is app-level. |
| Does a BLE-only device work? | Only for apps that explicitly implement BLE GPS parsing; not system-wide. |
| Can an accessory provide arbitrary coordinates? | Commercial spoof accessories claim yes. Normal GNSS receivers provide real satellite-derived coordinates. DIY arbitrary system-wide coordinates are blocked by MFi/licensed protocol requirements. |
| Can it provide lat/lon/altitude/speed/course/accuracy? | Real GNSS/NMEA can provide those fields. Whether iOS maps every field into each app’s `CLLocation` varies and should be tested. |
| Does `isProducedByAccessory` become true? | Apple defines this flag for locations retrieved from an external accessory. Expected true for system external GPS. |
| Does `isSimulatedBySoftware` remain false? | Expected false because this is not Xcode/DVT software simulation. Test on actual hardware. |
| Could IOSSim control such hardware wirelessly? | Only if the accessory exposes a controllable API/protocol. That becomes a hardware-control project, not DVT. |
| Could Raspberry Pi/ESP32 emulate the accessory? | BLE app-level emulation yes; system-wide MFi/iAP2 emulation no without licensed/authenticated hardware. |
| Would MFi authentication prevent DIY hardware? | Yes for licensed system accessory protocols. No bypass instructions are included or recommended. |
| What commercial devices exist? | GFaker, iTools BT-style devices, Bad Elf/Garmin/Dual/Eos real GNSS receivers. GFaker/iTools are spoof/control devices; Bad Elf/Garmin/Dual/Eos are mainly real GNSS. |

## Relevance to IOSSim

External GPS can eliminate the Mac for location changes only if the hardware itself provides arbitrary coordinates and an iPhone control app. It will not reuse IOSSim’s current DVT pipeline. IOSSim could become a dashboard for a supported hardware device, but that is a separate integration track.

