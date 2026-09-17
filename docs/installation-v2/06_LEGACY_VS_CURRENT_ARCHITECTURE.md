# Legacy versus current architecture

| Topic | Legacy claim/path | Current truth | Disposition |
| --- | --- | --- | --- |
| Packaged engine | GUI searches for repository CLI | Build script compiles `BundledProvisioningEngine` and embeds helper | Mark old claims stale; remove friendly text |
| Native install | Native backend unavailable | Installation Proxy/AFC install, upgrade, uninstall are implemented | Keep and qualify |
| Device discovery | `devicectl` required | Native usbmux discovery is packaged and synthetic tests pass | Remove public fallback |
| App launch | Manual or devicectl launch required | CoreDevice/RSD AppService readiness and launch are implemented | Keep; requalify physically |
| Apple provisioning | Empty experimental scaffold | Full private Personal Team path exists | Rename/encapsulate; never call Apple-supported |
| Pairing | Manual plist handling | AES-GCM House Arrest delivery and Keychain import exist | Refactor security proof, retain mechanism |
| Runtime ready | Checkpoint means ready | No Rich runtime operation is attempted | Replace readiness semantics |
| State safety | Actor/generation prevents races | Protection stops at process boundary | Add OS lock/journal/CAS |
| DDI | Native mount means fresh setup solved | Only existing caches are searched | Add approved acquisition or block claim |
| Release artifact | No DMG produced | Later local dirty ad-hoc DMG exists | Artifact wins; it is not public |
| Architectures | Sidecar says universal | inspected GUI/helper are arm64 | Binary wins; fail future releases |
| Schema | sidecar/source intent implies current | artifact embeds setup schema 3 while source is 4 | Fail future releases |

## Legacy path policy

Legacy source is not automatically a runtime defect. It becomes a defect if a public build can select it, its error text confuses users, or its state overlaps the production engine. V2 applies four steps:

1. Compile public builds with a production-only composition root.
2. Reject runtime selectors and bridge path overrides in public distribution class.
3. Move retained diagnostic backends to a developer-only module/target.
4. Delete `DevicectlProvisioningBackend`, Xcode fallback selection, repository helper resolution, and obsolete UserDefaults only after migration tests and source checks prove no references.

Xcode remains a controlled release-build dependency for iPhone payloads. “No Xcode” is a customer-runtime statement, not a claim that Apple SDK products can be built without Apple build tools.
