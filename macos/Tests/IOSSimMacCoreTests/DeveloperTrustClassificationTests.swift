import XCTest
@testable import IOSSimMacCore

/// Conditional classification of the untrusted-developer state.
///
/// iOS folds invalid code signature, inadequate entitlements and untrusted developer
/// profile into one launch rejection, so the structured denial alone proves nothing.
/// These tests hold the two halves apart: the Apple-side shape, and the prerequisites
/// Veya proved itself. Neither half may classify on its own.
final class DeveloperTrustClassificationTests: XCTestCase {

    // MARK: fixtures

    private static let allProven = DeveloperTrustPrerequisites(
        developerServicesProven: true, applicationInstalled: true,
        payloadSignatureVerified: true, profileBindingValidated: true,
        certificateInventoryMatched: true)

    private func rejection(
        chain: [NativeErrorChainNode],
        envelope: NativeLaunchRejectionEnvelope = .coreDeviceErrorEnvelope,
        complete: Bool = true,
        schema: Int = NativeLaunchRejection.supportedSchemaVersion
    ) -> NativeDeviceBridgeError {
        .launchRejectedStructured(NativeLaunchRejection(
            schemaVersion: schema, envelope: envelope, chain: chain, chainComplete: complete))
    }

    /// The untrusted-developer chain: CoreDevice launch failure -> FrontBoard service
    /// denial -> FrontBoard open-application Security denial.
    private var untrustedDeveloperChain: [NativeErrorChainNode] {
        [
            .init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
            .init(domain: "FBSOpenApplicationServiceErrorDomain", code: 1, bsDescription: "RequestDenied"),
            .init(domain: "FBSOpenApplicationErrorDomain", code: 3, bsDescription: "Security"),
        ]
    }

    // MARK: positive

    func testStructuredSecurityDenialWithEveryPrerequisiteProvenIsDeveloperTrust() {
        let error = rejection(chain: untrustedDeveloperChain)
        XCTAssertTrue(error.isDeveloperTrustRejection(given: Self.allProven))
        let mapped = DeviceFailureMapping.map(error, trustPrerequisites: Self.allProven)
        XCTAssertEqual(mapped.state, .waitingForUser)
        XCTAssertEqual(mapped.userAction, DeviceFailureMapping.developerTrust)
    }

    func testTheTrustUserActionDrivesTheExistingTrustDeveloperStage() {
        // The presentation already routes this exact action; classification is the only
        // thing that was missing.
        let stage = DevelopmentInstallationStage.resolve(
            firstFailureCode: nil, failureDomain: .developerSupport,
            userAction: DeviceFailureMapping.developerTrust,
            status: nil, issuedRunSetupRequest: false)
        XCTAssertEqual(stage, .trustDeveloper)
        XCTAssertEqual(stage.primaryAction, .continueUserAction)
    }

    // MARK: negative — prerequisites not proven

    func testAnyUnprovenPrerequisiteRefusesTheTrustClassification() {
        let error = rejection(chain: untrustedDeveloperChain)
        let mutations: [(String, DeveloperTrustPrerequisites)] = [
            ("nothing proven", .unproven),
            ("developer services", DeveloperTrustPrerequisites(
                developerServicesProven: false, applicationInstalled: true,
                payloadSignatureVerified: true, profileBindingValidated: true,
                certificateInventoryMatched: true)),
            ("application installed", DeveloperTrustPrerequisites(
                developerServicesProven: true, applicationInstalled: false,
                payloadSignatureVerified: true, profileBindingValidated: true,
                certificateInventoryMatched: true)),
            ("payload signature", DeveloperTrustPrerequisites(
                developerServicesProven: true, applicationInstalled: true,
                payloadSignatureVerified: false, profileBindingValidated: true,
                certificateInventoryMatched: true)),
            ("profile binding", DeveloperTrustPrerequisites(
                developerServicesProven: true, applicationInstalled: true,
                payloadSignatureVerified: true, profileBindingValidated: false,
                certificateInventoryMatched: true)),
            ("certificate inventory", DeveloperTrustPrerequisites(
                developerServicesProven: true, applicationInstalled: true,
                payloadSignatureVerified: true, profileBindingValidated: true,
                certificateInventoryMatched: false)),
        ]
        for (missing, prerequisites) in mutations {
            XCTAssertFalse(error.isDeveloperTrustRejection(given: prerequisites),
                           "unproven \(missing) must not classify as developer trust")
            XCTAssertNotEqual(DeviceFailureMapping.map(error, trustPrerequisites: prerequisites).userAction,
                              DeviceFailureMapping.developerTrust)
        }
    }

    func testMapWithoutExplicitPrerequisitesNeverClassifiesTrust() {
        // The default argument is `.unproven`, so every existing caller stays fail-closed.
        let error = rejection(chain: untrustedDeveloperChain)
        XCTAssertNotEqual(DeviceFailureMapping.map(error).userAction, DeviceFailureMapping.developerTrust)
    }

    // MARK: negative — Apple-side shapes that must never become trust

    func testOtherLaunchRejectionShapesAreNeverDeveloperTrust() {
        let cases: [(String, [NativeErrorChainNode])] = [
            ("CoreDevice 10002 alone", [
                .init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
            ]),
            ("bad executable", [
                .init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
                .init(domain: "FBSOpenApplicationErrorDomain", code: 5, bsDescription: "BadExecutable"),
            ]),
            ("request denied for an unrelated reason", [
                .init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
                .init(domain: "FBSOpenApplicationErrorDomain", code: 1, bsDescription: "RequestDenied"),
            ]),
            ("security code without the Security description", [
                .init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
                .init(domain: "FBSOpenApplicationErrorDomain", code: 3, bsDescription: nil),
            ]),
            ("Security description on the wrong domain", [
                .init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
                .init(domain: "FBSOpenApplicationServiceErrorDomain", code: 3, bsDescription: "Security"),
            ]),
            ("application not found", [
                .init(domain: "com.apple.dt.CoreDeviceError", code: 10002),
                .init(domain: "FBSOpenApplicationErrorDomain", code: 2, bsDescription: "NotFound"),
            ]),
            ("an unknown future Apple domain", [
                .init(domain: "com.apple.SomeFutureErrorDomain", code: 3, bsDescription: "Security"),
            ]),
            ("empty chain", []),
        ]
        for (name, chain) in cases {
            let error = rejection(chain: chain)
            XCTAssertFalse(error.isDeveloperTrustRejection(given: Self.allProven),
                           "\(name) must not classify as developer trust")
        }
    }

    func testAHeuristicEnvelopeIsNeverEnoughEvenWithTheRightChain() {
        // A substring guess in the bridge must never reach classification, however
        // convincing the chain looks.
        let error = rejection(chain: untrustedDeveloperChain, envelope: .heuristic)
        XCTAssertFalse(error.isDeveloperTrustRejection(given: Self.allProven))
    }

    func testAnIncompleteOrUnknownSchemaChainIsRefused() {
        XCTAssertFalse(rejection(chain: untrustedDeveloperChain, complete: false)
            .isDeveloperTrustRejection(given: Self.allProven), "a truncated chain must fail closed")
        XCTAssertFalse(rejection(chain: untrustedDeveloperChain, schema: 99)
            .isDeveloperTrustRejection(given: Self.allProven), "an unknown schema must fail closed")
    }

    func testNonLaunchFailuresKeepTheirOwnMeaning() {
        let cases: [(NativeDeviceBridgeError, String)] = [
            (.developerModeRequired, DeviceFailureMapping.developerMode),
            (.deviceLocked, DeviceFailureMapping.unlock),
            (.trustRequired, DeviceFailureMapping.trust),
        ]
        for (error, expected) in cases {
            let mapped = DeviceFailureMapping.map(error, trustPrerequisites: Self.allProven)
            XCTAssertEqual(mapped.userAction, expected)
            XCTAssertNotEqual(mapped.userAction, DeviceFailureMapping.developerTrust)
        }
        for error: NativeDeviceBridgeError in [
            .deviceDisconnected, .deviceNotFound, .timedOut, .applicationNotFound("app"),
            .ddiRequired("image"), .rsdUnavailable("rsd"), .appServiceUnavailable("svc"),
        ] {
            XCTAssertFalse(error.isDeveloperTrustRejection(given: Self.allProven),
                           "\(error) must not classify as developer trust")
        }
    }

    // MARK: prerequisites are read from real journal evidence

    func testPrerequisitesRequireEvidenceBoundToTheActiveRecordAndGeneration() throws {
        let now = Date()
        func journal(kind: String, generation: UInt64, linked: Bool,
                     validUntil: Date?) throws -> InstallationJournal {
            let identity = try ResourceIdentity(domain: .payload, resourceID: "payload-1",
                                                digest: "sha256:" + String(repeating: "a", count: 64))
            let evidence = try Evidence(
                id: "sha256:" + String(repeating: "b", count: 64), kind: kind,
                generation: Generation(rawValue: generation), subject: identity,
                capturedAt: now, validUntil: validUntil, provenance: "veya-signing-core")
            var record = try ResourceRecord(
                identity: identity, lifecycle: .active, generation: Generation(rawValue: 1),
                ownership: .privateKeyControl, createdAt: now, observedAt: now)
            record.evidenceIDs = linked ? [evidence.id] : []
            var journal = InstallationJournal(installationID: UUID())
            journal.active[InstallationDomain.payload.rawValue] = record
            journal.evidence = [evidence]
            return journal
        }

        let good = try journal(kind: "payloadIndependentVerification", generation: 1,
                               linked: true, validUntil: nil)
        XCTAssertTrue(DeveloperTrustPrerequisites.proved(
            good, .payload, kind: "payloadIndependentVerification", at: now))

        // Wrong kind, unlinked evidence, a different generation, and expired evidence
        // must each fail: none of them proves this record.
        let wrongKind = try journal(kind: "somethingElse", generation: 1, linked: true, validUntil: nil)
        XCTAssertFalse(DeveloperTrustPrerequisites.proved(
            wrongKind, .payload, kind: "payloadIndependentVerification", at: now))

        let unlinked = try journal(kind: "payloadIndependentVerification", generation: 1,
                                   linked: false, validUntil: nil)
        XCTAssertFalse(DeveloperTrustPrerequisites.proved(
            unlinked, .payload, kind: "payloadIndependentVerification", at: now))

        let otherGeneration = try journal(kind: "payloadIndependentVerification", generation: 7,
                                          linked: true, validUntil: nil)
        XCTAssertFalse(DeveloperTrustPrerequisites.proved(
            otherGeneration, .payload, kind: "payloadIndependentVerification", at: now))

        let expired = try journal(kind: "payloadIndependentVerification", generation: 1,
                                  linked: true, validUntil: now.addingTimeInterval(-1))
        XCTAssertFalse(DeveloperTrustPrerequisites.proved(
            expired, .payload, kind: "payloadIndependentVerification", at: now))
    }

    func testAnEmptyJournalProvesNothing() throws {
        let journal = InstallationJournal(installationID: UUID())
        let prerequisites = DeveloperTrustPrerequisites.fromJournal(
            journal, developerServicesProven: true)
        XCTAssertFalse(prerequisites.allProven)
        XCTAssertFalse(prerequisites.applicationInstalled)
        XCTAssertFalse(prerequisites.payloadSignatureVerified)
        XCTAssertFalse(prerequisites.profileBindingValidated)
        XCTAssertFalse(prerequisites.certificateInventoryMatched)
    }
}
