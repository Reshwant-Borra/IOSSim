# Dependencies

## jkcoxson/idevice

- Repository: `https://github.com/jkcoxson/idevice`
- Pinned commit: `c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5`
- License: MIT (`LICENSE.txt`)
- Purpose: raw RPPairing, TLS-PSK developer tunnel, RSD, DVT, DeviceInfo warmup, LocationSimulation set/clear.
- Status in this repo: bridge code added; binary/XCFramework not committed.
- Artifact strategy: build reproducibly into ignored `ios/Vendor/idevice/lib/libidevice_ffi.a` with `ios/scripts/build_idevice_ios.sh`.
- Expected size: source-audited Locus vendored arm64 static library is about 91 MB; local pinned builds are expected to be similar.
- Exact APIs used when linked:
  - `rp_pairing_file_read`
  - `rp_pairing_file_free`
  - `tunnel_create_rppairing`
  - `remote_server_connect_rsd`
  - `device_info_new`
  - `device_info_directory_listing`
  - `device_info_string_array_free`
  - `device_info_free`
  - `location_simulation_new`
  - `location_simulation_set`
  - `location_simulation_clear`
  - `location_simulation_free`
  - `remote_server_free`
  - `rsd_handshake_free`
  - `adapter_free`
  - `idevice_error_free`

## Locus

- Repository: `https://github.com/ChrisMack32/Locus`
- Audited commit: `83c8fb324983728e8f44759cfd834dc637ee38b5`
- License: MIT.
- Purpose: source-level architecture reference only.
- Code reuse: no Locus app/session/UI code copied. The IOSSim bridge follows the audited call sequence and keeps it behind IOSSim-owned types.

## LocalDevVPN

- Repository: `https://github.com/seomin0610/LocalDevVPN`
- Audited commit: `467a845f04a4b0936a7fc3dd0b326b49aaf98bdf`
- Purpose: external Packet Tunnel prerequisite for the first POC.
- Status in this repo: not vendored and not reimplemented.

## pymobiledevice3

- Existing IOSSim host-side dependency.
- Purpose here: host-side baseline/reference only.
- Status in iOS POC: not embedded.
