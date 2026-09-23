import Foundation
@testable import IOSSimMacCore
import XCTest

final class DevelopmentInstallationPresentationTests: XCTestCase {
    func testInitialStateUsesInstallOrPrepare() {
        let presentation = DevelopmentInstallationPrimaryAction.resolve(firstFailureCode: nil, userAction: nil)
        XCTAssertEqual(presentation, .installOrPrepare)
        XCTAssertEqual(presentation.rawValue, "Install / Prepare")
    }

    func testCanonicalRecoverableActionsUseContinueAndNormalizedInstructions() {
        let actions = [
            DeviceFailureMapping.map(NativeDeviceBridgeError.deviceLocked).userAction,
            DeviceFailureMapping.map(NativeDeviceBridgeError.trustRequired).userAction,
            DeviceFailureMapping.map(NativeDeviceBridgeError.developerModeRequired).userAction,
            DeviceFailureMapping.developerTrust,
            DeviceDomainMapping.localDevVPN(.missing).userAction,
            DeviceDomainMapping.localDevVPN(.vpnPermissionRequired).userAction,
            DeviceFailureMapping.map(LocalDevVPNSetupFailure.vpnNotRunning).userAction,
            AppleDomainFailure.signInAction,
            AppleDomainFailure.selectDeviceAction,
        ]

        for action in actions {
            let action = try! XCTUnwrap(action)
            XCTAssertTrue(action.hasSuffix("then continue in Veya."), action)
            let presentation = DevelopmentInstallationPrimaryAction.resolve(firstFailureCode: nil, userAction: action)
            XCTAssertEqual(presentation, .continueUserAction, action)
            XCTAssertEqual(presentation.rawValue, "Continue", action)
        }
    }

    func testRunSetupContinuationTakesPrecedenceOverRecoverableAction() {
        let runSetupFailed = RuntimeReadinessDomain.runSetupFailed(code: "PHONE", message: "Try again")
        for code in [
            RuntimeReadinessDomain.runtimeActionRequired.code,
            RuntimeReadinessDomain.runSetupRequired.code,
            runSetupFailed.code,
        ] {
            let presentation = DevelopmentInstallationPrimaryAction.resolve(
                firstFailureCode: code,
                userAction: "Continue on iPhone"
            )
            XCTAssertEqual(presentation, .continueOrVerifySetup)
            XCTAssertEqual(presentation.rawValue, "Continue / Verify Setup")
        }
    }

    func testFailureWithoutUserActionDoesNotUseContinue() {
        for code in [DeviceDomainFailure.observationFailed.code, DeviceDomainFailure.ddiIncompatible.code] {
            let presentation = DevelopmentInstallationPrimaryAction.resolve(firstFailureCode: code, userAction: nil)
            XCTAssertEqual(presentation, .installOrPrepare)
            XCTAssertEqual(presentation.rawValue, "Install / Prepare")
            XCTAssertFalse(presentation.rawValue.hasPrefix("Continue"))
        }
    }

    func testEveryPresentationInvokesReconcile() {
        for presentation in DevelopmentInstallationPrimaryAction.allCases {
            XCTAssertEqual(presentation.command, .reconcile, presentation.rawValue)
        }
    }
}
