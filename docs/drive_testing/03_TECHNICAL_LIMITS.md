# Technical Limits

IOSSim can control:

- Road-following coordinate order.
- Host-planned apparent speed through coordinate distance and timing.
- Host update intervals and bounded timing variation.
- GPX coordinate content and host-side timestamps.

IOSSim cannot directly measure or inject:

- `CLLocation.speed` delivered to another application.
- `CLLocation.course` delivered to another application.
- Accelerometer or gyroscope values.
- Core Motion automotive classification.
- Arity confidence.
- A third-party application's private trip state.

Static DVT set accepts latitude and longitude only. GPX `<time>` elements control pymobiledevice3 sleeps on the host and are not transmitted as location metadata. GPX per-coordinate subprocess writes are opaque to IOSSim, so those runs receive incomplete telemetry rather than invented write metrics.
