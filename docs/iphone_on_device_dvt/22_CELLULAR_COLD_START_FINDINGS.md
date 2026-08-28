# Cellular Cold-Start Findings

Date: 2026-08-27

## Current Finding

STATUS: UNKNOWN

No physical cellular cold-start test was run in this implementation phase.

## Implemented Instrumentation

STATUS: IMPLEMENTED

The POC can now separate:

- LocalDevVPN route visibility: looks for `10.7.0.0/24` interface addresses.
- Developer endpoint TCP reachability: probes `10.7.0.1:49152` and records latency/error.
- Tunnel/authentication layer: `tunnel_create_rppairing` errors map to `TLS_PSK_FAILED`.
- RSD layer: `remote_server_connect_rsd` errors map to `RSD_FAILED`.
- DeviceInfo warmup: root listing errors map to `DEVICE_INFO_WARMUP_FAILED`.
- DVT LocationSimulation: `location_simulation_new`, `set`, and `clear` map to service/command errors.
- Core Location verification: expected coordinate timeout maps to `CORELOCATION_VERIFICATION_FAILED`.

## Required E4 Recording

Use the required test-result template from `21_POC_TEST_RESULTS.md`.

If E4 fails, classify the first failing layer as one of:

```text
LOCALDEVVPN_ROUTE_MISSING
ENDPOINT_UNREACHABLE
TLS_PSK_FAILED
RSD_FAILED
DEVICE_INFO_WARMUP_FAILED
LOCATION_SERVICE_FAILED
SET_COMMAND_FAILED
CORELOCATION_VERIFICATION_FAILED
```

Do not report "cellular cold-start unsupported" unless the route, listener, authentication, RSD, DVT, and verifier evidence supports that conclusion.
