# iPhone On-Device IOSSim Architecture

Status: GO WITH RISKS.

The iPhone architecture has been physically demonstrated for the core path: a stock iPhone, unplugged from the Mac, used imported RPPairing plus LocalDevVPN to reach DVT `LocationSimulation` and change the device's reported location. Long-duration persistence and cellular scenarios are not fully validated.

## Goal

```text
Mac used once
  -> RPPairing generated/imported
  -> Mac no longer needed at runtime
  -> iPhone performs its own developer tunnel
  -> DVT LocationSimulation
  -> Core Location
```

The POC is intentionally narrow. It does not include the Mac-hosted web UI, cloud control, remote Mac control, WLOC, or a custom VPN. It now includes an isolated experimental Drive Mode for developer testing only; that Drive Mode preserves the same on-device DVT stack and does not replace the existing static-location workflow.

## One-Time Setup

The setup model is:

- Use a Mac/USB once to establish normal Apple trust and generate a compatible RPPairing record.
- Import the RPPairing file into the iPhone POC.
- Store the imported RPPairing in the iPhone Keychain.
- Install and run LocalDevVPN from its existing signed/distributed path so the iPhone has the `10.7.0.x` route needed by the developer tunnel.
- Build and install the IOSSim POC with a free Personal Team; this worked for the POC app itself.

Self-building LocalDevVPN with a free Personal Team failed because Xcode reported that Personal development teams do not support the Network Extensions and Personal VPN capabilities. The IOSSim POC does not add NetworkExtension or Personal VPN entitlements; LocalDevVPN remains an external prerequisite.

## Runtime Path

The actual implemented chain is:

```text
KeychainRPPairingStore
  -> RPPairingValidator
  -> DeveloperRouteProbe
  -> 10.7.0.1:49152
  -> LocalDevVPN virtual route
  -> IdeviceOnDeviceTunnelClient
  -> rp_pairing_file_read
  -> tunnel_create_rppairing
  -> remote_server_connect_rsd
  -> device_info_directory_listing("/")
  -> location_simulation_new
  -> location_simulation_set / clear
  -> CoreLocationVerifier
```

## Component Responsibilities

`KeychainRPPairingStore` owns local protected storage of imported pairing bytes. It uses device-local Keychain storage and exposes only redacted summaries to diagnostics.

`RPPairingValidator` validates the semantic shape of imported records before storage or use. It checks required key material presence and expected byte lengths without logging raw pairing contents.

`DeveloperRouteProbe` checks whether LocalDevVPN has exposed the expected `10.7.0.x` interface/route and whether `10.7.0.1:49152` is reachable.

LocalDevVPN supplies the virtual local route. IOSSim does not vendor, rebuild, or reimplement it in this repo.

`IdeviceOnDeviceTunnelClient` is the Swift ownership boundary for pinned `jkcoxson/idevice` FFI handles. It loads the pairing file into FFI, creates the RPPairing tunnel, connects RSD, performs the DeviceInfo warmup, opens LocationSimulation, sends set/clear, and frees handles during explicit cleanup.

RSD is the developer-services endpoint reached through the RPPairing tunnel. DVT is the Instruments protocol layer used for the LocationSimulation service.

`LocationSimulation` sends the DVT selectors for `simulateLocationWithLatitude:longitude:` and `stopLocationSimulation`.

`CoreLocationVerifier` is a separate Core Location consumer that records what iOS actually reports, including coordinates, accuracy, and `sourceInformation` flags when available.

`BackgroundSessionKeeper` keeps a background task and background-capable Core Location observation active during persistence experiments. It does not resend coordinates.

`SessionDiagnosticRecorder` writes structured JSONL events and a text summary to the app container so unplugged tests can be inspected without Xcode.

## Security Model

RPPairing is sensitive credential material. It may include private trust material that can authenticate to the device developer tunnel.

Security rules:

- Store imported pairing data in Keychain/protected storage.
- Never commit RPPairing files, private keys, PSKs, authentication blobs, or raw pairing plists.
- Never persist full sensitive identifiers in diagnostics.
- Redact diagnostic messages and metadata before writing logs.
- Keep generated `libidevice_ffi.a`, Rust build output, symbol dumps, and local artifact folders ignored.

The repo-level `.gitignore` protects `ios/pairing/`, `ios/secrets/`, `ios/artifacts/`, `ios/.build/`, the generated static library path, known pairing filenames, and known RPPairing extensions.

## Background Persistence

Initial unplugged physical testing showed that one set command could change the iPhone's reported location, but the simulated coordinate reverted after a few seconds in one run and approximately 15 seconds in a later run.

The source-level lifetime comparison found that IOSSim retains the important FFI handles while the runner/client remain alive. The major difference from Locus was background execution behavior: Locus starts a background task and background location keepalive machinery, while the earlier POC used Core Location only as a short verifier.

The current leading cause is app lifecycle/background suspension interrupting the long-lived DVT/LocationSimulation connection or the process that owns it. The latest POC adds background task plus background Core Location observation for persistence diagnostics. The latest physical observation reported that simulation continued while the iPhone screen was locked, but controlled long-duration hold tests are still pending.

No periodic coordinate resend is part of the current persistence fix. If future diagnostics show that app/session ownership remains alive but Core Location still reverts due to an idle protocol requirement, that should be documented separately before adding resend traffic.

## Physical Validation Results

PHYSICALLY OBSERVED:

- IOSSim POC installed and launched on the iPhone.
- RPPairing validation reported PASS.
- LocalDevVPN route check reported PASS.
- Developer endpoint probe reported PASS.
- Developer tunnel reported PASS.
- RSD reported PASS.
- DeviceInfo warmup reported PASS.
- DVT reported PASS.
- LocationSimulation reported PASS.
- `SET TEST LOCATION` changed the iPhone's reported location.
- The successful set happened with the iPhone unplugged from the Mac.
- Google Maps reflected the simulated location.
- Find My reflected the simulated location.
- Life360 eventually reflected the simulated location with application/server delay.
- The latest observed test continued while the iPhone screen was locked.

NOT YET FULLY VALIDATED:

- Controlled 10-minute hold.
- 30-minute hold.
- Mac fully powered off.
- Wi-Fi to cellular transition.
- Cellular cold-start.
- Reboot recovery.
- Drive update-rate validation.

## Life360 Behavior

IOSSim/Core Location changed promptly during physical testing. Life360's observer-side display lagged by several minutes before reflecting the simulated coordinate.

Treat that delay as likely Life360 background/server propagation behavior unless Core Location diagnostics prove otherwise. Do not use Life360 refresh timing as IOSSim injection latency.

## Current Verdict

GO WITH RISKS.

The core Mac-free on-device DVT architecture is physically demonstrated. Basic foreground Drive route simulation is also physically demonstrated. The remaining risk is stability and characterization: speed reporting, cadence smoothness, foreground/background differences, controlled long-duration persistence, locked-screen behavior, and cellular scenarios still need recorded validation.
