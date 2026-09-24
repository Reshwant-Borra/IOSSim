import XCTest
@testable import IOSSimMacCore

final class NativeDeviceBridgeTests: XCTestCase {
    func testDeveloperSupportMountPreservesAuthoritativeDeviceStateOnly() {
        XCTAssertEqual(
            NativeDeveloperServicesCoordinator.mapMountFailure(
                NativeDeviceBridgeError.developerModeRequired
            ) as? NativeDeviceBridgeError,
            .developerModeRequired
        )
        XCTAssertEqual(
            NativeDeveloperServicesCoordinator.mapMountFailure(
                NativeDeviceBridgeError.deviceDisconnected
            ) as? NativeDeviceBridgeError,
            .deviceDisconnected
        )
        XCTAssertEqual(
            NativeDeveloperServicesCoordinator.mapMountFailure(
                NativeDeviceBridgeError.protocolFailure("tss service unavailable")
            ) as? DeveloperSupportFailure,
            .tssUnavailable
        )
        XCTAssertEqual(
            NativeDeveloperServicesCoordinator.mapMountFailure(
                NativeDeviceBridgeError.protocolFailure("image rejected")
            ) as? DeveloperSupportFailure,
            .mountRejected
        )
        XCTAssertEqual(
            NativeDeveloperServicesCoordinator.mapMountFailure(
                DeveloperSupportFailure.wrongBuildIdentity
            ) as? DeveloperSupportFailure,
            .mountRejected
        )
    }

    func testOptInPhysicalDeveloperServicesLaunchBoundary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let udid = environment["VEYA_PHYSICAL_DEVICE_UDID"],
              let launchBundleIdentifier = environment["VEYA_PHYSICAL_LAUNCH_BUNDLE_ID"] else {
            throw XCTSkip(
                "PHYSICAL_DEVICE_REQUIRED: set VEYA_PHYSICAL_DEVICE_UDID and VEYA_PHYSICAL_LAUNCH_BUNDLE_ID"
            )
        }
        let bridge = IOSSimDeviceBridge()
        let devices = try await bridge.listDevices()
        let selected = try XCTUnwrap(devices.first { $0.identity.udid == udid })
        let inspection = try await bridge.inspect(selected.identity)
        XCTAssertEqual(inspection.name, "Rishi Borra")

        let receipt = try await NativeDeveloperServicesCoordinator(
            providers: [ThirdPartyMirrorDevelopmentProvider()],
            providerPolicy: .localTest
        ).prepare(
            device: inspection.identity,
            context: DeveloperServicesProofContext(
                releaseIdentity: "veya-physical-boundary-test",
                pairingGeneration: nil,
                targetBundleIdentifier: launchBundleIdentifier
            )
        )

        XCTAssertTrue(receipt.transportReady)
        XCTAssertEqual(receipt.targetBundleIdentifier, launchBundleIdentifier)
        XCTAssertEqual(receipt.launchReceipt?.bundleIdentifier, launchBundleIdentifier)
        XCTAssertEqual(receipt.launchReceipt?.appServiceConnected, true)
        XCTAssertGreaterThan(receipt.launchReceipt?.pid ?? 0, 0)
    }

    func testOptInPhysicalSignedApplicationInstallBoundary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let udid = environment["VEYA_PHYSICAL_DEVICE_UDID"],
              let appPath = environment["VEYA_PHYSICAL_SIGNED_APP"] else {
            throw XCTSkip("PHYSICAL_DEVICE_REQUIRED: set VEYA_PHYSICAL_DEVICE_UDID and VEYA_PHYSICAL_SIGNED_APP")
        }
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
            XCTFail("physical install fixture has no bundle identifier")
            return
        }

        let bridge = IOSSimDeviceBridge()
        let devices = try await bridge.listDevices()
        let selected = try XCTUnwrap(devices.first { $0.identity.udid == udid })
        let inspection = try await bridge.inspect(selected.identity)
        XCTAssertEqual(inspection.identity.udid, udid)
        XCTAssertEqual(inspection.name, "Rishi Borra")

        let profile = await ProvisioningProfileInspector.inspect(
            appURL: appURL,
            bundleIdentifier: bundleIdentifier,
            selectedDeviceIdentifier: udid
        )
        let teamIdentifier = try XCTUnwrap(profile.teamIdentifier)
        let inventory = try await NativeApplicationService().inventory(on: inspection.identity)
        if let installed = inventory.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            guard let installedTeam = installed.teamIdentifier else {
                XCTFail("Installation Proxy omitted TeamIdentifier for the existing target application")
                return
            }
            guard installedTeam == teamIdentifier else {
                XCTFail("existing target application belongs to a different nonempty team")
                return
            }
        }
        let receipt = try await NativeApplicationManager().installOrUpgradeReceipt(
            appURL: appURL,
            expectedBundleIdentifier: bundleIdentifier,
            expectedTeamIdentifier: teamIdentifier,
            on: inspection.identity
        )
        XCTAssertEqual(receipt.bundleIdentifier, bundleIdentifier)
        XCTAssertEqual(receipt.teamIdentifier, teamIdentifier)
    }

    func testZeroDevices() async throws {
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: []))
        let devices = try await bridge.listDevices()
        XCTAssertEqual(devices, [])
    }

    func testOneDeviceGetsConnectionGenerationAndInspection() async throws {
        let device = try descriptor("PHONE-0001", connection: .usb, mux: 7)
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [device]))
        let listed = try await bridge.listDevices()
        XCTAssertEqual(listed.count, 1)
        XCTAssertGreaterThan(listed[0].identity.connectionGeneration, 0)
        let inspected = try await bridge.inspect(listed[0].identity)
        XCTAssertEqual(inspected.identity.udid, "PHONE-0001")
        XCTAssertEqual(inspected.trust, .trusted)
    }

    func testRediscoveryOfSameUDIDUsesANewConnectionGeneration() async throws {
        let descriptor = try descriptor("PHONE-0001", connection: .usb, mux: 7)
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [descriptor]))
        let beforeRestart = try await bridge.listDevices()[0]
        let afterRestart = try await bridge.listDevices()[0]
        XCTAssertEqual(beforeRestart.identity.udid, afterRestart.identity.udid)
        XCTAssertGreaterThan(
            afterRestart.identity.connectionGeneration,
            beforeRestart.identity.connectionGeneration
        )
        let inspected = try await bridge.inspect(afterRestart.identity)
        XCTAssertEqual(inspected.identity.connectionGeneration, afterRestart.identity.connectionGeneration)
    }

    func testTwoDevicesRemainDistinct() async throws {
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [
            try descriptor("PHONE-0001", connection: .usb, mux: 1),
            try descriptor("PHONE-0002", connection: .usb, mux: 2)
        ]))
        let devices = try await bridge.listDevices()
        XCTAssertEqual(devices.map(\.identity.udid), ["PHONE-0001", "PHONE-0002"])
    }

    func testUSBAndWirelessDuplicatePreferUSB() async throws {
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [
            try descriptor("PHONE-0001", connection: .wireless, mux: 5),
            try descriptor("PHONE-0001", connection: .usb, mux: 9)
        ]))
        let devices = try await bridge.listDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].connection, .usb)
        XCTAssertEqual(devices[0].identity.usbmuxIdentifier, 9)
        XCTAssertEqual(devices[0].identity.connection, .usb)
    }

    func testInspectionFallsBackToLiveWirelessRecordWhenPreferredUSBRecordIsStale() async throws {
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(
            devices: [
                try descriptor("PHONE-0001", connection: .wireless, mux: 5),
                try descriptor("PHONE-0001", connection: .usb, mux: 9)
            ],
            unavailableMuxes: [9]
        ))
        let listed = try await bridge.listDevices()
        XCTAssertEqual(listed[0].connection, .usb)

        let inspected = try await bridge.inspect(listed[0].identity)

        XCTAssertEqual(inspected.identity.udid, "PHONE-0001")
        XCTAssertEqual(inspected.identity.usbmuxIdentifier, 5)
        XCTAssertEqual(inspected.identity.connectionGeneration, listed[0].identity.connectionGeneration)
        XCTAssertEqual(inspected.connection, .wireless)
    }

    func testInspectionDoesNotUseAlternativesFromANewerDiscoveryGeneration() async throws {
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(
            devices: [
                try descriptor("PHONE-0001", connection: .wireless, mux: 5),
                try descriptor("PHONE-0001", connection: .usb, mux: 9)
            ],
            unavailableMuxes: [9]
        ))
        let firstGeneration = try await bridge.listDevices()[0].identity
        _ = try await bridge.listDevices()

        do {
            _ = try await bridge.inspect(firstGeneration)
            XCTFail("expected stale discovery generation to fail closed")
        } catch let error as NativeDeviceBridgeError {
            XCTAssertEqual(error, .deviceNotFound)
        }
    }

    func testDuplicateUSBRecordsChooseLowestMuxDeterministically() async throws {
        for orderedMuxes: [UInt32] in [[19, 7], [7, 19]] {
            let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: try orderedMuxes.map {
                try descriptor("PHONE-0001", connection: .usb, mux: $0)
            }))
            let devices = try await bridge.listDevices()
            XCTAssertEqual(devices.count, 1)
            XCTAssertEqual(devices[0].identity.usbmuxIdentifier, 7)
        }
    }

    func testLockedUntrustedAndDeveloperModeOffAreTyped() async throws {
        let device = try descriptor("PHONE-0001", connection: .usb, mux: 1)
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(
            devices: [device], trust: .missing, lockState: .locked, developerMode: .disabled
        ))
        let listed = try await bridge.listDevices()
        let state = try await bridge.inspect(listed[0].identity)
        XCTAssertEqual(state.trust, .missing)
        XCTAssertEqual(state.lockState, .locked)
        XCTAssertEqual(state.developerMode, .disabled)
    }

    func testDisconnectAndStructuredErrorPropagate() async throws {
        let device = try descriptor("PHONE-0001", connection: .usb, mux: 1)
        let disconnected = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [device], failure: .deviceDisconnected))
        let listed = try await disconnected.listDevices()
        do {
            _ = try await disconnected.inspect(listed[0].identity)
            XCTFail("expected disconnect")
        } catch let error as NativeDeviceBridgeError {
            XCTAssertEqual(error, .deviceDisconnected)
        }

        let protocolFailure = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [], listFailure: .protocolFailure("safe")))
        do {
            _ = try await protocolFailure.listDevices()
            XCTFail("expected structured failure")
        } catch let error as NativeDeviceBridgeError {
            XCTAssertEqual(error, .protocolFailure("safe"))
        }
    }

    func testIdentityRejectsCrossDeviceBinding() throws {
        let first = try IOSSimDeviceIdentity(udid: "PHONE-0001")
        let second = try IOSSimDeviceIdentity(udid: "PHONE-0002")
        XCTAssertFalse(first.binds(to: second))
        let usb = try IOSSimDeviceIdentity(
            udid: "PHONE-0001", usbmuxIdentifier: 1, connection: .usb
        )
        let wireless = try IOSSimDeviceIdentity(
            udid: "PHONE-0001", usbmuxIdentifier: 2, connection: .wireless
        )
        XCTAssertFalse(usb.binds(to: wireless))
        XCTAssertThrowsError(try IOSSimDeviceIdentity(udid: "../bad"))
    }

    func testProductionCandidatesContainNoXcodePath() {
        let paths = DynamicNativeDeviceTransport.libraryCandidates(environment: [:], bundle: .main)
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix("libiossim_device_bridge.dylib") })
        XCTAssertFalse(paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined().contains("devicectl"))
    }

    func testBundledHelperResolvesBridgeRelativeToOuterApp() {
        let executable = URL(fileURLWithPath: "/Applications/IOSSim.app/Contents/MacOS/IOSSimProvisioner")
        let paths = DynamicNativeDeviceTransport.libraryCandidates(
            environment: [:],
            bundle: .main,
            executableURL: executable
        )
        XCTAssertTrue(paths.contains(
            "/Applications/IOSSim.app/Contents/Resources/NativeDeviceBridge/libiossim_device_bridge.dylib"
        ))
    }

    func testRustDeviceListPayloadDecodesAcrossFFIWireFormat() throws {
        let payload = Data(#"[{"stableId":"00008150-00022D581E12401C","usbmuxId":42,"connection":"usb"}]"#.utf8)
        let devices = try DynamicNativeDeviceTransport.decodeDeviceListPayload(payload)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].identity.udid, "00008150-00022D581E12401C")
        XCTAssertEqual(devices[0].identity.usbmuxIdentifier, 42)
        XCTAssertEqual(devices[0].connection, .usb)
    }

    func testDynamicLoaderDiagnosticDoesNotExposePaths() {
        let raw = "dlopen(/Users/example/IOSSim.app/bridge.dylib): code signature not valid; different Team IDs"
        let diagnostic = DynamicNativeDeviceTransport.safeLoadDiagnostic(raw)
        XCTAssertEqual(diagnostic, "native bridge rejected by hardened runtime library validation")
        XCTAssertFalse(diagnostic.contains("/Users/"))
    }

    func testFutureIPhoneModelIsNotFiltered() async throws {
        let device = try descriptor("PHONE-0001", connection: .usb, mux: 1)
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [device]))
        let snapshot = await IdeviceProvisioningBackend(bridge: bridge).discoverDeviceSnapshot(
            context: .init(resourcesURL: FileManager.default.temporaryDirectory)
        )
        XCTAssertEqual(snapshot.rawDeviceCount, 1)
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(snapshot.devices[0].model, "iPhone99,1")
        XCTAssertEqual(snapshot.devices[0].osVersion, "26.0")
    }

    func testUnknownConnectionTypeRemainsVisible() async throws {
        let device = try descriptor("PHONE-0001", connection: .unknown, mux: 1)
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: [device]))
        let listed = try await bridge.listDevices()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].connection, .unknown)
    }

    func testInspectionFailureDoesNotBecomeNoDevice() async throws {
        let device = try descriptor("PHONE-0001", connection: .usb, mux: 1)
        let bridge = IOSSimDeviceBridge(transport: FakeNativeTransport(
            devices: [device],
            failure: .protocolFailure("lockdown service unavailable")
        ))
        let snapshot = await IdeviceProvisioningBackend(bridge: bridge).discoverDeviceSnapshot(
            context: .init(resourcesURL: FileManager.default.temporaryDirectory)
        )
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(snapshot.devices[0].developerModeStatus, DeveloperModeReadiness.unknown.rawValue)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.code == .lockdownFailed })
    }

    func testBridgeFailureIsDistinguishableFromZeroDevices() async throws {
        let failed = IOSSimDeviceBridge(transport: FakeNativeTransport(
            devices: [],
            listFailure: .libraryUnavailable
        ))
        let failedSnapshot = await IdeviceProvisioningBackend(bridge: failed).discoverDeviceSnapshot(
            context: .init(resourcesURL: FileManager.default.temporaryDirectory)
        )
        let empty = IOSSimDeviceBridge(transport: FakeNativeTransport(devices: []))
        let emptySnapshot = await IdeviceProvisioningBackend(bridge: empty).discoverDeviceSnapshot(
            context: .init(resourcesURL: FileManager.default.temporaryDirectory)
        )
        XCTAssertEqual(failedSnapshot.primaryDiagnostic?.code, .helperLibraryMissing)
        XCTAssertEqual(emptySnapshot.primaryDiagnostic?.code, .zeroDevicesReturned)
    }

    func testDeveloperServicesReceiptRequiresBoundExactAppServiceLaunch() throws {
        let device = try IOSSimDeviceIdentity(
            udid: "PHONE-0001",
            usbmuxIdentifier: 7,
            connection: .usb,
            connectionGeneration: 12
        )
        let receipt = DeveloperServicesReadinessReceipt(
            coreDeviceProxyReady: true,
            softwareTunnelReady: true,
            rsdReady: true,
            remoteXPCReady: true,
            appServiceReady: true,
            launchFeatureReady: true,
            ddiMounted: true,
            schemaVersion: DeveloperServicesReadinessReceipt.currentSchemaVersion,
            deviceUDIDHash: DeveloperServicesReadinessReceipt.hash(device.udid),
            usbmuxIdentifier: 7,
            connection: .usb,
            connectionGeneration: 12,
            developerSupportIdentity: "23A1:identity:image-hash",
            pairingGeneration: 4,
            releaseIdentity: "0.1.0:4",
            sessionIdentifier: UUID().uuidString,
            targetBundleIdentifier: "com.example.runner",
            launchReceipt: NativeLaunchReceipt(
                bundleIdentifier: "com.example.runner",
                pid: 42,
                processIdentifierVersion: 1,
                appServiceConnected: true
            ),
            observedAt: Date()
        )
        XCTAssertTrue(receipt.ready)
        XCTAssertTrue(receipt.isCurrent(
            for: device,
            releaseIdentity: "0.1.0:4",
            pairingGeneration: 4,
            targetBundleIdentifier: "com.example.runner"
        ))
        XCTAssertFalse(receipt.isCurrent(
            for: device,
            releaseIdentity: "0.1.1:5",
            pairingGeneration: 4,
            targetBundleIdentifier: "com.example.runner"
        ))
        XCTAssertFalse(receipt.isCurrent(
            for: device,
            releaseIdentity: "0.1.0:4",
            pairingGeneration: 4,
            targetBundleIdentifier: "com.example.runner",
            now: Date().addingTimeInterval(301)
        ))
    }

    func testTransportStatusAloneIsNotOperationalReadiness() {
        let receipt = DeveloperServicesReadinessReceipt(
            coreDeviceProxyReady: true,
            softwareTunnelReady: true,
            rsdReady: true,
            remoteXPCReady: true,
            appServiceReady: true,
            launchFeatureReady: true,
            ddiMounted: true
        )
        XCTAssertTrue(receipt.transportReady)
        XCTAssertFalse(receipt.ready)
    }

    func testDeveloperServicesReceiptRejectsWrongAppAndStaleConnection() throws {
        let device = try IOSSimDeviceIdentity(
            udid: "PHONE-0001", usbmuxIdentifier: 7,
            connection: .usb, connectionGeneration: 12
        )
        let wrongApp = DeveloperServicesReadinessReceipt(
            coreDeviceProxyReady: true, softwareTunnelReady: true, rsdReady: true,
            remoteXPCReady: true, appServiceReady: true, launchFeatureReady: true,
            ddiMounted: true,
            schemaVersion: 2,
            deviceUDIDHash: DeveloperServicesReadinessReceipt.hash(device.udid),
            usbmuxIdentifier: 7, connection: .usb, connectionGeneration: 11,
            developerSupportIdentity: "23A1:active-device-service-map",
            pairingGeneration: nil, releaseIdentity: "0.1.0:4",
            sessionIdentifier: UUID().uuidString,
            targetBundleIdentifier: "com.example.runner",
            launchReceipt: NativeLaunchReceipt(
                bundleIdentifier: "com.example.other", pid: 1,
                processIdentifierVersion: 1, appServiceConnected: true
            ),
            observedAt: Date()
        )
        XCTAssertFalse(wrongApp.ready)
        XCTAssertFalse(wrongApp.isCurrent(
            for: device, releaseIdentity: "0.1.0:4",
            pairingGeneration: nil, targetBundleIdentifier: "com.example.runner"
        ))
    }

    private func descriptor(_ id: String, connection: DeviceConnectionKind, mux: UInt32) throws -> NativeDeviceDescriptor {
        NativeDeviceDescriptor(
            identity: try IOSSimDeviceIdentity(
                udid: id,
                usbmuxIdentifier: mux,
                connection: connection
            ),
            connection: connection
        )
    }
}

private actor FakeNativeTransport: NativeDeviceTransport {
    let devices: [NativeDeviceDescriptor]
    let trust: DeviceTrustState
    let lockState: DeviceLockState
    let developerMode: DeveloperModeReadiness
    let failure: NativeDeviceBridgeError?
    let listFailure: NativeDeviceBridgeError?
    let unavailableMuxes: Set<UInt32>

    init(
        devices: [NativeDeviceDescriptor],
        trust: DeviceTrustState = .trusted,
        lockState: DeviceLockState = .unlocked,
        developerMode: DeveloperModeReadiness = .enabled,
        failure: NativeDeviceBridgeError? = nil,
        listFailure: NativeDeviceBridgeError? = nil,
        unavailableMuxes: Set<UInt32> = []
    ) {
        self.devices = devices
        self.trust = trust
        self.lockState = lockState
        self.developerMode = developerMode
        self.failure = failure
        self.listFailure = listFailure
        self.unavailableMuxes = unavailableMuxes
    }

    func listDevices(timeout: Duration) async throws -> [NativeDeviceDescriptor] {
        if let listFailure { throw listFailure }
        return devices
    }

    func inspect(_ identity: IOSSimDeviceIdentity, timeout: Duration) async throws -> NativeDeviceInspection {
        if let failure { throw failure }
        if let mux = identity.usbmuxIdentifier, unavailableMuxes.contains(mux) {
            throw NativeDeviceBridgeError.deviceNotFound
        }
        guard let device = devices.first(where: {
            $0.identity.udid == identity.udid
                && $0.identity.usbmuxIdentifier == identity.usbmuxIdentifier
                && $0.connection == identity.connection
        }) else {
            throw NativeDeviceBridgeError.deviceNotFound
        }
        return NativeDeviceInspection(
            identity: identity,
            connection: device.connection,
            name: "Test iPhone",
            model: "iPhone99,1",
            osVersion: "26.0",
            osBuild: "23A1",
            trust: trust,
            lockState: lockState,
            developerMode: developerMode
        )
    }
}
