# 13 Commercial Tool Architectures

## Method classes

Commercial iOS location tools appear to fall into four architecture classes:

1. Desktop DVT tools: require Developer Mode, Trust, Apple drivers/root/admin, and a desktop app; may offer Wi-Fi after setup.
2. Sideloaded helper app plus desktop installer: marketed as “no computer after installation,” but initial setup still uses desktop trust/developer flow.
3. External GPS/spoof hardware: accessory acts as a location provider or GPS-like source; can be computer-free during use.
4. Jailbreak/TrollStore tools: local override on vulnerable devices only.

## Tool table

| Tool/category | Wireless? | Initial USB? | On-device helper? | Likely mechanism | Developer Mode | Desktop running? | Persists after unplug? | Notes |
|---|---:|---:|---:|---|---:|---:|---:|---|
| iAnyGo desktop | Claims Wi-Fi/no computer modes | Yes for iOS 17+ guide | Yes for assistant mode | DVT and/or signed helper | Yes for iOS 17+ guide | For desktop mode yes; helper mode maybe no | Vendor claims, unverified | Guide asks for Developer Mode, Trust, Apple driver/root steps |
| Dr.Fone / AnyTo / similar desktop spoofers | Often claim cable-free after setup | Usually yes | Sometimes | DVT-style desktop bridge | Usually yes on modern iOS | Usually yes | Sometimes last-location until reboot | Treat marketing as low-confidence |
| GeoPort | Desktop app | Yes/likely | No | DVT/pymobiledevice-like | Yes | Yes | No durable guarantee | Open-source desktop location simulator class |
| 3uTools | Desktop iOS management | Yes | No/unknown | Apple device services / DVT-like for virtual location | Likely | Yes | Unclear | Proprietary |
| LocationSimulator open-source class | Desktop | Yes | No | DVT / developer service | Yes | Yes | No | Mostly mirrors known DVT limits |
| GFaker | Hardware | No “big computer” during use claimed | Companion app likely | External/spoof GPS hardware | No jailbreak claimed | No | Yes while hardware active | Vendor claims iOS 26.x support; technical details proprietary |
| iTools BT 2.5 | Hardware | No for normal use after hardware/app setup | Companion app | Bluetooth GPS-like accessory | No jailbreak claimed | No | Yes while hardware active | Third-party writeups describe external GPS source behavior |
| Real GNSS: Bad Elf/Garmin/Dual/Eos | Hardware | No | Optional companion | Real external GPS | No | No | Yes while paired | Provides real coordinates, not arbitrary spoof unless hardware supports injection |
| Jailbreak tools / Locsim class | Local | Setup varies | Tweak/app | CoreLocation/locationd hooks | No DVT Developer Mode required | No after setup | Depends on jailbreak state | Not viable for stock iOS 26.x |

## Technical evidence vs marketing

- If a product requires Developer Mode, Trust, Apple drivers, root/admin, and desktop setup, assume DVT/CoreDevice developer services unless proven otherwise.
- If it works without computer and without jailbreak while affecting all apps, assume hardware/accessory path unless proven otherwise.
- “Wi-Fi mode” often means no cable between phone and desktop, not no desktop.
- “No computer required after installation” often means a sideloaded/companion mode, not that the phone can self-access Apple developer services.

Sources: Tenorshare [iAnyGo](https://www.ianygo.com/) and [iOS assistant guide](https://www.ianygo.com/guide/ianygo-ios-assistant.html), [GFaker](https://www.gfaker.com/), [GeoPort GitHub](https://github.com/davesc63/GeoPort), Bad Elf [GPS SDK](https://github.com/BadElf/gps-sdk), Apple MFi/CoreLocation docs.

