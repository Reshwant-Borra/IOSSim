# Goal And Acceptance Criteria

## Exact Goal

Determine whether IOSSim can become:

```text
Mac once -> iPhone only afterward
```

The runtime target is not iPhone-to-Mac over Wi-Fi, not iPhone-to-home-Mac over the Internet, and not a carried companion computer. The iPhone should establish the developer tunnel to itself and set system-wide simulated location while the Mac is powered off.

## Safety Scope

All experimentation is for devices owned and authorized by the developer. This research is limited to Apple's developer location-simulation architecture and legitimate device-development experimentation. It does not design anti-fraud, anti-cheat, device-management bypass, or third-party security-evasion features.

## Minimum Success

STATUS: PLAUSIBLE / STRONG EVIDENCE

```text
Mac used once.
Mac powered off.
iPhone on unrelated Wi-Fi.
IOSSim establishes local developer tunnel.
IOSSim sets arbitrary system location.
```

Evidence: Locus source shows an on-device Swift app importing an RPPairing plist, connecting to `10.7.0.1:49152`, creating a raw RPPairing tunnel, opening RSD/DVT, and calling `LocationSimulation`.

## Strong Success

STATUS: STRONG EVIDENCE

```text
Minimum success plus Wi-Fi -> cellular continuation.
```

Evidence: Locus explicitly documents starting on Wi-Fi and continuing on cellular. Mirage also claims this and describes a mobile-data workaround, but Mirage is not source-auditable.

## Target Success

STATUS: UNKNOWN / EXPERIMENT REQUIRED

```text
Mac used once.
Mac powered off indefinitely.
Only iPhone carried.
iPhone has LTE/5G only.
Cold-launch IOSSim.
Establish local developer session.
Set and update arbitrary coordinates.
```

No audited source proves a clean cellular-only cold-start without toggling cellular or using Wi-Fi first.

## Future Success

STATUS: PLAUSIBLE FOR IOS 27+, NOT REQUIRED FOR MAC-ONCE POC

Apple's Xcode Device Hub documentation says iOS/iPadOS 27 or later can pair wirelessly. The idevice and Locus source implement a pairable-host responder using `_remotepairing-pairable-host._tcp`, allowing the iPhone to pair to an on-device host-like listener. This may remove the initial Mac requirement on iOS 27+, but the first POC should stay focused on iOS 18-26 Mac-once behavior.
