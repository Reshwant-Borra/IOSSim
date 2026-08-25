# Advanced Wireless Diagnostics

Advanced Wireless Diagnostics is an isolated experimental IOSSim feature for preserving older same-LAN discovery and persistent tunnel experiments.

It is not Drive Testing and is not required for normal wireless location. The normal product path uses the main Device panel and the userspace RSD -> DVT -> DeviceInfo warmup -> LocationSimulation sequence documented in [../validation_evidence/wireless_userspace_location.md](../validation_evidence/wireless_userspace_location.md).

## Scope

The lab tests two hypotheses:

- Experiment A, Remove Cable After Pairing: start with USB connected, capture the stable baseline, run IOSSim native pairing preparation, unplug USB, then prove whether the same iPhone can be discovered and controlled over Wi-Fi.
- Experiment B, Fresh Cable-Free Session: start IOSSim with USB already disconnected after a previous wired pairing setup, discover the paired iPhone over the same LAN, create a fresh Wi-Fi tunnel/RSD session, Set Location, manually confirm device behavior, and Reset GPS.

Historical Experiment B was the strongest evidence for the older persistent-tunnel path. Production wireless readiness no longer depends on this lab reporting:

```text
CABLE-FREE IOSIM CONFIRMED ON THIS TESTED DEVICE/CONFIGURATION
```

Do not generalize that to every device, iOS version, network, or future pymobiledevice3 version.

## Launch

Stable mode remains the default and hides Advanced Wireless Diagnostics.

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\reshw\Desktop\ios-location-sim\RUN_EVERYTHING.ps1" -Mode wireless-testing
```

macOS:

```bash
cd /path/to/ios-location-sim
chmod +x RUN_EVERYTHING.sh
./RUN_EVERYTHING.sh wireless-testing
```

Manual backend/frontend gates:

```text
IOS_SIM_ENABLE_EXPERIMENTAL=1
IOS_SIM_ENABLE_WIRELESS_TESTING=1
VITE_ENABLE_EXPERIMENTAL_FEATURES=1
VITE_ENABLE_WIRELESS_TESTING=1
```

Drive Testing flags are not required and should not be enabled for Advanced Wireless Diagnostics.

## IOSSim Native Pairing Preparation

For iOS 26.5.2, expect initial wired setup.

1. Connect the iPhone by USB.
2. Unlock it and tap Trust if iOS prompts.
3. Enable Developer Mode if iOS requires it.
4. Run Wireless Pairing Check in IOSSim.
5. IOSSim runs RemotePairing bootstrap over trusted USB.
6. IOSSim enables lockdown Wi-Fi connections using the syntax supported by the installed pymobiledevice3.
7. IOSSim runs wireless discovery probes.
8. Keep the computer and iPhone on the same Wi-Fi/LAN.

On the physical macOS test host with pymobiledevice3 10.7.4, IOSSim detected and uses:

```text
python -m pymobiledevice3 lockdown remotepairing --pair [--udid UDID]
python -m pymobiledevice3 lockdown wifi-connections --state on [--udid UDID]
```

The RemotePairing step is host preparation only. It does not create a Wi-Fi tunnel and IOSSim stores only safe evidence such as status, abbreviated UDID, device name/model/iOS when available, wireProtocolVersion, timestamp, latency, and concise failure status. It does not persist pair records, private keys, KVS blobs, or raw secret-bearing command output.

If either native command is unsupported by the installed CLI, IOSSim reports `UNSUPPORTED` instead of crashing. Xcode remains an optional macOS troubleshooting path: use the installed Xcode device-management interface only if IOSSim native preparation is partial, unsupported, or inconclusive.

IOSSim reports pairing state as one of:

- CONFIRMED BY IOSSim
- LIKELY READY
- MANUAL CONFIRMATION REQUIRED
- NOT READY
- UNKNOWN

UNKNOWN does not mean impossible. It means the backend cannot introspect that state reliably.

## Verified pymobiledevice3 10.7.4 Command Shapes

The implementation constructs commands dynamically from the active Python executable, but the command shapes are:

```text
python -m pymobiledevice3 usbmux list --usb
python -m pymobiledevice3 usbmux list --network
python -m pymobiledevice3 remote browse --timeout 2
python -m pymobiledevice3 bonjour remotepairing --timeout 2
python -m pymobiledevice3 bonjour rsd
python -m pymobiledevice3 bonjour mobdev2 --timeout 2
python -m pymobiledevice3 lockdown remotepairing --pair [--udid UDID]
python -m pymobiledevice3 lockdown wifi-connections --state on [--udid UDID]
python -m pymobiledevice3 remote start-tunnel --connection-type wifi --script-mode [--udid UDID] --protocol quic
python -m pymobiledevice3 remote start-tunnel --connection-type wifi --script-mode [--udid UDID] --protocol tcp
python -m pymobiledevice3 remote rsd-info --rsd HOST PORT
python -m pymobiledevice3 developer dvt simulate-location set --rsd HOST PORT -- LAT LON
python -m pymobiledevice3 developer dvt simulate-location clear --rsd HOST PORT
```

For the installed 10.7.4 CLI, `lockdown wifi-connections --help` shows `--state <on|off>`, so IOSSim uses `--state on`. Do not substitute syntax from another pymobiledevice3 version without rechecking `--help`.

`bonjour mobdev2 --timeout 10` and `bonjour rsd` returned `[]` in the physical test environment before a tunnel existed, so IOSSim does not assume either means fresh Wi-Fi RSD is available.

## Tunnel Strategy and Diagnostics

Discovery alone is not success. The lab records `DISCOVERY PASS / TUNNEL FAILED` separately from total wireless failure.

The production wireless feature does not call `remote start-tunnel`.

For protocol `default`, this diagnostic lab now runs a deliberately conservative strategy:

1. Record whether USB is absent before tunnel creation. A tunnel created while USB is present can be useful evidence but cannot count as cable-free proof.
2. Run wireless discovery immediately before tunnel start and score RemotePairing candidates conservatively. IPv4 candidates are preferred over duplicate link-local IPv6 candidates when both are advertised.
3. Attempt QUIC only.
4. Do not fall back to TCP automatically.
5. If no attempt succeeds, return the attempt with protocol, candidate, pid, return code, signal when inferable, timeout state, output tail, failure class, and failure message.

Explicit `tcp` or `quic` protocol selection attempts only that protocol. IOSSim does not silently retry the other protocol for explicit choices.

Observed physical caveats on iPhone 17 Pro, iPhone18,1, iOS 26.5.2:

- USB can be absent and IOSSim can still detect the same iPhone wirelessly.
- RemotePairingTunnelService can be discovered over LAN on port 49152.
- RemotePairing bootstrap over trusted USB returned wireProtocolVersion 24.
- QUIC RemotePairing reached the device but failed with `Encountered a QUIC protocol error.`
- Forcing TCP could crash the pymobiledevice3 process with a shell-reported `bus error`.
- Link-local candidates can fail with `OSError: [Errno 65] No route to host`.
- Later discovery exposed usable-looking IPv4 candidates.
- The successful physical wireless Set/Reset path was later proven through userspace RSD and does not require persistent QUIC/TCP tunnels.

## Staged Workflow

Wireless Testing Lab exposes these stages:

1. Wired Baseline
2. Wireless Pairing Preparation
3. Ready to Unplug
4. Detect Without USB
5. Establish Wi-Fi Tunnel
6. Validate Fresh RSD
7. Test Wireless Set Location
8. Manual Device Confirmation
9. Test Wireless Reset GPS
10. Final Verdict

The UI records each command result separately. Full identifiers are redacted from UI and reports.

## Experiment A: Remove Cable After Pairing

1. Launch `wireless-testing` mode.
2. Create Experiment A.
3. Run Wired Baseline with USB connected.
4. Optionally run baseline Set Location and Reset GPS through the stable path.
5. Complete IOSSim native pairing preparation. Use Xcode only as optional troubleshooting if IOSSim reports partial or unsupported preparation.
6. Run Wireless Pairing Check.
7. Click Ready to Unplug.
8. Physically remove the USB cable.
9. Click Cable Removed - Continue Test. USB discovery must show no USB device for cable-free proof.
10. Run Detect Without USB.
11. Start Fresh Wi-Fi Tunnel.
12. Validate Fresh RSD.
13. Test Wireless Set Location with an explicit coordinate.
14. Confirm manually whether the iPhone location actually moved.
15. Test Wireless Reset GPS.
16. Generate the final verdict and report.

Pass criteria require USB absent before Wi-Fi tunnel creation, same iPhone reachable wirelessly, fresh Wi-Fi RSD, Set Location success, positive manual confirmation, and Reset GPS success.

## Experiment B: Fresh Cable-Free Session

1. Complete IOSSim native pairing preparation earlier while USB is connected. Use Xcode only as optional troubleshooting if needed.
2. Close IOSSim completely.
3. Disconnect USB before launching IOSSim.
4. Keep the computer and iPhone on the same LAN.
5. Launch `wireless-testing` mode.
6. Create Experiment B.
7. Run Detect Without USB.
8. Start Fresh Wi-Fi Tunnel.
9. Validate Fresh RSD.
10. Test Wireless Set Location.
11. Confirm manually whether the iPhone location changed.
12. Test Wireless Reset GPS.
13. Generate the report.

This is the strongest cable-free test because no USB is present at IOSSim session start.

## Reports and Logs

Reports are written locally under:

```text
backend/data/wireless_testing/experiments/WIRELESS-...
```

Each experiment folder contains manifest data, event logs, observations, and `report.md`. JSON export is available from the UI.

Reports answer:

- Was USB connected at test start?
- Was USB absent before the Wi-Fi tunnel command started?
- Was the device discovered wirelessly?
- Did RemotePairing bootstrap complete?
- Were Wi-Fi connections enabled?
- Was a Wi-Fi developer tunnel established?
- Which QUIC/TCP tunnel attempts succeeded, failed, or crashed?
- Was fresh RSD obtained?
- Did Set Location succeed?
- Did the user confirm location changed?
- Did Reset GPS succeed?
- Did the tunnel remain stable?
- What verdict is justified?

## Recovery

At any point:

1. Click Stop Wireless Test.
2. Click Stop Wi-Fi Tunnel.
3. Reconnect USB.
4. Return to the normal IOSSim surface.
5. Initialize the known-good USB tunnel if needed.
6. Use stable Reset GPS.

Wireless state is separate from the stable USB tunnel state. A Wi-Fi failure should not overwrite stable USB connection state.

## Known Limits

- Initial trust/pairing may still require USB.
- IOSSim cannot always prove Xcode wireless pairing state; Xcode is fallback troubleshooting, not required evidence when native preparation succeeds.
- Bonjour and remote discovery can be network-sensitive.
- A remote candidate not appearing at one moment is not proof that cable-free operation is impossible.
- RemotePairing discovery on port 49152 is not the same as a fresh RSD tunnel.
- A tunnel created while USB is still connected cannot prove cable-free operation.
- Cached USB RSD cannot qualify as fresh Wi-Fi RSD.
- QUIC/TCP tunnel failures can be pymobiledevice3 or Apple protocol behavior, not proof that wireless discovery is impossible.
- A successful Set Location subprocess without positive manual device confirmation is partial or inconclusive.
- Wireless Set Location without successful Reset GPS is not a full success.
