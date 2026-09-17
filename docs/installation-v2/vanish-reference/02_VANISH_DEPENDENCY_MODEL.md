# Vanish dependency model

| Capability | Bundled? | macOS | Apple service | Phone | External app | Download/generated/cache | Xcode? | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| USB/usbmux discovery | Python 3.13 + PMD | usbmux daemon/device transport | — | usbmux endpoint | no | live | no | `CONFIRMED_VANISH_ARTIFACT/STATIC_CODE` |
| Lockdown/trust | PMD and helper logic | pair-record facilities | trust protocol | user Trust prompt | no | pair record generated/cached | no | `CONFIRMED_VANISH_STATIC_CODE` |
| AFC/InstallationProxy/House Arrest | PMD/Rust stack | transport | — | services | no | session only | no | `CONFIRMED_VANISH_ARTIFACT/STATIC_CODE` |
| Developer Mode | PMD commands | — | — | setting/reboot/consent | no | device state | no | `CONFIRMED_VANISH_STATIC_CODE` |
| Personalized DDI assets | acquisition package/client | filesystem/cache | TSS later | device identity/nonce | GitHub is external source | downloaded to `~/Xcode_iOS_DDI_Personalized` | no | `CONFIRMED_VANISH_STATIC_CODE` |
| DDI personalization/mount | PMD mounter | network/transport | Apple TSS manifest | ImageMounter | no | manifest generated; mount session/device state | no | `CONFIRMED_VANISH_STATIC_CODE` |
| CoreDevice/RSD tunnel | PMD | elevation/process/network | — | CoreDevice services | no | temp pid/log, RSD endpoint | no | `CONFIRMED_VANISH_STATIC_CODE` |
| Apple account auth/2FA | Rust helper | safeStorage optional | Apple identity/developer services | trusted-device 2FA | no | session/cache | no | static command protocol; backend internals `STRONG_INFERENCE` |
| Machine identity/anisette | Python/Rust resources | host facts | Apple auth | — | no | generated machine identity | no | `CONFIRMED_VANISH_ARTIFACT`, details `LIKELY` |
| Certificate/CSR/team/device/App ID/profile | Rust sideloader | cryptography/key storage | Developer Services | device UDID | no | generated/reused | no | command/error evidence; exact implementation `STRONG_INFERENCE` |
| IPA signing/install | Rust sideloader + bundled IPA | filesystem | profiles/certificates | install service | no | signed temp artifact | no | `CONFIRMED_VANISH_ARTIFACT/STATIC_CODE` |
| RemotePairing/pairing placement | PMD/Rust | local data | — | pairing protocol/app container | no | generated/cached/placed | no | `CONFIRMED_VANISH_STATIC_CODE` |
| LocalDevVPN | no complete app observed in Mac bundle | URL launch/network | App Store likely | separate bundle queried by IPA | LocalDevVPN | installed/configured externally; exact path unknown | no | IPA strings/static code; `UNKNOWN` ownership |
| Profile refresh | sideloader architecture likely supports reinstall | cache/account | Developer Services | installed app | no | renewed profile and signed artifact | no | commands/errors; autonomous schedule `UNKNOWN` |
| Desktop updates | Electron updater | Gatekeeper/updater | configured update backend | — | no | downloaded update cache | no | `CONFIRMED_VANISH_STATIC_CODE` |

## Clean-Mac answer

Vanish eliminates toolchain prerequisites by shipping the interpreter, device libraries, sideloader, and payload. It still depends on macOS trust/elevation, Apple services, the user's iPhone actions, an internet connection, and a third-party GitHub DDI source. “Self-contained” describes ownership of the installer stack; it does not mean offline or free of external services.
