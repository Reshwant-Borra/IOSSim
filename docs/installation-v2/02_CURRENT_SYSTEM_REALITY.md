# Current system reality

## Repository baseline

Branch is `work/final-no-xcode-setup-v1`; HEAD is `1259da507ecded222022cc86bf82863c15640db9`. The original evidence baseline covers 412 source/document paths. Continuation comparison found no changed or missing baseline path and the same branch/HEAD. The working tree was already dirty: 44 tracked files, 4,885 insertions, and 436 deletions plus substantial untracked engineering artifacts. `CONFIRMED_LOCAL_IOSSIM_CODE`

## What the packaged app actually does

`IOSSimMacApp` selects `BundledProvisioningEngine.live()` when compiled with `IOSSIM_BUNDLED_ENGINE`; `macos/scripts/build_app.sh` sets that flag. The engine invokes embedded `Contents/MacOS/IOSSimProvisioner`. The helper owns `doctor`, team discovery, provision, resume, reconcile, status, runtime-ready, and support export. Consumer commands require `.nativePersonalTeam`; legacy backend selection is rejected. `CONFIRMED_LOCAL_IOSSIM_CODE`

The native bridge implements more than older reports state:

- usbmux device enumerate/open/inspect;
- existing Lockdown pair-record use;
- RemotePairing create/validate;
- personalized developer-image status and mount;
- app inventory, install, upgrade, uninstall;
- CoreDevice software tunnel, RSD handshake, AppService readiness and launch;
- House Arrest/AFC container reads and writes.

It does not expose initial Lockdown pairing. It also chooses the first Rust device with a matching UDID before checking the expected mux connection, which can reject a valid second USB/network duplicate. `CONFIRMED_LOCAL_IOSSIM_CODE`

## What is implemented but incomplete

The Personal Team path performs GrandSlam SRP, trusted-device 2FA, Xcode-scoped token exchange, Developer Services operations, team selection, managed RSA key/CSR/certificate work, device/App ID preparation, profile retrieval, and validation. It is a private/version-bound compatibility adapter, not an Apple-supported public provisioning API. `CONFIRMED_LOCAL_IOSSIM_CODE`

Automatic RemotePairing delivery already uses a phone-created 32-byte key and nonce, AES-GCM envelope, House Arrest, phone Keychain import, and receipt. The receipt proves storage only. `ReceiptBoundRemotePairingProof.verify` has no effective proof, forced repair deletes the old Mac record before candidate success, and bootstrap material is not adequately request-bound. `CONFIRMED_LOCAL_IOSSIM_CODE`

Developer support only reads existing cache roots. LocalDevVPN orchestration requires external `com.jkcoxson.LocalDevVPN` and proves `10.7.0.1:49152`, but does not install or configure the VPN app. Phone `.task` polling can expire and need not rerun on foreground. `CONFIRMED_LOCAL_IOSSIM_CODE`

## Readiness and state reality

Setup schema is 4, provisioner schema 4, helper schema 1, payload manifest schema 2, pairing/mapping wire schemas 1. `SETUP_READY_FOR_RUNTIME` is currently derived from checkpoints such as LocalDevVPN verification; no fresh Rich runtime command is executed. `CONFIRMED_LOCAL_IOSSIM_CODE`

`ConsumerProvisioningStateStore` writes a single `provisioning-state.json`; `NativeProvisioningArtifactStore` writes one `native-provisioning-artifacts.json` containing profile blobs. Actor/generation controls are process-local. Multiple helpers can race. Pairing storage is better scoped by team/device. `CONFIRMED_LOCAL_IOSSIM_CODE`

## Artifact and test reality

The local DMG SHA-256 is `1b25cd7c41ec2fcb597f24f94184f38bfa29392e638baa06490ea477a92cf14a`. Mounted and assembled apps share deterministic tree hash `42fe6b9a861c88ff902b8926ab2972aa8dfb885c87b2202400315391479862c2` and `diff -qr` is empty. Both primary executables are arm64, although the sidecar claims arm64/x86_64. `BuildProvenance.plist` records schema 3 because the direct build script hardcodes it; current source and the release builder use 4. `CONFIRMED_LOCAL_IOSSIM_ARTIFACT`

Safe source checks pass, but the newest broad Swift log does not: 279 tests, 7 skipped, 36 failures, 1 unexpected. See 38 for classification. `CONFIRMED_LOCAL_IOSSIM_TEST`
