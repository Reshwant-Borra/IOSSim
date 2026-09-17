import Foundation
import XCTest
@testable import IOSSimMacCore

final class LocalDevVPNSetupCoordinatorTests: XCTestCase {
    func testLaunchesInstalledLocalDevVPNAndRequiresFunctionalReceipt() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        let service = LocalDevVPNFixtureService(
            iosSimBundleIdentifier: iosSimID,
            localDevVPNInstalled: true,
            readyAfterLaunch: true
        )
        let coordinator = LocalDevVPNSetupCoordinator(
            service: service,
            initialProbeAttempts: 1,
            readinessAttempts: 2,
            delayNanoseconds: 0
        )
        let receipt = try await coordinator.prepare(
            device: try IOSSimDeviceIdentity(udid: "00008150-00022D581E12401C"),
            iosSimBundleIdentifier: iosSimID
        )

        XCTAssertEqual(receipt.status, "ready")
        XCTAssertEqual(receipt.endpoint, LocalDevVPNEndpoint())
        XCTAssertTrue(receipt.endpointReachable)
        let launchedBundleIdentifiers = await service.launchedBundleIdentifiers()
        XCTAssertEqual(launchedBundleIdentifiers, [
            iosSimID, LocalDevVPNSetupCoordinator.localDevVPNBundleIdentifier
        ])
    }

    func testMissingLocalDevVPNIsTypedPrerequisite() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        let service = LocalDevVPNFixtureService(
            iosSimBundleIdentifier: iosSimID,
            localDevVPNInstalled: false,
            readyAfterLaunch: false
        )
        let coordinator = LocalDevVPNSetupCoordinator(
            service: service,
            initialProbeAttempts: 1,
            readinessAttempts: 1,
            delayNanoseconds: 0
        )

        do {
            _ = try await coordinator.prepare(
                device: try IOSSimDeviceIdentity(udid: "00008150-00022D581E12401C"),
                iosSimBundleIdentifier: iosSimID
            )
            XCTFail("Expected LocalDevVPN prerequisite")
        } catch let failure as LocalDevVPNSetupFailure {
            XCTAssertEqual(failure, .appMissing)
        }
    }

    func testUnreadyLocalDevVPNIsTypedUserAction() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        let service = LocalDevVPNFixtureService(
            iosSimBundleIdentifier: iosSimID,
            localDevVPNInstalled: true,
            readyAfterLaunch: false
        )
        let coordinator = LocalDevVPNSetupCoordinator(
            service: service,
            initialProbeAttempts: 1,
            readinessAttempts: 2,
            delayNanoseconds: 0
        )

        do {
            _ = try await coordinator.prepare(
                device: try IOSSimDeviceIdentity(udid: "00008150-00022D581E12401C"),
                iosSimBundleIdentifier: iosSimID
            )
            XCTFail("Expected LocalDevVPN user action")
        } catch let failure as LocalDevVPNSetupFailure {
            XCTAssertEqual(failure, .vpnPermissionRequired)
        }
    }

    func testUnsupportedInstalledVersionFailsClosed() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        let service = LocalDevVPNFixtureService(
            iosSimBundleIdentifier: iosSimID,
            localDevVPNInstalled: true,
            readyAfterLaunch: false,
            localDevVPNVersion: "2.0.0"
        )
        let coordinator = LocalDevVPNSetupCoordinator(service: service, initialProbeAttempts: 1, readinessAttempts: 1, delayNanoseconds: 0)
        do {
            _ = try await coordinator.prepare(device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), iosSimBundleIdentifier: iosSimID)
            XCTFail("Expected unsupported version")
        } catch let failure as LocalDevVPNSetupFailure {
            XCTAssertEqual(failure, .unsupportedVersion)
        }
    }

    func testRunningButEndpointUnavailableIsDistinctFromConfiguredButStopped() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        for (state, expected) in [
            (LocalDevVPNLifecycleState.running, LocalDevVPNSetupFailure.endpointUnavailable),
            (.configured, .vpnNotRunning),
        ] {
            let service = LocalDevVPNFixtureService(
                iosSimBundleIdentifier: iosSimID,
                localDevVPNInstalled: true,
                readyAfterLaunch: false,
                observedState: state
            )
            let coordinator = LocalDevVPNSetupCoordinator(service: service, initialProbeAttempts: 1, readinessAttempts: 1, delayNanoseconds: 0)
            do {
                _ = try await coordinator.prepare(device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), iosSimBundleIdentifier: iosSimID)
                XCTFail("Expected \(expected)")
            } catch let failure as LocalDevVPNSetupFailure {
                XCTAssertEqual(failure, expected)
            }
        }
    }
}

private actor LocalDevVPNFixtureService: NativeApplicationServicing {
    private let iosSimBundleIdentifier: String
    private let localDevVPNInstalled: Bool
    private let readyAfterLaunch: Bool
    private let localDevVPNVersion: String
    private let observedState: LocalDevVPNLifecycleState?
    private var request: LocalDevVPNSetupRequestPayload?
    private var launches: [String] = []

    init(iosSimBundleIdentifier: String, localDevVPNInstalled: Bool, readyAfterLaunch: Bool,
         localDevVPNVersion: String = "1.3.0", observedState: LocalDevVPNLifecycleState? = nil) {
        self.iosSimBundleIdentifier = iosSimBundleIdentifier
        self.localDevVPNInstalled = localDevVPNInstalled
        self.readyAfterLaunch = readyAfterLaunch
        self.localDevVPNVersion = localDevVPNVersion
        self.observedState = observedState
    }

    func inventory(on device: IOSSimDeviceIdentity) async throws -> [NativeInstalledApplication] {
        var result = [NativeInstalledApplication(bundleIdentifier: iosSimBundleIdentifier)]
        if localDevVPNInstalled {
            result.append(NativeInstalledApplication(
                bundleIdentifier: LocalDevVPNSetupCoordinator.localDevVPNBundleIdentifier,
                version: localDevVPNVersion
            ))
        }
        return result
    }

    func install(appURL: URL, mode: NativeApplicationInstallMode, on device: IOSSimDeviceIdentity) async throws {}
    func uninstall(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {}

    func launch(bundleIdentifier: String, on device: IOSSimDeviceIdentity) async throws {
        launches.append(bundleIdentifier)
    }

    func writeContainer(
        bundleIdentifier: String,
        relativePath: String,
        data: Data,
        on device: IOSSimDeviceIdentity
    ) async throws {
        request = try JSONDecoder().decode(LocalDevVPNSetupRequestPayload.self, from: data)
    }

    func readContainer(
        bundleIdentifier: String,
        relativePath: String,
        on device: IOSSimDeviceIdentity
    ) async throws -> Data {
        guard let request else { throw LocalDevVPNSetupFailure.receiptMissing }
        let localDevVPNLaunched = launches.contains(LocalDevVPNSetupCoordinator.localDevVPNBundleIdentifier)
        let ready = readyAfterLaunch && localDevVPNLaunched
        let receipt = LocalDevVPNSetupReceiptPayload(
            schemaVersion: 1,
            requestID: request.requestID,
            status: ready ? "ready" : (localDevVPNLaunched ? "action_required" : "checking"),
            endpoint: request.endpoint,
            interfaceVisible: ready,
            endpointReachable: ready,
            errorCode: ready ? nil : (localDevVPNLaunched ? "LOCALDEVVPN_USER_ACTION_REQUIRED" : nil),
            timestamp: .now,
            lifecycleState: ready ? .runtimeEndpointReachable : (observedState ?? .vpnPermissionRequired),
            deviceUDID: request.deviceUDID,
            teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity
        )
        return try JSONEncoder().encode(receipt)
    }

    func launchedBundleIdentifiers() -> [String] { launches }
}
