# IOSSim Wireless / Cable-Free Research

Date: 2026-07-28  
Status: research audit only; no runtime behavior changed.

## Scope boundaries

These are separate goals and are evaluated separately throughout this folder:

- No cable during normal operation.
- No nearby computer.
- No computer at all.
- Remote control UI.
- Remote backend or cloud control plane.
- Persistent last location after disconnect.
- Wireless developer connection.
- External GPS accessory.
- Jailbreak-based local control.

## Document map

| File | Purpose |
|---|---|
| `00_CURRENT_ARCHITECTURE_AUDIT.md` | Current IOSSim USB/RSD/DVT path |
| `01_APPLE_WIRELESS_PAIRING.md` | Apple-supported wireless device workflow |
| `02_PYMOBILEDEVICE3_WIRELESS_AUDIT.md` | Installed/upstream pymobiledevice3 wireless capability audit |
| `03_USBMUX_AND_LIBIMOBILEDEVICE.md` | usbmuxd/libimobiledevice network options |
| `04_REMOTE_MAC_ARCHITECTURE.md` | Remote Mac and routed/VPN architecture |
| `05_HOSTED_CONTROL_PLANE.md` | Cloud dashboard plus local Mac/host agent |
| `06_MINIMUM_HOST_OPTIONS.md` | Smallest host comparison |
| `07_IPHONE_ONLY_OPTIONS.md` | No-host iPhone-only feasibility |
| `08_EXTERNAL_GPS_ACCESSORIES.md` | MFi/BLE/GPS hardware architecture |
| `09_JAILBREAK_FEASIBILITY.md` | Jailbreak-only feasibility category |
| `10_WIRELESS_TEST_MATRIX.md` | Cable-removal and wireless test matrix |
| `11_PROTOCOL_STACK.md` | Discovery/pairing/transport/RSD/DVT layering |
| `12_COREDEVICE_AUDIT.md` | CoreDevice/RemoteXPC/RSD architecture |
| `13_COMMERCIAL_TOOL_ARCHITECTURES.md` | Commercial tool architecture inference |
| `14_USB_OVER_IP.md` | USB-over-IP and usbmux forwarding |
| `15_LOCAL_RELAY_OPTIONS.md` | Tiny relay devices near the phone |
| `16_IPHONE_REMOTE_CONTROL_UI.md` | Using Safari on the iPhone as controller |
| `17_SECURITY_MODEL.md` | Security model for remote architectures |
| `18_ARCHITECTURE_DECISION_MATRIX.md` | Ranked architecture matrix |
| `19_MINIMUM_EXPERIMENTS.md` | Minimum experiments before implementation |
| `20_FINAL_RECOMMENDATION.md` | Final verdict and recommended next path |

## Source ledger

All source claims are current as checked on 2026-07-28 unless noted otherwise.

| Source | Type | Date / recency | Claim used | Confidence | Physical iPhone applicability |
|---|---|---:|---|---|---|
| Apple Help: [Pair a wireless device with Xcode](https://help.apple.com/xcode/mac/current/en.lproj/devbc48d1bad.html) | Apple documentation | current Help | iOS wireless Xcode pairing requires initial cable, Trust, “Connect via network,” then disconnect | High | Direct |
| Apple Help: [Run an app on a wireless device](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html) | Apple documentation | current Help | Xcode can run over Wi-Fi/other network; Bonjour for same network; IP address for network device | High | Direct |
| Apple Help: [Troubleshoot a wireless device](https://help.apple.com/xcode/mac/current/en.lproj/devac3261a70.html) | Apple documentation | current Help | Same-network troubleshooting, sleep warning, port 62078 | High | Direct |
| Apple Help: [network device](https://help.apple.com/xcode/mac/current/en.lproj/dev2a1a3824e.html) | Apple documentation | current Help | iOS network device only needs cable for pairing | High | Direct |
| Apple Help: [Run an app on a device](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html) | Apple documentation | current Help | Unlock and Trust are required for physical iOS device setup | High | Direct |
| Apple Developer Forums: [Xcode 15.3 device connection issues](https://developer.apple.com/forums/thread/747823) | Apple DTS forum | Mar 2024 | Xcode 15+ device communication can depend on direct-link IPv6 interfaces; VPN/firewall can break it | Medium-high | Direct |
| pymobiledevice3: [iOS 17+ tunnels guide](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md) | upstream docs | current GitHub | iOS 17.4+ lockdown tunnel, Wi-Fi remote tunnel, RSD address/port, elevated privileges, userspace limits | High | Direct |
| pymobiledevice3: [RemoteXPC.md](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md) | reverse-engineered technical notes | current GitHub | Remote pairing, trusted tunnel, RSD over tunnel, QUIC/TCP parameters | Medium-high | Direct |
| pymobiledevice3: [README](https://github.com/doronz88/pymobiledevice3) | upstream docs | current GitHub | Cross-platform Python API/CLI and DDI/DVT tooling over iOS 17+ tunnel | High | Direct |
| pymobiledevice3: [iDevice protocol layers](https://github.com/doronz88/pymobiledevice3/blob/master/misc/understanding_idevice_protocol_layers.md) | reverse-engineered technical notes | current GitHub | iOS 17 developer services require RemoteXPC/RSD tunnel; Wi-Fi tunnel path exists after remote pairing | Medium-high | Direct |
| pymobiledevice3 discussion [#1463](https://github.com/doronz88/pymobiledevice3/discussions/1463) | maintainer/community discussion | Sep 2025 | DVT location simulation tested on iOS 26 | Medium | Direct |
| pymobiledevice3 issue [#618](https://github.com/doronz88/pymobiledevice3/issues/618) | issue report | Oct 2023 | Xcode may see Wi-Fi iPhone while pymobiledevice3 usbmux list does not | Medium | Direct |
| pymobiledevice3 issue [#1046](https://github.com/doronz88/pymobiledevice3/issues/1046) | issue report | Jun 2024 | Windows Bonjour/remote browse reliability problems | Medium | Direct |
| libimobiledevice site: [Network Support](https://libimobiledevice.org/) | upstream project site | 2025 releases visible | Wi-Fi Sync devices can be accessed wirelessly; cross-platform native protocol stack | Medium-high | Direct, mostly pre-CoreDevice paths |
| libusbmuxd issue [#88](https://github.com/libimobiledevice/libusbmuxd/issues/88) | issue report | 2018 | Wi-Fi lockdown/usbmux depends on port 62078 and implementation details | Medium-low due age | Direct, older stack |
| Arch man page: [usbmuxd(8)](https://man.archlinux.org/man/usbmuxd.8.en) | package man page | current | usbmuxd multiplexes host connections to device localhost ports over USB | High | Direct |
| Apple MFi FAQ: [FAQs](https://mfi.apple.com/en/faqs.html) | Apple MFi docs | current | BLE-only/CoreBluetooth accessories are outside MFi; MFi covers licensed accessory technologies | High | Direct |
| Apple docs: [ExternalAccessory](https://developer.apple.com/documentation/externalaccessory/) | Apple documentation | current JS docs | External Accessory is for communicating with MFi accessories | High | Direct |
| Apple docs: [CLLocationSourceInformation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation) | Apple documentation | current JS docs/search snippets | `isProducedByAccessory` / `isSimulatedBySoftware` classify source | High | Direct |
| Eos GNSS: [External GNSS receiver check](https://eos-gnss.com/knowledge-base/articles/ios-android-device-using-bluetooth-gnss-receiver) | vendor technical article | older, still applicable | External GNSS receivers can be selected/validated through companion app workflows | Medium | Direct |
| Bad Elf: [gps-sdk](https://github.com/BadElf/gps-sdk) | vendor SDK | current GitHub | Bad Elf exposes SDK for GPS accessories | Medium | Direct |
| GFaker: [product page](https://www.gfaker.com/) | vendor marketing | 2026 claims | Hardware-based iPhone GPS spoofing without jailbreak/computer; iOS 26 compatibility claimed | Low-medium | Direct, unverified |
| iAnyGo: [iOS assistant guide](https://www.ianygo.com/guide/ianygo-ios-assistant.html) | vendor guide | current | Requires Developer Mode/Trust/root steps for iOS 17+ install path | Low-medium | Direct, proprietary |
| GeoPort: [GitHub](https://github.com/davesc63/GeoPort) | open-source project | current GitHub | Desktop iOS location simulator class of tool | Medium | Direct |
| Corellium: [USBFlux](https://support.corellium.com/features/connect/usbflux) and [usbfluxd](https://github.com/corellium/usbfluxd) | vendor/open-source docs | current | usbmux-like forwarding over network can make remote iOS devices appear via USB protocol | Medium | Virtual devices primarily; pattern relevant |
| VirtualHere: [iOS devices](https://www.virtualhere.com/node/3500) | vendor forum | current | Raw USB-over-IP for iOS can conflict with usbmuxd and macOS interface ownership | Medium | Direct |
| Dopamine: [GitHub](https://github.com/opa334/dopamine) / [site](https://ellekit.space/dopamine/) | jailbreak project docs | current | Dopamine supports iOS 15/16 ranges, not iOS 26 | Medium-high | Direct |
| palera1n: [compatibility chart](https://docs.palera.in/docs/reference/compatibility-chart/) / [site](https://palera.in/) | jailbreak project docs | current | checkm8-based jailbreak on A8-A11 devices for iOS 15+ ranges | Medium-high | Direct for old devices |

## Repository-only facts

- Local installed `pymobiledevice3`: `9.12.0`.
- Latest available on PyPI during audit: `10.1.0` (`python -m pip index versions pymobiledevice3`).
- Installed `9.12.0` exposes `remote browse`, `remote pair`, `remote start-tunnel --connection-type usb|wifi`, and `remote tunneld`.
- Installed `9.12.0` does not expose upstream-documented `lockdown remotepairing --pair`.
- No IOSSim code changes were made for wireless architecture in this audit.

