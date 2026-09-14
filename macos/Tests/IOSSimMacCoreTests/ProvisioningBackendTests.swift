import XCTest
@testable import IOSSimMacCore

final class ProvisioningBackendTests: XCTestCase {
    func testConsumerBackendPreferenceDefaultsToAutomatic() {
        XCTAssertEqual(ConsumerProvisioningBackendPreference.selected(environment: [:]), .automatic)
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

    func testAutomaticUsesHeadlessXcodeOnlyWhenInitialAuthorizationIsReady() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .automatic,
            capabilities: capabilities(native: false, xcodePresent: true, headlessXcodeAuth: true)
        )
        XCTAssertEqual(selection.backend, .xcodeInvisible)
        XCTAssertTrue(selection.ready)
        XCTAssertFalse(selection.zeroXcodeMode)
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
                sha256: "unused"
            ),
            rawDeviceIdentifier: "PHONE-0001",
            context: RuntimeProvisioningContext(resourcesURL: FileManager.default.temporaryDirectory)
        )
        XCTAssertEqual(result.exitCode, 70)
        XCTAssertTrue(result.stderr.contains("NATIVE_INSTALL_FAILED"))
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
