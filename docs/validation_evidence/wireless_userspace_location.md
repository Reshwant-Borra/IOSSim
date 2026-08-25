# Wireless Userspace Location Validation

This note preserves the successful physical validation evidence for the production wireless location path.

## Known-Good Architecture

Normal wireless location uses:

```text
UserspaceRsdTunnel(real_udid)
  -> RemoteServiceDiscoveryService
  -> DvtProvider
  -> DeviceInfo(dvt).ls("/")
  -> LocationSimulation(dvt)
  -> set() / clear()
```

`DeviceInfo(dvt).ls("/")` is required before opening `LocationSimulation`. Do not remove this warmup from production or debug probes.

## Physical Evidence Preserved

- USB can be absent during spoofing.
- The same explicit UDID remains reachable over Wi-Fi.
- Userspace RSD works without persistent QUIC/TCP tunnel setup.
- DVT works over the userspace RSD connection.
- `LocationSimulation.set(lat, lon)` works wirelessly.
- The userspace session can remain alive for several minutes.
- Multiple coordinate changes work in the same live session.
- Apple Maps followed the simulated location.
- Find My followed the simulated location.
- Life360 eventually followed the simulated location, with slower refresh behavior.
- `clear()` reset GPS successfully.
- Clean userspace/DVT teardown worked.

## Persistent Tunnel Limitations

- Persistent QUIC currently fails protocol negotiation.
- Persistent TCP can crash in the native SSL-PSK/OpenSSL/BoringSSL path.
- Normal user flows must not invoke persistent tunnel diagnostics automatically.
- TCP diagnostics, if used, must remain explicit and diagnostic-only.

## Production Acceptance Test

1. Launch IOSSim.
2. If setup is needed, connect the iPhone with USB, unlock it, Trust this Mac, click **Add iPhone**, then unplug when IOSSim says to.
3. Confirm IOSSim shows **Wireless Ready**.
4. Set San Francisco.
5. Confirm Maps and Find My move.
6. Change to New York.
7. Confirm the update.
8. Click **Reset GPS**.
9. Close and reopen IOSSim.
10. Verify the same iPhone reconnects wirelessly without USB when it is still reachable.

Life360 timing can be checked separately. Some apps may take longer to refresh their displayed location.
