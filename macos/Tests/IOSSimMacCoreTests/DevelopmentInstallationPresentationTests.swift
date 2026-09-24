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

    func testFirstRunRequirementsMapToExplicitStagesAndContinueReconcile() {
        let developerMode = DevelopmentInstallationStage.resolve(
            firstFailureCode: nil,
            failureDomain: .developerSupport,
            userAction: DeviceFailureMapping.developerMode,
            status: "userActionRequired",
            issuedRunSetupRequest: false
        )
        XCTAssertEqual(developerMode, .enableDeveloperMode)
        XCTAssertEqual(developerMode.title, "Enable Developer Mode")

        let developerTrust = DevelopmentInstallationStage.resolve(
            firstFailureCode: nil,
            failureDomain: .developerSupport,
            userAction: DeviceFailureMapping.developerTrust,
            status: "userActionRequired",
            issuedRunSetupRequest: false
        )
        XCTAssertEqual(developerTrust, .trustDeveloper)
        XCTAssertEqual(developerTrust.title, "Trust Developer")

        for failure in [
            DeviceDomainFailure.vpnMissing,
            DeviceDomainFailure.vpnPermissionRequired,
            DeviceDomainFailure.vpnNotRunning,
            DeviceDomainFailure.vpnEndpointUnavailable,
        ] {
            let stage = DevelopmentInstallationStage.resolve(
                firstFailureCode: failure.code,
                failureDomain: .vpn,
                userAction: failure.userAction,
                status: "userActionRequired",
                issuedRunSetupRequest: false
            )
            XCTAssertEqual(stage, .connectLocalDevVPN)
            XCTAssertEqual(stage.primaryAction.command, .reconcile)
        }

        XCTAssertTrue(developerMode.instruction.contains("Settings > Privacy & Security > Developer Mode"))
        XCTAssertTrue(developerMode.instruction.contains("restart prompt"))
        XCTAssertTrue(developerTrust.instruction.contains("VPN & Device Management"))
        XCTAssertEqual(developerMode.primaryAction.command, .reconcile)
        XCTAssertEqual(developerTrust.primaryAction.command, .reconcile)
    }

    func testReadyForSetupRequiresBoundRequestProgress() {
        let code = RuntimeReadinessDomain.runSetupRequired.code
        XCTAssertNotEqual(
            DevelopmentInstallationStage.resolve(
                firstFailureCode: code,
                failureDomain: .runtime,
                userAction: "Tap Run Setup",
                status: "userActionRequired",
                issuedRunSetupRequest: false
            ),
            .readyForSetup
        )
        XCTAssertEqual(
            DevelopmentInstallationStage.resolve(
                firstFailureCode: code,
                failureDomain: .runtime,
                userAction: "Tap Run Setup",
                status: "userActionRequired",
                issuedRunSetupRequest: true
            ),
            .readyForSetup
        )
        XCTAssertEqual(DevelopmentInstallationStage.transition(.pairing), .preparingPairing)
        XCTAssertEqual(
            DevelopmentInstallationStage.resolve(
                firstFailureCode: nil,
                failureDomain: nil,
                userAction: nil,
                status: ReconciliationOutcomeStatus.ready.rawValue,
                issuedRunSetupRequest: false
            ),
            .ready
        )
    }

    func testDeveloperModeRestartRebindSelectsOnlyTheSameStableUDID() throws {
        let old = try NativeDeviceDescriptor(
            identity: IOSSimDeviceIdentity(
                udid: "PHONE-0001", usbmuxIdentifier: 1,
                connection: .usb, connectionGeneration: 1
            ),
            connection: .usb
        )
        let rebound = try NativeDeviceDescriptor(
            identity: IOSSimDeviceIdentity(
                udid: "PHONE-0001", usbmuxIdentifier: 9,
                connection: .usb, connectionGeneration: 2
            ),
            connection: .usb
        )
        let other = try NativeDeviceDescriptor(
            identity: IOSSimDeviceIdentity(
                udid: "PHONE-0002", usbmuxIdentifier: 4,
                connection: .usb, connectionGeneration: 2
            ),
            connection: .usb
        )

        let selected = try XCTUnwrap(DevelopmentDeviceRebinding.descriptor(
            forStableUDID: old.identity.udid,
            in: [other, rebound]
        ))
        XCTAssertEqual(selected.identity.udid, old.identity.udid)
        XCTAssertEqual(selected.identity.connectionGeneration, 2)
        XCTAssertEqual(selected.identity.usbmuxIdentifier, 9)
        XCTAssertNil(DevelopmentDeviceRebinding.descriptor(
            forStableUDID: old.identity.udid,
            in: [other]
        ), "another attached iPhone is never selected")
        XCTAssertNil(DevelopmentDeviceRebinding.descriptor(
            forStableUDID: old.identity.udid,
            in: []
        ), "a temporarily absent phone remains a user action")
    }

    func testRuntimeTransitionDoesNotResetVerificationPresentation() {
        XCTAssertEqual(
            DevelopmentInstallationStage.transition(.runtime, current: .verifyingSetup),
            .verifyingSetup
        )
        XCTAssertEqual(
            DevelopmentInstallationStage.transition(.pairing, current: .preparingApp),
            .preparingPairing
        )
    }

    func testEveryStagedPrimaryActionStillInvokesReconcile() {
        for stage in DevelopmentInstallationStage.allCases {
            XCTAssertEqual(stage.primaryAction.command, .reconcile, stage.title)
        }
    }

    func testFailureContextRetainsTypedVPNFailureSeparateFromObservation() throws {
        let failure = DeviceDomainFailure.vpnEndpointUnavailable
        let result = EngineHost.failureResult(
            EngineRequest(command: .reconcile),
            error: failure,
            identity: EngineIdentity(packaged: false, qualificationBuild: true)
        )
        let context = try XCTUnwrap(DevelopmentInstallationFailureContext(result: result))
        XCTAssertEqual(context.domain, .vpn)
        XCTAssertEqual(context.code, failure.code)
        XCTAssertEqual(context.safeMessage, failure.safeMessage)
        XCTAssertEqual(context.userAction, failure.userAction)
        XCTAssertNotEqual(context.code, DeviceDomainFailure.observationFailed.code)
    }
}
