import XCTest
@testable import IOSSimMacCore

final class PersonalTeamProvisioningPOCTests: XCTestCase {
    func testDerivedBundleIdentifiersAreStableForSameTeam() throws {
        let first = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "ABCD123456")
        let second = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "abcd123456")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.runner, "\(first.uiTests).xctrunner")
        XCTAssertEqual(Set([first.main, first.witness, first.unitTests, first.uiTests, first.runner]).count, 5)
    }

    func testDerivedBundleIdentifiersDoNotMutateSourceIdentifiers() throws {
        let source = ProtectedSourceBundleIdentifiers.default
        let derived = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "ABCD123456")

        XCTAssertEqual(source.main, "com.iossim.on-device-dvt-poc")
        XCTAssertEqual(source.runner, "com.iossim.location-control-uitests.xctrunner")
        XCTAssertNotEqual(source.main, derived.main)
        XCTAssertNotEqual(source.runner, derived.runner)
    }

    func testDerivedBundleIdentifiersAreValidAppleIdentifiers() throws {
        let derived = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "ABCD123456")
        for identifier in [derived.main, derived.witness, derived.unitTests, derived.uiTests, derived.runner] {
            XCTAssertTrue(PersonalTeamBundleIdentifierSet.isValidAppleBundleIdentifier(identifier), identifier)
        }
    }

    func testRefreshPlanIsValidOutsideThreshold() {
        let now = Date(timeIntervalSince1970: 1_000)
        let manifest = makeManifest(
            teamIdentifier: "TEAM1",
            deviceIdentifierHash: "device-hash",
            mainExpiration: now.addingTimeInterval(7 * 24 * 60 * 60),
            runnerExpiration: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        let plan = PersonalTeamProvisioningPOC.refreshPlan(
            manifest: manifest,
            currentTeamIdentifier: "TEAM1",
            currentDeviceIdentifierHash: "device-hash",
            now: now
        )

        XCTAssertEqual(plan.state, .valid)
        XCTAssertFalse(plan.refreshRecommended)
    }

    func testRefreshPlanRecommendsWithinFortyEightHours() {
        let now = Date(timeIntervalSince1970: 1_000)
        let manifest = makeManifest(
            teamIdentifier: "TEAM1",
            deviceIdentifierHash: "device-hash",
            mainExpiration: now.addingTimeInterval(47 * 60 * 60),
            runnerExpiration: now.addingTimeInterval(60 * 60 * 60)
        )

        let plan = PersonalTeamProvisioningPOC.refreshPlan(
            manifest: manifest,
            currentTeamIdentifier: "TEAM1",
            currentDeviceIdentifierHash: "device-hash",
            now: now
        )

        XCTAssertEqual(plan.state, .refreshRecommended)
        XCTAssertTrue(plan.refreshRecommended)
    }

    func testRefreshPlanRejectsChangedTeam() {
        let now = Date(timeIntervalSince1970: 1_000)
        let manifest = makeManifest(
            teamIdentifier: "TEAM1",
            deviceIdentifierHash: "device-hash",
            mainExpiration: now.addingTimeInterval(7 * 24 * 60 * 60),
            runnerExpiration: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        let plan = PersonalTeamProvisioningPOC.refreshPlan(
            manifest: manifest,
            currentTeamIdentifier: "TEAM2",
            currentDeviceIdentifierHash: "device-hash",
            now: now
        )

        XCTAssertEqual(plan.state, .teamChanged)
        XCTAssertFalse(plan.refreshRecommended)
    }

    func testRefreshPlanRejectsDeviceMismatch() {
        let now = Date(timeIntervalSince1970: 1_000)
        let manifest = makeManifest(
            teamIdentifier: "TEAM1",
            deviceIdentifierHash: "device-a",
            mainExpiration: now.addingTimeInterval(7 * 24 * 60 * 60),
            runnerExpiration: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        let plan = PersonalTeamProvisioningPOC.refreshPlan(
            manifest: manifest,
            currentTeamIdentifier: "TEAM1",
            currentDeviceIdentifierHash: "device-b",
            now: now
        )

        XCTAssertEqual(plan.state, .deviceMismatch)
        XCTAssertFalse(plan.refreshRecommended)
    }

    func testRefreshPlanMarksExpiredProfile() {
        let now = Date(timeIntervalSince1970: 1_000)
        let manifest = makeManifest(
            teamIdentifier: "TEAM1",
            deviceIdentifierHash: "device-hash",
            mainExpiration: now.addingTimeInterval(-1),
            runnerExpiration: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        let plan = PersonalTeamProvisioningPOC.refreshPlan(
            manifest: manifest,
            currentTeamIdentifier: "TEAM1",
            currentDeviceIdentifierHash: "device-hash",
            now: now
        )

        XCTAssertEqual(plan.state, .expired)
        XCTAssertTrue(plan.refreshRecommended)
    }

    func testManifestRoundTripsWithoutSecrets() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let manifest = makeManifest(
            teamIdentifier: "TEAM1",
            deviceIdentifierHash: PersonalTeamProvisioningPOC.deviceIdentifierHash("raw-device-id"),
            mainExpiration: now.addingTimeInterval(7 * 24 * 60 * 60),
            runnerExpiration: now.addingTimeInterval(7 * 24 * 60 * 60)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("raw-device-id"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("private"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("pairing"))

        let decoded = try JSONDecoder().decode(PersonalTeamProvisioningManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }

    func testNoSourceBundleIdentifierMutationGuard() throws {
        let manifest = makeManifest(
            teamIdentifier: "TEAM1",
            deviceIdentifierHash: "device-hash",
            mainExpiration: Date().addingTimeInterval(60),
            runnerExpiration: Date().addingTimeInterval(60)
        )

        XCTAssertNoThrow(try PersonalTeamProvisioningPOC.validateNoSourceBundleIdentifierMutation(manifest))

        let mutated = PersonalTeamProvisioningManifest(
            teamIdentifier: manifest.teamIdentifier,
            teamKind: manifest.teamKind,
            deviceIdentifierHash: manifest.deviceIdentifierHash,
            sourceMainBundleID: "com.example.changed",
            installedMainBundleID: manifest.installedMainBundleID,
            sourceRunnerBundleID: manifest.sourceRunnerBundleID,
            installedRunnerBundleID: manifest.installedRunnerBundleID,
            sourceWitnessBundleID: manifest.sourceWitnessBundleID,
            installedWitnessBundleID: manifest.installedWitnessBundleID,
            mainExpiration: manifest.mainExpiration,
            runnerExpiration: manifest.runnerExpiration,
            witnessExpiration: manifest.witnessExpiration
        )

        XCTAssertThrowsError(try PersonalTeamProvisioningPOC.validateNoSourceBundleIdentifierMutation(mutated))
    }

    func testSigningIdentityRejectsDifferentRefreshTeam() {
        let prior = ProvisioningIdentity(teamIdentifier: "TEAM1", kind: .personalTeam)
        let current = ProvisioningIdentity(teamIdentifier: "TEAM2", kind: .personalTeam)

        XCTAssertThrowsError(try current.validateRefreshIdentity(matches: prior)) { error in
            XCTAssertEqual(
                error as? PersonalTeamProvisioningError,
                .signingTeamChanged(expected: "TEAM1", actual: "TEAM2")
            )
        }
    }

    func testAppleDevelopmentIdentityParserExtractsTeamIDsOnly() {
        let output = """
          1) ABCDEF "Apple Development: user@example.com (TEAM123456)"
          2) FEDCBA "Developer ID Application: Example Corp (PAID123456)"
             2 valid identities found
        """

        let identities = AppleCodeSigningIdentity.parseSecurityFindIdentityOutput(output)

        XCTAssertEqual(identities, [
            AppleCodeSigningIdentity(commonName: "Apple Development: user@example.com (TEAM123456)", teamIdentifier: "TEAM123456")
        ])
    }

    func testCodeSignatureParserExtractsIdentifierTeamAndAuthorities() {
        let output = """
        Executable=/tmp/App.app/App
        Identifier=com.example.app
        Authority=Apple Development: user@example.com (TEAM123456)
        Authority=Apple Worldwide Developer Relations Certification Authority
        TeamIdentifier=TEAM123456
        """

        let summary = CodeSignatureSummary.parseCodesignDisplayOutput(output)

        XCTAssertEqual(summary.identifier, "com.example.app")
        XCTAssertEqual(summary.teamIdentifier, "TEAM123456")
        XCTAssertEqual(summary.authorityTeamIdentifiers, ["TEAM123456"])
        XCTAssertEqual(summary.authorities.count, 2)
    }

    private func makeManifest(
        teamIdentifier: String,
        deviceIdentifierHash: String,
        mainExpiration: Date?,
        runnerExpiration: Date?
    ) -> PersonalTeamProvisioningManifest {
        let installed = try! PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: teamIdentifier)
        let source = ProtectedSourceBundleIdentifiers.default
        return PersonalTeamProvisioningManifest(
            teamIdentifier: teamIdentifier,
            teamKind: .personalTeam,
            deviceIdentifierHash: deviceIdentifierHash,
            sourceMainBundleID: source.main,
            installedMainBundleID: installed.main,
            sourceRunnerBundleID: source.runner,
            installedRunnerBundleID: installed.runner,
            sourceWitnessBundleID: source.witness,
            installedWitnessBundleID: installed.witness,
            mainExpiration: mainExpiration,
            runnerExpiration: runnerExpiration,
            witnessExpiration: nil,
            artifacts: [
                ProvisionedArtifactIdentity(
                    role: "iosMain",
                    sourceBundleIdentifier: source.main,
                    installedBundleIdentifier: installed.main,
                    profile: ProvisioningExpiration(creationDate: nil, expirationDate: mainExpiration)
                ),
                ProvisionedArtifactIdentity(
                    role: "locationControlRunner",
                    sourceBundleIdentifier: source.runner,
                    installedBundleIdentifier: installed.runner,
                    profile: ProvisioningExpiration(creationDate: nil, expirationDate: runnerExpiration)
                )
            ]
        )
    }
}
