# Alternative Architectures

## A - On-Device DVT Via Imported RPPairing And LocalDevVPN

STATUS: RECOMMENDED POC

```text
one-time Mac/USB RPPairing generation
  -> import pairing file into IOSSim iOS component
  -> start LocalDevVPN
  -> dial 10.7.0.1:49152
  -> raw RPPairing
  -> TLS-PSK tunnel
  -> RSD/DVT LocationSimulation
```

This is the narrowest path that tests the core question.

## B - On-Device DVT With Built-In Packet Tunnel

STATUS: PLAUSIBLE / ENTITLEMENT RISK

Same as A, but IOSSim ships its own Packet Tunnel extension instead of relying on LocalDevVPN. Better UX and fewer dependencies, but requires NetworkExtension entitlement and more distribution risk.

## C - iOS 27 Same-Device PairableHost

STATUS: FUTURE POC

Use PairableHost to create the RPPairing file on the iPhone itself:

```text
IOSSim advertises _remotepairing-pairable-host._tcp
  -> user opens Settings / Developer Mode / Pair with Host
  -> IOSSim displays PIN
  -> iOS pairs with IOSSim's host identity
  -> IOSSim stores RPPairing
```

Useful after the Mac-once POC passes.

## D - WLOC / Network Positioning Fallback

STATUS: SECONDARY FALLBACK ONLY

Packet Tunnel plus MITM rewrites Apple `/clls/wloc` responses. This can affect network-derived location and may include cell tower data, but it is not DVT, likely depends on certificates/proxying and location cache behavior, and may lose to GPS/GNSS outdoors.

## E - Keep Mac Or Server In Loop

STATUS: REJECTED FOR THIS TARGET

Out of scope because the target explicitly requires the Mac powered off and no home server/cloud Linux/Raspberry Pi runtime dependency.
