# No-Xcode device bridge

IOSSim’s consumer device path is owned by `IOSSimMacCore`. Swift talks to the
Rust `idevice` family only through `native/iossim-device-bridge`, an IOSSim C
ABI with opaque handles, bounded buffers, typed status codes, panic trapping,
and redacted diagnostics. The pinned host dependency is `jkcoxson/idevice`
release 0.1.67, commit `1838db107d38701b4044361163aac049006c2627` (MIT).

The bridge covers usbmuxd/Lockdown discovery and inspection, AMFI Developer
Mode, DDI/TSS/mobile-image-mounter preparation, Installation Proxy inventory
and install/uninstall, and scoped House Arrest/AFC container access. Swift’s
`IOSSimDeviceIdentity` binds UDID, signing registration, usbmux, RemotePairing,
and developer-service identifiers without conflating them.

`devicectl` remains only in the explicitly selected legacy comparison backend
used by the existing technical setup engine and tests. It is not used by the
new native bridge, pairing coordinator, application manager, or onboarding
coordinator. A complete source classification is recorded in the final report.

Physical discovery, DDI mount, AppService launch, and clean-host operation:
`AWAITING_PHYSICAL_VALIDATION`.
