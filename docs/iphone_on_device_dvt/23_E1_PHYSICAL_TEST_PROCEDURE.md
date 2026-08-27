# E1 Physical Test Procedure

Status: READY PROCEDURE / PHYSICAL INSTALL BLOCKED LOCALLY

Date: 2026-08-27

Do not mark E1 PASS unless the Mac is physically powered off and Core Location on the iPhone observes the expected coordinate.

## Preconditions

- Full Xcode installed.
- Xcode license accepted with `sudo xcodebuild -license`.
- Rust installed with `rustup`/`cargo`.
- `ios/scripts/build_idevice_ios.sh` completed.
- `ios/scripts/verify_idevice_symbols.sh` passed.
- `IOSSimOnDevicePOC` builds and installs with normal development signing.
- iPhone Developer Mode enabled.
- External LocalDevVPN installed and configured.
- RPPairing file generated from the pinned/compatible Mac-side tooling.

## Procedure

1. Connect the iPhone to the Mac if initial trust/provisioning is needed.
2. Generate an RPPairing file using compatible tooling.
3. Build and install `IOSSimOnDevicePOC` on the iPhone using normal Apple development signing.
4. Launch the POC while the Mac is still available.
5. Tap `IMPORT RPPAIRING`.
6. Choose the RPPairing plist with the iOS document picker.
7. Confirm the POC shows:
   - Pairing loaded
   - Pairing valid
   - Pairing stored securely
8. Launch LocalDevVPN and confirm it is active in iOS VPN status.
9. Disconnect the iPhone from USB.
10. Power the Mac fully off.
11. Connect the iPhone to an unrelated Wi-Fi network.
12. Launch `IOSSimOnDevicePOC`.
13. Tap `RUN DIAGNOSTICS`.
14. Confirm the stage list distinguishes:
   - LocalDevVPN PASS
   - Endpoint PASS
15. Tap `CONNECT`.
16. Confirm:
   - Tunnel PASS
   - RSD PASS
   - DVT PASS
   - LocationSimulation PASS
17. Tap `SET TEST LOCATION`.
18. Expected test coordinate:

```text
latitude: 40.7580
longitude: -73.9855
```

19. Confirm Core Location Verification reports the expected coordinate within tolerance.
20. Record `isSimulatedBySoftware` and `isProducedByAccessory`.
21. Tap `CLEAR SIMULATION`.
22. Confirm clear succeeds.

## Required Result Record

Use this exact format:

```text
Test ID: E1
Date:
iPhone model:
iOS version:
IOSSim commit:
idevice commit/version: c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5
LocalDevVPN version:
Network state:
Wi-Fi:
Cellular:
Mac power state:
Pairing source:
Developer Mode:
Steps:
Expected:
Observed:
Timing:
Core Location flags:
Logs:
Verdict:
```

## Failure Classification

Record the first failing layer:

```text
PAIRING_FILE_INVALID
PAIRING_CREDENTIAL_MISSING
LOCALDEVVPN_ROUTE_MISSING
ENDPOINT_UNREACHABLE
TLS_PSK_FAILED
RSD_FAILED
DVT_FAILED
DEVICE_INFO_WARMUP_FAILED
LOCATION_SERVICE_FAILED
SET_COMMAND_FAILED
CORELOCATION_VERIFICATION_FAILED
```
