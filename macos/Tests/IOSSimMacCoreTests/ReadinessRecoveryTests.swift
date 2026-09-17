import Foundation
import XCTest
@testable import IOSSimMacCore

final class ReadinessRecoveryTests: XCTestCase {
    func testPairingRepairDoesNotTriggerSigningOrReinstall() async {
        let values: [ReadinessDomain: ReadinessDomainStatus] = [
            .appleAccount: .init(.ready), .signing: .init(.ready), .pairing: .init(.repairable), .installation: .init(.ready)
        ]
        let snapshot = await ReadinessCoordinator().evaluate(using: StaticReadinessProbe(values))
        XCTAssertEqual(snapshot.recovery.actions, [.repairPairing])
    }

    func testExpiredSigningProducesRenewalOnly() {
        let plan = ReadinessCoordinator.plan(for: [.signing: .init(.expired), .pairing: .init(.ready)])
        XCTAssertEqual(plan.actions, [.renewSigning])
    }

    func testLockedDeviceRequestsUserAction() {
        let plan = ReadinessCoordinator.plan(for: [.device: .init(.userActionRequired, reason: .init(code: "unlock", message: "Unlock iPhone"))])
        XCTAssertEqual(plan.actions, [.askUser(action: "unlock")])
    }

    func testTransientRuntimeUsesBoundedRetry() {
        let plan = ReadinessCoordinator.plan(for: [.runtime: .init(.transientFailure)])
        XCTAssertEqual(plan.actions, [.retryTransport(maxAttempts: 3, backoffSeconds: [0.5, 1, 2])])
    }

    func testRecoveryPlanSelectsOnlyEarliestInvalidPrerequisite() {
        let plan = ReadinessCoordinator.plan(for: [
            .signing: .init(.expired),
            .installation: .init(.repairable),
            .pairing: .init(.repairable),
            .runtime: .init(.stale)
        ])
        XCTAssertEqual(plan.actions, [.renewSigning])
    }

    func testRuntimeStalenessRerunsProofWithoutReinstall() {
        let plan = ReadinessCoordinator.plan(for: [
            .installation: .init(.ready),
            .pairing: .init(.ready),
            .vpnTunnel: .init(.ready),
            .runtime: .init(.stale)
        ])
        XCTAssertEqual(plan.actions, [.rerunRuntimeProof])
    }

    func testSetupReconciliationChoosesSmallestOwnedArtifactRepair() {
        var input = SetupReconciliationInput()
        input.mainInstalled = false
        XCTAssertEqual(input.smallestRepair, .reinstallMain)

        input.mainInstalled = true
        input.runnerInstalled = false
        XCTAssertEqual(input.smallestRepair, .reinstallRunner)

        input.mainInstalled = false
        XCTAssertEqual(input.smallestRepair, .reinstallOwnedArtifacts)
    }

    func testSetupReconciliationOrdersDependentRepairDomains() {
        var input = SetupReconciliationInput()
        input.signingCurrent = false
        input.releaseCurrent = false
        input.pairingOperational = false
        input.vpnReady = false
        input.runtimeProofCurrent = false
        XCTAssertEqual(input.smallestRepair, .renewSigning)

        input.signingCurrent = true
        XCTAssertEqual(input.smallestRepair, .reinstallOwnedArtifacts)

        input.releaseCurrent = true
        XCTAssertEqual(input.smallestRepair, .repairPairing)

        input.pairingOperational = true
        XCTAssertEqual(input.smallestRepair, .startOrApproveVPN)

        input.vpnReady = true
        XCTAssertEqual(input.smallestRepair, .rerunRuntimeProof)
    }

    func testUnavailableDevicePrecedesAllOtherRepair() {
        var input = SetupReconciliationInput()
        input.deviceAvailable = false
        input.signingCurrent = false
        input.mainInstalled = false
        XCTAssertEqual(input.smallestRepair, .waitForDevice)
    }

    func testJournalPersistsSafeFieldsAndRejectsSecretShapedData() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iossim-journal-\(UUID().uuidString).json")
        let journal = SetupJournalStore(url: url)
        try await journal.save(SetupJournalEntry(selectedDeviceUDID: "DEVICE-001", completedStages: ["checking"], currentStage: "pairing"))
        let loaded = try await journal.load()
        XCTAssertEqual(loaded?.currentStage, "pairing")
        try? FileManager.default.removeItem(at: url)
    }
}
