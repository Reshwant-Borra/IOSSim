import Foundation
import CryptoKit
import Security
import XCTest
@testable import IOSSimMacCore

/// Physical defect 002 -- recovery from Veya's own obsolete Apple Development
/// certificate when the Personal Team's certificate capacity is exhausted.
///
/// Classification: **UNIT**. Every Apple mutation is scripted against a fixture
/// transport. No test in this file contacts Apple, revokes a real certificate,
/// creates one, or touches the user's Personal Team. The first real revocation
/// happens only during the physical Build-3 run.
///
/// The safety property under test is narrow and load-bearing: Veya may revoke a
/// certificate *only* when it can deterministically prove the certificate is its
/// own and already unusable. Every other situation must fail closed.
final class CertificateCapacityRecoveryTests: XCTestCase {

    // MARK: - Reuse and ordinary replacement

    /// Case B -- a working identity is reused untouched. No listing beyond the
    /// first, no revoke, no new key.
    func testValidIdentityIsReusedWithoutRevocationOrReissue() async throws {
        let identity = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = recoveryFixtureTag()
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: tag, certificate: identity, serial: "CURRENT"),
            keys: [tag: identity.privateKey]
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(identity.certificateData, serial: "CURRENT")
            ], available: 0))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        let resolved = try await harness.backend.prepareIdentity(team: .fixturePersonal)

        XCTAssertTrue(resolved.reused)
        await assertNoRevocation(transport)
        XCTAssertEqual(keychain.createdKeyCount, 0)
        XCTAssertNil(keychain.recoveryIntent)
    }

    /// Case C -- a stale identity with a free slot takes the pre-existing
    /// replacement path. Capacity is not exhausted, so nothing is revoked.
    func testStaleIdentityWithAvailableCapacityReissuesWithoutRevoking() async throws {
        let stale = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let replacement = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let staleTag = recoveryFixtureTag()
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: staleTag, certificate: stale, serial: "STALE"),
            keys: [:],
            keysToCreate: [replacement.privateKey]
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(stale.certificateData, serial: "STALE")
            ], available: 1)),
            .plist(recoverySubmission(replacement.certificateData, serial: "REPLACEMENT"))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        let resolved = try await harness.backend.prepareIdentity(team: .fixturePersonal)

        XCTAssertFalse(resolved.reused)
        await assertNoRevocation(transport)
        XCTAssertEqual(keychain.createdKeyCount, 1)
    }

    // MARK: - The Intel Mac case

    /// Case D -- the migration case this defect exists for. A Build-1 identity
    /// whose key is invisible under Build 2's scoped lookup, plus a full Personal
    /// Team. Veya must revoke exactly its own recorded serial and reissue.
    func testProvenOwnedStaleCertificateIsRevokedExactlyOnceThenReissued() async throws {
        let build1 = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let foreign = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let replacement = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let build1Tag = recoveryFixtureTag()
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: build1Tag, certificate: build1, serial: "BUILD1"),
            keys: [:],
            keysToCreate: [replacement.privateKey]
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(build1.certificateData, serial: "BUILD1"),
                recoveryCertificate(foreign.certificateData, serial: "XCODE", machineName: "Someone's MacBook Pro")
            ], available: 0)),
            .plist(["resultCode": 0]),
            .plist(recoveryInventory([
                recoveryCertificate(foreign.certificateData, serial: "XCODE", machineName: "Someone's MacBook Pro")
            ], available: 1)),
            .plist(recoverySubmission(replacement.certificateData, serial: "REPLACEMENT"))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        let resolved = try await harness.backend.prepareIdentity(team: .fixturePersonal)

        XCTAssertFalse(resolved.reused)
        let revocations = await revocationRequests(transport)
        XCTAssertEqual(revocations.count, 1, "Exactly one certificate may be revoked per recovery")
        XCTAssertEqual(revocations.first?["serialNumber"] as? String, "BUILD1")
        XCTAssertEqual(keychain.createdKeyCount, 1)
        XCTAssertNil(keychain.recoveryIntent, "A completed reclaim must clear its intent")

        let checkpoints = harness.checkpoints()
        XCTAssertTrue(checkpoints.contains("CERTIFICATE_CAPACITY_EXHAUSTED"))
        XCTAssertTrue(checkpoints.contains("CERTIFICATE_OWNERSHIP_PROVEN"))
        XCTAssertTrue(checkpoints.contains("CERTIFICATE_RECLAIM_STARTED"))
        XCTAssertTrue(checkpoints.contains("CERTIFICATE_REVOKED"))
        XCTAssertTrue(checkpoints.contains("CERTIFICATE_CAPACITY_RESTORED"))
    }

    // MARK: - Fail-closed cases

    /// Case E -- every slot is held by a certificate Veya cannot attribute to
    /// itself. It must refuse to revoke and surface the capacity error.
    func testUnknownCertificatesAreNeverRevoked() async throws {
        let foreignA = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let foreignB = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let keychain = FixtureRecoveryKeychain(metadata: nil, keys: [:])
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(foreignA.certificateData, serial: "FOREIGN-A"),
                recoveryCertificate(foreignB.certificateData, serial: "FOREIGN-B")
            ], available: 0))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        await assertThrows(.certificateLimit) {
            _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)
        }
        await assertNoRevocation(transport)
        XCTAssertEqual(keychain.createdKeyCount, 0)
        XCTAssertTrue(harness.checkpoints().contains("CERTIFICATE_RECLAIM_UNAVAILABLE"))
    }

    /// Case L -- an Xcode certificate carries no Veya marker and must be left
    /// alone even when it is the only thing occupying capacity.
    func testXcodeStyleCertificateIsNeverRevokedEvenWhenItBlocksCapacity() async throws {
        let xcode = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let keychain = FixtureRecoveryKeychain(metadata: nil, keys: [:])
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(
                    xcode.certificateData,
                    serial: "XCODE-ISSUED",
                    machineId: "SOME-XCODE-MACHINE",
                    machineName: "Xcode"
                )
            ], available: 0))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        await assertThrows(.certificateLimit) {
            _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)
        }
        await assertNoRevocation(transport)
    }

    /// Ownership evidence must be *this installation's own record*. A certificate
    /// Veya merely could have created, with no persisted serial or fingerprint
    /// naming it, is not reclaimable.
    func testAmbiguousOwnershipFailsClosed() async throws {
        let ambiguous = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = recoveryFixtureTag()
        // Metadata exists, but records a different certificate than the one
        // occupying the slot -- no serial or fingerprint match.
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: tag, certificate: nil, serial: "SOME-OTHER-SERIAL"),
            keys: [:]
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(ambiguous.certificateData, serial: "UNRELATED")
            ], available: 0))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        await assertThrows(.certificateLimit) {
            _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)
        }
        await assertNoRevocation(transport)
    }

    /// Case K -- another Mac's Build-3 certificate carries Veya's structured
    /// machine name with a *different* installation id. It may be live on that
    /// Mac, so it is never revoked from here.
    func testAnotherVeyaInstallationsCertificateIsNeverAutomaticallyRevoked() async throws {
        let otherMac = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let keychain = FixtureRecoveryKeychain(metadata: nil, keys: [:], installation: "AAAAAAAA-1111")
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(
                    otherMac.certificateData,
                    serial: "OTHER-MAC",
                    machineId: "BBBBBBBB-2222",
                    machineName: veyaMachineName(installationIdentifier: "BBBBBBBB-2222")
                )
            ], available: 0))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        await assertThrows(.certificateLimit) {
            _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)
        }
        await assertNoRevocation(transport)
    }

    /// Invariant 2, the strongest safety rule: a certificate whose private key is
    /// present and can actually sign is never selected, even when this
    /// installation's own metadata names it.
    func testCertificateBackedByAUsableKeyIsNeverSelectedForRevocation() async throws {
        let usable = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let usableTag = recoveryFixtureTag()
        let staleTag = recoveryFixtureTag()
        // The active record names the usable certificate; the candidate record is
        // stale and names nothing reclaimable. Capacity is full.
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: usableTag, certificate: usable, serial: "USABLE"),
            keys: [usableTag: usable.privateKey]
        )
        keychain.candidateMetadata = recoveryMetadata(tag: staleTag, certificate: nil, serial: nil)
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(usable.certificateData, serial: "USABLE")
            ], available: 0))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        // Whatever the outcome, the usable certificate must survive.
        _ = try? await harness.backend.prepareIdentity(team: .fixturePersonal)

        let revocations = await revocationRequests(transport)
        XCTAssertTrue(
            revocations.allSatisfy { ($0["serialNumber"] as? String) != "USABLE" },
            "A certificate that can still sign must never be revoked"
        )
    }

    // MARK: - Ordering, failure, and restart

    /// Apple refuses issuance into a full quota, so the revoke must be sent
    /// before the CSR. This asserts the real request ordering.
    func testRevocationPrecedesCertificateSubmission() async throws {
        let build1 = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let replacement = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = recoveryFixtureTag()
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: tag, certificate: build1, serial: "BUILD1"),
            keys: [:],
            keysToCreate: [replacement.privateKey]
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([recoveryCertificate(build1.certificateData, serial: "BUILD1")], available: 0)),
            .plist(["resultCode": 0]),
            .plist(recoveryInventory([], available: 2)),
            .plist(recoverySubmission(replacement.certificateData, serial: "REPLACEMENT"))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)

        let operations = await transport.operations()
        let revokeIndex = operations.firstIndex { $0.contains("revokeDevelopmentCert") }
        let submitIndex = operations.firstIndex { $0.contains("submitDevelopmentCSR") }
        XCTAssertNotNil(revokeIndex)
        XCTAssertNotNil(submitIndex)
        XCTAssertLessThan(revokeIndex!, submitIndex!, "Revocation must precede CSR submission")
    }

    /// Capacity that never propagates inside the bounded window is a recoverable
    /// error, not a second revocation and not an infinite loop.
    func testDelayedCapacityPropagationIsBoundedAndDoesNotRevokeAgain() async throws {
        let build1 = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = recoveryFixtureTag()
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: tag, certificate: build1, serial: "BUILD1"),
            keys: [:]
        )
        var script: [ScriptedRecoveryTransport.Response] = [
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([recoveryCertificate(build1.certificateData, serial: "BUILD1")], available: 0)),
            .plist(["resultCode": 0])
        ]
        // Every confirmation re-read still reports a full team.
        for _ in 0..<LiveApplePersonalTeamBackend.capacityConfirmationAttempts {
            script.append(.plist(recoveryInventory([], available: 0)))
        }
        let transport = ScriptedRecoveryTransport(script)
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        await assertThrows(.certificateCapacityNotReleased) {
            _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)
        }
        let revocations = await revocationRequests(transport)
        XCTAssertEqual(revocations.count, 1, "A slow slot must never trigger a second revocation")
        XCTAssertNotNil(keychain.recoveryIntent, "The intent is retained so Try Again reconciles")
        XCTAssertTrue(harness.checkpoints().contains("CERTIFICATE_CAPACITY_NOT_RELEASED"))
    }

    /// A rejected revoke is reported precisely, not collapsed into the capacity
    /// error, and does not fall through to revoking something else.
    func testFailedRevocationIsReportedAndDoesNotCascade() async throws {
        let build1 = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let other = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = recoveryFixtureTag()
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: tag, certificate: build1, serial: "BUILD1"),
            keys: [:]
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([
                recoveryCertificate(build1.certificateData, serial: "BUILD1"),
                recoveryCertificate(other.certificateData, serial: "OTHER")
            ], available: 0)),
            .plist(["resultCode": 1100, "userString": "Unable to revoke"])
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        await assertThrows(.certificateRevocationFailed) {
            _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)
        }
        let revocations = await revocationRequests(transport)
        XCTAssertEqual(revocations.count, 1, "A failed revoke must not cascade into another certificate")
        XCTAssertTrue(harness.checkpoints().contains("CERTIFICATE_REVOCATION_FAILED"))
    }

    /// Case F -- a crash between the revoke call and its confirmation. On restart
    /// the target is gone from Apple's listing, so the intent is reconciled and
    /// no second certificate is revoked.
    func testRestartAfterRevocationReconcilesWithoutDoubleRevoking() async throws {
        let survivor = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let replacement = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = recoveryFixtureTag()
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: tag, certificate: nil, serial: "ALREADY-REVOKED"),
            keys: [:],
            keysToCreate: [replacement.privateKey],
            recoveryIntent: CertificateRecoveryIntent(
                teamIdentifier: "ABCDEFGHIJ",
                targetSerial: "ALREADY-REVOKED",
                targetFingerprint: nil,
                installationIdentifier: "INSTALL-THIS-MAC",
                startedAt: Date(),
                attempts: 1
            )
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            // The target is already absent: the earlier revoke landed.
            .plist(recoveryInventory([
                recoveryCertificate(survivor.certificateData, serial: "SURVIVOR")
            ], available: 0)),
            .plist(recoveryInventory([
                recoveryCertificate(survivor.certificateData, serial: "SURVIVOR")
            ], available: 1)),
            .plist(recoverySubmission(replacement.certificateData, serial: "REPLACEMENT"))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)

        await assertNoRevocation(transport)
        XCTAssertNil(keychain.recoveryIntent)
        XCTAssertTrue(harness.checkpoints().contains("CERTIFICATE_RECLAIM_RECONCILED"))
    }

    /// Cases G and H -- once a slot is free, a later profile or signing-probe
    /// failure must not provoke any further revocation.
    func testDownstreamFailureAfterReclaimDoesNotTriggerFurtherRevocation() async throws {
        let build1 = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let replacement = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let tag = recoveryFixtureTag()
        let keychain = FixtureRecoveryKeychain(
            metadata: recoveryMetadata(tag: tag, certificate: build1, serial: "BUILD1"),
            keys: [:],
            keysToCreate: [replacement.privateKey],
            // The replacement key cannot prove it can sign.
            usabilityFailure: .signingFailure
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([recoveryCertificate(build1.certificateData, serial: "BUILD1")], available: 0)),
            .plist(["resultCode": 0]),
            .plist(recoveryInventory([], available: 2)),
            .plist(recoverySubmission(replacement.certificateData, serial: "REPLACEMENT"))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        await assertThrows(.missingPrivateKey) {
            _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)
        }
        let revocations = await revocationRequests(transport)
        XCTAssertEqual(revocations.count, 1, "A signing-probe failure must not revoke anything further")
    }

    // MARK: - Metadata schema and migration

    /// Case J -- a Build-1/Build-2 record has no schema-2 fields. It must decode
    /// unchanged and still be usable as ownership evidence, or the Intel Mac
    /// cannot be recovered at all.
    func testLegacyMetadataDecodesAndStillProvesOwnership() throws {
        let legacy: [String: Any] = [
            "teamIdentifier": "ABCDEFGHIJ",
            "certificateFingerprint": "ABCDEF0123456789",
            "certificateSerial": "BUILD1",
            "keyApplicationTag": Data("com.iossim.personal-team.ABCDEFGHIJ.\(UUID().uuidString.uppercased())".utf8),
            "createdAt": Date(),
            "generatedByIOSSim": true
        ]
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: legacy, format: .binary, options: 0
        )
        let decoded = try PropertyListDecoder().decode(IOSSimIdentityMetadata.self, from: encoded)

        XCTAssertEqual(decoded.certificateSerial, "BUILD1")
        XCTAssertTrue(decoded.generatedByIOSSim)
        XCTAssertNil(decoded.installationIdentifier, "A legacy record carries no installation id")

        // And it still classifies as reclaimable.
        let ownership = classifyDevelopmentCertificate(
            ["serialNumber": "BUILD1"],
            activeMetadata: decoded,
            candidateMetadata: nil,
            installationIdentifier: "INSTALL-THIS-MAC",
            usableFingerprints: []
        )
        XCTAssertEqual(ownership, .ownedLocalRecord)
    }

    /// The machine identity sent to Apple must be stable, or every run would
    /// throw away the remote ownership marker the way Build 1 and Build 2 did.
    func testMachineIdentityIsStableAndDistinguishesInstallations() async throws {
        let first = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let second = try SyntheticDevelopmentIdentity(teamIdentifier: "ABCDEFGHIJ")
        let keychain = FixtureRecoveryKeychain(
            metadata: nil,
            keys: [:],
            keysToCreate: [first.privateKey, second.privateKey]
        )
        let transport = ScriptedRecoveryTransport([
            .plist(recoveryTeamResponse()),
            .plist(recoveryInventory([], available: 2)),
            .plist(recoverySubmission(first.certificateData, serial: "FIRST")),
            .plist(recoveryInventory([], available: 1)),
            .plist(recoverySubmission(second.certificateData, serial: "SECOND"))
        ])
        let harness = try await makeHarness(transport: transport, keychain: keychain)
        defer { harness.cleanup() }

        _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)
        keychain.metadata = nil
        keychain.candidateMetadata = nil
        _ = try await harness.backend.prepareIdentity(team: .fixturePersonal)

        let submissions = await transport.bodies(matching: "submitDevelopmentCSR")
        XCTAssertEqual(submissions.count, 2)
        let identifiers = submissions.compactMap { $0["machineId"] as? String }
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(identifiers[0], identifiers[1], "machineId must be stable across requests")
        XCTAssertEqual(identifiers[0], keychain.installation)

        let names = submissions.compactMap { $0["machineName"] as? String }
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("Veya (") })
        XCTAssertEqual(
            veyaInstallationShortIdentifier(fromMachineName: names[0]),
            installationShortIdentifier(keychain.installation)
        )
        // A legacy name must not be mistaken for another installation's marker.
        XCTAssertNil(veyaInstallationShortIdentifier(fromMachineName: "IOSSim"))
    }

    // MARK: - Harness

    private struct Harness {
        let backend: LiveApplePersonalTeamBackend
        let diagnostics: ApplePersonalTeamDiagnosticsStore
        let diagnosticsURL: URL

        func checkpoints() -> [String] {
            (diagnostics.load()?.events ?? []).compactMap(\.checkpoint)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: diagnosticsURL)
        }
    }

    private func makeHarness(
        transport: ScriptedRecoveryTransport,
        keychain: FixtureRecoveryKeychain
    ) async throws -> Harness {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("veya-cert-recovery-\(UUID().uuidString).json")
        let store = ApplePersonalTeamDiagnosticsStore(url: url)
        let backend = LiveApplePersonalTeamBackend(
            transport: transport,
            machineIdentity: FixtureMachineIdentity(),
            sessionStore: MemoryRecoverySessionStore(session: recoveryFixtureSession()),
            diagnostics: store,
            srpRandomBytesForTesting: Data(repeating: 1, count: 32),
            identityKeychain: keychain,
            certificateCapacityRetryDelay: 0
        )
        _ = try await backend.resumeSession()
        return Harness(backend: backend, diagnostics: store, diagnosticsURL: url)
    }

    private func assertThrows(
        _ expected: ExperimentalBackendError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ExperimentalBackendError, expected, file: file, line: line)
        }
    }

    private func revocationRequests(_ transport: ScriptedRecoveryTransport) async -> [[String: Any]] {
        await transport.bodies(matching: "revokeDevelopmentCert")
    }

    private func assertNoRevocation(
        _ transport: ScriptedRecoveryTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let operations = await transport.operations()
        XCTAssertFalse(
            operations.contains { $0.contains("revoke") },
            "No revocation may be attempted in this case",
            file: file,
            line: line
        )
    }
}

// MARK: - Fixtures local to this suite

/// Records every Developer Services request so a test can assert exactly which
/// operations ran, in what order, and with what parameters. That is how the
/// "exactly one revocation, of exactly this serial" invariants are proven.
private actor ScriptedRecoveryTransport: AppleHTTPTransport {
    struct Response {
        let status: Int
        let headers: [AnyHashable: Any]
        let body: Data

        static func plist(_ value: Any, status: Int = 200) -> Response {
            Response(
                status: status,
                headers: ["Content-Type": "text/x-xml-plist"],
                body: try! plistData(value)
            )
        }
    }

    private var scripted: [Response]
    private var captured: [URLRequest] = []

    init(_ scripted: [Response]) { self.scripted = scripted }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppleHTTPResponse {
        if request.url == URLBagGrandSlamEndpointResolver.lookupURL {
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

    /// Developer Services operation paths, in call order.
    func operations() -> [String] {
        captured.compactMap { $0.url?.path }
    }

    /// Decoded request bodies for every call whose operation path contains `needle`.
    func bodies(matching needle: String) -> [[String: Any]] {
        captured.compactMap { request in
            guard let path = request.url?.path, path.contains(needle),
                  let body = request.httpBody,
                  let decoded = try? PropertyListSerialization.propertyList(
                      from: body, options: [], format: nil
                  ) as? [String: Any] else { return nil }
            return decoded
        }
    }
}

private final class FixtureRecoveryKeychain: IOSSimManagedIdentityKeychain, @unchecked Sendable {
    var metadata: IOSSimIdentityMetadata?
    var candidateMetadata: IOSSimIdentityMetadata?
    var keys: [Data: SecKey]
    var keysToCreate: [SecKey]
    var installation: String
    var recoveryIntent: CertificateRecoveryIntent?
    let usabilityFailure: ExperimentalBackendError?
    private(set) var createdKeyCount = 0

    init(
        metadata: IOSSimIdentityMetadata?,
        keys: [Data: SecKey],
        keysToCreate: [SecKey] = [],
        usabilityFailure: ExperimentalBackendError? = nil,
        installation: String = "INSTALL-THIS-MAC",
        recoveryIntent: CertificateRecoveryIntent? = nil
    ) {
        self.metadata = metadata
        self.keys = keys
        self.keysToCreate = keysToCreate
        self.usabilityFailure = usabilityFailure
        self.installation = installation
        self.recoveryIntent = recoveryIntent
    }

    func load(teamIdentifier: String) throws -> IOSSimIdentityMetadata? {
        metadata?.teamIdentifier == teamIdentifier ? metadata : nil
    }

    func loadCandidate(teamIdentifier: String) throws -> IOSSimIdentityMetadata? {
        candidateMetadata?.teamIdentifier == teamIdentifier ? candidateMetadata : nil
    }

    func save(_ metadata: IOSSimIdentityMetadata) throws { self.metadata = metadata }
    func saveCandidate(_ metadata: IOSSimIdentityMetadata) throws { candidateMetadata = metadata }

    func promoteCandidate(teamIdentifier: String) throws {
        guard candidateMetadata?.teamIdentifier == teamIdentifier else { return }
        metadata = candidateMetadata
        candidateMetadata = nil
    }

    func installationIdentifier() throws -> String { installation }

    func loadRecoveryIntent(teamIdentifier: String) throws -> CertificateRecoveryIntent? {
        recoveryIntent?.teamIdentifier == teamIdentifier ? recoveryIntent : nil
    }

    func saveRecoveryIntent(_ intent: CertificateRecoveryIntent) throws { recoveryIntent = intent }

    func clearRecoveryIntent(teamIdentifier: String) throws {
        guard recoveryIntent?.teamIdentifier == teamIdentifier else { return }
        recoveryIntent = nil
    }

    func lookupPrivateKey(applicationTag: Data) -> ManagedPrivateKeyLookup {
        guard let key = keys[applicationTag] else {
            return ManagedPrivateKeyLookup(key: nil, status: errSecItemNotFound)
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
        guard keys[applicationTag] != nil else { throw ExperimentalBackendError.missingPrivateKey }
    }

    func addCertificate(_ certificate: SecCertificate, teamIdentifier: String) throws {}

    /// Hermetic stand-in for the real `/usr/bin/codesign` proof.
    func verifySigningKeyUsable(certificate: SecCertificate) throws {
        if let usabilityFailure { throw usabilityFailure }
    }
}

private final class MemoryRecoverySessionStore: AppleAuthorizationSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: AppleAuthorizationSessionMetadata?
    private var payload: Data?

    init(session: AppleAuthorizationSession?) {
        if let session {
            metadata = session.metadata
            payload = session.withOpaquePayload { Data($0) }
        }
    }

    func load() throws -> AppleAuthorizationSession? {
        lock.lock(); defer { lock.unlock() }
        guard let metadata, let payload else { return nil }
        return AppleAuthorizationSession(metadata: metadata, opaquePayload: payload)
    }

    func loadMetadata() throws -> AppleAuthorizationSessionMetadata? {
        lock.lock(); defer { lock.unlock() }
        return metadata
    }

    func save(_ session: AppleAuthorizationSession) throws {
        lock.lock(); defer { lock.unlock() }
        metadata = session.metadata
        payload = session.withOpaquePayload { Data($0) }
    }

    func remove() throws {
        lock.lock(); defer { lock.unlock() }
        metadata = nil
        payload = nil
    }
}

private struct RecoverySessionEnvelope: Codable {
    let dsid: String
    let xcodeToken: String
    let tokenExpiresAt: Date?
}

private func recoveryFixtureSession() -> AppleAuthorizationSession {
    let payload = try! PropertyListEncoder().encode(RecoverySessionEnvelope(
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

private func recoveryTeamResponse() -> [String: Any] {
    [
        "resultCode": 0,
        "teams": [[
            "teamId": "ABCDEFGHIJ", "name": "Fixture Personal Team", "type": "Individual",
            "memberships": [["name": "Free"]]
        ]]
    ]
}

private func recoveryCertificate(
    _ data: Data,
    serial: String,
    machineId: String? = nil,
    machineName: String? = nil
) -> [String: Any] {
    var object: [String: Any] = ["certContent": data, "serialNumber": serial]
    if let machineId { object["machineId"] = machineId }
    if let machineName { object["machineName"] = machineName }
    return object
}

private func recoveryInventory(_ certificates: [[String: Any]], available: Int) -> [String: Any] {
    ["resultCode": 0, "certificates": certificates, "availableQuantity": available]
}

private func recoverySubmission(_ data: Data, serial: String) -> [String: Any] {
    ["resultCode": 0, "certRequest": recoveryCertificate(data, serial: serial)]
}

private func recoveryFixtureTag() -> Data {
    Data("com.iossim.personal-team.ABCDEFGHIJ.\(UUID().uuidString.uppercased())".utf8)
}

private func recoveryMetadata(
    tag: Data,
    certificate: SyntheticDevelopmentIdentity?,
    serial: String?
) -> IOSSimIdentityMetadata {
    IOSSimIdentityMetadata(
        teamIdentifier: "ABCDEFGHIJ",
        certificateFingerprint: certificate.map {
            Data(SHA256.hash(data: $0.certificateData)).map { String(format: "%02X", $0) }.joined()
        },
        certificateSerial: serial,
        certificateExpiration: certificate == nil ? nil : Date().addingTimeInterval(86_400),
        keyApplicationTag: tag,
        createdAt: Date(),
        generatedByIOSSim: true
    )
}
