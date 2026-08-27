# Diagnostic Recorder

Date: 2026-08-27

Scope: E1 session persistence and observability only.

## Goal

The recorder exists to identify the first layer that fails after a Mac-free on-device DVT `LocationSimulation` set succeeds.

It begins on `CONNECT` and continues until explicit `DISCONNECT` or process termination. Logs are written to the app container so unplugged tests do not depend on Xcode.

## Files

Each session creates:

```text
Documents/Diagnostics/E1-YYYYMMDD-HHMMSS.jsonl
Documents/Diagnostics/E1-YYYYMMDD-HHMMSS-summary.txt
```

The JSONL file is append-only structured event data. The summary is regenerated as events arrive so a partially completed run still has a readable state summary.

## Event Schema

Each JSONL event contains:

- `id`
- `monotonicTimestamp`
- `wallClockTimestamp`
- `sessionID`
- `category`
- `component`
- `previousState`
- `newState`
- `elapsedSessionTime`
- `errorCode`
- `redactedMessage`
- `metadata`

Timestamps use wall-clock `Date` plus `ProcessInfo.systemUptime` for monotonic elapsed timing.

## Recorded Components

The recorder captures:

- Pairing load/validation without raw pairing data.
- LocalDevVPN route visibility for `10.7.0.x`.
- Developer endpoint reachability for `10.7.0.1:49152`.
- Developer tunnel state.
- RSD handshake and remote server lifecycle.
- DVT availability.
- DeviceInfo warmup.
- LocationSimulation creation, set, clear, and FFI handle free.
- Core Location observations.
- App scene lifecycle.
- memory warnings.
- background task start/expiration/end.
- monitor task start/cancellation.
- user markers.

## Sampling

Network diagnostics are intentionally low-rate:

- bridge status and LocalDevVPN route sampling every 5 seconds;
- endpoint TCP reachability sampling every 10 seconds with a short timeout.

Endpoint probes create a separate short TCP connection to `10.7.0.1:49152`. This could add noise, but it gives evidence for route/endpoint loss without changing the primary DVT session handles.

## Core Location Recorder

The verifier now records meaningful Core Location updates continuously once a session starts.

For each published observation it records:

- latitude;
- longitude;
- location timestamp;
- horizontal accuracy;
- distance from the requested simulated coordinate;
- `isSimulatedBySoftware`;
- `isProducedByAccessory`;
- classified state.

States:

- `EXPECTED_SIMULATED_LOCATION`
- `REAL_LOCATION`
- `OTHER_LOCATION`
- `NO_LOCATION`

Duplicate suppression avoids logging every identical sample. State changes are always logged.

## In-App View

The POC screen now shows:

- session ID;
- elapsed time;
- Pairing / LocalDevVPN / Endpoint / Tunnel / RSD / DVT / LocationSimulation / CoreLocation status;
- requested coordinate;
- observed coordinate;
- Core Location state;
- last successful DVT event age;
- last Core Location update age;
- recent session timeline.

## Manual Markers

`ADD MARKER` writes a `USER_MARKER` event. Use it when the visible device state changes, for example when Maps visibly reverts.

## Export

Press `EXPORT DIAGNOSTICS` in the POC. The iOS share sheet opens with the JSONL and summary files. Use AirDrop, Save to Files, or another local share target.

The app also enables iOS File Sharing and "open documents in place" for easier retrieval from the container.

## Security

The recorder must not persist:

- raw RPPairing plist data;
- RPPairing private key;
- PSK;
- cryptographic key material;
- authentication blobs;
- complete sensitive identifiers;
- memory addresses.

The implementation records redacted RPPairing summaries only. Error messages and metadata pass through a conservative redactor before persistence. Unit coverage verifies that strings containing `private_key` and `psk` are replaced with `[REDACTED]`.

## Current Limitation

The current FFI surface has no callback for EOF, socket close, DTX disconnect, or Rust reader-task termination. Until that exists, tunnel/RSD/DVT liveness is inferred from retained handles, explicit FFI errors, bridge status, route/endpoint probes, and Core Location behavior.

If the next failure is classified as `UNKNOWN` or as Core Location reversion while all developer-layer state appears alive, the next engineering action should be to expose an explicit idevice health probe or reader-task/disconnect signal rather than guessing.
