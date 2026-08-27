# Other Open Source Projects

## idevice

Repository: `https://github.com/jkcoxson/idevice`

Audited commit: `c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5`

License: MIT.

STATUS: CONFIRMED / REUSE CANDIDATE

idevice is the best source-level protocol implementation for an iOS on-device POC because it already has:

- RPPairing file generation/read/write.
- RPPairing pair-verify and pair-setup.
- raw RPPairing tunnel creation.
- TLS-PSK tunnel creation.
- RSD handshake.
- DVT remote server and LocationSimulation service.
- FFI exports used by Locus.
- iOS 27 pairable-host responder support.

Risk: the API is research-stage and evolving. Prefer pinning a commit and creating a narrow wrapper boundary.

## pymobiledevice3

Repository: `https://github.com/doronz88/pymobiledevice3`

Audited commit: `4fcfdd82ffcf30b6a11460b505fadb5579e7b2bb`

License: GPL-3.0.

STATUS: CONFIRMED / DO NOT EMBED IN IOS APP

pymobiledevice3 is IOSSim's current host-side dependency and remains excellent evidence for DVT service names and host-side tunnel behavior. Its userspace tunnel is Python/PyTCP, in-process only, and oriented around host-initiated connections. GPL-3.0 makes embedding or porting into a proprietary/non-GPL IOSSim app unattractive.

## go-ios

Repository: `https://github.com/danielpaulus/go-ios`

Audited commit: `3ebc297691a9e364772aef027744ebc0c49421a5`

License: MIT.

STATUS: USE AS REFERENCE, NOT FIRST REUSE

go-ios has strong RemotePairing/tunnel source. Its tunnel manager explicitly skips network devices in the audited path, saying network-connected devices cannot establish a tunnel. That is not directly applicable to same-device LocalDevVPN raw RPPairing, but it is important counter-evidence that not every host-side tunnel implementation can be repurposed.

## libimobiledevice

Repository: `https://github.com/libimobiledevice/libimobiledevice`

Audited commit: `fa0f79190142bc309307967c058f89c1b36eb6b8`

License: GPL-2.0 family in audited repo root.

STATUS: USE AS HISTORICAL REFERENCE ONLY

libimobiledevice includes legacy `idevicesetlocation` for `com.apple.dt.simulatelocation` and lockdown pairing code. It is not the right basis for iOS 17.4+ RPPairing/on-device DVT work.

## apple-corelocation-experiments

Repository: `https://github.com/acheong08/apple-corelocation-experiments`

Audited commit: `0b136860e80585c02c12f64933995b872d7623af`

STATUS: SECONDARY WLOC REFERENCE

Documents Apple's `/clls/wloc` network-positioning service, Wi-Fi BSSID response format, cell tower requests, and MITM-based spoofing experiments. This is not DVT, but it can inform a possible fallback engine.

## acheong08/ios-location-spoofer

Repository: `https://github.com/acheong08/ios-location-spoofer`

Audited commit: `bfb44fa3b00e2cc8820536fb58e375d7269ef90a`

License: AGPL-3.0.

STATUS: DO NOT REUSE CODE; REFERENCE ONLY

It is a standalone iOS app that starts a Packet Tunnel, an on-device proxy, MITMs Apple WLOC requests, and rewrites network-positioning responses. The AGPL license and non-DVT behavior make it a poor fit for the primary IOSSim POC.

## mekos2772/ios-location-spoofer

Repository: `https://github.com/mekos2772/ios-location-spoofer`

Audited commit: `c8ef1d81b30b3fa759c1efe8761303e330515bf5`

License: AGPL-3.0.

STATUS: REFERENCE ONLY

JavaScript/proxy-platform port of WLOC response rewriting. It adds cell-tower coordinate rewriting claims and multiple response envelope support. This is useful evidence that cellular network-positioning responses exist, but it is not DVT and should not be the first IOSSim architecture.
