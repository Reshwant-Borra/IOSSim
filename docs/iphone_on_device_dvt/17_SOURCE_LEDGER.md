# Source Ledger

| ID | Source | Date | Type | Claim | Evidence strength | Relevant files/lines | Notes |
| -- | ------ | ---- | ---- | ----- | ----------------- | -------------------- | ----- |
| S01 | IOSSim local repo | 2026-08-26 | SOURCE_CODE | Current wireless path uses `UserspaceRsdTunnel -> RSD -> DvtProvider -> DeviceInfo -> LocationSimulation` | CONFIRMED | `backend/wireless_location/session.py` lines 11-16, 104-111, 129, 144 | Host-side baseline |
| S02 | IOSSim local repo | 2026-08-26 | SOURCE_CODE | Wireless controller requires same-device network visibility | CONFIRMED | `backend/wireless_location/controller.py` lines 148-178, 321-336 | Not suitable for Mac-off runtime |
| S03 | IOSSim local repo | 2026-08-26 | SOURCE_CODE | Setup runs pymobiledevice3 RemotePairing and Wi-Fi enablement | CONFIRMED | `backend/wireless_location/discovery.py` lines 112-152 | Stores UDID, not pairing secrets |
| S04 | IOSSim local repo | 2026-08-26 | SOURCE_CODE | USB/stable location uses pymobiledevice3 DVT CLI | CONFIRMED | `backend/location_service.py` lines 65-132 | Existing host DVT |
| S05 | Locus `83c8fb324983728e8f44759cfd834dc637ee38b5` | 2026-08-26 | SOURCE_CODE | On-device app uses idevice FFI and LocalDevVPN for DVT simulation | CONFIRMED | `README.md` lines 37-47; `LocationEngine.swift` lines 98-162 | Strongest source |
| S06 | Locus `83c8fb...` | 2026-08-26 | SOURCE_CODE | RPPairing imported/stored as plist with 0600 permissions | CONFIRMED | `PairingStore.swift` lines 10-27, 89-111 | Needs stronger semantic validation |
| S07 | Locus `83c8fb...` | 2026-08-26 | SOURCE_CODE | iOS 27 pairable-host uses Bonjour/NWListener and PIN | CONFIRMED | `PairOnDeviceService.swift` lines 188-255; `PairableHostAdvertiser.swift` lines 27-47, 95-102 | Source-level same-device pairing |
| S08 | Locus `83c8fb...` | 2026-08-26 | OPEN_SOURCE_DOC | Start on Wi-Fi first; session can continue on cellular | STRONG EVIDENCE | `README.md` line 47; `SETUP.md` line 42 | Does not prove cellular cold-start |
| S09 | LocalDevVPN `467a845f04a4b0936a7fc3dd0b326b49aaf98bdf` | 2026-08-26 | SOURCE_CODE | Packet Tunnel creates local virtual interface and rewrites packets | CONFIRMED | `TunnelProv/PacketTunnelProvider.swift` lines 18-58 | Default `10.7.0.0/24` |
| S10 | LocalDevVPN `467a845...` | 2026-08-26 | SOURCE_CODE | Requires packet tunnel entitlements | CONFIRMED | `LocalDevVPN/LocalDevVPN.entitlements` lines 5-12; `TunnelProv/TunnelProv.entitlements` lines 5-8 | External dependency for free sideload |
| S11 | idevice `c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5` | 2026-08-26 | SOURCE_CODE | DVT LocationSimulation channel and methods | CONFIRMED | `idevice/src/services/dvt/location_simulation.rs` lines 1-5, 63-68, 73-110 | Core POC service |
| S12 | idevice `c442bd...` | 2026-08-26 | SOURCE_CODE | RPPairing file fields are Ed25519 keys, identifier, optional alt_irk | CONFIRMED | `idevice/src/remote_pairing/rp_pairing_file.rs` lines 15-21, 68-147 | Contains private key |
| S13 | idevice `c442bd...` | 2026-08-26 | SOURCE_CODE | RPPairing uses X25519, Ed25519, HKDF, ChaCha20Poly1305 and TLS-PSK tunnel key | CONFIRMED | `remote_pairing/mod.rs` lines 7-21, 53-55, 134-299 | Cryptographic boundary |
| S14 | idevice `c442bd...` | 2026-08-26 | SOURCE_CODE | Raw RPPairing tunnel path is direct TCP -> RPPairing -> tunnel | CONFIRMED | `ffi/src/tunnel_provider.rs` lines 6-10, 32-75, 280-337 | Matches Locus |
| S15 | idevice `c442bd...` | 2026-08-26 | SOURCE_CODE | iOS 27 pairable-host advertises `_remotepairing-pairable-host._tcp` | CONFIRMED | `ffi/src/pairable_host.rs` lines 1-8, 115-127, 197-230 | Future no-Mac path |
| S16 | pymobiledevice3 `4fcfdd82ffcf30b6a11460b505fadb5579e7b2bb` | 2026-08-26 | SOURCE_CODE | UserspaceRsdTunnel is host-side in-process PyTCP and falls back to RemotePairing over Bonjour | CONFIRMED | `remote/userspace_tunnel.py` lines 1-30, 706-793 | Current IOSSim dependency |
| S17 | pymobiledevice3 `4fcfdd...` | 2026-08-26 | SOURCE_CODE | pymobiledevice3 DVT service names match idevice | CONFIRMED | `services/dvt/instruments/location_simulation.py` lines 7-47 | Independent implementation |
| S18 | go-ios `3ebc297691a9e364772aef027744ebc0c49421a5` | 2026-08-26 | SOURCE_CODE | Tunnel manager skips network devices in audited host path | CONFIRMED | `ios/tunnel/tunnel_api.go` lines 444-500 | Counterexample; not same-device LocalDevVPN |
| S19 | go-ios `3ebc...` | 2026-08-26 | SOURCE_CODE | TCP tunnel uses pair-verify shared secret as TLS-PSK on iOS 18.2+ | STRONG EVIDENCE | `ios/tunnel/untrusted.go` lines 178-218 | Corroborates idevice |
| S20 | Apple Developer Documentation | 2026-08-26 | PRIMARY_APPLE | Packet Tunnel providers require NetworkExtension entitlement and use packetFlow/routes | CONFIRMED | `NEPacketTunnelProvider`, `NETunnelProviderManager` docs | Official API boundary |
| S21 | Apple Developer Documentation | 2026-08-26 | PRIMARY_APPLE | Developer Mode is required for development workflows and exposes developer-only functionality | CONFIRMED | "Enabling Developer Mode on a device" | Security boundary |
| S22 | Apple Developer Documentation | 2026-08-26 | PRIMARY_APPLE | iOS/iPadOS 27 or later required for wireless pairing in Device Hub | CONFIRMED | "Managing your simulated and physical devices in Device Hub" | Supports iOS 27 future path |
| S23 | Apple Developer Documentation | 2026-08-26 | PRIMARY_APPLE | `isSimulatedBySoftware` and `isProducedByAccessory` identify location source | CONFIRMED | Core Location docs | Needed for verifier |
| S24 | Mirage-updates `37adcf5b9c7ee67cae78ebafdb5aa7a1459175cb` | 2026-08-26 | OPEN_SOURCE_DOC | Mirage claims DVT GPS override, one-time RPPairing, iOS 27 on-device pairing, LocalDevVPN fallback | PLAUSIBLE | `README.md` lines 35-46, 102-125; `SETUP.md` lines 62-91 | Not source-auditable |
| S25 | iAnyGo docs | 2026-08-26 | VENDOR_DOC | Computer installs helper app; computer no longer needed after iOS app install | PLAUSIBLE | Vendor install guide | Marketing, not protocol proof |
| S26 | iMyFone AnyTo/iGo docs | 2026-08-26 | VENDOR_DOC | Computer-assisted install, Developer Mode, profile/VPN helper app workflow | PLAUSIBLE | Vendor iOS guide | Marketing, mixed modes |
| S27 | apple-corelocation-experiments `0b136860e80585c02c12f64933995b872d7623af` | 2026-08-26 | SOURCE_CODE | WLOC endpoint `/clls/wloc` maps BSSID/cell data to coordinates | STRONG EVIDENCE | `README.md` lines 10-23, 86-94; `lib/wloc.go` lines 29-155 | Secondary fallback |
| S28 | acheong08/ios-location-spoofer `bfb44fa3b00e2cc8820536fb58e375d7269ef90a` | 2026-08-26 | SOURCE_CODE | WLOC spoof app uses PacketTunnel/proxy/MITM to rewrite responses | CONFIRMED | `README.md` lines 10-44; `Tunnel/PacketTunnelProvider.swift` lines 20-110; `GoSpoofer/main.go` lines 193-338 | AGPL; not DVT |
| S29 | mekos2772/ios-location-spoofer `c8ef1d81b30b3fa759c1efe8761303e330515bf5` | 2026-08-26 | OPEN_SOURCE_DOC/SOURCE_CODE | WLOC JS port rewrites Wi-Fi and cell fields | PLAUSIBLE | `README.en.md` lines 11-26, 42-63; `location-spoofer.js` field rewrite references | AGPL; not DVT |

## Permanent Links For Highest-Value External Evidence

- Locus on-device DVT call path: `https://github.com/ChrisMack32/Locus/blob/83c8fb324983728e8f44759cfd834dc637ee38b5/Locus/Engine/LocationEngine.swift#L98-L162`
- Locus RPPairing import/storage: `https://github.com/ChrisMack32/Locus/blob/83c8fb324983728e8f44759cfd834dc637ee38b5/Locus/Engine/PairingStore.swift#L10-L111`
- Locus iOS 27 PairableHost service: `https://github.com/ChrisMack32/Locus/blob/83c8fb324983728e8f44759cfd834dc637ee38b5/Locus/Engine/PairOnDeviceService.swift#L188-L255`
- Locus PairableHost Bonjour relay: `https://github.com/ChrisMack32/Locus/blob/83c8fb324983728e8f44759cfd834dc637ee38b5/Locus/Engine/PairableHostAdvertiser.swift#L27-L102`
- LocalDevVPN packet rewrite: `https://github.com/seomin0610/LocalDevVPN/blob/467a845f04a4b0936a7fc3dd0b326b49aaf98bdf/TunnelProv/PacketTunnelProvider.swift#L18-L58`
- idevice LocationSimulation service: `https://github.com/jkcoxson/idevice/blob/c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5/idevice/src/services/dvt/location_simulation.rs#L1-L110`
- idevice RPPairing file format: `https://github.com/jkcoxson/idevice/blob/c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5/idevice/src/remote_pairing/rp_pairing_file.rs#L15-L147`
- idevice raw RPPairing tunnel FFI: `https://github.com/jkcoxson/idevice/blob/c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5/ffi/src/tunnel_provider.rs#L280-L337`
- idevice pairable-host FFI: `https://github.com/jkcoxson/idevice/blob/c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5/ffi/src/pairable_host.rs#L1-L8`
- pymobiledevice3 userspace tunnel selection: `https://github.com/doronz88/pymobiledevice3/blob/4fcfdd82ffcf30b6a11460b505fadb5579e7b2bb/pymobiledevice3/remote/userspace_tunnel.py#L706-L793`
- pymobiledevice3 DVT LocationSimulation: `https://github.com/doronz88/pymobiledevice3/blob/4fcfdd82ffcf30b6a11460b505fadb5579e7b2bb/pymobiledevice3/services/dvt/instruments/location_simulation.py#L7-L47`
- go-ios network-device tunnel skip: `https://github.com/danielpaulus/go-ios/blob/3ebc297691a9e364772aef027744ebc0c49421a5/ios/tunnel/tunnel_api.go#L444-L500`
- Mirage public cellular workaround claim: `https://github.com/xXWapixelXx/Mirage-updates/blob/37adcf5b9c7ee67cae78ebafdb5aa7a1459175cb/SETUP.md#L62-L91`
- acheong08 WLOC app mechanism: `https://github.com/acheong08/ios-location-spoofer/blob/bfb44fa3b00e2cc8820536fb58e375d7269ef90a/README.md#L10-L44`
- acheong08 WLOC request library: `https://github.com/acheong08/apple-corelocation-experiments/blob/0b136860e80585c02c12f64933995b872d7623af/lib/wloc.go#L29-L155`
