# Repository Audit

## A. Current frontend architecture

React 18, TypeScript, Vite, React Leaflet, one `App.tsx` sidebar/map workspace, and a typed API client using Vite's `/api` proxy.

## B. Current backend architecture

One FastAPI application composes `DeviceManager`, `LocationService`, stable `DriveController`, and cached `DriveRoutingClient` instances.

## C. Current Drive Mode call path

```text
App.tsx
-> api/client.ts
-> FastAPI endpoint in main.py
-> DriveController
-> LocationService.set_location()
-> pymobiledevice3
-> developer dvt simulate-location set
-> lat/lon
```

## D. Current DVT command formats

iOS 17+ uses `developer dvt simulate-location set --rsd HOST PORT -- LAT LON`. Older iOS uses `developer simulate-location set -- LAT LON`. Static set sends only latitude and longitude.

## E. Current GPX implementation

The legacy builder emits `trk/trkseg/trkpt` with latitude and longitude only. It has no timestamps, elevation, speed, or course. Experimental timestamped GPX adds `<time>` only for pymobiledevice3 host pacing.

## F. Existing feature flags

Stable Drive Mode is always available. Generic experimental flags gate existing experiments. Drive Testing adds a second backend and frontend flag.

## G. Existing test structure

The repository used Python `unittest` for DriveController and routing tests. The lab adds unittest controller/API/core regressions and lightweight Vitest frontend tests.

## H. Stable files at risk

`main.py`, `location_service.py`, `App.tsx`, `api/client.ts`, and both launchers are stable-path risk. The stable controller, routing client, DeviceManager, tunnel implementation, Set response, Clear response, and route response remain compatible.

## I. Files created

`backend/drive_testing/`, modular `frontend/src/components/drive-testing/`, focused tests, and this documentation directory.

## J. Files modified

Composition, API client, App launcher/map overlays, additive LocationService telemetry/GPX cancellation, feature configuration, root documentation, and launchers.

## K. Implementation sequence

Flags and deterministic profile core; storage/metrics/QC; injected controller and API; integrated UI; GPX/queue/history/comparison; launchers/docs; regression verification.

## L. Known technical limits

Host-observable coordinate/timing behavior is measurable. Device sensor values and third-party internal classification are not.
