import XCTest
@testable import IOSSimMacCore

final class ApplePersonalTeamExperimentalTests: XCTestCase {
    func testFreshAuthorizationRequiresAndCompletesLegitimateTwoFactor() async throws {
        let backend = ExperimentalBackendMock(auth: .verification)
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        let password = SensitiveInput("not-a-real-password")

        let challenge = try await coordinator.begin(account: "fixture@example.invalid", password: password)
        XCTAssertEqual(challenge?.method, .trustedDevice)
        XCTAssertTrue(password.isEmpty)
        var summary = await coordinator.authorization
        XCTAssertEqual(summary.stage, .verificationRequired)
        XCTAssertFalse(summary.sessionValid)

        let code = SensitiveInput("123456")
        let nextChallenge = try await coordinator.verify(code: code)
        XCTAssertNil(nextChallenge)
        XCTAssertTrue(code.isEmpty)
        summary = await coordinator.authorization
        XCTAssertEqual(summary.stage, .authorized)
        XCTAssertTrue(summary.sessionValid)
    }

    func testBadPasswordIsSanitizedState() async throws {
        let coordinator = ExperimentalConsumerProvisioningCoordinator(
            backend: ExperimentalBackendMock(auth: .failure(.badPassword))
        )
        do {
            _ = try await coordinator.begin(
                account: "fixture@example.invalid",
                password: SensitiveInput("not-a-real-password")
            )
            XCTFail("Expected bad password")
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, .badPassword)
        }
        let summary = await coordinator.authorization
        XCTAssertEqual(summary.stage, .failed)
        XCTAssertEqual(summary.safeErrorCode, "BADPASSWORD")
    }

    func testExpiredVerificationCodeRequestsNewVerification() async throws {
        let backend = ExperimentalBackendMock(auth: .verification, verificationFailure: .verificationExpired)
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        _ = try await coordinator.begin(account: "fixture@example.invalid", password: SensitiveInput("secret"))
        do {
            _ = try await coordinator.verify(code: SensitiveInput("000000"))
            XCTFail("Expected expired verification")
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, .verificationExpired)
        }
        let summary = await coordinator.authorization
        XCTAssertEqual(summary.stage, .verificationRequired)
        XCTAssertEqual(summary.safeErrorCode, "VERIFICATION_EXPIRED")
    }

    func testValidSessionIsReusedWithoutPassword() async throws {
        let backend = ExperimentalBackendMock(auth: .success, resumedTeams: [.personal])
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        let resumed = try await coordinator.resume()
        XCTAssertTrue(resumed)
        let events = await backend.events
        XCTAssertEqual(events, ["resume"])
        let summary = await coordinator.authorization
        XCTAssertTrue(summary.sessionValid)
    }

    func testExpiredSessionIsNotReused() async throws {
        let backend = ExperimentalBackendMock(auth: .success, resumeFailure: .sessionExpired)
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        let resumed = try await coordinator.resume()
        XCTAssertFalse(resumed)
        let summary = await coordinator.authorization
        XCTAssertEqual(summary.stage, .sessionExpired)
        XCTAssertFalse(summary.sessionValid)
    }

    func testPersonalTeamIsPreferredAuthoritativelyWhenPaidTeamAlsoExists() throws {
        XCTAssertEqual(
            try ExperimentalConsumerProvisioningCoordinator.preferredTeam(from: [.paid, .personal]).id,
            ExperimentalAppleTeam.personal.id
        )
        XCTAssertThrowsError(
            try ExperimentalConsumerProvisioningCoordinator.preferredTeam(from: [.personal, .secondPersonal])
        )
    }

    func testNoTeamAndMalformedTeamFailClosed() throws {
        XCTAssertThrowsError(try ExperimentalConsumerProvisioningCoordinator.validateTeams([]))
        XCTAssertThrowsError(try ExperimentalConsumerProvisioningCoordinator.validateTeams([
            .init(id: "bad team", name: "Invalid", isPersonalTeam: true, isPaidDeveloperTeam: false)
        ]))
    }

    func testFreshEndToEndOrdersEveryProvisioningAndPairingGate() async throws {
        let backend = ExperimentalBackendMock(auth: .success)
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        _ = try await coordinator.begin(account: "fixture@example.invalid", password: SensitiveInput("secret"))

        let receipt = try await coordinator.provision(.fixture(operation: .install))

        XCTAssertEqual(receipt.team.id, ExperimentalAppleTeam.personal.id)
        XCTAssertTrue(receipt.identity.reused)
        XCTAssertTrue(receipt.inventory.isExpected)
        XCTAssertTrue(receipt.pairingVerified)
        let events = await backend.events
        XCTAssertEqual(
            events,
            ["auth", "identity", "device", "identifiers", "profiles", "sign", "install", "pairing"]
        )
    }

    func testReturningUserRefreshReusesSessionIdentityAndDerivedIDs() async throws {
        let backend = ExperimentalBackendMock(auth: .success, resumedTeams: [.personal])
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        let resumed = try await coordinator.resume()
        XCTAssertTrue(resumed)
        let receipt = try await coordinator.provision(.fixture(operation: .refresh))
        XCTAssertTrue(receipt.identity.reused)
        XCTAssertEqual(
            receipt.derivedIdentifiers,
            try PersonalTeamBundleIdentifierSet(teamIdentifier: ExperimentalAppleTeam.personal.id)
        )
    }

    func testReturningUserExpiredSessionReauthorizesThenRefreshes() async throws {
        let backend = ExperimentalBackendMock(auth: .success, resumeFailure: .sessionExpired)
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        let resumed = try await coordinator.resume()
        XCTAssertFalse(resumed)
        _ = try await coordinator.begin(account: "fixture@example.invalid", password: SensitiveInput("secret"))
        let receipt = try await coordinator.provision(.fixture(operation: .refresh))
        XCTAssertTrue(receipt.inventory.isExpected)
    }

    func testCertificateLimitAndMissingPrivateKeyAreNotRecoveredByRevokingOthers() async throws {
        for failure in [ExperimentalBackendError.certificateLimit, .missingPrivateKey] {
            let backend = ExperimentalBackendMock(auth: .success, operationFailure: failure)
            let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
            _ = try await coordinator.begin(account: "fixture@example.invalid", password: SensitiveInput("secret"))
            do {
                _ = try await coordinator.provision(.fixture())
                XCTFail("Expected \(failure)")
            } catch {
                XCTAssertEqual(error as? ExperimentalBackendError, failure)
            }
            let events = await backend.events
            XCTAssertFalse(events.contains("revoke"))
        }
    }

    func testDeviceAndIdentifierLimitsAndCollisionPropagateWithoutRetryStorm() async throws {
        for failure in [ExperimentalBackendError.deviceLimit, .appIDLimit, .appIDCollision] {
            let backend = ExperimentalBackendMock(auth: .success, operationFailure: failure)
            let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
            _ = try await coordinator.begin(account: "fixture@example.invalid", password: SensitiveInput("secret"))
            await XCTAssertThrowsErrorAsync { try await coordinator.provision(.fixture()) }
            let events = await backend.events
            XCTAssertLessThanOrEqual(events.filter { $0 == "device" || $0 == "identifiers" }.count, 2)
        }
    }

    func testInvalidAndExpiredProfilesFailBeforeSigning() async throws {
        for mode in [
            ProfileMode.invalidTeam,
            .invalidCertificate,
            .wrongDevice,
            .invalidEntitlement,
            .expired
        ] {
            let backend = ExperimentalBackendMock(auth: .success, profileMode: mode)
            let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
            _ = try await coordinator.begin(account: "fixture@example.invalid", password: SensitiveInput("secret"))
            await XCTAssertThrowsErrorAsync { try await coordinator.provision(.fixture()) }
            let events = await backend.events
            XCTAssertFalse(events.contains("sign"))
        }
    }

    func testNestedSigningInstallInventoryAndPairingFailuresAreSeparated() async throws {
        for failure in [
            ExperimentalBackendError.nestedSigningFailure,
            .installationFailure,
            .inventoryMismatch,
            .pairingFailure
        ] {
            let backend = ExperimentalBackendMock(auth: .success, operationFailure: failure)
            let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
            _ = try await coordinator.begin(account: "fixture@example.invalid", password: SensitiveInput("secret"))
            await XCTAssertThrowsErrorAsync { try await coordinator.provision(.fixture()) }
        }
    }

    func testRepairPlannerChoosesSmallestRepair() {
        XCTAssertEqual(ExperimentalRepairPlanner.nextAction(for: .fixture(auth: false)), .reauthorize)
        XCTAssertEqual(ExperimentalRepairPlanner.nextAction(for: .fixture(profiles: false)), .refreshProfiles)
        XCTAssertEqual(ExperimentalRepairPlanner.nextAction(for: .fixture(main: false)), .reinstallMain)
        XCTAssertEqual(ExperimentalRepairPlanner.nextAction(for: .fixture(runner: false)), .reinstallRunner)
        XCTAssertEqual(ExperimentalRepairPlanner.nextAction(for: .fixture(pairing: false)), .repairPairing)
        XCTAssertEqual(ExperimentalRepairPlanner.nextAction(for: .fixture()), .none)
    }

    func testVersionedPrivateAdapterAllowsOnlyExpectedHTTPSHostsAndContent() throws {
        let adapter = PrivateAppleProtocolAdapter.researched2026
        XCTAssertEqual(adapter.version, "research-2026-09")
        XCTAssertEqual(
            try adapter.developerURL(operation: "ios/listDevices").absoluteString,
            "https://developerservices2.apple.com/services/QH65B2/ios/listDevices.action"
        )
        XCTAssertNoThrow(try adapter.validateResponse(
            url: adapter.grandSlamService,
            statusCode: 200,
            contentType: "text/x-xml-plist",
            body: Data("fixture".utf8)
        ))
        XCTAssertThrowsError(try adapter.validateResponse(
            url: URL(string: "https://example.invalid/steal")!,
            statusCode: 200,
            contentType: "application/json",
            body: Data("{}".utf8)
        ))
        XCTAssertThrowsError(try adapter.validateResponse(
            url: adapter.grandSlamService,
            statusCode: 503,
            contentType: "text/x-xml-plist",
            body: Data("fixture".utf8)
        ))
    }

    @MainActor
    func testSetupStoreOwnsAppleAuthorizationAndTwoFactorState() async throws {
        let backend = ExperimentalBackendMock(auth: .verification)
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        let store = SetupStore(
            engine: MockIOSSimSetupEngine(scenario: .ready),
            authorizationCoordinator: coordinator
        )

        store.beginAppleAuthorization(account: "fixture@example.invalid", password: "secret")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .appleAccount)
        XCTAssertEqual(store.appleVerificationChallenge?.method, .trustedDevice)

        store.submitAppleVerification(code: "123456")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .installing)
        XCTAssertEqual(store.selectedTeamIdentifier, ExperimentalAppleTeam.personal.id)
        XCTAssertTrue(store.appleAuthorization.sessionValid)
    }

    @MainActor
    func testUnavailableLiveBoundaryShowsConsumerSafeAuthorizationError() async throws {
        let store = SetupStore(engine: MockIOSSimSetupEngine(scenario: .ready))
        store.beginAppleAuthorization(account: "fixture@example.invalid", password: "secret")
        try await waitUntilIdle(store)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.lastError?.headline, "IOSSim couldn't prepare Apple authorization.")
        XCTAssertEqual(store.lastError?.details, "UNAVAILABLE")
        XCTAssertFalse(store.lastError?.details.contains("secret") == true)
    }
}

private enum AuthMode: Sendable {
    case success
    case verification
    case failure(ExperimentalBackendError)
}

private enum ProfileMode: Sendable {
    case valid
    case invalidTeam
    case invalidCertificate
    case wrongDevice
    case invalidEntitlement
    case expired
}

private actor ExperimentalBackendMock: ExperimentalPersonalTeamBackend {
    nonisolated let method = AppleAuthorizationMethodCategory.privateGrandSlamSRP
    nonisolated let clientIdentityVersion = "fixture-v1"
    nonisolated let isPhysicallyQualified = false

    private let auth: AuthMode
    private let resumedTeams: [ExperimentalAppleTeam]?
    private let resumeFailure: ExperimentalBackendError?
    private let verificationFailure: ExperimentalBackendError?
    private let operationFailure: ExperimentalBackendError?
    private let profileMode: ProfileMode
    private(set) var events: [String] = []

    init(
        auth: AuthMode,
        resumedTeams: [ExperimentalAppleTeam]? = nil,
        resumeFailure: ExperimentalBackendError? = nil,
        verificationFailure: ExperimentalBackendError? = nil,
        operationFailure: ExperimentalBackendError? = nil,
        profileMode: ProfileMode = .valid
    ) {
        self.auth = auth
        self.resumedTeams = resumedTeams
        self.resumeFailure = resumeFailure
        self.verificationFailure = verificationFailure
        self.operationFailure = operationFailure
        self.profileMode = profileMode
    }

    func resumeSession() async throws -> [ExperimentalAppleTeam]? {
        events.append("resume")
        if let resumeFailure { throw resumeFailure }
        return resumedTeams
    }

    func beginAuthorization(account: String, password: SensitiveInput) async throws -> ExperimentalAuthorizationResult {
        events.append("auth")
        guard !account.isEmpty, !password.isEmpty else { throw ExperimentalBackendError.badPassword }
        switch auth {
        case .success: return .authorized([.personal])
        case .verification:
            return .verificationRequired(.init(method: .trustedDevice, safeDestinationHint: "trusted device"))
        case .failure(let error): throw error
        }
    }

    func submitVerification(code: SensitiveInput) async throws -> ExperimentalAuthorizationResult {
        events.append("verify")
        if let verificationFailure { throw verificationFailure }
        guard !code.isEmpty else { throw ExperimentalBackendError.verificationExpired }
        return .authorized([.personal])
    }

    func invalidateSession() async { events.append("invalidate") }

    func prepareIdentity(team: ExperimentalAppleTeam) async throws -> ExperimentalSigningIdentity {
        events.append("identity")
        if [.certificateLimit, .missingPrivateKey].contains(operationFailure) { throw operationFailure! }
        return .init(
            certificateFingerprint: "fixture-fingerprint",
            certificateExpiration: Date().addingTimeInterval(86_400),
            privateKeyPersistentReference: Data("keychain-reference".utf8),
            reused: true
        )
    }

    func registerDevice(_ request: ExperimentalProvisioningRequest, team: ExperimentalAppleTeam) async throws {
        events.append("device")
        if operationFailure == .deviceLimit { throw ExperimentalBackendError.deviceLimit }
    }

    func registerIdentifiers(_ identifiers: PersonalTeamBundleIdentifierSet, team: ExperimentalAppleTeam) async throws {
        events.append("identifiers")
        if [.appIDLimit, .appIDCollision].contains(operationFailure) { throw operationFailure! }
    }

    func obtainProfiles(
        identifiers: PersonalTeamBundleIdentifierSet,
        identity: ExperimentalSigningIdentity,
        request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam
    ) async throws -> [ExperimentalProfile] {
        events.append("profiles")
        let now = Date()
        let profileTeam = profileMode == .invalidTeam ? "WRONGTEAM" : team.id
        let fingerprint = profileMode == .invalidCertificate ? "wrong-certificate" : identity.certificateFingerprint
        let devices = profileMode == .wrongDevice ? Set(["different-device"]) : Set([request.selectedDeviceIdentifier])
        let expiration = profileMode == .expired ? now.addingTimeInterval(-60) : now.addingTimeInterval(6 * 86_400)
        return [identifiers.main, identifiers.runner].map {
            ExperimentalProfile(
                bundleIdentifier: $0,
                teamIdentifier: profileTeam,
                certificateFingerprint: fingerprint,
                provisionedDeviceIdentifiers: devices,
                applicationIdentifierEntitlement: profileMode == .invalidEntitlement
                    ? "wrong.entitlement"
                    : "\(team.id).\($0)",
                issuedAt: now.addingTimeInterval(-60),
                expiresAt: expiration,
                profileData: Data("fixture-profile".utf8)
            )
        }
    }

    func signArtifacts(
        identifiers: PersonalTeamBundleIdentifierSet,
        identity: ExperimentalSigningIdentity,
        profiles: [ExperimentalProfile]
    ) async throws {
        events.append("sign")
        if operationFailure == .nestedSigningFailure { throw ExperimentalBackendError.nestedSigningFailure }
    }

    func installArtifacts(
        identifiers: PersonalTeamBundleIdentifierSet,
        request: ExperimentalProvisioningRequest
    ) async throws -> ExperimentalInstallInventory {
        events.append("install")
        if operationFailure == .installationFailure { throw ExperimentalBackendError.installationFailure }
        if operationFailure == .inventoryMismatch {
            return .init(derivedMainCount: 1, derivedRunnerCount: 0, canonicalRunnerCount: 1, witnessCount: 0)
        }
        return .init(derivedMainCount: 1, derivedRunnerCount: 1, canonicalRunnerCount: 0, witnessCount: 0)
    }

    func preparePairing(for request: ExperimentalProvisioningRequest) async throws -> Bool {
        events.append("pairing")
        if operationFailure == .pairingFailure { return false }
        return true
    }
}

private extension ExperimentalAppleTeam {
    static let personal = ExperimentalAppleTeam(
        id: "TEAM123456",
        name: "Personal Team",
        isPersonalTeam: true,
        isPaidDeveloperTeam: false
    )
    static let paid = ExperimentalAppleTeam(
        id: "PAID123456",
        name: "Developer Team",
        isPersonalTeam: false,
        isPaidDeveloperTeam: true
    )
    static let secondPersonal = ExperimentalAppleTeam(
        id: "TEAM654321",
        name: "Second Personal Team",
        isPersonalTeam: true,
        isPaidDeveloperTeam: false
    )
}

private extension ExperimentalProvisioningRequest {
    static func fixture(operation: ConsumerProvisioningOperation = .install) -> Self {
        .init(selectedDeviceIdentifier: "fixture-device", selectedDeviceName: "Test iPhone", operation: operation)
    }
}

private extension ExperimentalRepairObservation {
    static func fixture(
        auth: Bool = true,
        profiles: Bool = true,
        main: Bool = true,
        runner: Bool = true,
        pairing: Bool = true
    ) -> Self {
        .init(
            authSessionValid: auth,
            profilesValid: profiles,
            mainInstalled: main,
            runnerInstalled: runner,
            pairingVerified: pairing
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

@MainActor
private func waitUntilIdle(_ store: SetupStore) async throws {
    for _ in 0..<100 where store.isRunning {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    if store.isRunning {
        XCTFail("SetupStore did not become idle")
    }
}
