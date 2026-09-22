import CryptoKit
import Foundation
@testable import IOSSimMacCore
import XCTest

/// M6 routing: `.authorization`/`.team`/`.certificate`/`.profile` on the production engine, driving the
/// real `LiveApplePersonalTeamBackend` request/parse code against a simulated Developer Services portal
/// at the HTTP layer. The portal signs Veya's actual CSR with a fake CA (so the issued SPKI is the key
/// store's key) and CMS-signs real-shape profiles. Labelled SIMULATED_APPLE: no Apple account is used.
final class AppleDomainsTests: XCTestCase {
    private var root: URL!
    private var repository: InstallationJournalRepository!
    private var keyStore: VeyaSigningKeyStore!
    private var portal: SimulatedApplePortal!
    private var clockOffset = ClockOffset()
    private var device = DeviceRegistrationTarget(udid: "00008150-00022D581E12401C", name: "Fixture iPhone")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-m6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
        keyStore = VeyaSigningKeyStore(rootURL: root.appendingPathComponent("secrets/signing-keys", isDirectory: true),
                                       wrapping: MemoryWrapping())
        portal = try SimulatedApplePortal(workspace: root.appendingPathComponent("portal", isDirectory: true), clock: clockOffset)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func engine(session: AppleAuthorizationSession? = fixtureSession()) throws -> VeyaReconciliationEngine {
        let backend = LiveApplePersonalTeamBackend(
            transport: portal,
            machineIdentity: FixtureMachineIdentity(),
            sessionStore: MemoryAuthorizationSessionStore(session: session),
            diagnostics: ApplePersonalTeamDiagnosticsStore(url: root.appendingPathComponent("diagnostics-\(UUID()).json"))
        )
        let account = AppleAccountContext(services: backend)
        let offset = clockOffset
        let now: @Sendable () -> Date = { Date().addingTimeInterval(offset.seconds) }
        let target = device
        let domains: [any InstallationObserver & InstallationTransition] = [
            AppleAccountDomain(domain: .authorization, account: account, now: now),
            AppleAccountDomain(domain: .team, account: account, now: now),
            SigningKeyDomain(store: keyStore, now: now),
            CertificateDomain(rootURL: root, repository: repository, account: account, keyStore: keyStore, now: now),
            ProfileDomain(rootURL: root, repository: repository, account: account, device: { target }, now: now),
        ]
        return try VeyaReconciliationEngine(journalRepository: repository, observers: domains, transitions: domains,
                                            sleeper: InstantSleep(), leaseSleeper: InstantSleep(), now: now)
    }

    private static let chain: [InstallationDomain] = [.authorization, .team, .signingKey, .certificate, .profile]

    private func reconcile(permission: ReconciliationPermission = .safeRepair,
                           session: AppleAuthorizationSession? = fixtureSession()) async throws -> ReconciliationOutcome {
        try await engine(session: session).reconcile(
            scope: InstallationScope(domains: Self.chain),
            to: DesiredInstallationState(requirements: Self.chain.map { DesiredDomainState(domain: $0) }),
            policy: ReconciliationPolicy(maximumPermission: permission, allowedDomains: Self.chain, maximumTransitions: 16,
                                         localRetryLimit: 0, remoteRetryLimit: 0)
        )
    }

    private func signingSPKI() async throws -> String? { try await repository.load().activeResource(for: .signingKey)?.identity.digest }

    func testFreshAccountIssuesCertificateForKeyStoreKeyAndProfilesThenIsIdempotent() async throws {
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready, "\(String(describing: outcome.failure))")
        let journal = try await repository.load()
        let certificate = try XCTUnwrap(journal.activeResource(for: .certificate))
        let listed = await portal.certificates()
        XCTAssertEqual(listed.count, 1)
        // The CSR carried the key store's public key: Apple's certificate SPKI is the journal key digest.
        let spki = try await signingSPKI()
        XCTAssertEqual(AppleCertificateObservation(serial: "x", der: listed[0].der)?.spkiSHA256, spki)
        XCTAssertEqual(certificate.identity.resourceID, listed[0].serial)
        let profiles = try XCTUnwrap(journal.activeResource(for: .profile))
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: SimulatedApplePortal.team)
        XCTAssertEqual(Set(ProfileDomain.profiles(of: profiles, root: root)?.keys ?? [:].keys), [identifiers.main, identifiers.runner])
        let calls = await portal.calls
        XCTAssertEqual(calls.filter { $0 == "submitDevelopmentCSR" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "addDevice" }.count, 1)
        XCTAssertFalse(calls.contains("revokeDevelopmentCert"))

        await portal.resetCalls()
        let again = try await reconcile()
        XCTAssertEqual(again.status, .ready)
        XCTAssertEqual(again.transitionsCompleted, 0)
        let mutating = await portal.calls.filter { ["submitDevelopmentCSR", "addDevice", "addAppId", "revokeDevelopmentCert", "downloadTeamProvisioningProfile"].contains($0) }
        XCTAssertEqual(mutating, [], "a satisfied installation performs no Apple mutation")
    }

    func testNoStoredSessionIsASignInActionWithoutAnyDeveloperCall() async throws {
        let outcome = try await reconcile(session: nil)
        XCTAssertEqual(outcome.status, .userActionRequired)
        XCTAssertEqual(outcome.userAction, AppleDomainFailure.signInAction)
        let calls = await portal.calls
        XCTAssertEqual(calls, [])
    }

    func testCapacityFullOfUnknownCertificatesNeverRevokesAndReportsUserSafeGuidance() async throws {
        try await portal.seedForeignCertificates(2)
        await portal.setCapacity(2)
        await assertFails(CertificateFailure.capacityRequiresUser.code) { _ = try await self.reconcile(permission: .destructiveOwned) }
        let calls = await portal.calls
        XCTAssertFalse(calls.contains("revokeDevelopmentCert"))
        XCTAssertEqual(calls.filter { $0 == "submitDevelopmentCSR" }.count, 1, "one rejected issue, no retry without a reclaim")
        let journal = try await repository.load()
        XCTAssertNil(journal.activeResource(for: .certificate))
    }

    func testKeyRotationReclaimsOnlyThisInstallationsRetiredCertificateAndOnlyWithDestructiveOwnedPolicy() async throws {
        await portal.setCapacity(2)
        try await portal.seedForeignCertificates(1)
        _ = try await reconcile()
        let initial = try await repository.load()
        let first = try XCTUnwrap(initial.activeResource(for: .certificate)).identity.resourceID
        // Lose the key file: the key is replaced and its certificate can no longer sign.
        let key = try XCTUnwrap(initial.activeResource(for: .signingKey))
        try FileManager.default.removeItem(at: root.appendingPathComponent(key.relativeLocation!))

        await portal.resetCalls()
        await assertFails(CertificateFailure.capacityRequiresUser.code) { _ = try await self.reconcile(permission: .safeRepair) }
        var calls = await portal.calls
        XCTAssertFalse(calls.contains("revokeDevelopmentCert"), "safeRepair never revokes")

        await portal.resetCalls()
        let outcome = try await reconcile(permission: .destructiveOwned)
        XCTAssertEqual(outcome.status, .ready, "\(String(describing: outcome.failure))")
        calls = await portal.calls
        XCTAssertEqual(calls.filter { $0 == "revokeDevelopmentCert" }.count, 1)
        let revoked = await portal.revokedSerials
        XCTAssertEqual(revoked, [first], "only the retired key's certificate is revoked; the foreign one survives")
        let remaining = await portal.certificates()
        XCTAssertEqual(remaining.count, 2)
        let spki = try await signingSPKI()
        XCTAssertEqual(AppleCertificateObservation(serial: "x", der: remaining.last!.der)?.spkiSHA256, spki)
    }

    func testLostIssueResponseIsResolvedBySPKIWithoutASecondCertificate() async throws {
        await portal.dropNextResponse(of: "submitDevelopmentCSR")
        do { _ = try await reconcile(); XCTFail("the lost response must fail this run") } catch {}
        let afterLoss = await portal.certificates()
        XCTAssertEqual(afterLoss.count, 1, "Apple issued before the response was lost")
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready)
        let calls = await portal.calls
        XCTAssertEqual(calls.filter { $0 == "submitDevelopmentCSR" }.count, 1, "no blind reissue")
        let final = await portal.certificates()
        XCTAssertEqual(final.count, 1)
    }

    func testDeviceChangeReissuesOnlyProfilesAndReusesTheCertificate() async throws {
        _ = try await reconcile()
        let certificate = try await repository.load().activeResource(for: .certificate)
        await portal.resetCalls()
        device = DeviceRegistrationTarget(udid: "00008030-001A2B3C4D5E6F70", name: "Second iPhone")
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready)
        let journal = try await repository.load()
        XCTAssertEqual(journal.activeResource(for: .certificate), certificate)
        XCTAssertEqual(journal.activeResource(for: .profile)?.metadata["device"], device.digest)
        let calls = await portal.calls
        XCTAssertFalse(calls.contains("submitDevelopmentCSR"))
        XCTAssertEqual(calls.filter { $0 == "addDevice" }.count, 1)
    }

    func testCertificateRevokedElsewhereIsDetectedAtReproofAndReplaced() async throws {
        _ = try await reconcile()
        let firstJournal = try await repository.load()
        let first = try XCTUnwrap(firstJournal.activeResource(for: .certificate))
        await portal.revokeOutOfBand(serial: first.identity.resourceID)
        clockOffset.seconds = CertificateDomain.proofLifetime + 60
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready, "\(String(describing: outcome.failure))")
        let journal = try await repository.load()
        let replacement = try XCTUnwrap(journal.activeResource(for: .certificate))
        XCTAssertNotEqual(replacement.identity.resourceID, first.identity.resourceID)
        XCTAssertEqual(journal.activeResource(for: .profile)?.metadata["certificate"], replacement.identity.digest,
                       "profiles follow the replacement certificate")
    }

    func testRenewalWindowReplacesTheCertificateForTheSameKey() async throws {
        _ = try await reconcile()
        let firstJournal = try await repository.load()
        let first = try XCTUnwrap(firstJournal.activeResource(for: .certificate))
        let expiry = try XCTUnwrap(first.expiresAt)
        clockOffset.seconds = expiry.timeIntervalSinceNow - CertificatePlanner.minimumRemainingValidity + 3600
        await portal.setValidityDays(730)
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready, "\(String(describing: outcome.failure))")
        let renewedJournal = try await repository.load()
        let renewed = try XCTUnwrap(renewedJournal.activeResource(for: .certificate))
        XCTAssertNotEqual(renewed.identity.resourceID, first.identity.resourceID)
        XCTAssertEqual(renewed.metadata["spkiSHA256"], first.metadata["spkiSHA256"], "same key, new certificate")
    }

    func testTamperedCertificateFileIsRestoredFromAppleInventoryWithoutReissue() async throws {
        _ = try await reconcile()
        let recordJournal = try await repository.load()
        let record = try XCTUnwrap(recordJournal.activeResource(for: .certificate))
        try Data("tampered".utf8).write(to: root.appendingPathComponent(record.relativeLocation!))
        await portal.resetCalls()
        let outcome = try await reconcile()
        XCTAssertEqual(outcome.status, .ready)
        let calls = await portal.calls
        XCTAssertFalse(calls.contains("submitDevelopmentCSR"))
        let restored = try await repository.load()
        XCTAssertEqual(restored.activeResource(for: .certificate)?.identity.resourceID, record.identity.resourceID)
    }

    func testProfileNotContainingOurCertificateIsNeverStagedOrPromoted() async throws {
        await portal.omitCertificatesFromProfiles()
        await assertFails(AppleDomainFailure.profileInvalid.code) { _ = try await self.reconcile() }
        let journal = try await repository.load()
        XCTAssertNil(journal.activeResource(for: .profile))
        XCTAssertNil(journal.candidateResource(for: .profile))
        XCTAssertNotNil(journal.activeResource(for: .certificate), "earlier domains stay promoted")
    }

    private func assertFails(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let failure as VeyaFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("expected \(code), got \(error)", file: file, line: line)
        }
    }
}

final class ClockOffset: @unchecked Sendable {
    var seconds: TimeInterval = 0
}

struct InstantSleep: ReconciliationSleeping {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: .milliseconds(1)) }
}

/// In-memory wrapping secret (hermetic tests only; production uses the DP Keychain backend).
final class MemoryWrapping: WrappingSecretStore, @unchecked Sendable {
    let kind: WrappingSecretBackendKind = .dataProtectionKeychain
    private var secrets: [UUID: SymmetricKey] = [:]
    private let lock = NSLock()
    func read(installationID: UUID) throws -> SymmetricKey? { lock.withLock { secrets[installationID] } }
    func create(installationID: UUID) throws -> SymmetricKey {
        lock.withLock {
            let key = SymmetricKey(size: .bits256)
            secrets[installationID] = key
            return key
        }
    }
    func delete(installationID: UUID) throws { lock.withLock { secrets[installationID] = nil } }
}

/// Developer Services at the HTTP boundary: certificates are issued by signing the submitted CSR with a
/// fake CA (`openssl x509 -req`, which also verifies the CSR self-signature), and profiles are CMS-signed.
actor SimulatedApplePortal: AppleHTTPTransport {
    static let team = "ABCDEFGHIJ"
    struct Certificate { let serial: String; let der: Data }

    private let workspace: URL
    private let clock: ClockOffset
    private var issued: [Certificate] = []
    private var capacity = 2
    private var validityDays = 365
    private var nextSerial = 0x5A0001
    private var devices: [String] = []
    private var appIDs: [(id: String, bundle: String)] = []
    private var drop: Set<String> = []
    private var profilesOmitCertificates = false
    private(set) var calls: [String] = []
    private(set) var revokedSerials: [String] = []

    init(workspace: URL, clock: ClockOffset = ClockOffset()) throws {
        self.workspace = workspace
        self.clock = clock
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Self.openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", workspace.appendingPathComponent("ca.key").path,
                          "-out", workspace.appendingPathComponent("ca.pem").path, "-days", "800", "-subj", "/CN=Simulated Apple WWDR"])
    }

    func certificates() -> [Certificate] { issued }
    func setCapacity(_ value: Int) { capacity = value }
    func setValidityDays(_ value: Int) { validityDays = value }
    func resetCalls() { calls = [] }
    func dropNextResponse(of operation: String) { drop.insert(operation) }
    func omitCertificatesFromProfiles() { profilesOmitCertificates = true }
    func revokeOutOfBand(serial: String) { issued.removeAll { $0.serial == serial } }

    func seedForeignCertificates(_ count: Int) throws {
        for _ in 0..<count {
            let key = workspace.appendingPathComponent("foreign-\(UUID()).key")
            let csr = workspace.appendingPathComponent("foreign-\(UUID()).csr")
            try Self.openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", csr.path, "-subj", "/CN=Other Mac"])
            issued.append(try sign(csrURL: csr))
        }
    }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppleHTTPResponse {
        if request.url == URLBagGrandSlamEndpointResolver.lookupURL {
            return try response(request, ["urls": [
                "gsService": PrivateAppleProtocolAdapter.researched2026.grandSlamService.absoluteString,
                "trustedDeviceSecondaryAuth": PrivateAppleProtocolAdapter.researched2026.trustedDeviceVerification.absoluteString,
                "validateCode": PrivateAppleProtocolAdapter.researched2026.verificationValidation.absoluteString,
            ]])
        }
        let operation = (request.url?.lastPathComponent ?? "").replacingOccurrences(of: ".action", with: "")
        calls.append(operation)
        let body = (try? PropertyListSerialization.propertyList(from: request.httpBody ?? Data(), options: [], format: nil)) as? [String: Any] ?? [:]
        let reply: [String: Any]
        switch operation {
        case "listTeams":
            reply = teamResponse()
        case "listAllDevelopmentCerts":
            reply = ["resultCode": 0, "certificates": issued.map { ["certContent": $0.der, "serialNumber": $0.serial] }]
        case "submitDevelopmentCSR":
            guard issued.count < capacity else {
                reply = ["resultCode": 7460, "userString": "You already have a current iOS Development certificate or a pending certificate request."]
                break
            }
            let csr = workspace.appendingPathComponent("\(UUID()).csr")
            try Data(((body["csrContent"] as? String) ?? "").utf8).write(to: csr)
            let certificate = try sign(csrURL: csr)
            issued.append(certificate)
            reply = ["resultCode": 0, "certRequest": ["certContent": certificate.der, "serialNumber": certificate.serial]]
        case "revokeDevelopmentCert":
            let serial = body["serialNumber"] as? String ?? ""
            revokedSerials.append(serial)
            issued.removeAll { $0.serial == serial }
            reply = ["resultCode": 0]
        case "listDevices":
            reply = ["resultCode": 0, "devices": devices.map { ["deviceNumber": $0] }]
        case "addDevice":
            devices.append(body["deviceNumber"] as? String ?? "")
            reply = ["resultCode": 0]
        case "listAppIds":
            reply = ["resultCode": 0, "appIds": appIDs.map { ["appIdId": $0.id, "identifier": $0.bundle] }, "availableQuantity": 10]
        case "addAppId":
            appIDs.append((id: "APPID\(appIDs.count)", bundle: body["identifier"] as? String ?? ""))
            reply = ["resultCode": 0]
        case "downloadTeamProvisioningProfile":
            let appID = body["appIdId"] as? String ?? ""
            guard let bundle = appIDs.first(where: { $0.id == appID })?.bundle else { throw URLError(.badServerResponse) }
            reply = ["resultCode": 0, "provisioningProfile": ["encodedProfile": try profile(bundle: bundle)]]
        default:
            throw URLError(.unsupportedURL)
        }
        if drop.remove(operation) != nil { throw URLError(.networkConnectionLost) }
        return try response(request, reply)
    }

    private func response(_ request: URLRequest, _ value: Any) throws -> AppleHTTPResponse {
        AppleHTTPResponse(url: request.url!, statusCode: 200, headers: ["Content-Type": "text/x-xml-plist"],
                          body: try plistData(value))
    }

    private func sign(csrURL: URL) throws -> Certificate {
        let serial = String(format: "%06X", nextSerial)
        nextSerial += 1
        let out = workspace.appendingPathComponent("\(serial).der")
        try Self.openssl(["x509", "-req", "-in", csrURL.path, "-CA", workspace.appendingPathComponent("ca.pem").path,
                          "-CAkey", workspace.appendingPathComponent("ca.key").path, "-set_serial", "0x\(serial)",
                          "-days", String(validityDays), "-outform", "DER", "-out", out.path])
        return Certificate(serial: serial, der: try Data(contentsOf: out))
    }

    private func profile(bundle: String) throws -> Data {
        let now = Date().addingTimeInterval(clock.seconds)
        let plist: [String: Any] = [
            "Name": "Simulated \(bundle)",
            "TeamIdentifier": [Self.team],
            "ApplicationIdentifierPrefix": [Self.team],
            "Entitlements": [
                "application-identifier": "\(Self.team).\(bundle)",
                "com.apple.developer.team-identifier": Self.team,
                "get-task-allow": true,
                "keychain-access-groups": ["\(Self.team).*"],
            ],
            "ProvisionedDevices": devices,
            "CreationDate": now.addingTimeInterval(-60),
            "ExpirationDate": now.addingTimeInterval(7 * 86_400),
            "DeveloperCertificates": profilesOmitCertificates ? [Data("other".utf8)] : issued.map(\.der),
        ]
        let input = workspace.appendingPathComponent("\(UUID()).plist")
        let output = workspace.appendingPathComponent("\(UUID()).mobileprovision")
        try plistData(plist).write(to: input)
        try Self.openssl(["cms", "-sign", "-binary", "-nodetach", "-outform", "DER", "-md", "sha256", "-in", input.path,
                          "-signer", workspace.appendingPathComponent("ca.pem").path,
                          "-inkey", workspace.appendingPathComponent("ca.key").path, "-out", output.path])
        return try Data(contentsOf: output)
    }

    static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            print("openssl \(arguments.first ?? "") failed: \(diagnostic)")
            throw URLError(.cannotDecodeContentData)
        }
    }
}

/// M7 on the exact shipped payload (installed Veya resources) with the real Rust signer. Key, certificate
/// and profiles come from the simulated portal, so the signer must refuse the non-Apple CMS profile; the
/// test proves plan derivation, the per-team identifier rewrite and graph approval on the real bundles,
/// and that the refusal publishes nothing and leaves the shipped source intact.
final class ShippedPayloadIntegrationTests: XCTestCase {
    func testExactPayloadRewriteIsApprovedAndSimulatedProfilesAreRefusedWithoutPublishing() async throws {
        guard let library = ProcessInfo.processInfo.environment["VEYA_SIGNING_TEST_LIBRARY"] else {
            throw XCTSkip("INTEGRATION_REQUIRED: build native bridge and set VEYA_SIGNING_TEST_LIBRARY")
        }
        let resources = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEYA_EXACT_PAYLOAD_RESOURCES"]
            ?? "/Applications/Veya.app/Contents/Resources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("DeviceArtifacts").path) else {
            throw XCTSkip("INTEGRATION_REQUIRED: set VEYA_EXACT_PAYLOAD_RESOURCES to a Veya Resources directory")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veya-m7-exact-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InstallationJournalRepository(rootURL: root.appendingPathComponent("installation", isDirectory: true))
        let keyStore = VeyaSigningKeyStore(rootURL: root.appendingPathComponent("secrets/signing-keys", isDirectory: true), wrapping: MemoryWrapping())
        let portal = try SimulatedApplePortal(workspace: root.appendingPathComponent("portal", isDirectory: true))
        let backend = LiveApplePersonalTeamBackend(
            transport: portal, machineIdentity: FixtureMachineIdentity(),
            sessionStore: MemoryAuthorizationSessionStore(session: fixtureSession()),
            diagnostics: ApplePersonalTeamDiagnosticsStore(url: root.appendingPathComponent("diagnostics.json")))
        let account = AppleAccountContext(services: backend)
        let shipped = ShippedPayload(resourcesURL: resources)
        let signer = try InProcessSigner(libraryURL: URL(fileURLWithPath: library))
        let payload = PayloadDomain(rootURL: root, repository: repository,
                                    planProvider: ShippedPayloadPlanProvider(payload: shipped, rootURL: root),
                                    signing: InProcessPayloadSigning(signer: signer, keyStore: keyStore))
        let domains: [any InstallationObserver & InstallationTransition] = [
            ArtifactDomain(payload: shipped),
            AppleAccountDomain(domain: .authorization, account: account), AppleAccountDomain(domain: .team, account: account),
            SigningKeyDomain(store: keyStore),
            CertificateDomain(rootURL: root, repository: repository, account: account, keyStore: keyStore),
            ProfileDomain(rootURL: root, repository: repository, account: account,
                          device: { DeviceRegistrationTarget(udid: "00008150-00022D581E12401C", name: "Fixture") }),
            payload,
        ]
        let chain: [InstallationDomain] = [.artifact, .authorization, .team, .signingKey, .certificate, .profile, .payload]
        let engine = try VeyaReconciliationEngine(journalRepository: repository, observers: domains, transitions: domains,
                                                  sleeper: InstantSleep(), leaseSleeper: InstantSleep())

        let plan = try await engine.reconcile(
            scope: InstallationScope(domains: chain),
            to: DesiredInstallationState(requirements: chain.dropLast().map { DesiredDomainState(domain: $0) }),
            policy: ReconciliationPolicy(allowedDomains: chain, maximumTransitions: 16, localRetryLimit: 0, remoteRetryLimit: 0))
        XCTAssertEqual(plan.status, .ready, "\(String(describing: plan.failure))")

        // The production plan: both shipped bundles, per-team identifiers, profile-derived entitlements.
        let journal = try await repository.load()
        let signingPlan = try await ShippedPayloadPlanProvider(payload: shipped, rootURL: root).plan(journal: journal)
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: SimulatedApplePortal.team)
        XCTAssertEqual(signingPlan.components.map(\.role), ["main", "runner"])
        XCTAssertEqual(signingPlan.components.map(\.bundleIdentifier), [identifiers.main, identifiers.runner])
        XCTAssertEqual(signingPlan.components[1].infoPlistRewrites.keys.sorted().last?.hasPrefix("PlugIns/"), true)
        // Exact, Xcode-equivalent requests under the profile's wildcard keychain grant (`TEAM.*`); the
        // signer refuses wildcard requests (veya-signing-core `grants_are_exact_or_scoped_wildcards...`).
        let team = SimulatedApplePortal.team
        for (index, bundle) in [identifiers.main, identifiers.runner].enumerated() {
            XCTAssertEqual(signingPlan.components[index].entitlements, [bundle: [
                "application-identifier": .string("\(team).\(bundle)"),
                "com.apple.developer.team-identifier": .string(team),
                "get-task-allow": .bool(true),
                "keychain-access-groups": .array([.string("\(team).\(bundle)")]),
            ]])
        }

        do {
            _ = try await engine.reconcile(
                scope: InstallationScope(domains: chain),
                to: DesiredInstallationState(requirements: chain.map { DesiredDomainState(domain: $0) }),
                policy: ReconciliationPolicy(allowedDomains: chain, maximumTransitions: 4, localRetryLimit: 0, remoteRetryLimit: 0))
            XCTFail("a non-Apple profile must never produce a signed payload")
        } catch let failure as VeyaFailure {
            XCTAssertNotEqual(failure.code, PayloadFailure.sourceGraphChanged.code, "the exact payload's rewrite must be approved")
            XCTAssertEqual(failure.code, PayloadFailure.signingFailed.code)
            XCTAssertEqual(failure.underlyingSubsystem, "veya-signing-core/VEYA-SIGN-REQUEST",
                           "refused by the signer's request validation (profile CMS is not Apple-signed)")
        } catch {
            XCTFail("unexpected \(error)")
        }
        let after = try await repository.load()
        XCTAssertNil(after.activeResource(for: .payload))
        XCTAssertNil(after.candidateResource(for: .payload))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path)) ?? [], [])
        XCTAssertNoThrow(try ArtifactManifestLoader.assertArtifactsVerified(
            resourcesURL: resources, manifest: ArtifactManifestLoader.load(resourcesURL: resources)), "shipped source unchanged")
    }
}
