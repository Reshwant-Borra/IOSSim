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
        XCTAssertEqual(selection.backend, .nativeZeroXcode)
        XCTAssertTrue(selection.zeroXcodeMode)
        XCTAssertTrue(selection.ready)
    }

    func testAutomaticIdentifiesTemporaryXcodeFallbackHonestly() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .automatic,
            capabilities: capabilities(native: false, xcodePresent: true)
        )
        XCTAssertEqual(selection.backend, .xcodeFallback)
        XCTAssertFalse(selection.zeroXcodeMode)
        XCTAssertTrue(selection.ready)
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

    func testNoXcodeAndUnqualifiedNativeBackendFailsClosed() {
        let selection = ConsumerProvisioningBackendSelector.select(
            preference: .automatic,
            capabilities: capabilities(native: false, xcodePresent: false)
        )
        XCTAssertNil(selection.backend)
        XCTAssertEqual(selection.failureCode, "ZERO_XCODE_PERSONAL_TEAM_BLOCKED")
        XCTAssertFalse(selection.xcodePresent)
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
            $0.paidTeam == .documentedSupported && $0.freePersonalTeam == .requiresXcode
        })
    }

    func testNoDevicectlEnvironmentFlagsAreRecognized() {
        XCTAssertTrue(RuntimeProvisioning.devicectlForbidden(environment: ["IOSSIM_FORBID_DEVICETCTL": "1"]))
        XCTAssertTrue(RuntimeProvisioning.devicectlForbidden(environment: ["IOSSIM_NO_DEVICETCTL": "true"]))
        XCTAssertFalse(RuntimeProvisioning.devicectlForbidden(environment: [:]))
    }

    func testIdeviceBackendFailsExplicitlyUntilMacOSFfiExists() async throws {
        let backend = IdeviceProvisioningBackend()
        let result = try await backend.install(
            component: DeviceArtifactComponent(
                role: "iosMain",
                bundleIdentifier: "com.iossim.on-device-dvt-poc",
                version: "0.1",
                relativePath: "DeviceArtifacts/IOSSim DVT POC.app",
                sha256: "unused"
            ),
            rawDeviceIdentifier: "A",
            context: RuntimeProvisioningContext(resourcesURL: FileManager.default.temporaryDirectory)
        )
        XCTAssertEqual(result.exitCode, 78)
        XCTAssertTrue(result.stderr.contains("IDEVICE_BACKEND_UNAVAILABLE"))
    }

    private func capabilities(native: Bool, xcodePresent: Bool) -> ConsumerProvisioningCapabilities {
        ConsumerProvisioningCapabilities(
            bundledDeviceBridgeReady: native,
            nativeAppleAuthenticationReady: native,
            nativePersonalTeamProvisioningReady: native,
            directSigningReady: native,
            xcodePresent: xcodePresent
        )
    }
}
