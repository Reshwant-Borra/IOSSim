import Foundation
@testable import IOSSimMacCore
import XCTest

// The test target inherits no build flags; the qualification symbols it exercises are compiled
// into IOSSimMacCore for debug builds, which is how the tests here and in
// DevelopmentInstallationPresentationTests reach them.
/// Scripted device for the pre-install Developer Mode gate. Nothing here installs, pairs, mounts
/// or launches anything: the gate is only allowed to reveal and to observe.
private actor FakeDeveloperModeGateServices: DeveloperModeGateServicing {
    var revealError: Error?
    var rebindError: Error?
    var inspection: NativeDeviceInspection
    var mounted = false
    var servicesReady = false
    private(set) var revealCount = 0
    private(set) var rebindCount = 0
    private(set) var revealedDevices: [String] = []

    init(inspection: NativeDeviceInspection) {
        self.inspection = inspection
    }

    func set(inspection: NativeDeviceInspection) { self.inspection = inspection }
    func set(revealError: Error?) { self.revealError = revealError }
    func set(rebindError: Error?) { self.rebindError = rebindError }
    func set(mounted: Bool) { self.mounted = mounted }
    func set(servicesReady: Bool) { self.servicesReady = servicesReady }

    func revealDeveloperMode(on device: IOSSimDeviceIdentity) async throws {
        revealCount += 1
        revealedDevices.append(device.udid)
        if let revealError { throw revealError }
    }

    func rebind(stableUDID: String) async throws -> NativeDeviceInspection {
        rebindCount += 1
        if let rebindError { throw rebindError }
        guard stableUDID == inspection.identity.udid else {
            throw NativeDeviceBridgeError.deviceNotFound
        }
        return inspection
    }

    func personalizedImageMounted(on device: IOSSimDeviceIdentity) async -> Bool { mounted }
    func developerServicesTransportReady(on device: IOSSimDeviceIdentity) async -> Bool { servicesReady }
}

final class DeveloperModeGateTests: XCTestCase {
    private func inspection(
        udid: String = "PHONE-0001",
        developerMode: DeveloperModeReadiness = .disabled,
        generation: UInt64 = 1,
        mux: UInt32 = 11
    ) throws -> NativeDeviceInspection {
        NativeDeviceInspection(
            identity: try IOSSimDeviceIdentity(
                udid: udid, usbmuxIdentifier: mux, connection: .usb, connectionGeneration: generation
            ),
            connection: .usb,
            name: "Test iPhone",
            osVersion: "26.6.2",
            osBuild: "23G93",
            trust: .trusted,
            lockState: .unlocked,
            developerMode: developerMode
        )
    }

    // MARK: - Evidence

    func testOnlyDeviceSideEvidenceSatisfiesTheGate() {
        XCTAssertNil(DeveloperModeGate.evidence(
            developerMode: .disabled, personalizedImageMounted: false, developerServicesTransportReady: false
        ))
        for readiness: DeveloperModeReadiness in [.disabled, .unknown, .serviceUnavailable, .requiresUserAction, .requiresReboot] {
            XCTAssertNil(DeveloperModeGate.evidence(
                developerMode: readiness, personalizedImageMounted: false, developerServicesTransportReady: false
            ), readiness.rawValue)
        }
        XCTAssertEqual(DeveloperModeGate.evidence(
            developerMode: .enabled, personalizedImageMounted: false, developerServicesTransportReady: false
        ), .amfiStatusEnabled)
        // AMFI is advisory and has been observed reporting `disabled` on a working iOS 26.6.2
        // device, so a mounted image or a live developer-services session also proves it.
        XCTAssertEqual(DeveloperModeGate.evidence(
            developerMode: .disabled, personalizedImageMounted: true, developerServicesTransportReady: false
        ), .personalizedImageMounted)
        XCTAssertEqual(DeveloperModeGate.evidence(
            developerMode: .disabled, personalizedImageMounted: false, developerServicesTransportReady: true
        ), .developerServicesReady)
    }

    // MARK: - Fresh phone

    func testFreshPhoneWithDeveloperModeHiddenStartsAtRevealAndBlocksTheEngine() async throws {
        let services = FakeDeveloperModeGateServices(inspection: try inspection())
        let gate = DeveloperModeGateCoordinator(services: services)

        let initial = await gate.adopt(inspection: try inspection())
        XCTAssertEqual(initial.phase, .reveal)
        XCTAssertFalse(initial.allowsEnginePipeline)
        XCTAssertEqual(DevelopmentInstallationStage.revealDeveloperMode.title, "Enable Developer Mode")
        XCTAssertTrue(DevelopmentInstallationStage.revealDeveloperMode.isDeveloperModeGate)
        let revealCount = await services.revealCount
        XCTAssertEqual(revealCount, 0, "evaluating the gate must not touch the device")
    }

    func testRevealSucceedsThenInstructsTheUserAndWaitsForContinue() async throws {
        let device = try inspection()
        let services = FakeDeveloperModeGateServices(inspection: device)
        let gate = DeveloperModeGateCoordinator(services: services)

        let progress = await gate.reveal(on: device.identity)
        XCTAssertEqual(progress.phase, .enable)
        XCTAssertFalse(progress.allowsEnginePipeline)
        XCTAssertTrue(progress.detail.contains("Settings > Privacy & Security > Developer Mode"))
        XCTAssertTrue(progress.detail.contains("restart prompt"))
        XCTAssertTrue(progress.detail.contains("Continue"))
        XCTAssertTrue(DevelopmentInstallationStage.enableDeveloperMode.isDeveloperModeGate)

        let revealed = await services.revealedDevices
        XCTAssertEqual(revealed, [device.identity.udid], "reveal targets only the selected iPhone")
        let rebindCount = await services.rebindCount
        XCTAssertEqual(rebindCount, 0, "reveal must not start verification, installation or pairing")
    }

    func testRevealFailureDoesNotAdvanceTheGate() async throws {
        let device = try inspection()
        let services = FakeDeveloperModeGateServices(inspection: device)
        await services.set(revealError: NativeDeviceBridgeError.deviceLocked)
        let gate = DeveloperModeGateCoordinator(services: services)

        let progress = await gate.reveal(on: device.identity)
        XCTAssertEqual(progress.phase, .reveal, "a failed reveal must not tell the user to look for a toggle")
        XCTAssertFalse(progress.allowsEnginePipeline)
        XCTAssertTrue(progress.detail.contains("locked"))
    }

    // MARK: - Continue is not proof

    func testContinueWithoutEnablingDeveloperModeRemainsGated() async throws {
        let device = try inspection(developerMode: .disabled)
        let services = FakeDeveloperModeGateServices(inspection: device)
        let gate = DeveloperModeGateCoordinator(services: services)
        _ = await gate.reveal(on: device.identity)

        for _ in 0..<3 {
            let progress = await gate.verify(stableUDID: device.identity.udid)
            XCTAssertEqual(progress.phase, .enable)
            XCTAssertNil(progress.evidence)
            XCTAssertFalse(progress.allowsEnginePipeline, "pressing Continue is never proof")
            XCTAssertTrue(progress.detail.contains("still reports Developer Mode as unavailable"))
        }
    }

    func testContinueThatCannotReachTheSameIPhoneStaysGated() async throws {
        let device = try inspection()
        let services = FakeDeveloperModeGateServices(inspection: device)
        let gate = DeveloperModeGateCoordinator(services: services)
        _ = await gate.reveal(on: device.identity)
        await services.set(rebindError: NativeDeviceBridgeError.deviceNotFound)

        let progress = await gate.verify(stableUDID: device.identity.udid)
        XCTAssertEqual(progress.phase, .enable)
        XCTAssertFalse(progress.allowsEnginePipeline)
        XCTAssertTrue(progress.detail.contains("not connected"))
    }

    // MARK: - Restart and rebinding

    func testRestartChangesTheConnectionGenerationAndTheGateRebindsByStableUDID() async throws {
        let before = try inspection(developerMode: .disabled, generation: 1, mux: 11)
        let services = FakeDeveloperModeGateServices(inspection: before)
        let gate = DeveloperModeGateCoordinator(services: services)
        _ = await gate.reveal(on: before.identity)

        // Enabling Developer Mode reboots the iPhone: the mux identity and connection
        // generation change, the stable UDID does not.
        let after = try inspection(developerMode: .enabled, generation: 2, mux: 27)
        await services.set(inspection: after)

        let progress = await gate.verify(stableUDID: before.identity.udid)
        XCTAssertEqual(progress.phase, .verified)
        XCTAssertEqual(progress.evidence, .amfiStatusEnabled)
        XCTAssertEqual(progress.device?.udid, before.identity.udid)
        XCTAssertEqual(progress.device?.connectionGeneration, 2)
        XCTAssertEqual(progress.device?.usbmuxIdentifier, 27)
    }

    func testAnotherAttachedIPhoneIsNeverASubstitute() async throws {
        let other = try inspection(udid: "PHONE-0002", developerMode: .enabled)
        let services = FakeDeveloperModeGateServices(inspection: other)
        let gate = DeveloperModeGateCoordinator(services: services)
        _ = await gate.reveal(on: try inspection().identity)

        let progress = await gate.verify(stableUDID: "PHONE-0001")
        XCTAssertNotEqual(progress.phase, .verified)
        XCTAssertFalse(progress.allowsEnginePipeline)
    }

    func testRebindingDescriptorSelectsOnlyTheSameStableUDID() throws {
        let wanted = NativeDeviceDescriptor(
            identity: try IOSSimDeviceIdentity(udid: "PHONE-0001", usbmuxIdentifier: 27, connection: .usb,
                                               connectionGeneration: 2),
            connection: .usb
        )
        let other = NativeDeviceDescriptor(
            identity: try IOSSimDeviceIdentity(udid: "PHONE-0002", usbmuxIdentifier: 28, connection: .usb,
                                               connectionGeneration: 2),
            connection: .usb
        )
        XCTAssertEqual(
            DevelopmentDeviceRebinding.descriptor(forStableUDID: "PHONE-0001", in: [other, wanted])?.identity,
            wanted.identity
        )
        XCTAssertNil(DevelopmentDeviceRebinding.descriptor(forStableUDID: "PHONE-0003", in: [other, wanted]))
    }

    // MARK: - Verified

    func testVerifiedDeveloperModeReleasesTheButtonToInstallOrPrepare() async throws {
        let device = try inspection(developerMode: .enabled)
        let services = FakeDeveloperModeGateServices(inspection: device)
        let gate = DeveloperModeGateCoordinator(services: services)
        _ = await gate.reveal(on: device.identity)

        let progress = await gate.verify(stableUDID: device.identity.udid)
        XCTAssertEqual(progress.phase, .verified)
        XCTAssertTrue(progress.allowsEnginePipeline)
        XCTAssertEqual(DevelopmentInstallationPrimaryAction.resolve(firstFailureCode: nil, userAction: nil),
                       .installOrPrepare)
        XCTAssertEqual(DevelopmentInstallationPrimaryAction.installOrPrepare.rawValue, "Install / Prepare")
        XCTAssertEqual(DevelopmentInstallationPrimaryAction.installOrPrepare.command, .reconcile)
    }

    func testAdvisoryAmfiFalseNegativeIsRescuedByDeviceSideEvidence() async throws {
        // Physically observed on iOS 26.6.2: AMFI reports `disabled` while developer services work.
        let device = try inspection(developerMode: .disabled)
        let services = FakeDeveloperModeGateServices(inspection: device)
        await services.set(servicesReady: true)
        let gate = DeveloperModeGateCoordinator(services: services)
        _ = await gate.reveal(on: device.identity)

        let progress = await gate.verify(stableUDID: device.identity.udid)
        XCTAssertEqual(progress.phase, .verified)
        XCTAssertEqual(progress.evidence, .developerServicesReady)
    }

    // MARK: - Already-ready phone

    func testAlreadyReadyPhoneIsNotInterrupted() async throws {
        let ready = try inspection(developerMode: .enabled)
        let services = FakeDeveloperModeGateServices(inspection: ready)
        let gate = DeveloperModeGateCoordinator(services: services)

        let progress = await gate.adopt(inspection: ready)
        XCTAssertEqual(progress.phase, .verified)
        XCTAssertEqual(progress.evidence, .amfiStatusEnabled)
        XCTAssertTrue(progress.allowsEnginePipeline)
        let revealCount = await services.revealCount
        let rebindCount = await services.rebindCount
        XCTAssertEqual(revealCount, 0)
        XCTAssertEqual(rebindCount, 0, "an established setup path must not be re-verified on selection")
    }

    func testAdoptNeverLowersAGateThatDeviceEvidenceAlreadyRaised() async throws {
        let device = try inspection(developerMode: .disabled)
        let services = FakeDeveloperModeGateServices(inspection: device)
        await services.set(mounted: true)
        let gate = DeveloperModeGateCoordinator(services: services)
        _ = await gate.reveal(on: device.identity)
        let verified = await gate.verify(stableUDID: device.identity.udid)
        XCTAssertEqual(verified.evidence, .personalizedImageMounted)

        // A later refresh reads AMFI's advisory `disabled` again; it must not un-verify the phone.
        let progress = await gate.adopt(inspection: device)
        XCTAssertEqual(progress.phase, .verified)
        XCTAssertTrue(progress.allowsEnginePipeline)
    }

    func testRelaunchWithDeveloperModeAlreadyOnAdoptsTheLiveAnswer() async throws {
        // Veya relaunch: a fresh coordinator, no journal memory, the phone restarted (new
        // connection generation, no mounted image). Only the live inspection may decide.
        let restarted = try inspection(developerMode: .enabled, generation: 7, mux: 42)
        let services = FakeDeveloperModeGateServices(inspection: restarted)
        let gate = DeveloperModeGateCoordinator(services: services)

        let progress = await gate.adopt(inspection: restarted)
        XCTAssertEqual(progress.phase, .verified)
        XCTAssertTrue(progress.allowsEnginePipeline)
        XCTAssertEqual(progress.device, restarted.identity)
        let revealCount = await services.revealCount
        XCTAssertEqual(revealCount, 0, "an enabled phone is never asked to reveal the toggle")
    }

    func testAnUnansweredStatusIsNeverPresentedAsDeveloperModeOff() async throws {
        for readiness: DeveloperModeReadiness in [.unknown, .serviceUnavailable] {
            let device = try inspection(developerMode: readiness)
            let services = FakeDeveloperModeGateServices(inspection: device)
            let gate = DeveloperModeGateCoordinator(services: services)

            let adopted = await gate.adopt(inspection: device)
            XCTAssertEqual(adopted.phase, .undetermined, readiness.rawValue)
            XCTAssertFalse(adopted.allowsEnginePipeline, "fail closed: no answer is not permission to install")
            XCTAssertFalse(adopted.detail.localizedCaseInsensitiveContains("unavailable"))

            // Continue re-checks the device; still no answer and no other evidence keeps it closed
            // without claiming the toggle is off.
            let checked = await gate.verify(stableUDID: device.identity.udid)
            XCTAssertEqual(checked.phase, .undetermined, readiness.rawValue)
            XCTAssertFalse(checked.allowsEnginePipeline)
            XCTAssertFalse(checked.detail.contains("still reports Developer Mode as unavailable"))

            // The next answer that arrives decides.
            await services.set(inspection: try inspection(developerMode: .enabled))
            let verified = await gate.verify(stableUDID: device.identity.udid)
            XCTAssertEqual(verified.phase, .verified, readiness.rawValue)
        }
        XCTAssertEqual(DevelopmentInstallationStage.checkDeveloperMode.title, "Checking Developer Mode")
        XCTAssertTrue(DevelopmentInstallationStage.checkDeveloperMode.isDeveloperModeGate)
        XCTAssertFalse(DevelopmentInstallationStage.checkDeveloperMode.instruction.contains("turn it on"))
    }

    func testAnUndeterminedGateMovesToRevealOnlyWhenThePhoneSaysOff() async throws {
        let unknown = try inspection(developerMode: .unknown)
        let services = FakeDeveloperModeGateServices(inspection: unknown)
        let gate = DeveloperModeGateCoordinator(services: services)
        _ = await gate.adopt(inspection: unknown)

        let off = await gate.adopt(inspection: try inspection(developerMode: .disabled))
        XCTAssertEqual(off.phase, .reveal, "an authoritative off returns to the normal enable flow")
        let revealed = await gate.reveal(on: unknown.identity)
        XCTAssertEqual(revealed.phase, .enable)

        // Mid-flow (after the user enabled it and the phone restarted), an unanswered read keeps
        // the user's place rather than sending them back to reveal.
        let midFlow = await gate.adopt(inspection: unknown)
        XCTAssertEqual(midFlow.phase, .enable)
        let checked = await gate.verify(stableUDID: unknown.identity.udid)
        XCTAssertEqual(checked.phase, .enable)
        XCTAssertFalse(checked.allowsEnginePipeline)
    }

    func testSelectingADifferentIPhoneResetsTheGate() async throws {
        let device = try inspection(developerMode: .enabled)
        let services = FakeDeveloperModeGateServices(inspection: device)
        let gate = DeveloperModeGateCoordinator(services: services)
        let adopted = await gate.adopt(inspection: device)
        XCTAssertTrue(adopted.allowsEnginePipeline)

        let reset = await gate.reset()
        XCTAssertEqual(reset.phase, .reveal)
        XCTAssertFalse(reset.allowsEnginePipeline)
    }

    // MARK: - Recovery after verification

    func testDeveloperModeBecomingUnavailableReEntersThePrerequisiteInsteadOfAGenericFailure() async throws {
        let device = try inspection(developerMode: .enabled)
        let services = FakeDeveloperModeGateServices(inspection: device)
        let gate = DeveloperModeGateCoordinator(services: services)
        let adopted = await gate.adopt(inspection: device)
        XCTAssertTrue(adopted.allowsEnginePipeline)

        let recovered = await gate.invalidate(detail: DeviceFailureMapping.developerMode)
        XCTAssertEqual(recovered.phase, .enable)
        XCTAssertFalse(recovered.allowsEnginePipeline, "validation is re-entered, never weakened")
        XCTAssertEqual(recovered.device?.udid, device.identity.udid)
    }

    func testDeveloperModeOffIsNoLongerReportedAsAGenericObservationFailure() {
        // The CoreDevice/RSD chain fails transport-shaped when Developer Mode is off; iOS only
        // returns its authoritative string on the install/launch/mount paths.
        let transportShaped: [Error] = [
            NativeDeviceBridgeError.coreDeviceProxyFailed("coredevice_proxy: connection refused"),
            NativeDeviceBridgeError.softwareTunnelFailed("software_tunnel: failed"),
            NativeDeviceBridgeError.rsdUnavailable("rsd_handshake: failed"),
            NativeDeviceBridgeError.remoteXPCFailed("remotexpc_handshake: failed"),
            NativeDeviceBridgeError.protocolFailure("unexpected response"),
        ]
        for error in transportShaped {
            XCTAssertEqual(
                DeviceFailureMapping.map(error).failure,
                DeviceDomainFailure.observationFailed,
                "precondition: this is the VEYA-DEVICE-030 path"
            )
            let recovered = DeviceFailureMapping.developerModeRecovery(from: error, developerMode: .disabled)
            XCTAssertEqual(recovered as? NativeDeviceBridgeError, .developerModeRequired)
            let mapped = DeviceFailureMapping.map(recovered)
            XCTAssertEqual(mapped.state, .waitingForUser)
            XCTAssertEqual(mapped.userAction, DeviceFailureMapping.developerMode)
            XCTAssertNil(mapped.failure)
        }
    }

    func testDeveloperModeRecoveryNeverRelabelsTypedFailuresOrHealthyDevices() {
        // A device that does not report Developer Mode off keeps the original failure.
        for readiness: DeveloperModeReadiness in [.enabled, .unknown, .serviceUnavailable] {
            let error = NativeDeviceBridgeError.coreDeviceProxyFailed("connection refused")
            XCTAssertEqual(
                DeviceFailureMapping.developerModeRecovery(from: error, developerMode: readiness) as? NativeDeviceBridgeError,
                error,
                readiness.rawValue
            )
        }
        // A lost, locked, untrusted or slow device, a missing image, and Veya's own defects keep
        // their accurate meaning even while the device reports Developer Mode off.
        let untouched: [NativeDeviceBridgeError] = [
            .deviceLocked, .trustRequired, .trustPromptPending, .trustDenied, .ddiRequired("ddi"),
            .deviceDisconnected, .deviceNotFound, .timedOut, .deviceResolutionFailed("gone"),
            .applicationNotFound("app"), .launchRejected("untrusted"), .containerUnavailable("c"),
            .internalFailure("bridge defect"), .decodingFailure("bad payload"),
            .incompatibleABI, .libraryUnavailable, .cancelled,
        ]
        for error in untouched {
            XCTAssertEqual(
                DeviceFailureMapping.developerModeRecovery(from: error, developerMode: .disabled) as? NativeDeviceBridgeError,
                error,
                String(describing: error)
            )
        }
        // A non-bridge error is never re-read as a device prerequisite.
        XCTAssertEqual(
            DeviceFailureMapping.developerModeRecovery(
                from: DeveloperSupportFailure.noApprovedSource, developerMode: .disabled
            ) as? DeveloperSupportFailure,
            .noApprovedSource
        )
    }

    // MARK: - Fail closed on an old native bridge

    func testTheGateRefusesAnOutdatedNativeBridge() async throws {
        XCTAssertEqual(DynamicNativeDeviceTransport.requiredABIVersion, 3,
                       "ABI 3 is the first bridge exporting iossim_bridge_reveal_developer_mode")

        let device = try inspection()
        let services = FakeDeveloperModeGateServices(inspection: device)
        await services.set(revealError: NativeDeviceBridgeError.incompatibleABI)
        let gate = DeveloperModeGateCoordinator(services: services)

        let progress = await gate.reveal(on: device.identity)
        XCTAssertEqual(progress.phase, .reveal)
        XCTAssertFalse(progress.allowsEnginePipeline)
        XCTAssertTrue(progress.detail.contains("device bridge is too old"))
    }

    func testAnAbsentNativeBridgeCannotRevealDeveloperMode() throws {
        let transport = DynamicNativeDeviceTransport(
            environment: ["IOSSIM_DEVICE_BRIDGE_PATH": "/nonexistent/libiossim_device_bridge.dylib"],
            bundle: Bundle(for: DeveloperModeGateTests.self)
        )
        XCTAssertNotNil(transport.loadError)
        XCTAssertThrowsError(try transport.revealDeveloperMode(on: try inspection().identity))
    }

    // MARK: - Developer trust stays post-install and conditional

    func testDeveloperTrustIsNotPartOfThePreInstallGate() {
        XCTAssertFalse(DevelopmentInstallationStage.trustDeveloper.isDeveloperModeGate)
        for stage in DevelopmentInstallationStage.allCases where stage.isDeveloperModeGate {
            XCTAssertFalse(stage.instruction.localizedCaseInsensitiveContains("VPN & Device Management"),
                           stage.rawValue)
            XCTAssertFalse(stage.instruction.localizedCaseInsensitiveContains("Trust"), stage.rawValue)
        }
        // Developer trust is only ever reached from the engine's own user action, which iOS
        // raises after the app is installed. It is never requested pre-emptively.
        XCTAssertEqual(
            DevelopmentInstallationStage.resolve(
                firstFailureCode: nil, failureDomain: nil,
                userAction: DeviceFailureMapping.developerTrust,
                status: "userActionRequired", issuedRunSetupRequest: false
            ),
            .trustDeveloper
        )
        XCTAssertNotEqual(
            DevelopmentInstallationStage.resolve(
                firstFailureCode: nil, failureDomain: nil, userAction: nil,
                status: "transitionRequired", issuedRunSetupRequest: false
            ),
            .trustDeveloper
        )
        XCTAssertTrue(DevelopmentInstallationStage.trustDeveloper.instruction
            .contains("VPN & Device Management"))
        XCTAssertEqual(DevelopmentInstallationStage.trustDeveloper.primaryAction, .continueUserAction)
    }
}
