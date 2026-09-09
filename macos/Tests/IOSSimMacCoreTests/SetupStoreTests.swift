import XCTest
@testable import IOSSimMacCore

@MainActor
final class SetupStoreTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "IOSSimMac.onboardingCompleted")
        UserDefaults.standard.removeObject(forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.removeObject(forKey: "IOSSimMac.selectedDeviceName")
        UserDefaults.standard.removeObject(forKey: "IOSSimMac.selectedPersonalTeam")
    }

    func testSuccessfulSetupFlowReachesRuntimeSetupWhenManualActionsRemain() async throws {
        let engine = MockIOSSimSetupEngine(scenario: .localDevVPNRequired)
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .runtimeSetup)
        XCTAssertNil(store.lastError)
    }

    func testNoDeviceFlowWaitsForDevice() async throws {
        let engine = MockIOSSimSetupEngine(scenario: .noDevice)
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .waitingForDevice)
        XCTAssertNil(store.selectedDevice)
    }

    func testOneDeviceAutoSelectsLiveDevice() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.selectedDeviceIdentifier, "A")
        XCTAssertEqual(store.selectedDevice?.name, "GOPI's iPhone")
    }

    func testMultipleDevicesWithoutRememberedSelectionRequiresExplicitChoice() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A"), Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertNil(store.selectedDeviceIdentifier)
        XCTAssertTrue(store.deviceSelectionRequired)
    }

    func testMultipleDevicesWithRememberedSelectionUsesRememberedDevice() async throws {
        UserDefaults.standard.set("B", forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.set("Test iPhone", forKey: "IOSSimMac.selectedDeviceName")
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A"), Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.selectedDeviceIdentifier, "B")
        XCTAssertEqual(store.selectedDevice?.name, "Test iPhone")
    }

    func testRememberedDeviceAbsentDoesNotShowStaleDevice() async throws {
        UserDefaults.standard.set("A", forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.set("GOPI's iPhone", forKey: "IOSSimMac.selectedDeviceName")
        let engine = SequenceSetupEngine(status: Self.status(devices: []))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertNil(store.selectedDeviceIdentifier)
        XCTAssertNil(store.selectedDevice)
        XCTAssertEqual(store.disconnectedDeviceName, "GOPI's iPhone")
    }

    func testNewSingleDeviceReplacingOldRememberedDeviceAutoSelectsLivePhone() async throws {
        UserDefaults.standard.set("A", forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.set("GOPI's iPhone", forKey: "IOSSimMac.selectedDeviceName")
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.selectedDeviceIdentifier, "B")
        XCTAssertEqual(store.selectedDevice?.name, "Test iPhone")
    }

    func testChangeDeviceActionPersistsExplicitSelection() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A"), Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.selectDevice(identifier: "B")
        XCTAssertEqual(store.selectedDeviceIdentifier, "B")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "IOSSimMac.selectedDeviceIdentifier"), "B")
    }

    func testOperationBoundToSelectedDevice() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)
        let provisioned = await engine.provisionedDeviceIdentifiers
        XCTAssertEqual(provisioned, ["A"])
    }

    func testAmbiguousOperationRejected() async throws {
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A"), Self.device("B")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.runUpdateComponents()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertTrue(store.lastError?.details.contains("DEVICE_SELECTION_REQUIRED") == true)
        let provisioned = await engine.provisionedDeviceIdentifiers
        XCTAssertTrue(provisioned.isEmpty)
    }

    func testDisconnectMidInstallFailsWithoutSwitchingDevices() async throws {
        let engine = SequenceSetupEngine(
            status: Self.status(devices: [Self.device("A")]),
            failProvisionFor: "A",
            failureText: "IPHONE_DISCONNECTED: reconnect the selected iPhone or choose another device."
        )
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.lastError?.headline, "iPhone Disconnected")
        let provisioned = await engine.provisionedDeviceIdentifiers
        XCTAssertEqual(provisioned, ["A"])
    }

    func testConsumerDisconnectSurfacesWaitingStateInsteadOfAuthenticationFailure() async throws {
        let engine = ConsumerDisconnectEngine()
        let store = SetupStore(engine: engine, nativeProvisioningExperiment: false)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .waitingForDevice)
        XCTAssertEqual(store.consumerStage, .waitingForDevice)
        XCTAssertTrue(store.lastError?.details.contains(ConsumerProvisioningErrorCode.deviceUnavailable.rawValue) == true)
        XCTAssertFalse(store.lastError?.headline.localizedCaseInsensitiveContains("authorization") == true)
    }

    func testReconnectSameDeviceRestoresSelection() async throws {
        UserDefaults.standard.set("A", forKey: "IOSSimMac.selectedDeviceIdentifier")
        UserDefaults.standard.set("GOPI's iPhone", forKey: "IOSSimMac.selectedDeviceName")
        let engine = SequenceSetupEngine(status: Self.status(devices: [Self.device("A")]))
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.selectedDeviceIdentifier, "A")
        XCTAssertEqual(store.selectedDevice?.name, "GOPI's iPhone")
    }

    func testDeveloperModeActionState() async throws {
        let engine = MockIOSSimSetupEngine(scenario: .developerModeRequired)
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .deviceActionRequired)
        let status = try await engine.doctor()
        XCTAssertEqual(StatusInterpreter.deviceReadiness(from: status), .developerModeRequired)
    }

    func testLockedSingleDeviceRequiresUnlockBeforeProvisioning() async throws {
        let locked = DetectedDevice(
            name: "Locked iPhone",
            identifier: "A",
            selectionIdentifier: "A",
            osVersion: "26.6",
            developerModeStatus: "enabled",
            pairingState: "paired",
            tunnelState: "connected",
            isLocked: true
        )
        let lockCheck = DoctorCheck(
            state: .action,
            component: "Device",
            name: "iPhone unlocked",
            detail: "locked",
            action: "Unlock the iPhone and keep it awake.",
            requiredFor: "device"
        )
        let engine = SequenceSetupEngine(status: Self.status(devices: [locked], runtimeActions: [lockCheck]))
        let store = SetupStore(engine: engine)

        store.getStarted()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .deviceActionRequired)
        XCTAssertFalse(store.selectedDeviceProvisioningReady)
    }

    func testInstallFailureFlow() async throws {
        let engine = MockIOSSimSetupEngine(scenario: .installFailure)
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertNotNil(store.lastError)
    }

    func testConsumerFlowRequiresTeamSelectionWhenMultipleTeamsExist() async throws {
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1"), .team("TEAM2")])
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .appleAccount)
        XCTAssertNil(store.selectedTeamIdentifier)
    }

    func testConsumerInstallBindsExplicitDeviceAndTeam() async throws {
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1"), .team("TEAM2")])
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.selectTeam(identifier: "TEAM2")
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .runtimeSetup)
        let requests = await engine.requests
        XCTAssertEqual(requests.map(\.selectedDeviceIdentifier), ["A"])
        XCTAssertEqual(requests.map(\.selectedTeamIdentifier), ["TEAM2"])
        XCTAssertEqual(requests.map(\.operation), [.install])
        XCTAssertEqual(store.provisioningManifest?.teamID, "TEAM2")
    }

    func testConsumerRuntimeConfirmationReachesCompleteAndPersistsReadyState() async throws {
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1")])
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .runtimeSetup)

        store.confirmRuntimeSetup()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .complete)
        XCTAssertEqual(store.provisioningManifest?.runtimeSetupStatus, .ready)
        XCTAssertTrue(store.onboardingCompleted)
    }

    func testCleanConsumerMacRoutesToProvisioningBeforeRuntimeActions() async throws {
        let engine = ConsumerSequenceEngine(
            teams: [.team("TEAM1"), .team("TEAM2")],
            runtimeActionsWithoutManifest: true
        )
        let store = SetupStore(engine: engine)

        store.getStarted()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .appleAccount)
        XCTAssertNotEqual(store.phase, .runtimeSetup)
        XCTAssertNil(store.provisioningManifest)
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCompletedOnboardingWithoutManifestRoutesBackToProvisioning() async throws {
        UserDefaults.standard.set(true, forKey: "IOSSimMac.onboardingCompleted")
        let engine = ConsumerSequenceEngine(
            teams: [.team("TEAM1"), .team("TEAM2")],
            runtimeActionsWithoutManifest: true
        )
        let store = SetupStore(engine: engine)

        store.bootstrap()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .appleAccount)
        XCTAssertNotEqual(store.phase, .complete)
        XCTAssertNotEqual(store.phase, .runtimeSetup)
    }

    func testManifestWithMissingRunnerMappingBlocksRuntimeSetup() async throws {
        let invalidManifest = try Self.consumerManifest(validRunnerMapping: false)
        let engine = ConsumerSequenceEngine(
            teams: [.team("TEAM1")],
            initialManifest: invalidManifest
        )
        let store = SetupStore(engine: engine)

        store.getStarted()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .installing)
        XCTAssertNotEqual(store.phase, .runtimeSetup)

        store.confirmRuntimeSetup()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .failed)
        XCTAssertTrue(store.lastError?.details.contains(ConsumerProvisioningErrorCode.runnerMappingMissing.rawValue) == true)
        let confirmations = await engine.runtimeConfirmationCount
        XCTAssertEqual(confirmations, 0)
    }

    func testValidManifestAndRunnerMappingAllowsRuntimeSetup() async throws {
        let manifest = try Self.consumerManifest(runtimeSetupStatus: .userActionRequired)
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1")], initialManifest: manifest)
        let store = SetupStore(engine: engine)

        store.getStarted()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .runtimeSetup)

        store.confirmRuntimeSetup()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .complete)
        let confirmations = await engine.runtimeConfirmationCount
        XCTAssertEqual(confirmations, 1)
    }

    func testFullyReadyConsumerUserStillRoutesToDashboard() async throws {
        UserDefaults.standard.set(true, forKey: "IOSSimMac.onboardingCompleted")
        let manifest = try Self.consumerManifest(runtimeSetupStatus: .ready)
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1")], initialManifest: manifest)
        let store = SetupStore(engine: engine)

        store.bootstrap()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .complete)
        XCTAssertEqual(store.provisioningManifest?.runtimeSetupStatus, .ready)
    }

    func testConsumerBootstrapResumesPendingRuntimeSetupAfterPriorOnboarding() async throws {
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1")])
        let initialStore = SetupStore(engine: engine)
        initialStore.getStarted()
        try await waitUntilIdle(initialStore)
        initialStore.continueFromCurrentStatus()
        try await waitUntilIdle(initialStore)
        XCTAssertEqual(initialStore.phase, .runtimeSetup)

        UserDefaults.standard.set(true, forKey: "IOSSimMac.onboardingCompleted")
        let resumedStore = SetupStore(engine: engine)
        resumedStore.bootstrap()
        try await waitUntilIdle(resumedStore)

        XCTAssertEqual(resumedStore.phase, .runtimeSetup)
    }

    func testDeveloperProfileTrustCheckpointSurvivesMacAppRelaunch() async throws {
        let pending = try Self.consumerManifest()
            .updatingSetupCheckpoint(.developerProfileTrustRequired, developerProfileTrustStatus: .required)
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1")], initialManifest: pending)
        let first = SetupStore(engine: engine, nativeProvisioningExperiment: false)

        first.getStarted()
        try await waitUntilIdle(first)
        XCTAssertEqual(first.phase, .developerProfileTrust)
        XCTAssertEqual(first.consumerStage, .developerProfileTrustRequired)

        let relaunched = SetupStore(engine: engine, nativeProvisioningExperiment: false)
        relaunched.getStarted()
        try await waitUntilIdle(relaunched)
        XCTAssertEqual(relaunched.phase, .developerProfileTrust)
        XCTAssertEqual(relaunched.provisioningManifest?.developerProfileTrustStatus, .required)
    }

    func testDeveloperProfileTrustContinueResumesWithoutProvisioningAgain() async throws {
        let pending = try Self.consumerManifest()
            .updatingSetupCheckpoint(.developerProfileTrustRequired, developerProfileTrustStatus: .required)
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1")], initialManifest: pending)
        let store = SetupStore(engine: engine, nativeProvisioningExperiment: false)
        store.getStarted()
        try await waitUntilIdle(store)

        store.continueDeveloperProfileTrust()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .runtimeSetup)
        XCTAssertEqual(store.provisioningManifest?.developerProfileTrustStatus, .trusted)
        let resumeCount = await engine.resumeCount
        let requests = await engine.requests
        XCTAssertEqual(resumeCount, 1)
        XCTAssertTrue(requests.isEmpty)
    }

    func testStillUntrustedContinueRemainsOnTrustStep() async throws {
        let pending = try Self.consumerManifest()
            .updatingSetupCheckpoint(.developerProfileTrustRequired, developerProfileTrustStatus: .required)
        let engine = ConsumerSequenceEngine(
            teams: [.team("TEAM1")],
            initialManifest: pending,
            resumeRemainsTrustRequired: true
        )
        let store = SetupStore(engine: engine, nativeProvisioningExperiment: false)
        store.getStarted()
        try await waitUntilIdle(store)

        store.continueDeveloperProfileTrust()
        try await waitUntilIdle(store)

        XCTAssertEqual(store.phase, .developerProfileTrust)
        XCTAssertNil(store.lastError)
        let resumeCount = await engine.resumeCount
        let requests = await engine.requests
        XCTAssertEqual(resumeCount, 1)
        XCTAssertTrue(requests.isEmpty)
    }

    func testOlderTrustVerificationFailureCannotOverwriteNewerSuccess() async throws {
        let pending = try Self.consumerManifest()
            .updatingSetupCheckpoint(.developerProfileTrustRequired, developerProfileTrustStatus: .required)
        let engine = RacingTrustResumeEngine(manifest: pending)
        let store = SetupStore(engine: engine, nativeProvisioningExperiment: false)
        store.getStarted()
        try await waitUntilIdle(store)

        store.continueDeveloperProfileTrust()
        while await engine.resumeCount < 1 { await Task.yield() }
        store.cancelCurrentOperation()
        store.continueDeveloperProfileTrust()
        try await waitUntilIdle(store)
        while !(await engine.firstResumeFinished) { await Task.yield() }

        XCTAssertEqual(store.phase, .runtimeSetup)
        XCTAssertEqual(store.provisioningManifest?.developerProfileTrustStatus, .trusted)
        XCTAssertNil(store.lastError)
    }

    func testConsumerRefreshAndRepairUseTypedOperations() async throws {
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1")])
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)
        store.continueFromCurrentStatus()
        try await waitUntilIdle(store)

        store.runUpdateComponents()
        try await waitUntilIdle(store)
        store.runRepair()
        try await waitUntilIdle(store)

        let requests = await engine.requests
        XCTAssertEqual(requests.map(\.operation), [.install, .refresh, .repair])
        XCTAssertTrue(requests.allSatisfy { !$0.allowFreshInstallAfterCrossTeamConflict })
    }

    func testFreshInstallFlagRequiresExplicitConfirmedAction() async throws {
        let engine = ConsumerSequenceEngine(teams: [.team("TEAM1")])
        let store = SetupStore(engine: engine)
        store.getStarted()
        try await waitUntilIdle(store)

        store.runConfirmedFreshInstall()
        try await waitUntilIdle(store)

        let request = await engine.requests.last
        XCTAssertEqual(request?.operation, .install)
        XCTAssertEqual(request?.allowFreshInstallAfterCrossTeamConflict, true)
    }

    func testCanceledOlderSuccessCannotOverwriteNewerDeviceState() async throws {
        let oldStatus = Self.status(devices: [Self.device("A")])
        let currentStatus = Self.status(devices: [])
        let engine = RacingDoctorEngine(oldResult: .success(oldStatus), currentStatus: currentStatus)
        let store = SetupStore(engine: engine)

        store.getStarted()
        while await engine.callCount < 1 { await Task.yield() }
        store.cancelCurrentOperation()
        store.getStarted()
        try await waitUntilIdle(store)
        while !(await engine.oldCallFinished) { await Task.yield() }

        XCTAssertEqual(store.phase, .waitingForDevice)
        XCTAssertTrue(store.status?.device.devices.isEmpty == true)
        XCTAssertNil(store.lastError)
    }

    func testCanceledOlderFailureCannotOverwriteNewerSuccess() async throws {
        let currentStatus = Self.status(devices: [])
        let engine = RacingDoctorEngine(oldResult: .failure, currentStatus: currentStatus)
        let store = SetupStore(engine: engine)

        store.getStarted()
        while await engine.callCount < 1 { await Task.yield() }
        store.cancelCurrentOperation()
        store.getStarted()
        try await waitUntilIdle(store)
        while !(await engine.oldCallFinished) { await Task.yield() }

        XCTAssertEqual(store.phase, .waitingForDevice)
        XCTAssertNil(store.lastError)
    }

    private func waitUntilIdle(_ store: SetupStore, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isRunning {
            if Date() > deadline {
                XCTFail("Timed out waiting for store operation")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func device(_ selectionIdentifier: String) -> DetectedDevice {
        DetectedDevice(
            name: selectionIdentifier == "A" ? "GOPI's iPhone" : "Test iPhone",
            identifier: RuntimeProvisioning.shortIdentifier(selectionIdentifier),
            selectionIdentifier: selectionIdentifier,
            osVersion: "26.6",
            developerModeStatus: "enabled",
            pairingState: "paired",
            tunnelState: "connected"
        )
    }

    private static func consumerManifest(
        validRunnerMapping: Bool = true,
        runtimeSetupStatus: RuntimeSetupStatus = .userActionRequired
    ) throws -> ConsumerProvisioningManifest {
        let teamIdentifier = "TEAM1"
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: teamIdentifier)
        let mainProfile = ConsumerProfileState(
            artifact: "main",
            teamIdentifier: teamIdentifier,
            bundleIdentifier: identifiers.main,
            creationDate: Date(),
            expirationDate: Date().addingTimeInterval(7 * 24 * 60 * 60),
            remainingValidity: 7 * 24 * 60 * 60,
            selectedDeviceIncluded: true,
            personalTeam: true,
            profileIdentifier: nil,
            profileFingerprint: nil,
            refreshRecommended: false
        )
        let runnerProfile = ConsumerProfileState(
            artifact: "runner",
            teamIdentifier: teamIdentifier,
            bundleIdentifier: identifiers.runner,
            creationDate: mainProfile.creationDate,
            expirationDate: mainProfile.expirationDate,
            remainingValidity: mainProfile.remainingValidity,
            selectedDeviceIncluded: true,
            personalTeam: true,
            profileIdentifier: nil,
            profileFingerprint: nil,
            refreshRecommended: false
        )
        return ConsumerProvisioningManifest(
            deviceIdentifierSafe: "A",
            deviceIdentifierHash: "hash",
            teamID: teamIdentifier,
            sourceMainBundleID: ProtectedSourceBundleIdentifiers.default.main,
            installedMainBundleID: identifiers.main,
            sourceUITestBundleID: ProtectedSourceBundleIdentifiers.default.uiTests,
            installedUITestBundleID: identifiers.uiTests,
            sourceRunnerBundleID: ProtectedSourceBundleIdentifiers.default.runner,
            installedRunnerBundleID: validRunnerMapping ? identifiers.runner : "",
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            lastInstallDate: Date(),
            runtimeSetupStatus: runtimeSetupStatus,
            appVersion: "1",
            provisionerVersion: "1"
        )
    }

    private static func status(devices: [DetectedDevice], runtimeActions: [DoctorCheck] = []) -> DoctorStatus {
        var checks: [DoctorCheck] = [
            .init(state: .pass, component: "Mac", name: "macOS supported", detail: "ready"),
            .init(state: .pass, component: "Apple Tooling", name: "xcrun", detail: "ready")
        ]
        if devices.isEmpty {
            checks.append(.init(
                state: .action,
                component: "Device",
                name: "connected iPhone",
                detail: "not detected",
                action: "Connect and unlock an iPhone.",
                requiredFor: "device"
            ))
        } else {
            for device in devices {
                checks.append(.init(state: .pass, component: "Device", name: "iPhone detected", detail: device.name, requiredFor: "device"))
                checks.append(.init(state: .pass, component: "Device", name: "device trusted", detail: "paired", requiredFor: "device"))
                checks.append(.init(state: .pass, component: "Device", name: "Developer Mode", detail: "enabled", requiredFor: "device"))
            }
        }
        checks.append(contentsOf: runtimeActions)
        return DoctorStatus(
            ready: !devices.isEmpty && runtimeActions.isEmpty,
            mac: MacSummary(ready: true),
            device: DeviceSummary(ready: !devices.isEmpty && runtimeActions.isEmpty, connected: !devices.isEmpty, devices: devices),
            actionsRequired: [],
            checks: checks
        )
    }
}

private actor RacingDoctorEngine: IOSSimSetupEngine {
    enum OldResult: Sendable {
        case success(DoctorStatus)
        case failure
    }

    private let oldResult: OldResult
    private let currentStatus: DoctorStatus
    private(set) var callCount = 0
    private(set) var oldCallFinished = false

    init(oldResult: OldResult, currentStatus: DoctorStatus) {
        self.oldResult = oldResult
        self.currentStatus = currentStatus
    }

    func doctor() async throws -> DoctorStatus {
        callCount += 1
        guard callCount == 1 else { return currentStatus }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                continuation.resume()
            }
        }
        oldCallFinished = true
        switch oldResult {
        case .success(let status): return status
        case .failure:
            throw ProcessFailure(
                commandName: "doctor",
                result: .init(exitCode: 1, stdout: "", stderr: "stale failure")
            )
        }
    }

    func setup() async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func build() async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        .init(exitCode: 0, stdout: "", stderr: "")
    }
}

private actor ConsumerDisconnectEngine: IOSSimSetupEngine {
    nonisolated let consumerProvisioningEnabled = true

    func doctor() async throws -> DoctorStatus {
        let device = DetectedDevice(
            name: "Fixture iPhone",
            identifier: "A",
            selectionIdentifier: "A",
            osVersion: "26.6",
            developerModeStatus: "enabled",
            pairingState: "paired",
            tunnelState: "connected"
        )
        return DoctorStatus(
            ready: false,
            mac: MacSummary(ready: true),
            device: DeviceSummary(ready: true, connected: true, devices: [device]),
            actionsRequired: [],
            checks: []
        )
    }

    func setup() async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func build() async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        .init(exitCode: 0, stdout: "", stderr: "")
    }
    func discoverPersonalTeams(selectedDeviceIdentifier: String?) async throws -> [PersonalTeamCandidate] {
        [.team("TEAM1")]
    }
    func consumerProvision(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        throw ConsumerProvisioningFailure(
            code: .deviceUnavailable,
            stage: .waitingForDevice,
            userMessage: "IOSSim is ready to continue when the selected iPhone reconnects.",
            remediation: "Reconnect the same iPhone and choose Repair.",
            developerDetail: "The selected device disconnected after local preparation."
        )
    }
}

private actor RacingTrustResumeEngine: IOSSimSetupEngine {
    nonisolated let consumerProvisioningEnabled = true
    private var manifest: ConsumerProvisioningManifest
    private(set) var resumeCount = 0
    private(set) var firstResumeFinished = false

    init(manifest: ConsumerProvisioningManifest) {
        self.manifest = manifest
    }

    func doctor() async throws -> DoctorStatus {
        let device = DetectedDevice(
            name: "Test iPhone",
            identifier: "A",
            selectionIdentifier: "A",
            developerModeStatus: "enabled",
            pairingState: "paired",
            tunnelState: "connected"
        )
        return DoctorStatus(
            ready: false,
            mac: MacSummary(ready: true),
            device: DeviceSummary(ready: true, connected: true, devices: [device]),
            actionsRequired: [],
            checks: []
        )
    }

    func setup() async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func build() async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        .init(exitCode: 0, stdout: "", stderr: "")
    }
    func discoverPersonalTeams(selectedDeviceIdentifier: String?) async throws -> [PersonalTeamCandidate] {
        [.team("TEAM1")]
    }
    func consumerProvisioningStatus() async throws -> ConsumerProvisioningManifest? { manifest }

    func resumeConsumerSetup(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        resumeCount += 1
        if resumeCount == 1 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { continuation.resume() }
            }
            firstResumeFinished = true
            throw ConsumerProvisioningFailure(
                code: .runtimeConfigurationWriteFailed,
                stage: .writingRuntimeConfiguration,
                userMessage: "stale failure",
                remediation: "stale failure",
                developerDetail: "stale generation"
            )
        }
        manifest = manifest.updatingSetupCheckpoint(
            .runtimeConfigurationVerified,
            developerProfileTrustStatus: .trusted
        )
        return ConsumerProvisioningResult(
            operation: request.operation,
            finalStage: .complete,
            manifest: manifest,
            installedBundleIdentifiers: [manifest.installedMainBundleID, manifest.installedRunnerBundleID],
            runtimeRecoveryRecommended: false
        )
    }
}

private extension PersonalTeamCandidate {
    static func team(_ identifier: String) -> PersonalTeamCandidate {
        PersonalTeamCandidate(
            teamIdentifier: identifier,
            teamDisplayName: "Team \(identifier)",
            signingIdentityCommonName: "Apple Development",
            signingIdentityFingerprint: String(repeating: "A", count: 40),
            certificateSubjectTeamIdentifier: identifier,
            profileTeamIdentifiers: [identifier],
            matchingProfileCount: 1,
            selectedDeviceIncluded: true,
            personalTeam: true
        )
    }
}

private actor ConsumerSequenceEngine: IOSSimSetupEngine {
    nonisolated let consumerProvisioningEnabled = true
    let teams: [PersonalTeamCandidate]
    private(set) var requests: [ConsumerProvisioningRequest] = []
    private(set) var runtimeConfirmationCount = 0
    private(set) var resumeCount = 0
    private var manifest: ConsumerProvisioningManifest?
    private let runtimeActionsWithoutManifest: Bool
    private let resumeRemainsTrustRequired: Bool

    init(
        teams: [PersonalTeamCandidate],
        initialManifest: ConsumerProvisioningManifest? = nil,
        runtimeActionsWithoutManifest: Bool = false,
        resumeRemainsTrustRequired: Bool = false
    ) {
        self.teams = teams
        self.manifest = initialManifest
        self.runtimeActionsWithoutManifest = runtimeActionsWithoutManifest
        self.resumeRemainsTrustRequired = resumeRemainsTrustRequired
    }

    func doctor() async throws -> DoctorStatus {
        var checks: [DoctorCheck] = [
            .init(state: .pass, component: "Mac", name: "macOS supported", detail: "ready"),
            .init(state: .pass, component: "Apple Tooling", name: "xcrun", detail: "ready")
        ]
        let device = DetectedDevice(
            name: "Test iPhone",
            identifier: "A",
            selectionIdentifier: "A",
            osVersion: "26.6",
            developerModeStatus: "enabled",
            pairingState: "paired",
            tunnelState: "connected"
        )
        checks.append(.init(state: .pass, component: "Device", name: "iPhone detected", detail: device.name, requiredFor: "device"))
        if manifest?.runtimeSetupStatus == .userActionRequired || (manifest == nil && runtimeActionsWithoutManifest) {
            checks.append(.init(
                state: .action,
                component: "Runtime",
                name: "PAIRING MATERIAL",
                detail: "stored on iPhone",
                action: "Open IOSSim on your iPhone and complete the pairing import.",
                requiredFor: "device"
            ))
        }
        return DoctorStatus(
            ready: false,
            mac: MacSummary(ready: true),
            device: DeviceSummary(ready: true, connected: true, devices: [device]),
            actionsRequired: [],
            checks: checks
        )
    }

    func setup() async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func build() async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult { .init(exitCode: 0, stdout: "", stderr: "") }
    func discoverPersonalTeams(selectedDeviceIdentifier: String?) async throws -> [PersonalTeamCandidate] { teams }
    func consumerProvisioningStatus() async throws -> ConsumerProvisioningManifest? { manifest }

    func resumeConsumerSetup(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        resumeCount += 1
        guard let manifest else {
            throw ConsumerProvisioningFailure(
                code: .installVerificationFailed,
                stage: .verifyingInstallation,
                userMessage: "Missing checkpoint.",
                remediation: "Repair.",
                developerDetail: "Test checkpoint missing."
            )
        }
        let updated = resumeRemainsTrustRequired
            ? manifest.updatingSetupCheckpoint(.developerProfileTrustRequired, developerProfileTrustStatus: .required)
            : manifest.updatingSetupCheckpoint(.runtimeConfigurationVerified, developerProfileTrustStatus: .trusted)
        self.manifest = updated
        return ConsumerProvisioningResult(
            operation: request.operation,
            finalStage: resumeRemainsTrustRequired ? .developerProfileTrustRequired : .complete,
            manifest: updated,
            installedBundleIdentifiers: [updated.installedMainBundleID, updated.installedRunnerBundleID],
            runtimeRecoveryRecommended: false
        )
    }

    func confirmRuntimeSetup() async throws -> ConsumerProvisioningManifest {
        runtimeConfirmationCount += 1
        guard let manifest else {
            throw ConsumerProvisioningFailure(
                code: .runnerMappingMissing,
                stage: .verifyingRuntimeReadiness,
                userMessage: "Missing setup state.",
                remediation: "Repair.",
                developerDetail: "Test manifest missing."
            )
        }
        let updated = manifest.updatingRuntimeSetupStatus(.ready)
        self.manifest = updated
        return updated
    }

    func consumerProvision(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        requests.append(request)
        let ids = try PersonalTeamBundleIdentifierSet(teamIdentifier: request.selectedTeamIdentifier)
        let profile = ConsumerProfileState(
            artifact: "main",
            teamIdentifier: request.selectedTeamIdentifier,
            bundleIdentifier: ids.main,
            creationDate: Date(),
            expirationDate: Date().addingTimeInterval(7 * 24 * 60 * 60),
            remainingValidity: 7 * 24 * 60 * 60,
            selectedDeviceIncluded: true,
            personalTeam: true,
            profileIdentifier: nil,
            profileFingerprint: nil,
            refreshRecommended: false
        )
        let runnerProfile = ConsumerProfileState(
            artifact: "runner",
            teamIdentifier: request.selectedTeamIdentifier,
            bundleIdentifier: ids.runner,
            creationDate: profile.creationDate,
            expirationDate: profile.expirationDate,
            remainingValidity: profile.remainingValidity,
            selectedDeviceIncluded: true,
            personalTeam: true,
            profileIdentifier: nil,
            profileFingerprint: nil,
            refreshRecommended: false
        )
        let manifest = ConsumerProvisioningManifest(
            deviceIdentifierSafe: "A",
            deviceIdentifierHash: "hash",
            teamID: request.selectedTeamIdentifier,
            sourceMainBundleID: ProtectedSourceBundleIdentifiers.default.main,
            installedMainBundleID: ids.main,
            sourceUITestBundleID: ProtectedSourceBundleIdentifiers.default.uiTests,
            installedUITestBundleID: ids.uiTests,
            sourceRunnerBundleID: ProtectedSourceBundleIdentifiers.default.runner,
            installedRunnerBundleID: ids.runner,
            mainProfile: profile,
            runnerProfile: runnerProfile,
            lastInstallDate: Date(),
            appVersion: "1",
            provisionerVersion: "1"
        )
        self.manifest = manifest
        return ConsumerProvisioningResult(
            operation: request.operation,
            finalStage: .complete,
            manifest: manifest,
            installedBundleIdentifiers: [ids.main, ids.runner],
            runtimeRecoveryRecommended: false
        )
    }
}

private actor SequenceSetupEngine: IOSSimSetupEngine {
    let status: DoctorStatus
    let failProvisionFor: String?
    let failureText: String?
    private(set) var provisionedDeviceIdentifiers: [String] = []

    init(status: DoctorStatus, failProvisionFor: String? = nil, failureText: String? = nil) {
        self.status = status
        self.failProvisionFor = failProvisionFor
        self.failureText = failureText
    }

    func doctor() async throws -> DoctorStatus {
        status
    }

    func setup() async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "setup ok", stderr: "")
    }

    func build() async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "build ok", stderr: "")
    }

    func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        guard let selectedDeviceIdentifier else {
            throw ProcessFailure(
                commandName: "device",
                result: ProcessResult(exitCode: 2, stdout: "", stderr: "DEVICE_SELECTION_REQUIRED")
            )
        }
        provisionedDeviceIdentifiers.append(selectedDeviceIdentifier)
        if selectedDeviceIdentifier == failProvisionFor {
            throw ProcessFailure(
                commandName: "device",
                result: ProcessResult(exitCode: 2, stdout: "", stderr: failureText ?? "failed")
            )
        }
        return ProcessResult(exitCode: 0, stdout: "Installed artifacts", stderr: "")
    }
}
