import Foundation
import CommonCrypto
import CryptoKit
import Security
import XCTest
@testable import IOSSimMacCore

final class ApplePersonalTeamLiveTests: XCTestCase {
    func testGrandSlamClientIdentityUsesAKDInsteadOfBlockedXcodeIdentifier() {
        let value = LocalMacAppleMachineIdentityProvider.grandSlamClientInformation(
            model: "Mac15,7",
            osVersion: "26.0",
            build: "25A000"
        )

        XCTAssertEqual(
            value,
            "<Mac15,7> <macOS;26.0;25A000> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        )
        XCTAssertFalse(value.contains("com.apple.dt.Xcode"))
    }

    func testFinalGrandSlamIdentityNormalizerReplacesEveryUpstreamClientToken() throws {
        for upstream in [
            "<com.apple.AuthKit/1>",
            "<com.apple.dt.Xcode/23792>",
            "<com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        ] {
            let normalized = try GrandSlamRequestIdentity.normalizedClientInfo(
                "<Mac15,7> <macOS;26.0;25A000> \(upstream)"
            )
            XCTAssertEqual(
                normalized,
                "<Mac15,7> <macOS;26.0;25A000> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
            )
            XCTAssertEqual(GrandSlamRequestIdentity.classification(normalized), "akd")
            XCTAssertFalse(normalized.contains("com.apple.dt.Xcode"))
        }
        XCTAssertThrowsError(try GrandSlamRequestIdentity.normalizedClientInfo(nil))
        XCTAssertThrowsError(try GrandSlamRequestIdentity.normalizedClientInfo("Xcode/23792"))
        let headers = try GrandSlamRequestIdentity.normalizedMachineHeaders([
            "X-MMe-Client-Info": "<Mac> <macOS;26.0;25A> <com.apple.dt.Xcode/23792>",
            "Cookie": "must-not-survive",
            "Authorization": "must-not-survive",
            "X-Apple-I-MD": "structural-fixture"
        ])
        XCTAssertNil(headers["Cookie"])
        XCTAssertNil(headers["Authorization"])
        XCTAssertEqual(headers["X-Apple-I-MD"], "structural-fixture")
    }

    func testURLBagParsingSelectionCachingAndInvalidation() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = try plistData(["urls": [
            "gsService": "https://gsa.apple.com/grandslam/GsService2",
            "trustedDeviceSecondaryAuth": "https://gsa.apple.com/auth/verify/trusteddevice",
            "validateCode": "https://gsa.apple.com/grandslam/GsService2/validate"
        ]])
        let bag = try GrandSlamEndpointBag.parse(body, now: now, ttl: 900)
        XCTAssertEqual(try bag.endpoint(.validateCode).path, "/grandslam/GsService2/validate")
        XCTAssertEqual(bag.expiresAt, now.addingTimeInterval(900))

        let transport = ScriptedAppleTransport([])
        let resolver = URLBagGrandSlamEndpointResolver(transport: transport, now: { now })
        _ = try await resolver.endpoint(.gsService, machineHeaders: FixtureMachineIdentity.headers)
        _ = try await resolver.endpoint(.validateCode, machineHeaders: FixtureMachineIdentity.headers)
        let firstLookupCount = await transport.urlBagRequestCount()
        XCTAssertEqual(firstLookupCount, 1)
        await resolver.invalidate()
        _ = try await resolver.endpoint(.gsService, machineHeaders: FixtureMachineIdentity.headers)
        let secondLookupCount = await transport.urlBagRequestCount()
        XCTAssertEqual(secondLookupCount, 2)

        let wrongHost = try plistData(["urls": [
            "gsService": "https://example.invalid/grandslam",
            "trustedDeviceSecondaryAuth": "https://gsa.apple.com/auth/verify/trusteddevice",
            "validateCode": "https://gsa.apple.com/grandslam/GsService2/validate"
        ]])
        XCTAssertThrowsError(try GrandSlamEndpointBag.parse(wrongHost))
    }

    func testTrustedDeviceValidationUsesGETAndSixDigitHeader() throws {
        let request = try GrandSlamVerificationRequestBuilder.trustedDeviceValidation(
            endpoint: PrivateAppleProtocolAdapter.researched2026.verificationValidation,
            identityToken: "synthetic-identity",
            verificationCode: "123456"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "security-code"), "123456")
        XCTAssertThrowsError(try GrandSlamVerificationRequestBuilder.trustedDeviceValidation(
            endpoint: PrivateAppleProtocolAdapter.researched2026.verificationValidation,
            identityToken: "synthetic-identity",
            verificationCode: "12345x"
        ))
    }

    func testHTTPAndTransportFailuresRemainStructurallyDistinct() {
        XCTAssertEqual(AppleHTTPFailureClassifier.kind(status: 429, stage: "srpInit"), .rateLimited)
        XCTAssertEqual(AppleHTTPFailureClassifier.kind(status: 503, stage: "srpInit"), .serviceUnavailable)
        XCTAssertEqual(
            AppleHTTPFailureClassifier.kind(status: 503, stage: "srpInit", bodyKind: "plist-or-xml"),
            .clientMetadataRejected
        )
        XCTAssertEqual(AppleHTTPFailureClassifier.kind(status: 401, stage: "srpComplete"), .srpProofRejected)
        XCTAssertEqual(
            AppleHTTPFailureClassifier.kind(status: 401, stage: "validateVerification"),
            .twoFactorRejected
        )
        XCTAssertEqual(
            AppleTransportFailureClassifier.category(for: URLError(.cannotFindHost)), .dns
        )
        XCTAssertEqual(
            AppleTransportFailureClassifier.category(for: URLError(.secureConnectionFailed)), .tls
        )
        XCTAssertEqual(
            AppleTransportFailureClassifier.category(for: URLError(.notConnectedToInternet)), .unreachable
        )
    }

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

    func testM2MatchesAppleCoreCryptoFormulaAndRejectsMutation() throws {
        let client = try AppleSRPClient(randomBytes: Data((1...32).map(UInt8.init)))
        let challenge = try AppleSRPClient.parseChallenge([
            "sp": "s2k",
            "s": Data(repeating: 0x5a, count: 16),
            "i": 20_000,
            "B": Data(repeating: 0x7b, count: 256),
            "c": "synthetic-cookie"
        ])
        let proof = try client.proof(
            account: "fixture@example.invalid",
            password: Data("synthetic-password".utf8),
            challenge: challenge
        )
        let referenceM2 = Data(SHA256.hash(
            data: client.clientPublicKey + proof.clientProof + proof.sessionKey
        ))

        XCTAssertNoThrow(try AppleSRPClient.verifyServerProof(
            referenceM2,
            expected: proof.expectedServerProof
        ))
        var mutation = referenceM2
        mutation[mutation.startIndex] ^= 0x01
        XCTAssertThrowsError(try AppleSRPClient.verifyServerProof(
            mutation,
            expected: proof.expectedServerProof
        )) { error in
            XCTAssertEqual(error as? ExperimentalBackendError, .srpAuthFailed)
        }
    }

    func testNegotiationProofMatchesAltSignTranscriptWithAndWithoutSC() throws {
        let sessionKey = Data(0...31)
        let spd = Data(0...15)

        for sc in [Data([0xa1, 0xb2, 0xc3, 0xd4]), nil] as [Data?] {
            let np = referenceNegotiationProof(
                scheme: "s2k",
                spd: spd,
                sc: sc,
                sessionKey: sessionKey
            )
            var response: [String: Any] = ["spd": spd, "np": np]
            if let sc { response["sc"] = sc }

            XCTAssertNoThrow(try validateNegotiationProof(
                response: response,
                scheme: "s2k",
                sessionKey: sessionKey
            ))
        }
    }

    func testNegotiationProofRejectsMutation() throws {
        let sessionKey = Data(0...31)
        let spd = Data(0...15)
        var np = referenceNegotiationProof(
            scheme: "s2k",
            spd: spd,
            sc: nil,
            sessionKey: sessionKey
        )
        np[np.startIndex] ^= 0x01

        XCTAssertThrowsError(try validateNegotiationProof(
            response: ["spd": spd, "np": np],
            scheme: "s2k",
            sessionKey: sessionKey
        )) { error in
            XCTAssertEqual(error as? ExperimentalBackendError, .srpAuthFailed)
        }
    }

    func testFoundationPlistStatusIntegerBridging() throws {
        let data = try plistData([
            "false": false,
            "true": true,
            "integer": 200,
            "numericString": "0"
        ])
        let parsed = try XCTUnwrap(try parseApplePlist(data))

        XCTAssertEqual(integer(parsed["false"]), 0)
        XCTAssertEqual(integer(parsed["true"]), 1)
        XCTAssertEqual(integer(parsed["integer"]), 200)
        XCTAssertEqual(integer(parsed["numericString"]), 0)
        XCTAssertTrue(parsed["false"] is Bool)
        XCTAssertTrue(parsed["false"] is NSNumber)
    }

    func testSPDDecryptionMatchesReferenceAESCBCKDF() throws {
        let sessionKey = Data(0...31)
        let plaintext = try plistData(["fixture": "non-secret-value"])
        let encrypted = try referenceEncryptSPD(plaintext, sessionKey: sessionKey)
        let decrypted = try decryptCBC(encrypted, sessionKey: sessionKey)

        XCTAssertEqual(decrypted.count, plaintext.count)
        XCTAssertTrue(decrypted.elementsEqual(plaintext))
        XCTAssertEqual(try parseApplePlist(decrypted)?.keys.sorted(), ["fixture"])
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
        XCTAssertEqual(AppleHTTPFailureClassifier.error(status: 503, stage: "srpInit"), .serviceUnavailable)
        XCTAssertEqual(AppleHTTPFailureClassifier.error(status: 429, stage: "xcodeScopedToken"), .rateLimited)
    }

    func testSRPInitializationDiagnosticStopsAfterChallengeWithoutPassword() async throws {
        let challenge: [String: Any] = [
            "Status": ["ec": 0, "hsc": 200],
            "sp": "s2k",
            "s": Data(repeating: 1, count: 16),
            "i": 1_000,
            "B": Data(repeating: 2, count: 256),
            "c": "synthetic-cookie"
        ]
        let transport = ScriptedAppleTransport([.plist(["Response": challenge])])
        let backend = diagnosticBackend(transport: transport, diagnostics: temporaryDiagnostics().store)

        let result = await backend.diagnoseSRPInitialization(account: " Fixture.User@Example.Invalid ")

        XCTAssertEqual(result, .success)
        XCTAssertEqual(result.outputCode, "SRP_INIT_SUCCESS")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let root = try XCTUnwrap(try parseApplePlist(XCTUnwrap(requests[0].httpBody)))
        let request = try XCTUnwrap(root["Request"] as? [String: Any])
        XCTAssertEqual(request["u"] as? String, "fixture.user@example.invalid")
        XCTAssertEqual(request["o"] as? String, "init")
    }

    func testSRPInitializationDiagnosticClassifies503AndRecordsOnlySafeMetadata() async throws {
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let transport = ScriptedAppleTransport([.raw(
            status: 503,
            headers: [
                "Content-Type": "text/html",
                "Server": "Apple",
                "X-Apple-I-Retry-Request-UUID": "00000000-0000-4000-8000-000000000000"
            ],
            body: Data("<html>Service Temporarily Unavailable</html>".utf8)
        )])
        let backend = diagnosticBackend(transport: transport, diagnostics: diagnostics.store)

        let result = await backend.diagnoseSRPInitialization(account: "fixture@example.invalid")

        XCTAssertEqual(result, .http503)
        XCTAssertEqual(result.outputCode, "SRP_INIT_HTTP_503")
        let event = try XCTUnwrap(diagnostics.store.load()?.events.last)
        XCTAssertEqual(event.stage, "srpInitDiagnostic")
        XCTAssertEqual(event.safeErrorCode, "APPLE_SERVICE_UNAVAILABLE")
        XCTAssertEqual(event.httpStatus, 503)
        XCTAssertEqual(event.endpoint, "gsa.apple.com/grandslam/GsService2")
        XCTAssertEqual(event.httpMethod, "POST")
        XCTAssertEqual(event.responseContentType, "text/html")
        XCTAssertEqual(event.responseBodyKind, "html")
        XCTAssertEqual(event.serverIdentifier, "Apple")
        XCTAssertEqual(event.requestIdentifier, "sha256:db8055e0e0307d5a")
        let serialized = try String(contentsOf: diagnostics.url, encoding: .utf8)
        XCTAssertFalse(serialized.contains("Service Temporarily Unavailable"))
        XCTAssertFalse(serialized.contains("fixture@example.invalid"))
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

    func testManagedIdentityFirstCreationPersistsMatchingKeyAndCertificate() async throws {
        let synthetic = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let keychain = FixtureManagedIdentityKeychain(keysToCreate: [synthetic.privateKey])
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(certificateInventory([], available: 2)),
            .plist(certificateSubmission(synthetic.certificateData, serial: "FIRST"))
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeIdentityBackend(transport: transport, keychain: keychain, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        let identity = try await backend.prepareIdentity(team: .fixturePersonal)

        XCTAssertFalse(identity.reused)
        XCTAssertTrue(identity.pendingPromotion)
        XCTAssertEqual(keychain.createdKeyCount, 1)
        XCTAssertEqual(keychain.addedCertificateCount, 1)
        XCTAssertNil(keychain.metadata, "A new identity must remain a candidate before verified installation")
        XCTAssertNotNil(keychain.candidateMetadata?.certificateFingerprint)
        let savedTag = try XCTUnwrap(keychain.candidateMetadata?.keyApplicationTag)
        XCTAssertNotNil(keychain.candidateMetadata.flatMap {
            canonicalManagedKeyTag($0.keyApplicationTag, teamIdentifier: "ABCDEFGHIJ")
        })
        let retrieved = try XCTUnwrap(keychain.lookupPrivateKey(applicationTag: savedTag).key)
        XCTAssertTrue(publicKeysEqual(retrieved, synthetic.privateKey))
        XCTAssertTrue(diagnostics.store.load()?.events.contains(where: {
            $0.checkpoint == "PROVISIONING_PREPARATION_CONTINUED"
        }) == true)
        try keychain.promoteCandidate(teamIdentifier: "ABCDEFGHIJ")
        XCTAssertEqual(keychain.metadata?.keyApplicationTag, savedTag)
        XCTAssertNil(keychain.candidateMetadata)
    }

    func testManagedIdentityReusesValidCertificateAndMatchingPrivateKey() async throws {
        let synthetic = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let parsedCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, synthetic.certificateData as CFData))
        XCTAssertTrue(certificatePublicKeyMatchesPrivateKey(parsedCertificate, privateKey: synthetic.privateKey))
        XCTAssertEqual(certificateTeamIdentifiers(parsedCertificate), ["ABCDEFGHIJ"])
        XCTAssertGreaterThan(try XCTUnwrap(certificateExpiration(parsedCertificate)), Date())
        let tag = canonicalFixtureTag()
        let metadata = fixtureIdentityMetadata(tag: tag, certificate: synthetic, serial: "REUSE")
        let keychain = FixtureManagedIdentityKeychain(metadata: metadata, keys: [tag: synthetic.privateKey])
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(certificateInventory([
                certificateObject(synthetic.certificateData, serial: "REUSE")
            ], available: 2))
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeIdentityBackend(transport: transport, keychain: keychain, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        let identity = try await backend.prepareIdentity(team: .fixturePersonal)

        XCTAssertTrue(identity.reused)
        XCTAssertEqual(keychain.createdKeyCount, 0)
        XCTAssertEqual(keychain.authorizedTags, [tag], "Reused keys must have the packaged signing ACL repaired before helper use")
        XCTAssertEqual(keychain.addedCertificateCount, 1)
        let event = diagnostics.store.load()?.events.last(where: {
            $0.checkpoint == "CERTIFICATE_PUBLIC_KEY_MATCH"
        })
        XCTAssertEqual(event?.continuity?["certificatePublicKeyMatchesPrivateKey"], true)
    }

    func testProvisionalManagedMetadataResumesCSRWithExistingPrivateKey() async throws {
        let synthetic = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = canonicalFixtureTag()
        let keychain = FixtureManagedIdentityKeychain(
            metadata: fixtureIdentityMetadata(tag: tag),
            keys: [tag: synthetic.privateKey]
        )
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(certificateInventory([], available: 2)),
            .plist(certificateSubmission(synthetic.certificateData, serial: "RECOVERED"))
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeIdentityBackend(transport: transport, keychain: keychain, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        let identity = try await backend.prepareIdentity(team: .fixturePersonal)

        XCTAssertFalse(identity.reused)
        XCTAssertEqual(keychain.createdKeyCount, 0, "Recovery must reuse the existing permanent IOSSim key")
        XCTAssertEqual(keychain.authorizedTags, [tag])
        XCTAssertEqual(keychain.metadata?.keyApplicationTag, tag)
        XCTAssertNil(keychain.metadata?.certificateFingerprint)
        XCTAssertNotNil(keychain.candidateMetadata?.certificateFingerprint)
        XCTAssertTrue(diagnostics.store.load()?.events.contains(where: {
            $0.checkpoint == "MANAGED_IDENTITY_RECOVERY_SUCCEEDED"
        }) == true)
    }

    func testMissingManagedPrivateKeyCreatesOnlyFreshIOSSimMapping() async throws {
        let synthetic = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let staleCertificate = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let staleTag = canonicalFixtureTag()
        let unrelatedTag = Data("com.example.unrelated.signing-key".utf8)
        let historicalTag = canonicalFixtureTag()
        let unrelated = try SyntheticDevelopmentIdentity(teamIdentifier: "ZZZZZZZZZZ")
        let keychain = FixtureManagedIdentityKeychain(
            metadata: fixtureIdentityMetadata(tag: staleTag, certificate: staleCertificate, serial: "STALE"),
            keys: [
                unrelatedTag: unrelated.privateKey,
                historicalTag: staleCertificate.privateKey
            ],
            keysToCreate: [synthetic.privateKey]
        )
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(certificateInventory([
                certificateObject(staleCertificate.certificateData, serial: "STALE")
            ], available: 2)),
            .plist(certificateSubmission(synthetic.certificateData, serial: "NEWKEY"))
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeIdentityBackend(transport: transport, keychain: keychain, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        _ = try await backend.prepareIdentity(team: .fixturePersonal)

        XCTAssertEqual(keychain.createdKeyCount, 1)
        XCTAssertEqual(keychain.metadata?.keyApplicationTag, staleTag)
        XCTAssertNotEqual(keychain.candidateMetadata?.keyApplicationTag, staleTag)
        XCTAssertNotNil(keychain.keys[unrelatedTag], "Unrelated signing keys must remain untouched")
        XCTAssertNotNil(keychain.keys[historicalTag], "Historical IOSSim keys must remain untouched")
        XCTAssertTrue(keychain.deletedTags.isEmpty)
        let requests = await transport.requests()
        XCTAssertFalse(requests.contains { request in
            let path = request.url?.path.lowercased() ?? ""
            return path.contains("revoke") || path.contains("delete")
        })
        let missing = diagnostics.store.load()?.events.last(where: { $0.checkpoint == "PRIVATE_KEY_MISSING" })
        XCTAssertEqual(missing?.osStatus, Int(errSecItemNotFound))
    }

    func testPrivateKeyAccessFailureDoesNotCreateOrReplaceManagedIdentity() async throws {
        let staleTag = canonicalFixtureTag()
        let keychain = FixtureManagedIdentityKeychain(
            metadata: fixtureIdentityMetadata(tag: staleTag),
            missingKeyStatus: errSecInteractionNotAllowed
        )
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(certificateInventory([], available: 2))
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeIdentityBackend(transport: transport, keychain: keychain, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        do {
            _ = try await backend.prepareIdentity(team: .fixturePersonal)
            XCTFail("Expected inaccessible Keychain item to stop recovery")
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, .missingPrivateKey)
        }
        XCTAssertEqual(keychain.createdKeyCount, 0)
        XCTAssertEqual(keychain.metadata?.keyApplicationTag, staleTag)
        XCTAssertTrue(keychain.deletedTags.isEmpty)
    }

    func testUnrepairableLegacySigningACLAutomaticallyCreatesUsableIOSSimIdentity() async throws {
        let legacy = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let replacement = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let legacyTag = canonicalFixtureTag()
        let keychain = FixtureManagedIdentityKeychain(
            metadata: fixtureIdentityMetadata(tag: legacyTag, certificate: legacy, serial: "LEGACY"),
            keys: [legacyTag: legacy.privateKey],
            keysToCreate: [replacement.privateKey],
            authorizationFailure: .missingPrivateKey
        )
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(certificateInventory([
                certificateObject(legacy.certificateData, serial: "LEGACY")
            ], available: 2)),
            .plist(certificateSubmission(replacement.certificateData, serial: "REPLACEMENT"))
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeIdentityBackend(transport: transport, keychain: keychain, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        let identity = try await backend.prepareIdentity(team: .fixturePersonal)

        XCTAssertFalse(identity.reused)
        XCTAssertEqual(keychain.createdKeyCount, 1)
        XCTAssertEqual(keychain.metadata?.keyApplicationTag, legacyTag)
        XCTAssertNotEqual(keychain.candidateMetadata?.keyApplicationTag, legacyTag)
        XCTAssertNotNil(keychain.keys[legacyTag], "Recovery must not delete the consumer's legacy key")
        XCTAssertTrue(diagnostics.store.load()?.events.contains(where: {
            $0.checkpoint == "MANAGED_IDENTITY_RECOVERY_SUCCEEDED"
        }) == true)
    }

    func testMismatchedCertificatePublicKeyIsRejectedWithoutDeletingAnyIdentity() async throws {
        let managed = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let mismatched = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = canonicalFixtureTag()
        let keychain = FixtureManagedIdentityKeychain(
            metadata: fixtureIdentityMetadata(tag: tag),
            keys: [tag: managed.privateKey]
        )
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(certificateInventory([], available: 2)),
            .plist(certificateSubmission(mismatched.certificateData, serial: "WRONG")),
            .plist(certificateInventory([], available: 1))
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeIdentityBackend(transport: transport, keychain: keychain, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        do {
            _ = try await backend.prepareIdentity(team: .fixturePersonal)
            XCTFail("Expected mismatched certificate rejection")
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, .certificateRequestFailed)
        }
        XCTAssertTrue(keychain.deletedTags.isEmpty)
        XCTAssertNil(keychain.metadata?.certificateFingerprint)
        let mismatch = diagnostics.store.load()?.events.last(where: {
            $0.checkpoint == "CERTIFICATE_PUBLIC_KEY_MATCH"
        })
        XCTAssertEqual(mismatch?.continuity?["certificatePublicKeyMatchesPrivateKey"], false)
    }

    func testManagedKeychainPersistsCanonicalPrivateKeyAcrossStoreInstances() throws {
        let identifier = UUID().uuidString.uppercased()
        let service = "com.iossim.tests.personal-team-signing.\(identifier)"
        let team = "ABCDEFGHIJ"
        let tag = Data("com.iossim.personal-team.\(team).\(identifier)".utf8)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: team
            ] as CFDictionary)
            SecItemDelete([
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
            ] as CFDictionary)
        }

        let first = IOSSimIdentityMetadataStore(service: service, keyLabel: "IOSSim Test Signing Key")
        let key = try first.createPrivateKey(applicationTag: tag)
        try first.save(fixtureIdentityMetadata(tag: tag))
        let restarted = IOSSimIdentityMetadataStore(service: service, keyLabel: "IOSSim Test Signing Key")
        let lookup = restarted.lookupPrivateKey(applicationTag: tag)

        XCTAssertEqual(lookup.status, errSecSuccess)
        XCTAssertNotNil(lookup.key)
        XCTAssertEqual(try restarted.load(teamIdentifier: team)?.keyApplicationTag, tag)
        XCTAssertFalse(try restarted.persistentReference(applicationTag: tag).isEmpty)
        XCTAssertNotNil(canonicalManagedKeyTag(tag, teamIdentifier: team))
        XCTAssertTrue(publicKeysEqual(key, lookup.key!))
    }

    func testSigningKeyAccessPolicyUsesThePackagedMacOSHelperLocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-signing-policy-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("IOSSim.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let app = macOS.appendingPathComponent("IOSSim")
        let helper = macOS.appendingPathComponent("IOSSimProvisioner")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data().write(to: app)
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let policy = IOSSimSigningKeyAccessPolicy(
            bundleURL: bundle,
            bundleExecutableName: "IOSSim"
        )

        XCTAssertEqual(policy.trustedExecutablePaths, [
            "/usr/bin/codesign",
            app.path,
            helper.path,
        ])
        XCTAssertFalse(policy.trustedExecutablePaths.contains(where: { $0.contains("Contents/Helpers") }))
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

    func testResponseShapeChangePreservesStoredSessionAndReportsProtocolMismatch() async throws {
        let transport = ScriptedAppleTransport([
            .plist(["resultCode": 0, "teams": [["unexpected": "shape"]]])
        ])
        let store = MemoryAuthorizationSessionStore(session: fixtureSession())
        let backend = LiveApplePersonalTeamBackend(
            transport: transport,
            machineIdentity: FixtureMachineIdentity(),
            sessionStore: store,
            diagnostics: ApplePersonalTeamDiagnosticsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("iossim-live-test-\(UUID().uuidString).json"))
        )

        do {
            _ = try await backend.resumeSession()
            XCTFail("expected protocol mismatch")
        } catch let error as ExperimentalBackendError {
            XCTAssertEqual(error, .authenticationProtocolMismatch)
        }
        XCTAssertNotNil(try store.loadMetadata())
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
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

    func testExistingRegisteredDeviceIsReusedWithoutAddIncludingNormalization() async throws {
        for returned in ["00008150-00022D581E12401C", " 0000815000022d581e12401c \n"] {
            let transport = ScriptedAppleTransport([
                .plist(teamResponse()),
                .plist(["resultCode": 0, "devices": [["deviceNumber": returned]]])
            ])
            let diagnostics = temporaryDiagnostics()
            defer { try? FileManager.default.removeItem(at: diagnostics.url) }
            let backend = makeRegistrationBackend(transport: transport, diagnostics: diagnostics.store)
            _ = try await backend.resumeSession()

            try await backend.registerDevice(.physicalFixture, team: .fixturePersonal)

            let requests = await transport.requests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/ios/addDevice.action") == true })
            let events = try XCTUnwrap(diagnostics.store.load()?.events)
            XCTAssertTrue(events.contains { $0.checkpoint == "DEVICE_ALREADY_REGISTERED" })
            XCTAssertEqual(events.last { $0.checkpoint == "REGISTERED_DEVICE_MATCH_RESULT" }?.continuity?["matched"], true)
        }
    }

    func testRegisteredDeviceInventoryRejectsNonStringIdentifierWithoutAdding() async throws {
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(["resultCode": 0, "devices": [["deviceNumber": Data([1, 2, 3])]]])
        ])
        let backend = makeRegistrationBackend(transport: transport, diagnostics: temporaryDiagnostics().store)
        _ = try await backend.resumeSession()

        await assertAsyncThrows({
            try await backend.registerDevice(.physicalFixture, team: .fixturePersonal)
        }) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .responseChanged)
        }

        let requests = await transport.requests()
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/ios/addDevice.action") == true })
    }

    func testNewDeviceUsesPhysicalUDIDAndExactReferencePlistTypes() async throws {
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(["resultCode": 0, "devices": []]),
            .plist(["resultCode": 0, "device": ["deviceNumber": "00008150-00022D581E12401C"]])
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeRegistrationBackend(transport: transport, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        try await backend.registerDevice(.physicalFixture, team: .fixturePersonal)

        let requests = await transport.requests()
        let add = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/ios/addDevice.action") == true })
        let body = try XCTUnwrap(try parseApplePlist(XCTUnwrap(add.httpBody)))
        XCTAssertEqual(body["deviceNumber"] as? String, "00008150-00022D581E12401C")
        XCTAssertEqual(body["name"] as? String, "Rishi Borra")
        XCTAssertEqual(body["teamId"] as? String, "ABCDEFGHIJ")
        XCTAssertEqual(Set(body.keys), Set(["clientId", "protocolVersion", "requestId", "teamId", "deviceNumber", "name", "userLocale"]))
        XCTAssertEqual(safeFieldTypes(body), [
            "clientId": "String", "protocolVersion": "String", "requestId": "String",
            "teamId": "String", "deviceNumber": "String", "name": "String",
            "userLocale": "Array<String>"
        ])
        let prepared = diagnostics.store.load()?.events.last {
            $0.checkpoint == "DEVICE_REGISTRATION_REQUEST_PREPARED"
        }
        XCTAssertEqual(prepared?.deviceIdentifierSource, "physicalUDID")
        XCTAssertEqual(prepared?.structuralLengths?["deviceIdentifierLength"], 25)
        XCTAssertEqual(prepared?.structuralLengths?["deviceNameLength"], 11)
        XCTAssertEqual(prepared?.continuity?["authorizedTeamMatchesAddDeviceTeam"], true)
        XCTAssertEqual(prepared?.continuity?["deviceNamePresent"], true)
        XCTAssertEqual(prepared?.continuity?["deviceNameWhitespaceOnly"], false)
    }

    func testDeviceNameValidationRejectsMissingEmptyAndWhitespaceButAcceptsValidName() throws {
        XCTAssertThrowsError(try validatedDeviceName(nil)) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .deviceNameRequired)
        }
        XCTAssertThrowsError(try validatedDeviceName("")) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .deviceNameRequired)
        }
        XCTAssertThrowsError(try validatedDeviceName(" \t\n")) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .deviceNameRequired)
        }
        XCTAssertEqual(try validatedDeviceName("Fixture iPhone !"), "Fixture iPhone")
    }

    func testCoreDeviceUUIDIsRejectedWhilePhysicalUDIDIsAccepted() throws {
        XCTAssertThrowsError(try validatedDeviceRegistrationIdentifier(
            "812EB0E1-DB40-5E49-9347-08079A74CBAF", source: .coreDeviceIdentifier
        )) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .invalidDeviceIdentifier)
        }
        XCTAssertThrowsError(try validatedDeviceRegistrationIdentifier("not-a-udid", source: .other))
        XCTAssertEqual(
            try validatedDeviceRegistrationIdentifier("00008150-00022d581e12401c", source: .physicalUDID),
            "00008150-00022D581E12401C"
        )
    }

    func testAuthorizedTeamContinuityRejectsStaleHistoricalTeamBeforeDeviceRequest() async throws {
        let transport = ScriptedAppleTransport([.plist(teamResponse())])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeRegistrationBackend(transport: transport, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()
        let stale = ExperimentalAppleTeam(
            id: "5337SALD55", name: "Historical", isPersonalTeam: true, isPaidDeveloperTeam: false
        )

        await assertAsyncThrows({ try await backend.registerDevice(.physicalFixture, team: stale) }) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .invalidTeam)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let rejected = diagnostics.store.load()?.events.last { $0.checkpoint == "DEVICE_REGISTRATION_REJECTED" }
        XCTAssertEqual(rejected?.safeErrorCode, "INVALID_TEAM")
        XCTAssertEqual(rejected?.continuity?["authorizedTeamMatchesAddDeviceTeam"], false)
    }

    func testAuthorizedTeamPropagatesThroughDeviceAppIDAndProfileRequests() async throws {
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: "ABCDEFGHIJ")
        let appIDs = [identifiers.main, identifiers.uiTests, identifiers.runner].enumerated().map { index, bundle in
            ["appIdId": "app-\(index)", "identifier": bundle]
        }
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(["resultCode": 0, "devices": [["deviceNumber": "00008150-00022D581E12401C"]]]),
            .plist(["resultCode": 0, "appIds": appIDs, "availableQuantity": 5]),
            .plist(["resultCode": 0, "provisioningProfile": ["encodedProfile": Data([1, 2, 3])]])
        ])
        let backend = makeRegistrationBackend(transport: transport, diagnostics: temporaryDiagnostics().store)
        _ = try await backend.resumeSession()
        try await backend.registerDevice(.physicalFixture, team: .fixturePersonal)
        try await backend.registerIdentifiers(identifiers, team: .fixturePersonal)
        let identity = ExperimentalSigningIdentity(
            certificateFingerprint: String(repeating: "A", count: 64),
            certificateExpiration: Date().addingTimeInterval(86_400),
            privateKeyPersistentReference: Data([1]),
            reused: true
        )
        await assertAsyncThrows({
            try await backend.obtainProfiles(
                identifiers: identifiers,
                identity: identity,
                request: .physicalFixture,
                team: .fixturePersonal
            )
        }) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .invalidProfile)
        }

        let requests = await transport.requests()
        let teamBodies = try requests.dropFirst().map { request -> [String: Any] in
            try XCTUnwrap(try parseApplePlist(XCTUnwrap(request.httpBody)))
        }
        XCTAssertTrue(teamBodies.allSatisfy { $0["teamId"] as? String == "ABCDEFGHIJ" })
        XCTAssertFalse(teamBodies.contains { $0["teamId"] as? String == "5337SALD55" })
        XCTAssertTrue(requests.contains {
            $0.url?.path.hasSuffix("/ios/downloadTeamProvisioningProfile.action") == true
        })
    }

    func testCode35AlreadyRegisteredRelistsVerifiesAndReuses() async throws {
        let device = ["deviceNumber": "00008150-00022D581E12401C"]
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(["resultCode": 0, "devices": []]),
            .plist(["resultCode": 35, "userString": "Device is already registered."]),
            .plist(["resultCode": 0, "devices": [device]])
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeRegistrationBackend(transport: transport, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()

        try await backend.registerDevice(.physicalFixture, team: .fixturePersonal)

        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/ios/addDevice.action") == true }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/ios/listDevices.action") == true }.count, 2)
        XCTAssertTrue(diagnostics.store.load()?.events.contains {
            $0.checkpoint == "DEVICE_REGISTRATION_RECONCILIATION_STARTED"
                && $0.safeErrorCode == "ALREADY_REGISTERED"
        } == true)
    }

    func testSameCode35MessagesHaveDistinctClassificationsAndMissingNameIsNotDuplicate() async throws {
        XCTAssertEqual(classifyDeviceRegistrationRejection(
            code: 35, response: ["userString": "Device is already registered."]
        ), .alreadyRegistered)
        XCTAssertEqual(classifyDeviceRegistrationRejection(
            code: 35, response: ["userString": "No value was provided for the parameter 'name'."]
        ), .missingRequiredField)
        XCTAssertEqual(classifyDeviceRegistrationRejection(
            code: 35, response: ["userString": "An invalid value was provided for the parameter 'deviceNumber'."]
        ), .invalidDeviceIdentifier)

        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(["resultCode": 0, "devices": []]),
            .plist(["resultCode": 35, "userString": "No value was provided for the parameter 'name'."])
        ])
        let diagnostics = temporaryDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagnostics.url) }
        let backend = makeRegistrationBackend(transport: transport, diagnostics: diagnostics.store)
        _ = try await backend.resumeSession()
        await assertAsyncThrows({ try await backend.registerDevice(.physicalFixture, team: .fixturePersonal) }) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .deviceNameRequired)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter {
            $0.url?.path.hasSuffix("/ios/listDevices.action") == true
        }.count, 1, "Malformed requests must not be reconciled as duplicates")
        let response = diagnostics.store.load()?.events.last {
            $0.checkpoint == "DEVICE_REGISTRATION_RESPONSE_RECEIVED"
        }
        XCTAssertEqual(response?.safeErrorCode, "MISSING_REQUIRED_FIELD")
        XCTAssertEqual(response?.safeMessagePresent, true)
        XCTAssertEqual(response?.safeServerMessage, "No value was provided for the parameter 'name'.")
        XCTAssertEqual(response?.fieldTypes?["resultCode"], "Number")
        XCTAssertEqual(response?.fieldTypes?["userString"], "String")
        XCTAssertEqual(Set(response?.responseFieldNames ?? []), Set(["resultCode", "userString"]))
    }

    func testCapacityExceededAndHTTP200ApplicationFailureNeverDeleteDevices() async throws {
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(["resultCode": 0, "devices": []]),
            .plist(["resultCode": 35, "userString": "Maximum device limit reached."])
        ])
        let backend = makeRegistrationBackend(transport: transport, diagnostics: temporaryDiagnostics().store)
        _ = try await backend.resumeSession()
        await assertAsyncThrows({ try await backend.registerDevice(.physicalFixture, team: .fixturePersonal) }) {
            XCTAssertEqual($0 as? ExperimentalBackendError, .deviceLimit)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/ios/addDevice.action") == true }.count, 1)
        XCTAssertFalse(requests.contains {
            let path = $0.url?.path.lowercased() ?? ""
            return path.contains("delete") || path.contains("remove") || path.contains("disable")
        })
    }

    func testAmbiguousAddResponseRelistsBeforeRetryAndAvoidsDuplicateSideEffects() async throws {
        let transport = ScriptedAppleTransport([
            .plist(teamResponse()),
            .plist(["resultCode": 0, "devices": []]),
            .plist(["resultCode": 0], status: 503),
            .plist(["resultCode": 0, "devices": [["deviceNumber": "00008150-00022D581E12401C"]]])
        ])
        let backend = makeRegistrationBackend(transport: transport, diagnostics: temporaryDiagnostics().store)
        _ = try await backend.resumeSession()

        try await backend.registerDevice(.physicalFixture, team: .fixturePersonal)

        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/ios/addDevice.action") == true }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/ios/listDevices.action") == true }.count, 2)
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

    func testHTTP200Minus22406IsApplicationCredentialRejection() async throws {
        let challenge: [String: Any] = [
            "Status": ["ec": 0, "hsc": 200],
            "sp": "s2k_fo",
            "s": Data(repeating: 1, count: 16),
            "i": 1_000,
            "B": Data(repeating: 2, count: 256),
            "c": "fixture-cookie",
            "ptxid": "synthetic-transaction-id"
        ]
        let transport = ScriptedAppleTransport([
            .plist(["Response": challenge]),
            .plist(["Response": [
                "Status": [
                    "ec": -22406,
                    "hsc": 401,
                    "em": "Enter the correct password for this Apple Account."
                ]
            ]], status: 200)
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
        let password = SensitiveInput("synthetic-password")

        do {
            _ = try await backend.beginAuthorization(
                account: "fixture.user@example.invalid",
                password: password
            )
            XCTFail("Expected the replayed GrandSlam credential rejection")
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, .badPassword)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        let completeRoot = try XCTUnwrap(try parseApplePlist(XCTUnwrap(requests[1].httpBody)))
        let complete = try XCTUnwrap(completeRoot["Request"] as? [String: Any])
        XCTAssertEqual(complete["o"] as? String, "complete")
        XCTAssertEqual((complete["M1"] as? Data)?.count, 32)
        XCTAssertEqual(complete["c"] as? String, "fixture-cookie")
        XCTAssertNil(complete["ptxid"])
        let initialRoot = try XCTUnwrap(try parseApplePlist(XCTUnwrap(requests[0].httpBody)))
        let initialRequest = try XCTUnwrap(initialRoot["Request"] as? [String: Any])
        XCTAssertEqual(initialRequest["u"] as? String, complete["u"] as? String)
        XCTAssertEqual(
            initialRequest["cpd"] as? NSDictionary,
            complete["cpd"] as? NSDictionary
        )
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "X-Apple-I-MD"),
            requests[1].value(forHTTPHeaderField: "X-Apple-I-MD")
        )
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "X-Apple-I-MD-M"),
            requests[1].value(forHTTPHeaderField: "X-Apple-I-MD-M")
        )

        let events = try XCTUnwrap(diagnostics.load()?.events)
        XCTAssertEqual(events.compactMap(\.checkpoint), [
            "APPLE_AUTH_STARTED",
            "APPLE_AUTH_CHALLENGE_RECEIVED"
        ])
        let failure = try XCTUnwrap(events.last)
        XCTAssertEqual(failure.stage, "authentication")
        XCTAssertEqual(failure.safeErrorCode, "APPLE_AUTH_REJECTED")
        XCTAssertEqual(failure.httpStatus, 200)
        XCTAssertEqual(failure.appleErrorCode, -22406)
        XCTAssertFalse(failure.retryable)
        XCTAssertTrue(failure.reauthorizationRequired)

        let initStructure = try XCTUnwrap(events.first(where: { $0.stage == "srpInit" }))
        XCTAssertEqual(initStructure.srpProtocol, "s2k_fo")
        XCTAssertEqual(initStructure.srpVersion, "1.0.1")
        XCTAssertEqual(initStructure.structuralLengths, ["A": 256, "B": 256, "salt": 16])
        XCTAssertEqual(initStructure.requestFieldNames, ["A2k", "cpd", "o", "ps", "u"])
        XCTAssertEqual(initStructure.challengeFieldNames, ["B", "Status", "c", "i", "ptxid", "s", "sp"])
        XCTAssertNil(initStructure.responseFieldNames)
        XCTAssertEqual(initStructure.httpStatus, 200)
        XCTAssertEqual(initStructure.appleErrorCode, 0)
        XCTAssertEqual(initStructure.responseStatusCode, 200)
        XCTAssertEqual(initStructure.nonSecretIntegers, ["iterations": 1_000])
        XCTAssertEqual(initStructure.fieldTypes?["request.A2k"], "Data")
        XCTAssertEqual(initStructure.fieldTypes?["request.ps"], "Array<String>")
        XCTAssertEqual(initStructure.fieldTypes?["request.cpd"], "Dictionary")
        XCTAssertEqual(initStructure.fieldTypes?["response.B"], "Data")
        XCTAssertEqual(initStructure.fieldTypes?["response.s"], "Data")
        XCTAssertEqual(initStructure.fieldTypes?["response.i"], "Number")
        XCTAssertEqual(initStructure.fieldTypes?["response.ptxid"], "String")

        let derivation = try XCTUnwrap(events.first(where: { $0.stage == "srpDerivation" }))
        XCTAssertEqual(derivation.srpProtocol, "s2k_fo")
        XCTAssertEqual(derivation.nonSecretIntegers, ["iterations": 1_000])
        XCTAssertEqual(derivation.structuralLengths?["modulus"], 256)
        XCTAssertEqual(derivation.structuralLengths?["paddedGenerator"], 256)
        XCTAssertEqual(derivation.structuralLengths?["paddedA"], 256)
        XCTAssertEqual(derivation.structuralLengths?["paddedB"], 256)
        XCTAssertEqual(derivation.structuralLengths?["passwordPreprocessing"], 64)
        XCTAssertEqual(derivation.structuralLengths?["pbkdf2Output"], 32)
        XCTAssertEqual(derivation.structuralLengths?["xDigest"], 32)
        XCTAssertEqual(derivation.structuralLengths?["sharedPadded"], 256)
        XCTAssertEqual(derivation.structuralLengths?["sessionKey"], 32)

        let completeStructure = try XCTUnwrap(events.first(where: { $0.stage == "srpComplete" }))
        XCTAssertEqual(completeStructure.srpProtocol, "s2k_fo")
        XCTAssertEqual(completeStructure.srpVersion, "1.0.1")
        XCTAssertEqual(completeStructure.structuralLengths, ["M1": 32])
        XCTAssertEqual(completeStructure.requestFieldNames, ["M1", "c", "cpd", "o", "u"])
        XCTAssertNil(completeStructure.challengeFieldNames)
        XCTAssertEqual(completeStructure.responseFieldNames, ["Status"])
        XCTAssertEqual(completeStructure.httpStatus, 200)
        XCTAssertEqual(completeStructure.appleErrorCode, -22406)
        XCTAssertEqual(completeStructure.responseStatusCode, 401)
        XCTAssertEqual(completeStructure.fieldTypes?["request.M1"], "Data")
        XCTAssertEqual(completeStructure.fieldTypes?["request.c"], "String")
        XCTAssertEqual(completeStructure.fieldTypes?["request.cpd"], "Dictionary")
        XCTAssertEqual(completeStructure.responseStatusFieldNames, ["ec", "em", "hsc"])
        XCTAssertEqual(completeStructure.safeServerMessage, "Enter the correct password for this Apple Account.")
        XCTAssertEqual(completeStructure.continuity, [
            "challengeTokenPresent": true,
            "cpdPresent": true,
            "cpdStable": true,
            "anisetteHeadersStable": true,
            "usernameStable": true,
            "srpInstanceStable": true,
            "ptxidSent": false,
            "httpCookiePersistenceEnabled": false
        ])
    }

    func testMixedCaseAccountIsCanonicalizedForEntireSRPExchange() async throws {
        let challenge: [String: Any] = [
            "Status": ["ec": 0, "hsc": 200],
            "sp": "s2k",
            "s": Data(repeating: 1, count: 16),
            "i": 1_000,
            "B": Data(repeating: 2, count: 256),
            "c": "fixture-cookie"
        ]
        let transport = ScriptedAppleTransport([
            .plist(["Response": challenge]),
            .plist(["Response": ["Status": ["ec": 0, "hsc": 200]]])
        ])
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-live-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diagnosticsURL) }
        let backend = LiveApplePersonalTeamBackend(
            transport: transport,
            machineIdentity: FixtureMachineIdentity(),
            sessionStore: MemoryAuthorizationSessionStore(),
            diagnostics: ApplePersonalTeamDiagnosticsStore(url: diagnosticsURL)
        )

        do {
            _ = try await backend.beginAuthorization(
                account: "  Fixture.User@Example.Invalid  ",
                password: SensitiveInput("synthetic-password")
            )
            XCTFail("Expected the synthetic success envelope to stop before M2 validation")
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, .authenticationProtocolMismatch)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let root = try XCTUnwrap(try parseApplePlist(XCTUnwrap(request.httpBody)))
            let parameters = try XCTUnwrap(root["Request"] as? [String: Any])
            XCTAssertEqual(parameters["u"] as? String, "fixture.user@example.invalid")
        }
    }

    func testSuccessfulCompleteWithBooleanStatusAdvancesToTwoFactor() async throws {
        let account = "fixture@example.invalid"
        let passwordBytes = Data("synthetic-password".utf8)
        let randomBytes = Data((1...32).map(UInt8.init))
        let challenge: [String: Any] = [
            "Status": ["ec": false, "hsc": 200],
            "sp": "s2k",
            "s": Data(repeating: 0x5a, count: 16),
            "i": 20_000,
            "B": Data(repeating: 0x7b, count: 256),
            "c": "synthetic-cookie",
            "ptxid": "synthetic-transaction-id"
        ]
        let client = try AppleSRPClient(randomBytes: randomBytes)
        let proof = try client.proof(
            account: account,
            password: passwordBytes,
            challenge: AppleSRPClient.parseChallenge(challenge)
        )
        let spdPlaintext = try plistData([
            "adsid": "123456789",
            "GsIdmsToken": "synthetic-idms-token"
        ])
        let encryptedSPD = try referenceEncryptSPD(spdPlaintext, sessionKey: proof.sessionKey)
        let np = referenceNegotiationProof(
            scheme: "s2k",
            spd: encryptedSPD,
            sc: nil,
            sessionKey: proof.sessionKey
        )
        let transport = ScriptedAppleTransport([
            .plist(["Response": challenge]),
            .plist(["Response": [
                "M2": proof.expectedServerProof,
                "Status": ["ec": false, "hsc": 200, "au": "trustedDeviceSecondaryAuth"],
                "np": np,
                "ptxid": "synthetic-transaction-id",
                "spd": encryptedSPD
            ]]),
            .empty()
        ])
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-live-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diagnosticsURL) }
        let diagnostics = ApplePersonalTeamDiagnosticsStore(url: diagnosticsURL)
        let backend = LiveApplePersonalTeamBackend(
            transport: transport,
            machineIdentity: FixtureMachineIdentity(),
            sessionStore: MemoryAuthorizationSessionStore(),
            diagnostics: diagnostics,
            srpRandomBytesForTesting: randomBytes
        )

        let result = try await backend.beginAuthorization(
            account: account,
            password: SensitiveInput(data: passwordBytes)
        )
        guard case .verificationRequired(let verification) = result else {
            return XCTFail("Expected a trusted-device verification transition")
        }
        XCTAssertEqual(verification.method, .trustedDevice)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 3)
        let completeRoot = try XCTUnwrap(try parseApplePlist(XCTUnwrap(requests[1].httpBody)))
        let complete = try XCTUnwrap(completeRoot["Request"] as? [String: Any])
        XCTAssertTrue((complete["M1"] as? Data)?.elementsEqual(proof.clientProof) == true)

        let events = try XCTUnwrap(diagnostics.load()?.events)
        for stage in [
            "SRP_COMPLETE_ACCEPTED",
            "M2_RECEIVED",
            "M2_VERIFIED",
            "NEGOTIATION_PROOF_RECEIVED",
            "NEGOTIATION_PROOF_VERIFIED",
            "SPD_DECRYPTION_STARTED",
            "SPD_DECRYPTION_SUCCEEDED",
            "SPD_PARSED",
            "TWO_FACTOR_REQUIRED"
        ] {
            XCTAssertTrue(events.contains(where: { $0.stage == stage }), "Missing safe stage \(stage)")
        }
        let m2Event = try XCTUnwrap(events.first(where: { $0.stage == "M2_VERIFIED" }))
        XCTAssertEqual(m2Event.structuralLengths?["serverM2"], 32)
        XCTAssertEqual(m2Event.structuralLengths?["localM2"], 32)
        XCTAssertEqual(m2Event.continuity?["serverM2Present"], true)
        XCTAssertEqual(m2Event.continuity?["m2Match"], true)
        let parsedEvent = try XCTUnwrap(events.first(where: { $0.stage == "SPD_PARSED" }))
        XCTAssertEqual(parsedEvent.responseFieldNames, ["GsIdmsToken", "adsid"])
        XCTAssertEqual(parsedEvent.continuity?["spdPlistDecoded"], true)
        let serializedDiagnostics = try String(contentsOf: diagnosticsURL, encoding: .utf8)
        for secret in syntheticSecrets {
            XCTAssertFalse(serializedDiagnostics.contains(secret))
        }
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
         "synthetic-idms-token", "123456789", "private-key-secret", "pairing-material-secret",
         "synthetic-private-key"]
    }
}

private func referenceNegotiationProof(
    scheme: String,
    spd: Data,
    sc: Data?,
    sessionKey: Data
) -> Data {
    var transcript = Data("s2k,s2k_fo||\(scheme)|".utf8)
    transcript.appendReferenceLengthPrefixed(spd)
    transcript.append(Data("|".utf8))
    if let sc { transcript.appendReferenceLengthPrefixed(sc) }
    transcript.append(Data("|".utf8))
    let transcriptHash = Data(SHA256.hash(data: transcript))
    let hmacKey = Data(HMAC<SHA256>.authenticationCode(
        for: Data("HMAC key:".utf8),
        using: SymmetricKey(data: sessionKey)
    ))
    return Data(HMAC<SHA256>.authenticationCode(
        for: transcriptHash,
        using: SymmetricKey(data: hmacKey)
    ))
}

private func referenceEncryptSPD(_ plaintext: Data, sessionKey: Data) throws -> Data {
    let key = Data(HMAC<SHA256>.authenticationCode(
        for: Data("extra data key:".utf8),
        using: SymmetricKey(data: sessionKey)
    ))
    let iv = Data(HMAC<SHA256>.authenticationCode(
        for: Data("extra data iv:".utf8),
        using: SymmetricKey(data: sessionKey)
    )).prefix(kCCBlockSizeAES128)
    var output = Data(count: plaintext.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var outputLength = 0
    let status = output.withUnsafeMutableBytes { outputBytes in
        plaintext.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        inputBytes.baseAddress,
                        plaintext.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else { throw ExperimentalBackendError.srpAuthFailed }
    output.removeSubrange(outputLength..<output.count)
    return output
}

private extension Data {
    mutating func appendReferenceLengthPrefixed(_ value: Data) {
        var length = UInt32(value.count).littleEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(value)
    }
}

private struct FixtureMachineIdentity: AppleMachineIdentityProviding {
    static let headers = [
        "X-Apple-I-MD": "synthetic-md",
        "X-Apple-I-MD-M": "synthetic-mdm",
        "X-MMe-Client-Info": "<MacBookPro> <macOS;13.0;22A> <com.apple.AuthKit/1>"
    ]

    func headers(for request: URLRequest) async throws -> [String: String] {
        Self.headers
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

        static func empty(status: Int = 200, headers: [AnyHashable: Any] = [:]) -> Response {
            Response(status: status, headers: headers, body: Data())
        }

        static func raw(status: Int, headers: [AnyHashable: Any], body: Data) -> Response {
            Response(status: status, headers: headers, body: body)
        }
    }

    private var scripted: [Response]
    private var captured: [URLRequest] = []
    private var lookupCount = 0

    init(_ scripted: [Response]) { self.scripted = scripted }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppleHTTPResponse {
        if request.url == URLBagGrandSlamEndpointResolver.lookupURL {
            lookupCount += 1
            let body = try plistData(["urls": [
                "gsService": PrivateAppleProtocolAdapter.researched2026.grandSlamService.absoluteString,
                "trustedDeviceSecondaryAuth": PrivateAppleProtocolAdapter.researched2026.trustedDeviceVerification.absoluteString,
                "validateCode": PrivateAppleProtocolAdapter.researched2026.verificationValidation.absoluteString
            ]])
            return AppleHTTPResponse(
                url: request.url!, statusCode: 200,
                headers: ["Content-Type": "text/x-xml-plist"], body: body
            )
        }
        captured.append(request)
        guard !scripted.isEmpty else { throw URLError(.badServerResponse) }
        let response = scripted.removeFirst()
        return AppleHTTPResponse(
            url: request.url!, statusCode: response.status, headers: response.headers, body: response.body
        )
    }

    func requests() -> [URLRequest] { captured }
    func urlBagRequestCount() -> Int { lookupCount }
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

private extension ExperimentalAppleTeam {
    static let fixturePersonal = ExperimentalAppleTeam(
        id: "ABCDEFGHIJ",
        name: "Fixture Personal Team",
        isPersonalTeam: true,
        isPaidDeveloperTeam: false
    )
}

private extension ExperimentalProvisioningRequest {
    static let physicalFixture = ExperimentalProvisioningRequest(
        selectedDeviceIdentifier: "812EB0E1-DB40-5E49-9347-08079A74CBAF",
        selectedDeviceRegistrationIdentifier: "00008150-00022D581E12401C",
        deviceIdentifierSource: .physicalUDID,
        selectedDeviceName: "Rishi Borra",
        operation: .install
    )
}

private func makeRegistrationBackend(
    transport: ScriptedAppleTransport,
    diagnostics: ApplePersonalTeamDiagnosticsStore
) -> LiveApplePersonalTeamBackend {
    LiveApplePersonalTeamBackend(
        transport: transport,
        machineIdentity: FixtureMachineIdentity(),
        sessionStore: MemoryAuthorizationSessionStore(session: fixtureSession()),
        diagnostics: diagnostics
    )
}

private func diagnosticBackend(
    transport: ScriptedAppleTransport,
    diagnostics: ApplePersonalTeamDiagnosticsStore
) -> LiveApplePersonalTeamBackend {
    LiveApplePersonalTeamBackend(
        transport: transport,
        machineIdentity: FixtureMachineIdentity(),
        sessionStore: MemoryAuthorizationSessionStore(),
        diagnostics: diagnostics,
        srpRandomBytesForTesting: Data(repeating: 1, count: 32)
    )
}

private func assertAsyncThrows<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}

private func canonicalFixtureTag() -> Data {
    Data("com.iossim.personal-team.ABCDEFGHIJ.\(UUID().uuidString.uppercased())".utf8)
}

private func fixtureIdentityMetadata(
    tag: Data,
    certificate: SyntheticDevelopmentIdentity? = nil,
    serial: String? = nil
) -> IOSSimIdentityMetadata {
    IOSSimIdentityMetadata(
        teamIdentifier: "ABCDEFGHIJ",
        certificateFingerprint: certificate.map { fixtureCertificateFingerprint($0.certificateData) },
        certificateSerial: serial,
        certificateExpiration: certificate == nil ? nil : Date().addingTimeInterval(86_400),
        keyApplicationTag: tag,
        createdAt: Date(),
        generatedByIOSSim: true
    )
}

private func certificateObject(_ data: Data, serial: String) -> [String: Any] {
    ["certContent": data, "serialNumber": serial]
}

private func certificateInventory(_ certificates: [[String: Any]], available: Int) -> [String: Any] {
    ["resultCode": 0, "certificates": certificates, "availableQuantity": available]
}

private func certificateSubmission(_ data: Data, serial: String) -> [String: Any] {
    ["resultCode": 0, "certRequest": certificateObject(data, serial: serial)]
}

private func fixtureCertificateFingerprint(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).map { String(format: "%02X", $0) }.joined()
}

private func temporaryDiagnostics() -> (url: URL, store: ApplePersonalTeamDiagnosticsStore) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iossim-identity-diagnostics-\(UUID().uuidString).json")
    return (url, ApplePersonalTeamDiagnosticsStore(url: url))
}

private func makeIdentityBackend(
    transport: ScriptedAppleTransport,
    keychain: FixtureManagedIdentityKeychain,
    diagnostics: ApplePersonalTeamDiagnosticsStore
) -> LiveApplePersonalTeamBackend {
    LiveApplePersonalTeamBackend(
        transport: transport,
        machineIdentity: FixtureMachineIdentity(),
        sessionStore: MemoryAuthorizationSessionStore(session: fixtureSession()),
        diagnostics: diagnostics,
        srpRandomBytesForTesting: Data(repeating: 1, count: 32),
        identityKeychain: keychain
    )
}

private final class FixtureManagedIdentityKeychain: IOSSimManagedIdentityKeychain, @unchecked Sendable {
    var metadata: IOSSimIdentityMetadata?
    var candidateMetadata: IOSSimIdentityMetadata?
    var keys: [Data: SecKey]
    var keysToCreate: [SecKey]
    let missingKeyStatus: OSStatus
    let authorizationFailure: ExperimentalBackendError?
    /// Hermetic stand-in for the real `/usr/bin/codesign` usability proof.
    let usabilityFailure: ExperimentalBackendError?
    private(set) var createdKeyCount = 0
    private(set) var authorizedTags: [Data] = []
    private(set) var addedCertificateCount = 0
    private(set) var deletedTags: [Data] = []
    private(set) var usabilityProbeCount = 0

    init(
        metadata: IOSSimIdentityMetadata? = nil,
        keys: [Data: SecKey] = [:],
        keysToCreate: [SecKey] = [],
        missingKeyStatus: OSStatus = errSecItemNotFound,
        authorizationFailure: ExperimentalBackendError? = nil,
        usabilityFailure: ExperimentalBackendError? = nil
    ) {
        self.metadata = metadata
        self.keys = keys
        self.keysToCreate = keysToCreate
        self.missingKeyStatus = missingKeyStatus
        self.authorizationFailure = authorizationFailure
        self.usabilityFailure = usabilityFailure
    }

    func load(teamIdentifier: String) throws -> IOSSimIdentityMetadata? {
        metadata?.teamIdentifier == teamIdentifier ? metadata : nil
    }

    func loadCandidate(teamIdentifier: String) throws -> IOSSimIdentityMetadata? {
        candidateMetadata?.teamIdentifier == teamIdentifier ? candidateMetadata : nil
    }

    func save(_ metadata: IOSSimIdentityMetadata) throws {
        self.metadata = metadata
    }

    func saveCandidate(_ metadata: IOSSimIdentityMetadata) throws {
        candidateMetadata = metadata
    }

    func promoteCandidate(teamIdentifier: String) throws {
        guard candidateMetadata?.teamIdentifier == teamIdentifier else { return }
        metadata = candidateMetadata
        candidateMetadata = nil
    }

    func lookupPrivateKey(applicationTag: Data) -> ManagedPrivateKeyLookup {
        guard let key = keys[applicationTag] else {
            return ManagedPrivateKeyLookup(key: nil, status: missingKeyStatus)
        }
        return ManagedPrivateKeyLookup(key: key, status: errSecSuccess)
    }

    func persistentReference(applicationTag: Data) throws -> Data {
        guard keys[applicationTag] != nil else { throw ExperimentalBackendError.missingPrivateKey }
        return Data(SHA256.hash(data: applicationTag))
    }

    func createPrivateKey(applicationTag: Data) throws -> SecKey {
        guard !keysToCreate.isEmpty else { throw ExperimentalBackendError.certificateRequestFailed }
        let key = keysToCreate.removeFirst()
        keys[applicationTag] = key
        createdKeyCount += 1
        return key
    }

    func authorizePrivateKeyForSigning(applicationTag: Data) throws {
        if let authorizationFailure { throw authorizationFailure }
        guard keys[applicationTag] != nil else { throw ExperimentalBackendError.missingPrivateKey }
        authorizedTags.append(applicationTag)
    }

    func addCertificate(_ certificate: SecCertificate, teamIdentifier: String) throws {
        addedCertificateCount += 1
    }

    func verifySigningKeyUsable(certificate: SecCertificate) throws {
        usabilityProbeCount += 1
        if let usabilityFailure { throw usabilityFailure }
    }
}

private struct SyntheticDevelopmentIdentity {
    let privateKey: SecKey
    let certificateData: Data

    init(teamIdentifier: String) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-synthetic-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pem = folder.appendingPathComponent("private.pem")
        let der = folder.appendingPathComponent("private.der")
        let certificate = folder.appendingPathComponent("certificate.der")
        try runOpenSSL(["genrsa", "-out", pem.path, "2048"])
        try runOpenSSL([
            "req", "-new", "-x509", "-key", pem.path,
            "-outform", "DER", "-out", certificate.path,
            "-days", "2", "-subj", "/C=US/O=IOSSim Tests/OU=\(teamIdentifier)/CN=Fixture Development"
        ])
        try runOpenSSL(["rsa", "-in", pem.path, "-outform", "DER", "-out", der.path])
        let keyData = try Data(contentsOf: der)
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2_048
        ] as CFDictionary, &error) else {
            throw ExperimentalBackendError.certificateRequestFailed
        }
        privateKey = key
        certificateData = try Data(contentsOf: certificate)
    }
}

private func runOpenSSL(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ExperimentalBackendError.certificateRequestFailed }
}

private func publicKeysEqual(_ lhs: SecKey, _ rhs: SecKey) -> Bool {
    guard let leftPublic = SecKeyCopyPublicKey(lhs),
          let rightPublic = SecKeyCopyPublicKey(rhs),
          let left = SecKeyCopyExternalRepresentation(leftPublic, nil) as Data?,
          let right = SecKeyCopyExternalRepresentation(rightPublic, nil) as Data? else { return false }
    return left == right
}
