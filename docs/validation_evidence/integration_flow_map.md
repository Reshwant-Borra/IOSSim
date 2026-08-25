# IOSSim Integration Flow Map

## Wired Set Location

```text
frontend App.handleSet
  -> api.setLocation()
  -> POST /api/location/set
  -> LocationService.set_location()
  -> DeviceManager.device + DeviceManager.tunnel for iOS 17+
  -> pymobiledevice3 CLI developer dvt simulate-location set --rsd HOST PORT -- LAT LON
```

For iOS <= 16, `LocationService` uses `developer simulate-location set -- LAT LON`.

## Wired Reset GPS

```text
frontend App.handleClear
  -> api.clearLocation()
  -> POST /api/location/clear
  -> LocationService.clear_location()
  -> pymobiledevice3 CLI developer dvt simulate-location clear --rsd HOST PORT
```

For iOS <= 16, `LocationService` uses `developer simulate-location clear`.

## Production Wireless Set/Reset

```text
frontend DevicePanel + App.handleSet
  -> api.setLocation(lat, lon, connection_mode, device_udid)
  -> POST /api/location/set
  -> WirelessLocationController.set_location()
  -> WirelessUserspaceLocationSession.connect()
  -> UserspaceRsdTunnel(real_udid)
  -> DvtProvider
  -> DeviceInfo(dvt).ls("/")
  -> LocationSimulation(dvt)
  -> LocationSimulation.set(lat, lon)
```

Reset:

```text
frontend App.handleClear
  -> POST /api/location/clear
  -> WirelessLocationController.clear_location() when wireless simulation is active
  -> LocationSimulation.clear()
  -> session disconnect/cleanup
```

## Old Wireless Diagnostics Lab

```text
frontend WirelessTestingLab
  -> /api/experimental/wireless-testing/*
  -> WirelessTestingController
  -> CLI discovery/bootstrap/persistent tunnel diagnostics
  -> LocationService over diagnostic RSD adapter for old tunnel path
```

Persistent tunnel diagnostics remain explicit and are not invoked by normal Set/Reset.

## Userspace Diagnostic Tools

```text
backend/debug/userspace_dvt_location_probe.py
backend/debug/userspace_location_diagnostic.py
backend/debug/userspace_location_compatibility_probe.py
  -> explicit real UDID
  -> userspace RSD
  -> DVT
  -> DeviceInfo warmup
  -> LocationSimulation set/clear
```

These files are preserved as engineering diagnostics.

## Device Bootstrap

```text
frontend DevicePanel Add iPhone
  -> POST /api/wireless-location/setup/start
  -> WirelessLocationController.begin_setup()
  -> usbmux list --usb
  -> lockdown remotepairing --pair --udid REAL_UDID
  -> lockdown wifi-connections --state on --udid REAL_UDID
  -> WirelessDeviceStore saves stable identity
  -> UI prompts user to unplug
```

Unplug verification:

```text
DevicePanel "I've unplugged my iPhone"
  -> POST /api/wireless-location/setup/verify-unplugged
  -> usbmux list --usb + --network for same UDID
  -> production userspace session connect + DeviceInfo warmup
  -> Wireless Ready
```

## App Startup/Reconnect

```text
FastAPI startup
  -> WirelessLocationController.refresh_saved_devices()
  -> load backend/data/wireless_devices.json
  -> usbmux list --network for each saved UDID
  -> mark same saved device Wireless Ready when reachable
```

Frontend reload:

```text
DevicePanel polling
  -> GET /api/status
  -> embedded wireless_location status
  -> rehydrates selected device/session state without destroying backend session
```
