# Persistence And Reboot

## Pairing File Persistence

STATUS: STRONG EVIDENCE

RPPairing files are intended to be persisted. Locus stores one under Application Support and Mirage claims backups/imports can avoid re-pairing. idevice pairable-host FFI explicitly tells callers to persist the pairing file and host `altIRK`.

## Active Location Simulation Persistence

STATUS: CONFIRMED

The idevice DVT location simulation client comments that the connection must be maintained to keep location simulated. Locus keeps session handles alive and resends periodically. Therefore, after app kill, VPN restart, device reboot, or tunnel loss, IOSSim should assume the active simulation is gone or stale until verified.

## iPhone Reboot

STATUS: UNKNOWN

Expected behavior:

- Pairing file should remain on disk/Keychain.
- LocalDevVPN configuration may remain in iOS VPN preferences but the tunnel may not be connected.
- Developer Mode remains enabled unless toggled off, but listener availability must be rechecked.
- Active DVT simulation is not expected to survive because the DVT connection is gone.

POC E6 must measure exact user steps after reboot.

## iOS Update

STATUS: UNKNOWN

Apple Device Hub docs say if an OS is upgraded later, pair the device again in the Xcode wireless-pairing context. It is unknown whether imported RPPairing files for this architecture survive every iOS update. Treat iOS update as a possible invalidation boundary.

## App Force Quit

STATUS: UNKNOWN

Locus implements recovery/resend, but iOS force-quit can restrict background behavior. POC E7 must determine whether relaunch can reuse the stored RPPairing file and active LocalDevVPN route without Mac involvement.
