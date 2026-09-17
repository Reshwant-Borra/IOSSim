# Vanish clean-Mac architecture

## Packaged boundary

`Vanish.app` is an arm64 Electron application. Packaged resource resolution uses `process.resourcesPath`; the bundle contains Electron, a Python 3.13 runtime, PMD 9.12.0, `developer_disk_image` 0.2.0, `VanishSideloader`, and IPAs. This is the central reason a customer needs no repo checkout or language/toolchain installation. `CONFIRMED_VANISH_ARTIFACT`

```text
Vanish.app
├── Electron main/renderer orchestration
├── Python 3.13
│   ├── pymobiledevice3 9.12.0
│   └── developer_disk_image 0.2.0
├── VanishSideloader (Rust helper)
├── Vanish.ipa / StikDebug IPA
└── updater/signing/notarization metadata
```

## External boundary

The clean Mac still supplies system Python-independent facilities: Gatekeeper, Keychain/safeStorage, usbmux transport, privilege prompting, filesystem, network, and code-signature enforcement. Apple supplies account, Developer Services, TSS, and phone security prompts. GitHub/doronz88 supplies DDI binary inputs in the inspected path. LocalDevVPN is a phone-side external dependency whose acquisition path remains unproven.

## State and failure domains

Electron keeps installation identity, wireless profiles, sideloader data, optional encrypted account passwords, logs, entitlement state, and updater state under the app's user-data area or temporary directory. Personalized DDI data is outside the app container at `~/Xcode_iOS_DDI_Personalized`. The architecture maps failures by domain (`VAN-1xx` device, `VAN-6xx` sideload) and preserves retry/reconnect paths.

Veya should reproduce the explicit ownership and error behavior. It should use Application Support/Keychain with keyed, documented stores instead of copying Vanish's paths or storage formats.
