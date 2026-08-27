# Experiment Plan

All experiments use owned/authorized devices. The POC should set one hard-coded coordinate first and verify with a separate Core Location consumer.

## E1 - Mac-Off Wi-Fi

Setup: generate/import RPPairing once, power off Mac, connect iPhone to unrelated Wi-Fi, cold launch IOSSim POC.

Pass: POC starts local virtual networking, establishes RPPairing tunnel, opens DVT, sets coordinate, verifier reports `isSimulatedBySoftware == true`.

## E2 - Repeated Coordinates

Send 50 coordinate changes.

Record:

- tunnel setup latency;
- DVT channel setup latency;
- per-command latency;
- failure count;
- reconnect count;
- whether clear works afterward.

## E3 - Wi-Fi To Cellular

Start session on Wi-Fi, disable Wi-Fi, continue over LTE/5G.

Pass: at least 20 coordinate changes succeed after Wi-Fi is disabled.

## E4 - Cellular Cold-Start

Terminate POC and VPN, reboot if needed, Wi-Fi off, cellular on, launch from scratch.

Pass: new tunnel and DVT session establish without Mac, Wi-Fi, server, or companion device.

Critical instrumentation:

- interface list before VPN;
- route list visible to app if possible;
- packetFlow saw TCP packets to `10.7.0.1:49152`;
- TCP result: timeout/refused/connected;
- RPPairing result if connected.

## E5 - No External Network

Wi-Fi off, cellular off, start LocalDevVPN and direct TCP probe.

Purpose: separate external connectivity from interface-state/listener requirements.

## E6 - Reboot

Reboot iPhone while Mac remains off.

Record steps required:

- unlock only;
- reopen IOSSim only;
- restart LocalDevVPN;
- reimport pairing;
- impossible without Mac.

## E7 - App Force Quit

Force quit IOSSim, relaunch, try to reuse existing pairing and tunnel.

## E8 - VPN Restart

Stop LocalDevVPN while session is active, restart, observe whether IOSSim can reconnect and restore.

## E9 - Source Classification Verifier

Build a tiny separate Core Location consumer that records:

- latitude/longitude;
- timestamp;
- horizontal/vertical accuracy;
- `isSimulatedBySoftware`;
- `isProducedByAccessory`.

Pass for DVT: `isSimulatedBySoftware == true`, `isProducedByAccessory == false`.

## E10 - Drive Readiness

Without building Drive, test update rates:

- 0.5 Hz;
- 1 Hz;
- 2 Hz;
- 5 Hz.

Record stability and observed Core Location output. Locus source suggests 4 Hz joystick sends are attempted, but IOSSim must verify sustainable rates.
