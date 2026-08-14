# 20 Final Recommendation

## Direct answers

| Question | Answer | Classification |
|---|---|---|
| Can IOSSim operate without a cable after initial pairing? | Likely, if pymobiledevice3 Wi-Fi RemotePairing/RSD works on the target phone. Apple supports wireless Xcode devices; IOSSim still needs experiments. | LIKELY |
| Can IOSSim reconnect wirelessly after cable removal? | Possible via `pymobiledevice3 remote start-tunnel -t wifi`, but unproven in this repo. | POSSIBLE BUT UNPROVEN |
| Can IOSSim survive phone lock? | Likely while awake; Apple warns sleeping network devices may disconnect. | LIKELY |
| Can IOSSim survive phone reboot without reconnecting USB? | Pairing likely persists, but fresh wireless tunnel after reboot is unproven. | POSSIBLE BUT UNPROVEN |
| Can the Mac be physically remote? | Yes if the phone is routably reachable or a relay exists. Direct arbitrary remote Mac is fragile. | POSSIBLE BUT UNPROVEN |
| Does same-LAN networking matter? | Yes for Bonjour discovery. Manual IP may avoid same-LAN if routing works. | CONFIRMED |
| Can VPN routing replace same-LAN? | Maybe, but Apple/Xcode VPN issues make this unproven. | POSSIBLE BUT UNPROVEN |
| Can the IOSSim frontend be controlled from the iPhone? | Yes, by exposing an authenticated LAN/Tailscale UI. | CONFIRMED ARCHITECTURALLY |
| Can the backend run headlessly? | Yes. | CONFIRMED ARCHITECTURALLY |
| Can the backend run in the cloud? | The UI/control plane can. The DVT bridge should remain local or near the phone. | LIKELY |
| What minimum component must remain near the phone? | A trusted host/agent or external GPS hardware. For DVT, a host able to pair, tunnel, and run DVT must be reachable. | CONFIRMED |
| Can a Raspberry Pi replace the Mac? | Possibly for pymobiledevice3 USB bridge; Wi-Fi/RSD on iOS 26 needs validation. It cannot run Xcode. | POSSIBLE BUT UNPROVEN |
| Can external GPS hardware eliminate the Mac? | Yes for hardware that iOS accepts system-wide and that can provide desired coordinates. This is not IOSSim’s DVT architecture. | LIKELY |
| Can Pythonista eliminate the Mac? | No. iOS sandbox blocks system-wide CoreLocation override and developer-service access. | NOT POSSIBLE WITH CURRENT PUBLIC TOOLING |
| Can a normal signed iPhone app eliminate the Mac? | No. | NOT POSSIBLE WITH CURRENT PUBLIC TOOLING |
| Can a jailbroken device eliminate the Mac? | Yes on compatible vulnerable versions/devices, not stock modern iOS 26.x. | POSSIBLE BUT UNPROVEN |
| What is the best architecture right now? | Keep stable USB, test Wi-Fi RSD/DVT, then add feature-flagged wireless tunnel mode. For remote use, use cloud/LAN UI plus local bridge agent. | CONFIRMED RECOMMENDATION |
| What is the easiest experiment next? | EXP-W03/EXP-W04: Xcode-pair wirelessly, run `pymobiledevice3 remote start-tunnel -t wifi`, then DVT set/clear with `--rsd`. | CONFIRMED |

## Final verdict

Best cable-free path:

```text
Initial USB trust/pairing
  -> Xcode/pymobiledevice3 wireless pairing
  -> pymobiledevice3 Wi-Fi RSD tunnel
  -> existing IOSSim DVT set/clear using --rsd
  -> optional iPhone Safari UI over Tailscale/LAN
```

Best hosted path:

```text
Cloud dashboard
  -> authenticated command channel
small local Mac/PC agent
  -> pymobiledevice3 / RSD / DVT
iPhone
```

Best “no computer at all” path:

```text
External MFi/commercial GPS spoof hardware
  -> iPhone CoreLocation accessory source
```

This is outside IOSSim’s current DVT path.

## Unsupported ideas rejected

- Stock iPhone-only Python/Shortcuts/app solution for system-wide location simulation.
- Public unauthenticated IOSSim API.
- Assuming a USB-created RSD endpoint survives unplug without testing.
- Assuming VPN/Tailscale replaces same-LAN Bonjour without testing.
- Assuming commercial “wireless” marketing means no desktop/control host.
- DIY BLE GPS as system-wide CoreLocation replacement.

## Recommended next experiment

Run this before any implementation:

```text
1. Pair iPhone with Xcode over USB and enable Connect via network.
2. Disconnect USB.
3. Run: python -m pymobiledevice3 remote browse
4. Run: python -m pymobiledevice3 remote start-tunnel --connection-type wifi --script-mode
5. Use returned HOST PORT:
   python -m pymobiledevice3 developer dvt simulate-location set --rsd HOST PORT -- 37.7749 -122.4194
6. Clear:
   python -m pymobiledevice3 developer dvt simulate-location clear --rsd HOST PORT
```

If step 4 or 5 fails on `pymobiledevice3 9.12.0`, repeat in an isolated venv with current `10.1.0` before declaring the architecture infeasible.

