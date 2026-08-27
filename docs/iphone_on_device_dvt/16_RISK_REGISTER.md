# Risk Register

| ID | Risk | Status | Impact | Mitigation |
| -- | ---- | ------ | ------ | ---------- |
| R1 | Cellular cold-start does not work without Wi-Fi or cellular toggle | UNKNOWN | Target success blocked | Run E4/E5 before broad implementation |
| R2 | Apple changes RemotePairing/DVT behavior in iOS updates | PLAUSIBLE | Breaks POC or production | Pin supported iOS ranges, add diagnostics, avoid overclaiming |
| R3 | RPPairing records are invalidated by iOS update/Developer Mode changes | UNKNOWN | Re-pairing required | Run reboot/update/invalidation matrix |
| R4 | NetworkExtension entitlement unavailable for IOSSim distribution | CONFIRMED RISK | Built-in VPN blocked | First POC can use external LocalDevVPN; research entitlement path separately |
| R5 | App Store/TestFlight rejection | PLAUSIBLE | Distribution blocked | Treat as sideload/developer-tool first |
| R6 | Pairing private keys leaked in repo/logs | CONFIRMED RISK | Device trust compromise | Folder `.gitignore`, Keychain/file protection, redacted logs |
| R7 | Locus/idevice API drift | PLAUSIBLE | Build instability | Pin commit and wrap a minimal ABI |
| R8 | LocalDevVPN license restrictions limit code reuse | PLAUSIBLE | Cannot fork wholesale | Use as external dependency or implement independently if entitlement available |
| R9 | DVT session requires foreground/background allowances | PLAUSIBLE | Drive playback unreliable | Test background, Live Activity, and timer behavior separately |
| R10 | WLOC fallback creates certificate/MITM privacy risk | CONFIRMED RISK | Security/review issues | Keep WLOC out of first POC |
