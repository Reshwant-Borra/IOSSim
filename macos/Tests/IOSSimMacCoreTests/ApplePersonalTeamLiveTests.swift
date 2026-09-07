import Foundation
import XCTest
@testable import IOSSimMacCore

final class ApplePersonalTeamLiveTests: XCTestCase {
    func testLocalMachineIdentityWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["IOSSIM_TEST_LOCAL_MACHINE_IDENTITY"] == "1" else {
            throw XCTSkip("Credentials-free local system adapter probe is opt-in")
        }
        let request = URLRequest(url: PrivateAppleProtocolAdapter.researched2026.grandSlamService)
        let headers = try await LocalMacAppleMachineIdentityProvider().headers(for: request)
        for name in [
            "X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO",
            "X-Mme-Device-Id", "X-MMe-Client-Info", "X-Apple-I-Client-Time"
        ] {
            XCTAssertFalse(headers[name]?.isEmpty ?? true, "Missing local machine header named \(name)")
        }
    }

    func testSRPRequestMaterialAndBothPasswordSchemes() throws {
        let privateBytes = Data((1...32).map(UInt8.init))
        let client = try AppleSRPClient(randomBytes: privateBytes)
        XCTAssertEqual(client.clientPublicKey.count, 256)
        XCTAssertTrue(client.clientPublicKey.contains { $0 != 0 })

        for scheme in ["s2k", "s2k_fo"] {
            let challenge = try AppleSRPClient.parseChallenge([
                "sp": scheme,
                "s": Data(repeating: 0x5A, count: 16),
                "i": 20_000,
                "B": Data(repeating: 0x7B, count: 256),
                "c": "synthetic-cookie"
            ])
            let proof = try client.proof(
                account: "fixture@example.invalid",
                password: Data("synthetic-password".utf8),
                challenge: challenge
            )
            XCTAssertEqual(proof.clientProof.count, 32)
            XCTAssertEqual(proof.sessionKey.count, 32)
            XCTAssertEqual(proof.expectedServerProof.count, 32)
        }
    }

    func testSRPRejectsMalformedOrUnsafeChallengeParameters() throws {
        let valid: [String: Any] = [
            "sp": "s2k", "s": Data(repeating: 1, count: 16), "i": 10_000,
            "B": Data(repeating: 2, count: 256), "c": "fixture"
        ]
        XCTAssertNoThrow(try AppleSRPClient.parseChallenge(valid))
        for mutation in [
            ["sp": "unknown"],
            ["s": Data()],
            ["i": 0],
            ["i": 10_000_001],
            ["B": Data(repeating: 0, count: 256)],
            ["c": ""]
        ] as [[String: Any]] {
            var malformed = valid
            mutation.forEach { malformed[$0.key] = $0.value }
            XCTAssertThrowsError(try AppleSRPClient.parseChallenge(malformed))
        }
        XCTAssertThrowsError(try AppleSRPClient(randomBytes: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try AppleSRPClient(randomBytes: Data(repeating: 1, count: 31)))
    }

    func testMalformedAndOversizedPlistsFailClosed() throws {
        XCTAssertThrowsError(try parseApplePlist(Data()))
        XCTAssertThrowsError(try parseApplePlist(Data("{\"unexpected\":true}".utf8)))
        XCTAssertThrowsError(try parseApplePlist(Data(repeating: 0, count: 8_388_609)))
        let array = try PropertyListSerialization.data(fromPropertyList: ["wrong-root"], format: .xml, options: 0)
        XCTAssertNil(try parseApplePlist(array))
    }

    func testTokenAndVerificationResponseParsing() throws {
        let expiry: Int64 = 1_900_000_000_000
        let data = try plistData([
            "t": [PrivateAppleProtocolAdapter.researched2026.xcodeTokenAudience: [
                "token": "synthetic-session-token",
                "expiry": expiry
            ]]
        ])
        let parsed = try AppleTokenResponseParser.decryptedToken(
            data,
            audience: PrivateAppleProtocolAdapter.researched2026.xcodeTokenAudience
        )
        XCTAssertEqual(parsed.token, "synthetic-session-token")
        XCTAssertEqual(parsed.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertThrowsError(try AppleTokenResponseParser.decryptedToken(
            try plistData(["t": [:]]),
            audience: PrivateAppleProtocolAdapter.researched2026.xcodeTokenAudience
        ))

        XCTAssertNoThrow(try AppleVerificationResponseParser.validate(["ec": 0]))
        XCTAssertThrowsError(try AppleVerificationResponseParser.validate(["ec": -21669])) { error in
            XCTAssertEqual(error as? ExperimentalBackendError, .verificationRejected)
        }
        XCTAssertThrowsError(try AppleVerificationResponseParser.validate(["ec": -1])) { error in
            XCTAssertEqual(error as? ExperimentalBackendError, .verificationExpired)
        }
    }

    func testToken503AndDeveloperFailuresRemainDistinct() {
        XCTAssertEqual(
            AppleHTTPFailureClassifier.error(status: 503, stage: "xcodeScopedToken"),
            .xcodeScopedTokenFailed
        )
        XCTAssertEqual(
            AppleHTTPFailureClassifier.error(status: 503, stage: "developerServices/listTeams"),
            .developerServicesFailed
        )
        XCTAssertEqual(AppleHTTPFailureClassifier.error(status: 503, stage: "srpInit"), .networkFailure)
        XCTAssertEqual(AppleHTTPFailureClassifier.error(status: 429, stage: "xcodeScopedToken"), .rateLimited)
    }

    func testTeamCertificateAndProfileResponseParsing() throws {
        let response: [String: Any] = ["teams": [
            [
                "teamId": "ABCDEFGHIJ", "name": "Fixture Personal Team", "type": "Individual",
                "memberships": [["name": "Free"]]
            ],
            [
                "teamId": "KLMNOPQRST", "name": "Fixture Company", "type": "Company/Organization",
                "memberships": [["name": "Developer Program"]]
            ]
        ]]
        let teams = try AppleDeveloperResponseParser.teams(response)
        XCTAssertTrue(teams[0].isPersonalTeam)
        XCTAssertTrue(teams[1].isPaidDeveloperTeam)
        XCTAssertEqual(try ExperimentalConsumerProvisioningCoordinator.preferredTeam(from: teams).id, "ABCDEFGHIJ")
        XCTAssertThrowsError(try AppleDeveloperResponseParser.teams(["teams": [["teamId": 1]]]))

        let certificate = Data([1, 2, 3, 4])
        XCTAssertEqual(certificateData(["attributes": ["certContent": certificate]]), certificate)
        XCTAssertNil(certificateData(["attributes": ["certContent": 7]]))

        let profile = Data([5, 6, 7])
        XCTAssertEqual(try AppleDeveloperResponseParser.encodedProfile([
            "provisioningProfile": ["encodedProfile": profile]
        ]), profile)
        XCTAssertThrowsError(try AppleDeveloperResponseParser.encodedProfile([
            "provisioningProfile": ["encodedProfile": Data()]
        ]))
    }

    func testStoredSessionIsValidatedByLiveTeamDiscovery() async throws {
        let transport = ScriptedAppleTransport([
            .plist(teamResponse())
        ])
        let store = MemoryAuthorizationSessionStore(session: fixtureSession())
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-live-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diagnosticsURL) }
        let diagnostics = ApplePersonalTeamDiagnosticsStore(url: diagnosticsURL)
        let backend = LiveApplePersonalTeamBackend(
            transport: transport,
            machineIdentity: FixtureMachineIdentity(),
            sessionStore: store,
            diagnostics: diagnostics
        )

        let teams = try await backend.resumeSession()
        XCTAssertEqual(teams?.filter(\.isPersonalTeam).map(\.id), ["ABCDEFGHIJ"])
        XCTAssertTrue(diagnostics.load()?.sessionValid == true)
        XCTAssertTrue(diagnostics.load()?.personalTeamFound == true)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.host, "developerservices2.apple.com")
        XCTAssertTrue(requests[0].url?.path.hasSuffix("/listTeams.action") == true)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Apple-I-Identity-Id"), "123456789")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Apple-GS-Token"), "synthetic-session-token")
    }

    func testSelectedDeviceAndExistingDerivedAppIDsUseReadBeforeCreate() async throws {
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: "ABCDEFGHIJ")
        let appIDs = [identifiers.main, identifiers.uiTests, identifiers.runner].enumerated().map { index, bundle in
            ["appIdId": "fixture-id-\(index)", "identifier": bundle]
        }
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(["resultCode": 0, "devices": []]),
            .plist(["resultCode": 0]),
            .plist(["resultCode": 0, "appIds": appIDs, "availableQuantity": 5])
        ])
        let backend = LiveApplePersonalTeamBackend(
            transport: transport,
            machineIdentity: FixtureMachineIdentity(),
            sessionStore: MemoryAuthorizationSessionStore(session: fixtureSession()),
            diagnostics: ApplePersonalTeamDiagnosticsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("iossim-live-test-\(UUID().uuidString).json"))
        )
        _ = try await backend.resumeSession()
        let request = ExperimentalProvisioningRequest(
            selectedDeviceIdentifier: "00008150-00022D581E12401C",
            selectedDeviceName: "Fixture iPhone !",
            operation: .install
        )
        let team = ExperimentalAppleTeam(
            id: "ABCDEFGHIJ", name: "Fixture Personal Team", isPersonalTeam: true, isPaidDeveloperTeam: false
        )
        try await backend.registerDevice(request, team: team)
        try await backend.registerIdentifiers(identifiers, team: team)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests[1].url?.path.hasSuffix("/ios/listDevices.action") == true)
        XCTAssertTrue(requests[2].url?.path.hasSuffix("/ios/addDevice.action") == true)
        let addBody = try XCTUnwrap(try parseApplePlist(XCTUnwrap(requests[2].httpBody)))
        XCTAssertEqual(addBody["deviceNumber"] as? String, request.selectedDeviceIdentifier)
        XCTAssertEqual(addBody["name"] as? String, "Fixture iPhone")
        XCTAssertTrue(requests[3].url?.path.hasSuffix("/ios/listAppIds.action") == true)
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/ios/addAppId.action") == true })
    }

    func testLiveChallengeStateAndRequestConstructionWithSyntheticResponses() async throws {
        let challenge: [String: Any] = [
            "Status": ["ec": 0], "sp": "s2k", "s": Data(repeating: 1, count: 16),
            "i": 1_000, "B": Data(repeating: 2, count: 256), "c": "fixture-cookie"
        ]
        let transport = ScriptedAppleTransport([
            .plist(["Response": challenge]),
            .plist(["Response": ["Status": ["ec": 0]]])
        ])
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-live-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diagnosticsURL) }
        let diagnostics = ApplePersonalTeamDiagnosticsStore(url: diagnosticsURL)
        let backend = LiveApplePersonalTeamBackend(
            transport: transport,
            machineIdentity: FixtureMachineIdentity(),
            sessionStore: MemoryAuthorizationSessionStore(),
            diagnostics: diagnostics
        )
        let coordinator = ExperimentalConsumerProvisioningCoordinator(backend: backend)
        let password = SensitiveInput("synthetic-password")
        do {
            _ = try await coordinator.begin(account: "fixture@example.invalid", password: password)
            XCTFail("Expected the synthetic response to stop before password acceptance")
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, .authenticationProtocolMismatch)
        }
        XCTAssertTrue(password.isEmpty)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        let initial = try XCTUnwrap(try parseApplePlist(XCTUnwrap(requests[0].httpBody)))
        let request = try XCTUnwrap(initial["Request"] as? [String: Any])
        XCTAssertEqual(request["o"] as? String, "init")
        XCTAssertEqual((request["A2k"] as? Data)?.count, 256)
        XCTAssertEqual(request["ps"] as? [String], ["s2k", "s2k_fo"])
        let checkpoints = diagnostics.load()?.events.compactMap(\.checkpoint) ?? []
        XCTAssertTrue(checkpoints.contains("APPLE_AUTH_STARTED"))
        XCTAssertTrue(checkpoints.contains("APPLE_AUTH_CHALLENGE_RECEIVED"))
        XCTAssertFalse(checkpoints.contains("APPLE_AUTH_PASSWORD_ACCEPTED"))
    }

    func testDiagnosticsAndRedactorNeverSerializeInjectedSecrets() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-redaction-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ApplePersonalTeamDiagnosticsStore(url: url)
        store.update(adapterVersion: "fixture-adapter") {
            $0.events.append(.init(
                timestamp: Date(), checkpoint: nil, stage: "xcodeScopedToken",
                safeErrorCode: "XCODE_SCOPED_TOKEN_FAILED", httpStatus: 503, appleErrorCode: nil,
                retryAfterSeconds: 30, retryable: true, reauthorizationRequired: false
            ))
        }
        let serialized = try String(contentsOf: url, encoding: .utf8)
        for secret in syntheticSecrets { XCTAssertFalse(serialized.contains(secret)) }

        let injection = """
        password=synthetic-password security-code=123456 token=synthetic-session-token
        Cookie=synthetic-cookie Authorization=BearerSynthetic X-Apple-GS-Token=gs-secret
        DSID=123456789 private_key=private-key-secret pairing-secret=pairing-material-secret
        -----BEGIN PRIVATE KEY----- synthetic-private-key -----END PRIVATE KEY-----
        """
        let redacted = Redactor.redact(injection)
        for secret in syntheticSecrets { XCTAssertFalse(redacted.contains(secret)) }
    }

    private var syntheticSecrets: [String] {
        ["synthetic-password", "123456", "synthetic-session-token", "synthetic-cookie", "gs-secret",
         "123456789", "private-key-secret", "pairing-material-secret", "synthetic-private-key"]
    }
}

private struct FixtureMachineIdentity: AppleMachineIdentityProviding {
    func headers(for request: URLRequest) async throws -> [String: String] {
        [
            "X-Apple-I-MD": "synthetic-md",
            "X-Apple-I-MD-M": "synthetic-mdm",
            "X-MMe-Client-Info": "<MacBookPro> <macOS;13.0;22A> <com.apple.AuthKit/1>"
        ]
    }
}

private actor ScriptedAppleTransport: AppleHTTPTransport {
    struct Response {
        let status: Int
        let headers: [AnyHashable: Any]
        let body: Data

        static func plist(_ value: Any, status: Int = 200, headers: [AnyHashable: Any] = [:]) -> Response {
            var merged = headers
            merged["Content-Type"] = "text/x-xml-plist"
            return Response(status: status, headers: merged, body: try! plistData(value))
        }
    }

    private var scripted: [Response]
    private var captured: [URLRequest] = []

    init(_ scripted: [Response]) { self.scripted = scripted }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppleHTTPResponse {
        captured.append(request)
        guard !scripted.isEmpty else { throw URLError(.badServerResponse) }
        let response = scripted.removeFirst()
        return AppleHTTPResponse(
            url: request.url!, statusCode: response.status, headers: response.headers, body: response.body
        )
    }

    func requests() -> [URLRequest] { captured }
}

private final class MemoryAuthorizationSessionStore: AppleAuthorizationSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: AppleAuthorizationSessionMetadata?
    private var payload: Data?

    init(session: AppleAuthorizationSession? = nil) {
        if let session {
            metadata = session.metadata
            payload = session.withOpaquePayload { Data($0) }
        }
    }

    func load() throws -> AppleAuthorizationSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let metadata, let payload else { return nil }
        return AppleAuthorizationSession(metadata: metadata, opaquePayload: payload)
    }

    func loadMetadata() throws -> AppleAuthorizationSessionMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return metadata
    }

    func save(_ session: AppleAuthorizationSession) throws {
        lock.lock()
        defer { lock.unlock() }
        metadata = session.metadata
        payload = session.withOpaquePayload { Data($0) }
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        metadata = nil
        payload = nil
    }
}

private func fixtureSession() -> AppleAuthorizationSession {
    let payload = try! PropertyListEncoder().encode(FixtureSessionEnvelope(
        dsid: "123456789",
        xcodeToken: "synthetic-session-token",
        tokenExpiresAt: Date().addingTimeInterval(3_600)
    ))
    return AppleAuthorizationSession(
        metadata: .init(
            accountFingerprint: "fixture-account-fingerprint",
            clientIdentityVersion: PrivateAppleProtocolAdapter.researched2026.version,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3_600)
        ),
        opaquePayload: payload
    )
}

private struct FixtureSessionEnvelope: Codable {
    let dsid: String
    let xcodeToken: String
    let tokenExpiresAt: Date?
}

private func teamResponse() -> [String: Any] {
    [
        "resultCode": 0,
        "teams": [[
            "teamId": "ABCDEFGHIJ", "name": "Fixture Personal Team", "type": "Individual",
            "memberships": [["name": "Free"]]
        ]]
    ]
}

private func plistData(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}
