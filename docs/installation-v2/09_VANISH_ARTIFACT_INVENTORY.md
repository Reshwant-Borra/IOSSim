# Vanish artifact inventory

The official local `VanishSetup.dmg` is 147,766,400 bytes with SHA-256 `fef10cf9e2dcca54773f059fcbc865ad402f43637f9260c7f1391ac541c96ed0`. It was mounted read-only and statically inspected. `CONFIRMED_VANISH_ARTIFACT`

## Mac bundle

| Property | Observed value |
| --- | --- |
| Bundle ID | `com.vanish.app` |
| Version/build | 3.2.1 / 3.2.1 |
| Architecture | arm64 |
| Minimum macOS plist value | 10.15 |
| Publisher | Developer ID Application: Bhavya Khunt |
| Team ID | `6343MY26K5` |
| Signing | hardened runtime observed |
| Notarization | stapled-ticket validation observed |
| Regular files | 4,386 |
| Approximate regular-file bytes | 339,823,032 |
| ASAR entries | 161 |

Major contents are Electron, Squirrel, Mantle/ReactiveObjC, bundled Python 3.13, `pymobiledevice3` 9.12.0, a Rust `VanishSideloader`, Python device/tunnel helpers, and two IPAs. Saved exact inventories are `evidence/vanish-bundle-inventory.json` and `evidence/vanish-asar-inventory.json`.

## iPhone payloads

| File | SHA-256 | Static facts |
| --- | --- | --- |
| `Vanish.ipa` | `7959eba32164c8de29cec2d723df7381f63b8b292fbb76f137c9b40d0e935dbc` | source bundle `com.vanish.stikdebug`, 3.2.0 (1), minimum iOS 17.4, Live Activity extension |
| `StikDebug-2.3.7.ipa` | `9e697a42d1630ce9d6b3478597b4daccf331ef7536e2deaccffc0dc0f9104fef` | StikDebug payload and widget extension |

Observed URL schemes/queries include `vanish`, `locsim`, `sidestore`, `localdevvpn`, and `shortcuts`. Mach-O inspection found DeveloperToolsSupport references but no obvious XCTest bundle/framework in the ZIP inventory. That does not prove no runtime or dynamically reached XCTest technique. `CONFIRMED_VANISH_ARTIFACT`

## Static-analysis limits

No vendor executable was run, no account was used, and no network/device action was performed. Entitlement extraction was incomplete for some Mach-O signature layouts; absent extracted entitlements are `UNKNOWN`, not “none.” Proprietary code was searched in bounded excerpts and was not copied into IOSSim.
