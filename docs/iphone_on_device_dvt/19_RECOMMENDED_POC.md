# Recommended POC

## Research Verdict

GO WITH RISKS.

The narrow POC should be built next. It should not include polished UI, Drive, search, accounts, cloud services, remote Mac support, or WLOC fallback. It should answer only:

```text
Can this iPhone set its own DVT simulated location while the Mac is powered off?
```

## Question 1 - Can IOSSim Realistically Become Mac Once, iPhone-Only Afterward?

STATUS: GO WITH RISKS

Yes for the minimum Wi-Fi cold-start target. Locus source proves the architecture is implementable on stock iOS with an imported RPPairing file, LocalDevVPN, idevice FFI, and DVT LocationSimulation.

The full "anywhere, cellular-only cold-start" target is not proven.

## Question 2 - Exact Architecture To Implement

```text
One time:
  Mac + USB trust
  -> generate RPPairing file using idevice/compatible tool
  -> transfer pairing file to iPhone
  -> import into IOSSim POC with semantic validation

Runtime:
  Mac powered off
  -> user launches IOSSim POC
  -> ensure LocalDevVPN is connected
  -> IOSSim dials 10.7.0.1:49152
  -> raw RPPairing pair-verify
  -> create TLS-PSK developer tunnel
  -> RSD handshake
  -> DVT remote server
  -> LocationSimulation set hard-coded coordinate
  -> separate verifier checks Core Location source
```

## Question 3 - What To Reuse

Reuse/pin idevice MIT components behind a minimal C ABI:

- RPPairing plist read/validate.
- Raw RPPairing tunnel creation.
- RSD/DVT remote server connect.
- LocationSimulation set/clear.
- Later: iOS 27 pairable-host.

Use LocalDevVPN externally for the first POC unless IOSSim already has a valid Packet Tunnel entitlement.

## Question 4 - What Not To Reuse

- Do not embed pymobiledevice3 in the iOS app: GPL-3.0 and host/Python assumptions.
- Do not copy WLOC spoofing projects into the POC: AGPL and different engine.
- Do not copy Locus UI/session code: study it, but keep IOSSim's POC narrow.
- Do not rely on Mirage as implementation evidence: docs only.

## Question 5 - Apple Services / Protocols

- RemotePairing / RPPairing.
- `_remotepairing._tcp` on the local developer endpoint.
- TLS-PSK developer tunnel.
- RSD.
- DVT/DTX remote server.
- `com.apple.instruments.server.services.LocationSimulation`.
- `simulateLocationWithLatitude:longitude:`.
- `stopLocationSimulation`.
- iOS 27 future: `_remotepairing-pairable-host._tcp`.

## Question 6 - Why LocalDevVPN Matters

STATUS: CONFIRMED FOR REACHABILITY, EXACT APPLE BINDING STILL EXPERIMENTAL

LocalDevVPN supplies a local routable IPv4 path (`10.7.0.0/24`) that an app can use to reach the same iPhone's developer endpoint. It is not the tunnel authenticator. It is the path that makes `10.7.0.1:49152` reachable from app space.

## Question 7 - What RPPairing Provides

RPPairing provides the trusted host identity and cryptographic material needed to pair-verify with the iPhone and derive the secret used for encrypted RemotePairing traffic and TLS-PSK tunnel creation.

## Question 8 - Can The Mac Truly Be Powered Off?

STATUS: STRONG EVIDENCE FOR WI-FI TARGET

Yes, if the iPhone has the RPPairing file and can reach the local developer endpoint. Locus source has no runtime Mac dependency. The POC must physically power off the Mac for E1.

## Question 9 - Can This Work On Unrelated Wi-Fi?

STATUS: PLAUSIBLE / NEEDS POC

It should not require the original Mac's Wi-Fi because the runtime path is same-device. It may require Wi-Fi interface state, not same-LAN host discovery. E1 should use unrelated Wi-Fi.

## Question 10 - Can It Continue On Cellular?

STATUS: STRONG EVIDENCE

Locus and Mirage both state Wi-Fi-to-cellular continuation works after a session exists. POC E3 must reproduce this.

## Question 11 - Can It Cold-Start On Cellular?

STATUS: UNKNOWN / CRITICAL GATE

Not proven. Mirage claims a workaround involving briefly disabling Mobile Data with LocalDevVPN. Treat cellular cold-start as the main blocker for the ultimate target.

## Question 12 - What Happens After Reboot?

STATUS: UNKNOWN

Expected: pairing persists, active DVT simulation does not. E6 must measure exact restart steps.

## Question 13 - Signing / Entitlements

Minimum POC with external LocalDevVPN:

- sideloaded IOSSim iOS component;
- Developer Mode;
- Local Network permission for future iOS 27 pairing;
- no built-in Packet Tunnel entitlement needed if LocalDevVPN is external.

Built-in tunnel:

- paid developer account likely required;
- NetworkExtension Packet Tunnel entitlement required;
- TestFlight/App Store feasibility unknown.

## Question 14 - Drive Later?

STATUS: PLAUSIBLE

Locus attempts 4 Hz joystick updates and periodic resends, and IOSSim already has host-side GPX/route logic. Do not build Drive until E10 establishes stable update rates and reconnect behavior.

## Question 15 - Smallest POC

Suggested next files/components:

- `ios-poc/PairingImport`: import RPPairing plist, validate semantic keys, store securely.
- `ios-poc/LocalTunnelProbe`: check LocalDevVPN presence, interface addresses, and TCP reachability to `10.7.0.1:49152`.
- `ios-poc/IdeviceBridge`: pinned idevice FFI wrapper for connect/set/clear.
- `ios-poc/OneShotLocationSet`: hard-coded coordinate command.
- `ios-poc/LocationVerifier`: separate Core Location consumer logging coordinate and source information.
- `ios-poc/DiagnosticsLog`: redacted structured events for E1-E10.

Do not integrate with the production IOSSim UI until E1 passes and E4 is classified.
