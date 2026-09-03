import XCTest
@testable import IOSSimMacCore

final class ProvisioningBackendTests: XCTestCase {
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
}
