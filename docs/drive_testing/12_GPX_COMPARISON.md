# GPX Comparison

Methods:

- **Legacy coordinate-only GPX** reproduces the existing baseline with `trkpt` latitude/longitude and no time values.
- **Timestamped GPX experiment** adds monotonic `<time>` elements.
- **GPX pacing variations** compare constant/variable host timestamp spacing.
- **Timed coordinate updates** call `LocationService.set_location()` for each planned sample.

Installed pymobiledevice3 `9.12.0` parses GPX time deltas, sleeps on the host, then calls its latitude/longitude setter. A GPX timestamp does not populate a device `CLLocation.speed` field. The installed CLI does not provide confirmed pause support; the lab supports process cancellation and disables GPX pause.
