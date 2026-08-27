# Prior Findings

## Finding A - Commercial Computer-Once Operation

STATUS: PLAUSIBLE, VENDOR CLAIM

Commercial products now commonly describe a setup in which a desktop app installs/provisions an iOS helper app, after which the user can operate from the phone. iAnyGo documents installing an iOS app with a computer and then says the computer is no longer needed after installation. AnyTo/iGo documents a computer-assisted install and then an iOS app/VPN workflow.

Correction: vendor pages mix multiple modes: desktop DVT, Bluetooth/external-GPS style flows, helper apps, VPN/native mode, and network-positioning mode. Their marketing is not sufficient evidence for IOSSim's DVT architecture.

## Finding B - Locus

STATUS: CONFIRMED SOURCE-CODE EVIDENCE

Locus implements the reported on-device DVT architecture. It imports an RPPairing plist, uses LocalDevVPN reachability at `10.7.0.1`, calls idevice FFI `tunnel_create_rppairing`, opens RSD, opens `LocationSimulation`, and sends DVT set/clear calls.

Correction: Locus does not prove cellular cold-start. Its README says to start on Wi-Fi first and then continue on cellular.

## Finding C - LocalDevVPN

STATUS: CONFIRMED SOURCE-CODE EVIDENCE

LocalDevVPN is a Packet Tunnel app/extension that creates a local virtual IPv4 network and loops packets through `packetFlow` after rewriting addresses. It is needed to give the on-device app a routable path to the developer endpoint. It is not the RPPairing authenticator and does not itself create DVT sessions.

## Finding D - RPPairing

STATUS: STRONG EVIDENCE

RPPairing files contain long-term Ed25519 public/private key material, a stable identifier, and optionally a 16-byte `alt_irk` for mDNS identity/auth tags. The idevice implementation uses X25519 pair-verify, Ed25519 signatures, HKDF-SHA512, and ChaCha20Poly1305. The resulting shared secret is used for RemotePairing message encryption and TLS-PSK tunnel creation.

Unknowns: exact device-side invalidation behavior after iOS update, reset, Developer Mode toggle, and reboot must be experimentally measured.

## Finding E - Mirage

STATUS: PLAUSIBLE BUT NOT SOURCE-AUDITABLE

Mirage's public update repository describes the same high-level architecture and distinguishes GPS override from Wi-Fi/network-positioning mode. It claims no-computer iOS 27 pairing, iOS 18-26 one-time RPPairing, LocalDevVPN for free sideloads, and a mobile-data workaround.

Correction: Mirage is a public manifest/docs repository, not a source implementation. It cannot independently verify protocol mechanics.

## Finding F - Cellular Uncertainty

STATUS: CONFIRMED UNCERTAINTY

The strongest audited evidence supports:

```text
start DVT session while Wi-Fi path is available
  -> switch to cellular
  -> continue changing coordinates
```

No audited source proves:

```text
Wi-Fi off
cellular only
cold launch
new RPPairing tunnel and DVT session
```

Mirage claims a cellular workaround that temporarily disables mobile data to free the route, then reenables cellular after the session exists. Treat that as VENDOR/OPEN_SOURCE_DOC claim until reproduced.
