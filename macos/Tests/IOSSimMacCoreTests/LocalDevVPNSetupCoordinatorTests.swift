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

    func testInvalidReceiptAndTransportFailureRemainDistinct() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        let invalidService = LocalDevVPNFixtureService(
            iosSimBundleIdentifier: iosSimID,
            localDevVPNInstalled: true,
            readyAfterLaunch: false,
            receiptMode: .bindingMismatch
        )
        do {
            _ = try await LocalDevVPNSetupCoordinator(
                service: invalidService, initialProbeAttempts: 1, readinessAttempts: 1, delayNanoseconds: 0
            ).prepare(device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), iosSimBundleIdentifier: iosSimID)
            XCTFail("Expected an invalid receipt")
        } catch let failure as LocalDevVPNSetupFailure {
            XCTAssertEqual(failure, .receiptInvalid)
        }

        let transportService = LocalDevVPNFixtureService(
            iosSimBundleIdentifier: iosSimID,
            localDevVPNInstalled: true,
            readyAfterLaunch: false,
            failVeyaLaunch: true
        )
        do {
            _ = try await LocalDevVPNSetupCoordinator(
                service: transportService, initialProbeAttempts: 1, readinessAttempts: 1, delayNanoseconds: 0
            ).prepare(device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), iosSimBundleIdentifier: iosSimID)
            XCTFail("Expected transport failure")
        } catch let failure as LocalDevVPNSetupFailure {
            XCTAssertEqual(failure, .transportUnavailable)
        }
    }

    func testMissingReceiptIsNotMisreportedAsVPNPermission() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        let service = LocalDevVPNFixtureService(
            iosSimBundleIdentifier: iosSimID,
            localDevVPNInstalled: true,
            readyAfterLaunch: false,
            receiptMode: .missing
        )
        do {
            _ = try await LocalDevVPNSetupCoordinator(
                service: service, initialProbeAttempts: 1, readinessAttempts: 1, delayNanoseconds: 0
            ).prepare(device: try IOSSimDeviceIdentity(udid: "PHONE-0001"), iosSimBundleIdentifier: iosSimID)
            XCTFail("Expected missing receipt")
        } catch let failure as LocalDevVPNSetupFailure {
            XCTAssertEqual(failure, .receiptMissing)
        }
    }

    func testVeyaLaunchPreservesDeveloperModeAndDeveloperTrustActions() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        let trustDetail = "launchapplication: com.apple.dt.CoreDeviceError code = 10002 "
            + "FBSOpenApplicationErrorDomain code = 3 BSErrorCodeDescription: Security "
            + "profile has not been explicitly trusted"
        for (bridge, expected) in [
            (NativeDeviceBridgeError.developerModeRequired, LocalDevVPNSetupFailure.developerModeRequired),
            (NativeDeviceBridgeError.launchRejected(trustDetail), .developerTrustRequired),
        ] {
            let service = LocalDevVPNFixtureService(
                iosSimBundleIdentifier: iosSimID,
                localDevVPNInstalled: true,
                readyAfterLaunch: false,
                veyaLaunchError: bridge
            )
            do {
                _ = try await LocalDevVPNSetupCoordinator(
                    service: service,
                    initialProbeAttempts: 1,
                    readinessAttempts: 1,
                    delayNanoseconds: 0
                ).prepare(
                    device: try IOSSimDeviceIdentity(udid: "PHONE-0001"),
                    iosSimBundleIdentifier: iosSimID
                )
                XCTFail("expected typed launch failure")
            } catch {
                XCTAssertEqual(error as? LocalDevVPNSetupFailure, expected)
            }
        }
    }

    func testSecretFreeTraceRecordsEndpointDiagnosisAndTypedFailure() async throws {
        let iosSimID = "com.personalteam.iossim.test.on-device-dvt-poc"
        let trace = MemoryLocalDevVPNTraceRecorder()
        let service = LocalDevVPNFixtureService(
            iosSimBundleIdentifier: iosSimID,
            localDevVPNInstalled: true,
            readyAfterLaunch: false,
            observedState: .running
        )
        do {
            _ = try await LocalDevVPNSetupCoordinator(
                service: service, initialProbeAttempts: 1, readinessAttempts: 1,
                delayNanoseconds: 0, traceRecorder: trace
            ).prepare(
                device: try IOSSimDeviceIdentity(udid: "PHONE-SECRET-0001"),
                iosSimBundleIdentifier: iosSimID,
                teamIdentifier: "TEAM-SECRET",
                releaseIdentity: "RELEASE-SECRET"
            )
            XCTFail("Expected endpoint failure")
        } catch let failure as LocalDevVPNSetupFailure {
            XCTAssertEqual(failure, .endpointUnavailable)
        }

        let records = await trace.values
        XCTAssertTrue(records.contains { $0.event == "vpn.requestWritten" })
        XCTAssertTrue(records.contains { $0.event == "vpn.veyaLaunchSucceeded" })
        XCTAssertTrue(records.contains { $0.event == "vpn.receiptObserved" })
        XCTAssertTrue(records.contains { $0.event == "vpn.receiptState" && $0.value == "RUNNING" })
        XCTAssertTrue(records.contains { $0.event == "vpn.interfaceVisible" && $0.value == "false" })
        XCTAssertTrue(records.contains { $0.event == "vpn.endpointReachable" && $0.value == "false" })
        XCTAssertTrue(records.contains {
            $0.event == "vpn.failed" && $0.value == LocalDevVPNSetupFailure.endpointUnavailable.rawValue
        })
        XCTAssertTrue(records.allSatisfy { $0.bindingHash.count == 64 })
        let encoded = String(data: try JSONEncoder().encode(records), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("PHONE-SECRET-0001"))
        XCTAssertFalse(encoded.contains("TEAM-SECRET"))
        XCTAssertFalse(encoded.contains("RELEASE-SECRET"))
        XCTAssertFalse(encoded.contains(iosSimID))
    }
}

private enum FixtureReceiptMode {
    case normal
    case bindingMismatch
    case malformed
    case missing
}

private actor MemoryLocalDevVPNTraceRecorder: LocalDevVPNTraceRecording {
    private(set) var values: [LocalDevVPNTraceRecord] = []
    func record(_ value: LocalDevVPNTraceRecord) { values.append(value) }
}

private actor LocalDevVPNFixtureService: NativeApplicationServicing {
    private let iosSimBundleIdentifier: String
    private let localDevVPNInstalled: Bool
    private let readyAfterLaunch: Bool
    private let localDevVPNVersion: String
    private let observedState: LocalDevVPNLifecycleState?
    private let receiptMode: FixtureReceiptMode
    private let failVeyaLaunch: Bool
    private let veyaLaunchError: NativeDeviceBridgeError?
    private var request: LocalDevVPNSetupRequestPayload?
    private var launches: [String] = []

    init(iosSimBundleIdentifier: String, localDevVPNInstalled: Bool, readyAfterLaunch: Bool,
         localDevVPNVersion: String = "1.3.0", observedState: LocalDevVPNLifecycleState? = nil,
         receiptMode: FixtureReceiptMode = .normal, failVeyaLaunch: Bool = false,
         veyaLaunchError: NativeDeviceBridgeError? = nil) {
        self.iosSimBundleIdentifier = iosSimBundleIdentifier
        self.localDevVPNInstalled = localDevVPNInstalled
        self.readyAfterLaunch = readyAfterLaunch
        self.localDevVPNVersion = localDevVPNVersion
        self.observedState = observedState
        self.receiptMode = receiptMode
        self.failVeyaLaunch = failVeyaLaunch
        self.veyaLaunchError = veyaLaunchError
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
        if bundleIdentifier == iosSimBundleIdentifier, let veyaLaunchError { throw veyaLaunchError }
        if failVeyaLaunch, bundleIdentifier == iosSimBundleIdentifier {
            throw NativeDeviceBridgeError.deviceDisconnected
        }
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
        switch receiptMode {
        case .missing:
            throw NativeDeviceBridgeError.containerFileNotFound("fixture receipt missing")
        case .malformed:
            return Data("{malformed".utf8)
        case .normal, .bindingMismatch:
            break
        }
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
            deviceUDID: receiptMode == .bindingMismatch ? "OTHER-PHONE" : request.deviceUDID,
            teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity
        )
        return try JSONEncoder().encode(receipt)
    }

    func launchedBundleIdentifiers() -> [String] { launches }
}
