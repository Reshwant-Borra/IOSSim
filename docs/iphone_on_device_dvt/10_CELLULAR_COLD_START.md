# Cellular Cold-Start

## Verdict

STATUS: UNKNOWN / EXPERIMENT REQUIRED

Do not claim cellular cold-start works until IOSSim reproduces it on real devices. The audited source proves Wi-Fi cold-start is plausible and Wi-Fi-to-cellular continuation is strongly evidenced, but cellular-only session creation remains the critical gate.

## Known Evidence

STATUS: STRONG EVIDENCE

Locus says to start a teleport on Wi-Fi first and then continue on cellular. Its implementation contains no visible alternate cellular bootstrap logic.

STATUS: PLAUSIBLE / UNCONFIRMED

Mirage claims mobile-data operation and says with external LocalDevVPN the user may need to turn Mobile Data off for a few seconds so the session connects, then turn it back on. This suggests a route/path conflict rather than DVT authentication failure, but no Mirage source verifies it.

## Layer Separation

The experiments must identify which layer fails:

```text
Discovery
  - Is mDNS/Bonjour needed at runtime?
  - Can IOSSim bypass discovery by dialing 10.7.0.1:49152?

Routing
  - Does iOS install the 10.7.0.0/24 LocalDevVPN route while cellular is active?
  - Does a TCP SYN to 10.7.0.1:49152 enter packetFlow?

Service Binding
  - Is Apple's RemotePairing listener bound only when Wi-Fi/en0 exists?
  - Does the listener bind to utun/local virtual interfaces?

Authentication
  - Does RPPairing pair-verify fail, or is TCP refused before authentication?

NetworkExtension Policy
  - Does NECP prefer cellular/default IPv4 and reject the local packet-tunnel path?
  - Does temporarily disabling cellular make the local route active?
```

## Hypotheses

H1: RemotePairing listener only appears when Wi-Fi is associated.

STATUS: PLAUSIBLE

Test with Wi-Fi off/cellular off plus LocalDevVPN route and direct TCP probe to `10.7.0.1:49152`.

H2: LocalDevVPN route installation conflicts with cellular as the only IPv4 path.

STATUS: PLAUSIBLE

Mirage claims a mobile-data-off toggle frees the route. PacketFlow logs should show whether packets enter the tunnel before/after the toggle.

H3: Discovery is Wi-Fi-only but direct dial works.

STATUS: PLAUSIBLE

Locus does not rely on Bonjour at runtime; it hardcodes the LocalDevVPN target IP. IOSSim should avoid mDNS as a runtime dependency for the POC.

H4: RPPairing authentication is independent of external network once TCP connects.

STATUS: STRONG EVIDENCE

idevice raw RPPairing tunnel creation only needs the reachable socket and pairing file. Authentication failure should produce protocol errors, not TCP refusal.

H5: No external network is needed.

STATUS: UNKNOWN

LocalDevVPN itself is local, but Apple's developer listener lifecycle may still depend on active interface state. E5 is required.
