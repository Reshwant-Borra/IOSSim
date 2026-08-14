# iOS Drive Simulation — Next Experimental Feature
**Status:** Planned  
**Scope:** Visual iPhone display simulation that mirrors the drive in real time inside the web UI

---

## What This Feature Is

While Drive Mode moves the iPhone's GPS coordinates along a route, there is currently no visual feedback of what the iPhone screen looks like during the drive. iOS Drive Simulation adds a rendered iPhone frame in the web frontend that shows — in sync with the active drive — a simulated Maps/navigation view animating along the route.

This is a frontend-only simulation layer. It does not interact with the device. It mirrors the backend `DriveStatus` polling stream to render an animated phone UI that a user can use as a demo, screenshot, or preview tool.

---

## Core Concept

```
Backend DriveController (existing)
        │
        │ GET /api/location/drive/status  (1.5s poll, already running)
        ▼
Frontend DriveStatus stream
        │
        │ new: feed into SimulatedPhoneView component
        ▼
SimulatedPhoneView
  ├── iPhone frame (SVG or CSS border-radius shell)
  ├── Embedded mini-map (Leaflet sub-map, re-uses existing tile layer)
  │     └── current_location marker animates along route
  ├── Speed readout  (speed_mps → mph display)
  ├── ETA readout    (eta_s → "X min away")
  ├── Progress bar   (progress 0→1)
  └── Route polyline overlay (same coordinates as main map)
```

No new backend endpoints required. The existing `/api/location/drive/status` response carries everything needed.

---

## Frontend Architecture

### New component: `SimulatedPhoneView.tsx`

Props:
```ts
interface SimulatedPhoneViewProps {
  driveStatus: DriveStatus | null
  routeCoordinates: LatLon[]
  speedMph: number
}
```

Renders:
- An iPhone-shaped shell (CSS: `border-radius: 40px`, notch/dynamic island detail, 390×844 aspect ratio scaled down to ~220×480 in the sidebar or as a floating panel)
- Inside: a small Leaflet `MapContainer` centered on `current_location`, zoom ~15, no controls
- Bottom HUD bar: speed · ETA · distance remaining
- State badge: DRIVING / PAUSED / ARRIVED in color

### Integration in `App.tsx`

```tsx
{driveModeEnabled && driveStatus && driveStatus.state !== 'idle' && (
  <SimulatedPhoneView
    driveStatus={driveStatus}
    routeCoordinates={previewCoordinates}
    speedMph={selectedMph}
  />
)}
```

Shown only while a drive is active. Dismisses on stop/arrive.

### Placement options (decide when building)

| Option | Tradeoff |
|---|---|
| Fixed panel below drive controls in sidebar | Always visible, compact, no overlap |
| Floating overlay on the main map | More dramatic; needs drag handle |
| Separate drawer/sheet that slides in | Clean separation; extra interaction |

Recommendation: start with fixed sidebar panel. Easiest to ship, no z-index conflicts.

---

## Experimental Flag

This feature will be gated behind `IOS_SIM_ENABLE_EXPERIMENTAL` / `VITE_ENABLE_EXPERIMENTAL_FEATURES` until it is considered stable.

```tsx
// in App.tsx
const simulationEnabled = experimentalEnabled  // VITE_ENABLE_EXPERIMENTAL_FEATURES=1
```

---

## Implementation Plan

1. **Scaffold `SimulatedPhoneView.tsx`** — static iPhone shell, no map yet. Verify CSS shape is correct.
2. **Embed sub-Leaflet map** — small `MapContainer`, `TileLayer`, `CircleMarker` for current position. Confirm it centers/follows `current_location` on each status update.
3. **Add route polyline** — same `previewCoordinates` as main map.
4. **HUD bar** — speed · ETA · distance · state badge.
5. **Polish** — smooth marker transitions (`Marker` with CSS transition or Leaflet `flyTo`), iPhone notch/Dynamic Island SVG detail, dark theme matching the sidebar.
6. **Gate and ship** — wire `simulationEnabled` flag, add to launcher docs, move to stable when confirmed.

---

## Open Questions

- Should the sub-map follow the marker (auto-pan on each tick) or stay fixed on the full route?  
  → Probably auto-pan while driving, show full route on arrive.
- Should the iPhone frame match an iPhone 15 Pro silhouette (Dynamic Island) or a generic rounded rectangle?  
  → Generic is faster to build and avoids Apple trademark concerns.
- Should the simulation panel be visible on mobile-sized windows?  
  → Sidebar is already narrow (300px). Consider collapsing to a HUD-only strip at <320px sidebar.

---

## Sources

- Drive Mode stable implementation: `backend/drive_controller.py`, `backend/main.py`
- Frontend drive state: `frontend/src/App.tsx` (DriveStatus polling, `driveStatus` state)
- Existing map setup: `App.tsx` MapContainer + Polyline + CircleMarker pattern
