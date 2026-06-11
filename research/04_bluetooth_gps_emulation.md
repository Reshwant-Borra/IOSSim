# Bluetooth GPS Emulation — MFi Protocol, BLE NMEA, and macOS Peripheral Mode
**Date:** 2026-06-10  
**Agent:** Bluetooth GPS NMEA emulation on macOS/iOS  
**Scope:** Whether macOS can emulate a Bluetooth GPS device that iOS CoreLocation accepts as hardware

---

## Hard Boundary: Two Separate Tracks

### Track A — Bluetooth Classic + iAP2 (Full System-Level Integration)

MFi-certified GPS accessories (Garmin GLO, Bad Elf GPS Pro, Emlid Reach RX) use Bluetooth Classic with Apple's **iAP2 (iPod Accessory Protocol 2)** running over RFCOMM. This requires a **physical Apple Authentication Coprocessor chip** embedded in the hardware.

- Authentication: RSA-1024/SHA-1 challenge-response
- Private key: exists ONLY in the hardware chip — cannot be replicated in software
- When paired: `locationd` intercepts the NMEA stream and feeds it into the CoreLocation stack **system-wide**
- ALL apps using `CLLocationManager` transparently receive the external GPS data — no app code changes
- Sets `isProducedByAccessory = true`

**The hardware chip is NOT bypassable in software.** No macOS app, no software protocol emulation can replicate iAP2 authentication without the physical Apple Authentication Coprocessor.

### Track B — Bluetooth Low Energy (BLE) + GATT (App-Level Only)

BLE-only accessories are **explicitly excluded from the MFi program** (Apple's own FAQ: "Accessories which connect to an Apple device using Bluetooth Low Energy… do not fall under the MFi Program"). No authentication chip required. Standard BLE GATT profiles work.

**BUT:** This path produces a completely different outcome:
- iOS CoreLocation does NOT automatically consume BLE GPS data at the system level
- BLE GPS feeds ONLY into whichever app has explicitly connected to the peripheral and is parsing the data
- The internal iPhone GPS is NOT replaced
- `isProducedByAccessory` is **NOT set**
- `isSimulatedBySoftware` remains `false` (not DVT-based)

---

## isProducedByAccessory and isSimulatedBySoftware — Exact Criteria

Both are on `CLLocationSourceInformation` (iOS 15+).

- `isProducedByAccessory = true`: Set when `locationd` sources location from an MFi-certified hardware accessory via iAP2/Bluetooth Classic. Also set for CarPlay head units. **No public API, entitlement, or non-MFi path** can set this to `true` on an unmodified device.
- `isSimulatedBySoftware = true`: Set when Xcode debugger or `com.apple.dt.simulatelocation` service is active.
- BLE GPS produces: `isProducedByAccessory = false` (or nil), `isSimulatedBySoftware = false`

---

## macOS CoreBluetooth Peripheral Mode — What IS Achievable

macOS supports `CBPeripheralManager` fully. A macOS app CAN:
- Advertise BLE GATT services including Bluetooth SIG "Location and Navigation Service" (UUID `0x1819`, characteristic `0x2A67`)
- Broadcast NMEA sentences over BLE to nearby iPhones

An iOS app with explicit `CoreBluetooth` Central code CAN:
- Connect to the macOS BLE peripheral
- Parse NMEA sentences
- Construct `CLLocation` objects with valid speed, course, altitude, horizontalAccuracy

**What this CANNOT do:**
- Cause iOS to route that data into the system-wide CoreLocation stack
- Replace the iPhone's GPS for ALL apps
- Set `isProducedByAccessory = true`
- Be visible to Life360, Find My, or any app that doesn't have explicit BLE GPS code

This approach is ONLY useful if you control the app under test and can add CoreBluetooth GPS parsing code.

---

## "Non-MFi" GPS Accessories — Common Misconceptions

Garmin GLO and Bad Elf GPS Pro are frequently called "non-MFi" in casual discussion, but **this is incorrect**. Both are MFi-certified and use Bluetooth Classic + iAP2. That's precisely why they feed iOS CoreLocation system-wide.

**True BLE-only (non-MFi) examples:**
- BonoGPS (ESP32) — broadcasts GATT LNS `0x1819/0x2A67`; works with Harry's Lap Timer only
- ArduSimple RTK Bridge — BLE GATT; works with SW Maps, not iOS system CoreLocation
- GPS2IP — broadcasts iPhone's own GPS as BLE LNS outward; cannot receive

---

## Open-Source BLE GPS Peripheral Projects

### LELocation-framework-iOS (RomainQuidet)
- iOS framework using BLE SIG LNS (UUID `0x1819`) to receive GPS from a BLE peripheral
- Produces `CLLocation` objects with correct speed/course/altitude from NMEA
- App-level only (requires app to use `LELocationManager` instead of `CLLocationManager`)
- Companion firmware: `LEGPSRec-nRF51822` (nRF51822 board)
- A macOS `CBPeripheralManager` implementation would work as the peripheral side
- **Gap:** Still app-level only, not system-wide

### BonoGPS (ESP32)
- ESP32 + GPS module broadcasting GATT LNS at 20Hz
- Confirmed working on iOS with Harry's Lap Timer
- Does NOT set `isProducedByAccessory = true`

### GPS2IP (iOS app)
- Broadcasts iPhone's GPS over BLE/WiFi as NMEA — outbound direction only
- No "GPS2IP Receiver" equivalent for iOS that injects into CoreLocation

---

## The macOS → iOS BLE NMEA Pipeline (What CAN Be Built)

A working pipeline IS buildable with public documented tools:

```
macOS app (CBPeripheralManager)
  → BLE GATT LNS service (0x1819 / 0x2A67)
  → broadcasts NMEA sentences at driving speed
  
iOS app (CBCentralManager + LELocationManager-style parsing)
  → connects to macOS peripheral
  → parses NMEA (RMC, GGA sentences) 
  → produces CLLocation with speed > 0, course > 0, altitude
  → isSimulatedBySoftware = false
  → isProducedByAccessory = false (nil)
```

**Works for:** Your own test app that uses custom BLE GPS code  
**Does NOT work for:** Life360, Find My, Google Maps, or any unmodified app

---

## Verdict Table

| Goal | Requires MFi Chip | Software-Only Possible |
|---|---|---|
| `isProducedByAccessory = true` | YES — mandatory | NO |
| System-wide CoreLocation GPS replacement | YES — iAP2 + chip | NO |
| BLE GPS in a specific custom app | NO | YES |
| macOS CBPeripheralManager broadcasting NMEA/LNS BLE | NO | YES |
| Bluetooth Classic SPP to iOS | YES (via MFi iAP2) | NO |
| `isSimulatedBySoftware = false` with BLE GPS | N/A (stays false) | YES |
| NMEA BLE readable by select iOS apps with CoreBluetooth code | NO | YES |
| Life360 drive detection via BLE GPS | NO | NO (Life360 uses CLLocationManager, not custom BLE) |

---

## Critical Conclusion

**A macOS CBPeripheralManager app can serve NMEA over BLE. An iOS custom app can receive it and produce valid CLLocation objects with speed/course/altitude, with `isSimulatedBySoftware = false`. But this requires modifying the iOS app under test.**

**For triggering Life360, Find My, or any unmodified third-party app: only MFi iAP2 hardware (iTools BT 2.5, Bad Elf GPS Pro, Garmin GLO) provides system-wide CoreLocation replacement. And even then, the IMU (accelerometer/gyroscope) showing stationary contradicts the GPS-derived driving speed.**

---

## Sources

- [External Bluetooth GPS data source — Apple Developer Forums #75352](https://developer.apple.com/forums/thread/75352)
- [External NMEA GPS to CLLocationManager — Apple Developer Forums #69717](https://developer.apple.com/forums/thread/69717)
- [isProducedByAccessory — Apple Developer Documentation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation/isproducedbyaccessory)
- [MFi Program FAQs](https://mfi.apple.com/en/faqs)
- [Exploring Apple's MFi iAP2 protocol — wiomoc.de](https://wiomoc.de/misc/posts/mfi_iap.html)
- [LELocation-framework-iOS — GitHub](https://github.com/RomainQuidet/LELocation-framework-iOS)
- [BonoGPS ESP32 GPS — GitHub](https://github.com/renatobo/bonogps)
- [Eos GNSS: How to Know If iOS Is Using Your External GNSS Receiver](https://eos-gnss.com/knowledge-base/articles/ios-android-device-using-bluetooth-gnss-receiver)
- [Bad Elf GPS SDK — GitHub](https://github.com/BadElf/gps-sdk)
- [Emlid Reach RX MFi API Integration](https://docs.emlid.com/reachrx/developer-resources/api-integration-intro/)
- [ArcGIS NMEA Location Data Source for iOS](https://archive.developers.arcgis.com/ios/swift/sample-code/display-device-location-with-nmea-data-sources/)
- [ArduSimple RTK to iOS via BLE Bridge](https://www.ardusimple.com/how-to-connectrtk-receiver-to-ios-device-iphone-ipad-or-ipod-via-bluetooth/)
