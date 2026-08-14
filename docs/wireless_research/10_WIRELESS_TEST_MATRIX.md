# 10 Wireless Test Matrix

## Logging required for every test

Record:

```text
timestamp, platform, macOS/Windows/Linux version, iOS version,
pymobiledevice3 version, Python version, Xcode version if used,
device transport, USB connected, wireless detected, pairing state,
tunnel state, RSD address present, command attempted, duration,
result, stdout/stderr, disconnect reason
```

Redact full UDID, pair records, private keys, RSD secrets, and exact location unless necessary.

## Matrix

| ID | Setup | Command/action | Expected result | Pass criteria | Failure interpretation | Logs |
|---|---|---|---|---|---|---|
| W01 cable connected baseline | USB connected, trusted, Developer Mode on | Current IOSSim Initialize, Set, Reset | Stable path works | Set and clear succeed | Baseline broken; stop wireless work | IOSSim backend logs, pmd3 stderr |
| W02 establish tunnel then unplug | Run current `lockdown start-tunnel`, set location, unplug | DVT set again using stored RSD | Unknown | Set succeeds after unplug | USB-backed tunnel died | tunnel process exit, set command stderr |
| W03 restart tunnel after unplug | Paired phone, no cable | `pymobiledevice3 remote start-tunnel -t wifi --script-mode` | Wi-Fi RSD if paired | RSD host/port printed | Pairing/discovery not ready | remote browse output |
| W04 restart backend after unplug | Wireless-paired, backend killed/restarted | IOSSim status/init attempt | Current IOSSim likely fails | Device detected/tunnel established | Current code USB-only | `/api/status`, pmd3 help |
| W05 restart Mac after unplug | Wireless-paired, reboot Mac, no cable | Xcode Device Hub, pmd3 remote browse | Pair persists | Device visible without USB | Pair record not usable/wake issue | Xcode state, pmd3 logs |
| W06 reboot iPhone after unplug | Wireless-paired, reboot phone, no cable | Xcode/pmd3 browse/start tunnel | Pair likely persists; device may need wake/unlock | Tunnel starts | reboot cleared service/session | syslog/Xcode device logs |
| W07 switch Wi-Fi networks | Move phone to different Wi-Fi | Bonjour browse, IP connect | Bonjour fails; IP may work | Manual IP tunnel works | discovery/routing blocked | network addresses, port 62078 |
| W08 lock phone | Wireless tunnel active, lock screen | DVT set/clear | Possibly works if awake | Writes succeed for 5 min locked | lock/sleep gating | timing and device state |
| W09 screen off 30 min | Auto-Lock default | DVT set after idle | Apple warns may sleep | Writes succeed after 30 min | Wi-Fi sleep/power save | last successful heartbeat |
| W10 iPhone on hotspot | Mac joined iPhone hotspot or vice versa | Xcode/pmd3 browse/start tunnel | Unknown | RSD tunnel over hotspot | hotspot NAT/client isolation | IP routes, browse |
| W11 Mac Ethernet, iPhone Wi-Fi | Same LAN, different media | Bonjour/IP connect | Should work if same subnet | Xcode/pmd3 see phone | AP isolation/mDNS issue | ARP/mDNS/ping |
| W12 Tailscale active | Both devices on tailnet | Manual IP or tailnet IP connect | Unproven | DVT over tunnel works | Apple service not bound/routed | tailnet IP, pcap if safe |
| W13 VPN active | Corporate/private VPN active | Current baseline and wireless | May break Xcode 15+ device comms | No regression vs VPN off | VPN drops IPv6/directlink | VPN routes, pf/firewall state |

## Safety

Do not automate changing Developer Mode, Trust, VPN profiles, or network settings. Tests should prompt the human and collect observations.

