# Vanish device-install analysis

Vanish bundles both its payload and the device/install stacks that prepare it. Electron passes the bundled IPA path to `VanishSideloader` using `install_sidestore`; the helper receives a generous timeout covering download/sign/upload and maximum-certificate interaction. Installed-app discovery, device selection, pairing placement, and repair are separate commands. `CONFIRMED_VANISH_ARTIFACT/STATIC_CODE`

This separation implies four useful consumer responsibilities:

1. Resolve one exact connected device and retain its identity through the operation.
2. Prepare an artifact for the selected team/device without modifying the immutable bundled source.
3. Inventory before mutation and verify exact bundle/version/team/profile after installation.
4. Repair pairing or configuration without automatically reinstalling a healthy app.

Veya already implements these through `NativeDeviceBridge`, `NativeApplicationManagement`, and `ConsumerArtifactProvisioner`, using AFC/PublicStaging and InstallationProxy. This is preferable to adopting Vanish's Python/Rust split because Veya has one pinned native bridge with typed Swift receipts. The target hardening is exact `(UDID, mux connection)` selection, staged upgrade receipts, post-install inventory, profile-expiry inspection, and crash-safe state—not a backend replacement.

Static inspection does not prove Vanish's behavior under every interrupted install or wrong-team upgrade. Veya acceptance therefore derives from its own invariants and physical matrix rather than assuming Vanish parity.
