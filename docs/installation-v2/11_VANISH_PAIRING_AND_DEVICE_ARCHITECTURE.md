# Vanish pairing and device architecture

| Question | Finding | Confidence |
| --- | --- | --- |
| USB/device layer | Bundled pymobiledevice3 uses usbmux/Lockdown and developer services | CONFIRMED |
| First Trust flow | UI strings and upstream APIs support unlock/Trust prompts | LIKELY; no clean-device trace |
| RemotePairing | Create/check/store/repair/export behavior is represented | CONFIRMED static code |
| Pairing delivery | Normal workflow appears to place per-device pairing state for phone use | STRONG_INFERENCE |
| Tunnel | Local helper behavior around `127.0.0.1:49151` is present | CONFIRMED static code |
| Phone VPN | LocalDevVPN relationship appears in payload queries and runtime analysis | STRONG_INFERENCE |
| DDI | Bundled PMD tooling can acquire/personalize developer images | CONFIRMED capability; actual live source UNKNOWN |
| App launch | PMD/RSD developer-service machinery exists | CONFIRMED capability; clean live sequence UNKNOWN |

Vanish pairing is automation, not elimination. USB Lockdown pairing, RemotePairing, RPPairing, Developer Mode, profile trust, and VPN approval are different trust domains. Neither Vanish strings nor its success claims justify combining them into one “paired” boolean.

For Veya, the useful lessons are per-device records, a normal hidden delivery path, explicit repair, and user-facing prompt guidance. Veya must add stronger transactional replacement and proof than its current implementation. Vanish’s exact proprietary envelope or storage format is not adopted.

The presence of PMD’s third-party DeveloperDiskImage downloader is evidence that a technically complete flow can be packaged. It is not evidence of Apple support or redistribution permission. `PRODUCT_DECISION_REQUIRED`
