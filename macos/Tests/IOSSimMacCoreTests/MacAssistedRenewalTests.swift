import XCTest
@testable import IOSSimMacCore

final class MacAssistedRenewalTests: XCTestCase {
    func testNearExpiryReusesValidCertificateAndUpgradesInPlace() async throws {
        let input = RenewalInput(profile: .nearExpiry, certificate: .valid, session: .valid, pairingOperational: true, appInstalled: true)
        XCTAssertEqual(MacAssistedRenewalCoordinator.plan(for: input).actions, [.refreshProfiles, .installInPlace])
        let device = try IOSSimDeviceIdentity(udid: "RENEW-DEVICE-001")
        let service = FakeRenewalService(); let coordinator = MacAssistedRenewalCoordinator(service: service)
        _ = try await coordinator.renew(input: input, device: device)
        XCTAssertEqual(service.calls, ["profiles-reuse", "upgrade", "verify"])
    }

    func testExpiredProfileWithValidCertificateDoesNotRecreateCertificate() {
        let input = RenewalInput(profile: .expired, certificate: .valid, session: .valid, pairingOperational: true, appInstalled: false)
        XCTAssertEqual(MacAssistedRenewalCoordinator.plan(for: input).actions, [.refreshProfiles])
    }

    func testExpiredSessionRequiresLegitimateReauthentication() {
        let input = RenewalInput(profile: .nearExpiry, certificate: .valid, session: .reauthenticationRequired, pairingOperational: true, appInstalled: true)
        XCTAssertEqual(MacAssistedRenewalCoordinator.plan(for: input).actions, [.reauthenticate, .refreshProfiles, .installInPlace])
    }

    func testBadPairingIsRepairOnlyAndDoesNotDeleteSigningState() {
        let input = RenewalInput(profile: .valid, certificate: .valid, session: .valid, pairingOperational: false, appInstalled: true)
        XCTAssertEqual(MacAssistedRenewalCoordinator.plan(for: input).actions, [.repairPairing])
    }
}

private final class FakeRenewalService: MacAssistedRenewalService, @unchecked Sendable {
    private(set) var calls: [String] = []
    func reauthenticate() async throws { calls.append("reauth") }
    func refreshProfiles(reuseCertificate: Bool) async throws { calls.append(reuseCertificate ? "profiles-reuse" : "profiles-new") }
    func upgradeInPlace(on device: IOSSimDeviceIdentity) async throws { calls.append("upgrade") }
    func verifyAfterRenewal(on device: IOSSimDeviceIdentity) async throws { calls.append("verify") }
}
