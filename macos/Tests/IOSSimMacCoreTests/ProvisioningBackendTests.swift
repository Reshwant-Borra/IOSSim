import XCTest
@testable import IOSSimMacCore

final class ProvisioningBackendTests: XCTestCase {
    #if IOSSIM_BUNDLED_ENGINE
    func testPackagedBuildIgnoresLegacyBackendEnvironmentSelectors() {
        XCTAssertEqual(
            ConsumerProvisioningBackendPreference.selected(
                environment: ["IOSSIM_PROVISIONING_BACKEND": "XCODE_FALLBACK"]
            ),
            .nativePersonalTeam
        )
        XCTAssertEqual(
            ProvisioningBackendKind.selected(
                environment: ["IOSSIM_DEVICE_BACKEND": "devicectl"]
            ),
            .idevice
        )
    }
    #endif

    func testConsumerBackendPreferenceDefaultsToNativePersonalTeam() {
        XCTAssertEqual(ConsumerProvisioningBackendPreference.selected(environment: [:]), .nativePersonalTeam)
        XCTAssertEqual(
            ConsumerProvisioningBackendPreference.selected(
                environment: ["IOSSIM_PROVISIONING_BACKEND": "ZERO_XCODE"]
            ),
            .zeroXcode
        )
    }

    func testAutomaticPrefersQualifiedZeroXcodeBackend() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .automatic,
            capabilities: capabilities(native: true, xcodePresent: true)
        )
        XCTAssertEqual(selection.backend, .nativePersonalTeam)
        XCTAssertTrue(selection.zeroXcodeMode)
        XCTAssertTrue(selection.ready)
    }

    func testAutomaticDoesNotRouteConsumersToManualXcodeFallback() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .automatic,
            capabilities: capabilities(native: false, xcodePresent: true)
        )
        XCTAssertNil(selection.backend)
        XCTAssertFalse(selection.zeroXcodeMode)
        XCTAssertFalse(selection.ready)
        XCTAssertEqual(selection.failureCode, "CONSUMER_AUTHORIZATION_BACKEND_UNAVAILABLE")
    }

    func testExplicitZeroXcodeNeverFallsBackToXcode() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .zeroXcode,
            capabilities: capabilities(native: false, xcodePresent: true)
        )
        XCTAssertNil(selection.backend)
        XCTAssertTrue(selection.zeroXcodeMode)
        XCTAssertFalse(selection.ready)
        XCTAssertEqual(selection.failureCode, "ZERO_XCODE_BACKEND_NOT_QUALIFIED")
        XCTAssertEqual(
            ProvisioningBackendKind.selected(
                environment: ["IOSSIM_PROVISIONING_BACKEND": "ZERO_XCODE"]
            ),
            .idevice
        )
    }

    func testNativePersonalTeamProvisioningUsesNativeDeviceBridgeByDefault() {
        XCTAssertEqual(
            ProvisioningBackendKind.selected(
                environment: ["IOSSIM_PROVISIONING_BACKEND": "NATIVE_PERSONAL_TEAM"]
            ),
            .idevice
        )
        XCTAssertEqual(
            ProvisioningBackendKind.selected(
                environment: [
                    "IOSSIM_PROVISIONING_BACKEND": "NATIVE_PERSONAL_TEAM",
                    "IOSSIM_DEVICE_BACKEND": "idevice"
                ]
            ),
            .idevice
        )
    }

    func testNoXcodeAndUnqualifiedNativeBackendFailsClosed() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .automatic,
            capabilities: capabilities(native: false, xcodePresent: false)
        )
        XCTAssertNil(selection.backend)
        XCTAssertEqual(selection.failureCode, "CONSUMER_AUTHORIZATION_BACKEND_UNAVAILABLE")
        XCTAssertFalse(selection.xcodePresent)
    }

    func testAutomaticDoesNotSelectHeadlessXcodeEvenWhenInitialAuthorizationIsReady() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .automatic,
            capabilities: capabilities(native: false, xcodePresent: true, headlessXcodeAuth: true)
        )
        XCTAssertNil(selection.backend)
        XCTAssertFalse(selection.ready)
        XCTAssertFalse(selection.zeroXcodeMode)
        XCTAssertEqual(selection.failureCode, "CONSUMER_AUTHORIZATION_BACKEND_UNAVAILABLE")
    }

    func testExplicitHeadlessXcodeReportsInitialAccountAuthBlocker() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .xcodeInvisible,
            capabilities: capabilities(native: false, xcodePresent: true)
        )
        XCTAssertNil(selection.backend)
        XCTAssertEqual(selection.failureCode, "PATH_A_BLOCKED_AT_INITIAL_ACCOUNT_AUTH")
    }

    func testLegacyXcodeFallbackRemainsExplicitlyAvailable() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .xcodeFallback,
            capabilities: capabilities(native: false, xcodePresent: true)
        )
        XCTAssertEqual(selection.backend, .xcodeFallback)
        XCTAssertTrue(selection.ready)
    }

    func testXcodePresenceUsesOnlyKnownApplicationPaths() {
        var inspected: [String] = []
        let present = XcodePresenceDetector.isPresent { path in
            inspected.append(path)
            return path == "/Applications/Xcode-beta.app"
        }
        XCTAssertTrue(present)
        XCTAssertEqual(inspected, XcodePresenceDetector.knownApplicationPaths)
    }

    func testFreePersonalTeamOperationsAreNotMisrepresentedAsPublicAPIs() {
        XCTAssertEqual(
            Set(ZeroXcodeCapabilityPolicy.appleOperations.map(\.operation)),
            Set(AppleProvisioningOperation.allCases)
        )
        XCTAssertTrue(ZeroXcodeCapabilityPolicy.appleOperations.allSatisfy {
            $0.paidTeam == .documentedSupported && $0.freePersonalTeam == .undocumentedButObserved
        })
    }

    func testNoDevicectlEnvironmentFlagsAreRecognized() {
        XCTAssertTrue(RuntimeProvisioning.devicectlForbidden(environment: ["IOSSIM_FORBID_DEVICETCTL": "1"]))
        XCTAssertTrue(RuntimeProvisioning.devicectlForbidden(environment: ["IOSSIM_NO_DEVICETCTL": "true"]))
        XCTAssertFalse(RuntimeProvisioning.devicectlForbidden(environment: [:]))
    }

    func testIdeviceBackendFailsExplicitlyWhenBundledBridgeIsUnavailable() async throws {
        let backend = IdeviceProvisioningBackend()
        let result = try await backend.install(
            component: DeviceArtifactComponent(
                role: "iosMain",
                bundleIdentifier: "com.iossim.on-device-dvt-poc",
                version: "0.1",
                relativePath: "DeviceArtifacts/IOSSim DVT POC.app",
                sha256: "unused",
                expectedTeamIdentifier: "TEAM1"
            ),
            rawDeviceIdentifier: "PHONE-0001",
            context: RuntimeProvisioningContext(resourcesURL: FileManager.default.temporaryDirectory)
        )
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("NATIVE_DEVICE_IDENTITY_INVALID"))
    }

    func testIdeviceApplicationOperationsNeverInvokeProcessRunner() async throws {
        let identifier = "00008150-00022D581E12401C"
        let fixture = try Self.makeSignedApp(bundleID: "com.personalteam.iossim.fixture")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let service = RecordingNativeApplicationService(installedTeam: "TEAM1")
        let backend = IdeviceProvisioningBackend(
            bridge: IOSSimDeviceBridge(transport: try FixtureDeviceTransport(udid: identifier)),
            applicationService: service
        )
        let context = RuntimeProvisioningContext(
            resourcesURL: URL(fileURLWithPath: "/"),
            runner: ProcessRunner { _, _, _, _, _ in
                XCTFail("native application operations must not spawn a process")
                return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected process")
            }
        )
        let bundleIdentifier = "com.personalteam.iossim.fixture"

        let install = try await backend.install(
            component: DeviceArtifactComponent(
                role: "iosMain",
                bundleIdentifier: bundleIdentifier,
                version: "1",
                relativePath: fixture.path,
                sha256: "fixture",
                expectedTeamIdentifier: "TEAM1"
            ),
            rawDeviceIdentifier: identifier,
            context: context
        )
        XCTAssertEqual(install.exitCode, 0, install.stderr)
        let uninstall = try await backend.uninstall(
            bundleIdentifier: bundleIdentifier,
            expectedTeamIdentifier: "TEAM1",
            rawDeviceIdentifier: identifier,
            context: context
        )
        XCTAssertEqual(uninstall.exitCode, 0)
        let launch = try await backend.launch(
            bundleIdentifier: bundleIdentifier,
            rawDeviceIdentifier: identifier,
            context: context
        )
        XCTAssertEqual(launch.exitCode, 0)
        let data = try await backend.readContainerFile(
            bundleIdentifier: bundleIdentifier,
            relativePath: "Library/Preferences/fixture.plist",
            rawDeviceIdentifier: identifier,
            context: context
        )
        XCTAssertEqual(data, Data("fixture".utf8))
        let calls = await service.calls
        XCTAssertEqual(calls, [
            "inventory", "install:fresh", "inventory",
            "inventory", "uninstall", "inventory", "launch", "read"
        ])
    }

    func testNativeInstallFailureDoesNotFallBackToDevicectl() async throws {
        let identifier = "00008150-00022D581E12401C"
        let service = RecordingNativeApplicationService(failure: .serviceUnavailable)
        let backend = IdeviceProvisioningBackend(
            bridge: IOSSimDeviceBridge(transport: try FixtureDeviceTransport(udid: identifier)),
            applicationService: service
        )
        var processInvoked = false
        let result = try await backend.install(
            component: DeviceArtifactComponent(
                role: "iosMain",
                bundleIdentifier: "com.personalteam.iossim.fixture",
                version: "1",
                relativePath: "/tmp/Fixture.app",
                sha256: "fixture",
                expectedTeamIdentifier: "TEAM1"
            ),
            rawDeviceIdentifier: identifier,
            context: RuntimeProvisioningContext(
                resourcesURL: FileManager.default.temporaryDirectory,
                runner: ProcessRunner { _, _, _, _, _ in
                    processInvoked = true
                    return ProcessResult(exitCode: 99, stdout: "", stderr: "unexpected process")
                }
            )
        )
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("NATIVE_INSTALL_FAILED"))
        XCTAssertFalse(processInvoked)
    }

    func testIdeviceBackendRetainsDeterministicUSBConnectionBinding() async throws {
        let udid = "00008150-00022D581E12401C"
        let usb = try NativeDeviceDescriptor(
            identity: IOSSimDeviceIdentity(udid: udid, usbmuxIdentifier: 7, connection: .usb),
            connection: .usb
        )
        let wireless = try NativeDeviceDescriptor(
            identity: IOSSimDeviceIdentity(udid: udid, usbmuxIdentifier: 99, connection: .wireless),
            connection: .wireless
        )
        let service = RecordingNativeApplicationService()
        let backend = IdeviceProvisioningBackend(
            bridge: IOSSimDeviceBridge(transport: FixtureDeviceTransport(descriptors: [wireless, usb])),
            applicationService: service
        )
        let selected = await backend.rawDeviceIdentifier(
            matching: udid,
            context: RuntimeProvisioningContext(resourcesURL: URL(fileURLWithPath: "/"))
        )
        XCTAssertEqual(selected, udid)
        _ = await backend.isAppInstalled(
            bundleIdentifier: "com.example.app",
            rawDeviceIdentifier: udid,
            context: RuntimeProvisioningContext(resourcesURL: URL(fileURLWithPath: "/"))
        )
        let identities = await service.identities
        XCTAssertEqual(identities.last?.usbmuxIdentifier, 7)
        XCTAssertEqual(identities.last?.connection, .usb)
        XCTAssertGreaterThan(identities.last?.connectionGeneration ?? 0, 0)
    }

    func testNativeUninstallRefusesUnknownOwnership() async throws {
        let udid = "00008150-00022D581E12401C"
        let service = RecordingNativeApplicationService()
        await service.setInventory([
            NativeInstalledApplication(
                bundleIdentifier: "com.personalteam.iossim.fixture",
                version: "1",
                teamIdentifier: nil
            )
        ])
        let backend = IdeviceProvisioningBackend(
            bridge: IOSSimDeviceBridge(transport: try FixtureDeviceTransport(udid: udid)),
            applicationService: service
        )
        let result = try await backend.uninstall(
            bundleIdentifier: "com.personalteam.iossim.fixture",
            expectedTeamIdentifier: "TEAM1",
            rawDeviceIdentifier: udid,
            context: RuntimeProvisioningContext(resourcesURL: URL(fileURLWithPath: "/"))
        )
        XCTAssertEqual(result.exitCode, 77)
        XCTAssertEqual(result.stderr, "NATIVE_OWNERSHIP_CONFLICT")
        let calls = await service.calls
        XCTAssertFalse(calls.contains("uninstall"))
    }

    func testDevicectlDiscoveryKeepsPairedPhysicalIPhoneWhenLockStateSucceeds() async throws {
        guard RuntimeProvisioning.xcrunURL() != nil else {
            throw XCTSkip("/usr/bin/xcrun is unavailable on this Mac.")
        }
        let observedIdentifier = "812EB0E1-DB40-5E49-9347-08079A74CBAF"
        let staleIdentifier = "E08CABAF-0FC4-5000-91E8-146F2E99B3EA"
        let runner = ProcessRunner { _, arguments, _, environment, _ in
            XCTAssertEqual(environment, RuntimeProvisioning.deterministicEnvironment())
            guard let outputIndex = arguments.firstIndex(of: "--json-output"),
                  arguments.indices.contains(arguments.index(after: outputIndex)) else {
                return ProcessResult(exitCode: 2, stdout: "", stderr: "missing --json-output")
            }
            let outputURL = URL(fileURLWithPath: arguments[arguments.index(after: outputIndex)])
            if arguments.prefix(3) == ["devicectl", "list", "devices"] {
                try Self.writeJSON(Self.deviceListJSON(
                    observedIdentifier: observedIdentifier,
                    staleIdentifier: staleIdentifier
                ), to: outputURL)
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            if arguments.prefix(4) == ["devicectl", "device", "info", "lockState"],
               let deviceIndex = arguments.firstIndex(of: "--device"),
               arguments.indices.contains(arguments.index(after: deviceIndex)) {
                let identifier = arguments[arguments.index(after: deviceIndex)]
                if identifier == observedIdentifier {
                    try Self.writeJSON(Self.lockStateJSON(identifier: observedIdentifier), to: outputURL)
                    return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                }
                if identifier == staleIdentifier {
                    try Self.writeJSON(Self.lockStateFailureJSON(identifier: staleIdentifier), to: outputURL)
                    return ProcessResult(exitCode: 1, stdout: "", stderr: "device unavailable")
                }
            }
            return ProcessResult(exitCode: 2, stdout: "", stderr: "unexpected arguments: \(arguments.joined(separator: " "))")
        }
        let devices = await DevicectlProvisioningBackend().discoverDevices(
            context: RuntimeProvisioningContext(
                resourcesURL: FileManager.default.temporaryDirectory,
                runner: runner
            )
        )
        XCTAssertEqual(devices.map(\.selectionIdentifier), [observedIdentifier])
        XCTAssertEqual(devices[0].name, "Rishi Borra")
        XCTAssertEqual(devices[0].model, "iPhone 17 Pro")
        XCTAssertEqual(devices[0].pairingState, "paired")
        XCTAssertEqual(devices[0].developerModeStatus, "enabled")
        XCTAssertEqual(devices[0].tunnelState, "connected")
        XCTAssertEqual(devices[0].isLocked, false)
    }

    private func capabilities(
        native: Bool,
        xcodePresent: Bool,
        headlessXcodeAuth: Bool = false
    ) -> ConsumerProvisioningCapabilities {
        ConsumerProvisioningCapabilities(
            bundledDeviceBridgeReady: native,
            nativeAppleAuthenticationReady: native,
            nativePersonalTeamProvisioningReady: native,
            directSigningReady: native,
            xcodePresent: xcodePresent,
            headlessXcodeAuthenticationReady: headlessXcodeAuth
        )
    }

    private static func writeJSON(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)?.write(to: url)
    }

    private static func makeSignedApp(bundleID: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appendingPathComponent(".build/iossim/v7-backend-tests/\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("_CodeSignature"),
            withIntermediateDirectories: true
        )
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleVersion": "1"]
        XCTAssertTrue(info.write(to: app.appendingPathComponent("Info.plist"), atomically: true))
        try Data("profile".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        try Data("signature".utf8).write(to: app.appendingPathComponent("_CodeSignature/CodeResources"))
        return app
    }

    private static func deviceListJSON(observedIdentifier: String, staleIdentifier: String) -> String {
        """
        {
          "info": {
            "commandType": "devicectl.list.devices",
            "jsonVersion": 3,
            "outcome": "success"
          },
          "result": {
            "devices": [
              {
                "connectionProperties": {
                  "pairingState": "paired",
                  "tunnelState": "unavailable"
                },
                "deviceProperties": {
                  "developerModeStatus": "enabled",
                  "name": "Stale iPhone",
                  "osVersionNumber": "26.6"
                },
                "hardwareProperties": {
                  "deviceType": "iPhone",
                  "marketingName": "iPhone 17",
                  "platform": "iOS",
                  "udid": "00008150-001C5C463A7B401C"
                },
                "identifier": "\(staleIdentifier)"
              },
              {
                "connectionProperties": {
                  "pairingState": "paired",
                  "transportType": "wired",
                  "tunnelState": "connected"
                },
                "deviceProperties": {
                  "developerModeStatus": "enabled",
                  "name": "Rishi Borra",
                  "osVersionNumber": "26.6"
                },
                "hardwareProperties": {
                  "deviceType": "iPhone",
                  "marketingName": "iPhone 17 Pro",
                  "platform": "iOS",
                  "udid": "00008150-001C5C463A7B401C"
                },
                "identifier": "\(observedIdentifier)"
              }
            ]
          }
        }
        """
    }

    private static func lockStateJSON(identifier: String) -> String {
        """
        {
          "info": {
            "commandType": "devicectl.device.info.lockState",
            "jsonVersion": 3,
            "outcome": "success"
          },
          "result": {
            "deviceIdentifier": "\(identifier)",
            "passcodeRequired": false,
            "unlockedSinceBoot": true
          }
        }
        """
    }

    private static func lockStateFailureJSON(identifier: String) -> String {
        """
        {
          "error": {
            "code": 1011,
            "domain": "com.apple.dt.CoreDeviceError"
          },
          "info": {
            "commandType": "devicectl.device.info.lockState",
            "jsonVersion": 3,
            "outcome": "failed"
          }
        }
        """
    }
}

private actor RecordingNativeApplicationService: NativeApplicationServicing {
    private(set) var calls: [String] = []
    private var applications: [NativeInstalledApplication] = []
    private let failure: NativeApplicationManagementError?
    private let installedTeam: String?
    private(set) var identities: [IOSSimDeviceIdentity] = []

    init(failure: NativeApplicationManagementError? = nil, installedTeam: String? = nil) {
        self.failure = failure
        self.installedTeam = installedTeam
    }

    func setInventory(_ values: [NativeInstalledApplication]) {
        applications = values
    }

    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] {
        calls.append("inventory")
        identities.append(device)
        if let failure { throw failure }
        return applications
    }

    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {
        calls.append("install:\(mode.rawValue)")
        if let failure { throw failure }
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))
        let bundle = info?["CFBundleIdentifier"] as? String ?? "missing"
        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
        applications.removeAll { $0.bundleIdentifier == bundle }
        applications.append(.init(bundleIdentifier: bundle, version: version, teamIdentifier: installedTeam))
    }

    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        calls.append("uninstall")
        if let failure { throw failure }
        applications.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        calls.append("launch")
        if let failure { throw failure }
    }

    func writeContainer(
        bundleIdentifier: String,
        relativePath: String,
        data: Data,
        on device: IOSSimDeviceIdentity
    ) async throws {
        calls.append("write")
        if let failure { throw failure }
    }

    func readContainer(
        bundleIdentifier: String,
        relativePath: String,
        on device: IOSSimDeviceIdentity
    ) async throws -> Data {
        calls.append("read")
        if let failure { throw failure }
        return Data("fixture".utf8)
    }
}

private actor FixtureDeviceTransport: NativeDeviceTransport {
    private let descriptors: [NativeDeviceDescriptor]

    init(udid: String) throws {
        descriptors = [NativeDeviceDescriptor(
            identity: try IOSSimDeviceIdentity(udid: udid, usbmuxIdentifier: 7, connection: .usb),
            connection: .usb
        )]
    }

    init(descriptors: [NativeDeviceDescriptor]) {
        self.descriptors = descriptors
    }

    func listDevices(timeout: Duration) async throws -> [NativeDeviceDescriptor] { descriptors }

    func inspect(_ identity: IOSSimDeviceIdentity, timeout: Duration) async throws -> NativeDeviceInspection {
        guard let descriptor = descriptors.first(where: {
            $0.identity.udid == identity.udid && $0.identity.usbmuxIdentifier == identity.usbmuxIdentifier
        }) else { throw NativeDeviceBridgeError.deviceNotFound }
        return NativeDeviceInspection(
            identity: identity,
            connection: descriptor.connection,
            trust: .trusted,
            lockState: .unlocked,
            developerMode: .enabled
        )
    }
}
