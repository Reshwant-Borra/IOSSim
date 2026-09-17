# iPhone Setup Ingress Call Graph

Verified against the dirty source tree based on HEAD `1259da507ecded222022cc86bf82863c15640db9` on 2026-09-15.

## Target membership

`ios/IOSSimOnDevicePOC.xcodeproj/project.pbxproj` now contains a file reference and PBXBuildFile for `AutomaticPairingInbox.swift`, and the build file is in the `IOSSimOnDevicePOC` target's `PBXSourcesBuildPhase`. The application entry file `ios/App/IOSSimOnDeviceDVTPOCApp.swift` is in the same phase. This corrects the pre-rebuild integration defect where the inbox source existed but was not a member of the device app target.

## Startup graph

```text
IOSSimOnDeviceDVTPOCApp.body
  -> RootTabView.task
  -> AutomaticPairingInboxController.init
       -> KeychainRPPairingStore.init
            service = com.iossim.on-device-dvt-poc.rppairing
            account = primary
  -> bounded watch: at most 240 attempts, 250 ms apart
  -> AutomaticPairingInboxController.reconcile
       -> applicationSupportDirectory/IOSSim/SetupInbox
       -> decode remote-pairing.request as AutomaticPairingBootstrapRequest
       -> validate schema 1, ten-minute lifetime, app bundle binding
       -> reuse or create remote-pairing.bootstrap
            nonce = UUID
            importKey = 32 random bytes
            atomic + complete file protection
       -> if remote-pairing.envelope is absent: return nil and wait
       -> AutomaticPairingInboxProcessor.process
            -> decode AutomaticPairingEnvelope schema 1
            -> verify device/team binding and bootstrap nonce
            -> AES.GCM.open sealed payload with bootstrap import key
            -> KeychainRPPairingStore.importPairingData
                 -> RPPairingValidator.validate
                      public_key = exactly 32 bytes
                      private_key = exactly 32 bytes
                      identifier = non-empty
                      alt_irk = absent or exactly 16 bytes
                 -> SecItemUpdate or SecItemAdd
            -> parse only identifier/public key for receipt metadata
            -> SHA-256 public-key fingerprint
            -> AutomaticPairingReceipt schema 1, status stored
       -> atomically write protected remote-pairing.receipt
       -> delete request, bootstrap, and encrypted envelope
       -> return receipt
```

The pairing startup task never opens LocalDevVPN, RSD, TestManager, XCTest, XCUILocation, Spoof, or Drive. A persistent malformed/expired request stops the current activation's watcher immediately; the Mac can replace the request and activate the app again. A valid request without an envelope is polled for at most 60 seconds. Therefore failed processing cannot create an infinite startup loop.

## LocalDevVPN setup readiness ingress

```text
IOSSimOnDeviceDVTPOCApp.task
  -> LocalDevVPNSetupInboxController.reconcileIfRequested()
  -> decode/bind localdevvpn.request
  -> DeveloperRouteProbe.run(10.7.0.1:49152)
  -> ready only when localDevVPNFunctionalReady (TCP connected)
  -> atomically write localdevvpn.receipt
  -> remove request on success
```

The Mac-side `LocalDevVPNSetupCoordinator` writes the request through House Arrest, activates IOSSim's bounded watcher, and—if not already ready—opens external `com.jkcoxson.LocalDevVPN` through native AppService. The external app owns VPN creation/start and any Apple confirmation. IOSSim never starts TestManager/XCTest/location in this gate.

## Runtime mapping graph

```text
Gate3XCTestRunnerBundleIdentifierResolver.resolvedInstalledRunnerBundleID
  1. explicit process environment override (developer/runtime compatibility)
  2. Library/Application Support/IOSSim/runtime-mapping.json
       -> DeliveredRuntimeMapping schema 1
       -> 64-hex safe device hash
       -> non-empty team when present
       -> current main-bundle equality
       -> valid runner-bundle syntax/identity
       -> persist accepted runner ID in UserDefaults
  3. IOSSimGate3RunnerBundleIdentifier from Info.plist
  4. previously accepted UserDefaults value
  5. canonical source runner ID
```

The Mac remains the full semantic authority: `NativeApplicationManager` constructs schema 1 from the selected device hash, team, exact installed main ID, and exact installed runner ID, writes through House Arrest/AFC, reads back, decodes, and compares the complete value. The phone additionally rejects a delivered mapping whose schema, safe device hash, main app identity, team shape, or runner identity is invalid, then retains the proven fallback chain.

## Compiled-product evidence gate

The payload packager does not declare capabilities from source presence alone. Before it writes the manifest it requires the built main executable to contain markers for:

- `AutomaticPairingInboxController`
- `remote-pairing.bootstrap`
- `remote-pairing.receipt`
- `com.iossim.on-device-dvt-poc.rppairing`
- `runtime-mapping.json`

The stale Release product currently in DerivedData fails this gate. A fresh Xcode device build is required before capability metadata can be emitted.
