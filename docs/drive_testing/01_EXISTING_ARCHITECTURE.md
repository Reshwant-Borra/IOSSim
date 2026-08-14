# Existing Architecture

IOSSim remains one web application and one backend:

```text
React 18 + TypeScript + Vite
-> existing FastAPI backend
-> existing DeviceManager
-> existing LocationService
-> pymobiledevice3 DVT simulate-location
-> connected physical iPhone
```

The laboratory uses a separate `DriveExperimentController`. It reuses stable route math and the existing Nominatim/OSRM client. It does not replace `DriveController`, DeviceManager, LocationService, or the frontend map.

Stable Drive Mode and Drive Testing share an operation lock and cannot write location concurrently.
