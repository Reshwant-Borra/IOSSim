import XCTest
@testable import IOSSimMacCore

final class PersonalTeamProvisioningPOCTests: XCTestCase {
    func testDerivedBundleIdentifiersAreStableForSameTeam() throws {
        let first = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "ABCD123456")
        let second = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "abcd123456")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.main.hasSuffix(".on-device-dvt-poc"))
        XCTAssertEqual(first.runner, "\(first.uiTests).xctrunner")
        XCTAssertEqual(Set([first.main, first.witness, first.unitTests, first.uiTests, first.runner]).count, 5)
    }

    func testDerivedBundleIdentifiersDifferForDifferentTeams() throws {
        let first = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "ABCD123456")
        let second = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "WXYZ987654")

        XCTAssertNotEqual(first.main, second.main)
        XCTAssertNotEqual(first.uiTests, second.uiTests)
        XCTAssertNotEqual(first.runner, second.runner)
    }

    func testDerivedBundleIdentifiersDoNotMutateSourceIdentifiers() throws {
        let source = ProtectedSourceBundleIdentifiers.default
        let derived = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "ABCD123456")

        XCTAssertEqual(source.main, "com.iossim.on-device-dvt-poc")
        XCTAssertEqual(source.uiTests, "com.iossim.location-control-uitests")
        XCTAssertEqual(source.runner, "com.iossim.location-control-uitests.xctrunner")
        XCTAssertNotEqual(source.main, derived.main)
        XCTAssertNotEqual(source.uiTests, derived.uiTests)
        XCTAssertNotEqual(source.runner, derived.runner)
    }

    func testCleanMacFailureTeamUsesDerivedMainIdentifier() throws {
        let derived = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "LA898U57K7")

        XCTAssertEqual(derived.main, "com.personalteam.iossim.t812ad2aa5dec.on-device-dvt-poc")
        XCTAssertNotEqual(derived.main, ProtectedSourceBundleIdentifiers.default.main)
        XCTAssertEqual(
            derived.runner,
            "com.personalteam.iossim.t812ad2aa5dec.location-control-uitests.xctrunner"
        )
    }

    func testRunnerIdentifierRelationshipIsCoherent() throws {
        let derived = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "5337SALD55")

        XCTAssertTrue(derived.runner.hasSuffix(".xctrunner"))
        XCTAssertEqual(derived.runner, "\(derived.uiTests).xctrunner")
        XCTAssertNotEqual(derived.runner, derived.main)
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

    func testManifestRecordsMainUITestAndRunnerInstalledIdentifiers() throws {
        let manifest = makeManifest(
            teamIdentifier: "5337SALD55",
            deviceIdentifierHash: "device-hash",
            mainExpiration: nil,
            runnerExpiration: nil
        )
        let derived = try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: "5337SALD55")

        XCTAssertEqual(manifest.sourceMainBundleID, ProtectedSourceBundleIdentifiers.default.main)
        XCTAssertEqual(manifest.installedMainBundleID, derived.main)
        XCTAssertEqual(manifest.sourceUITestBundleID, ProtectedSourceBundleIdentifiers.default.uiTests)
        XCTAssertEqual(manifest.installedUITestBundleID, derived.uiTests)
        XCTAssertEqual(manifest.sourceRunnerBundleID, ProtectedSourceBundleIdentifiers.default.runner)
        XCTAssertEqual(manifest.installedRunnerBundleID, derived.runner)
    }

    func testWitnessIsExcludedFromConsumerPersonalTeamManifest() {
        let manifest = makeManifest(
            teamIdentifier: "TEAM1",
            deviceIdentifierHash: "device-hash",
            mainExpiration: nil,
            runnerExpiration: nil
        )

        XCTAssertEqual(manifest.sourceWitnessBundleID, ProtectedSourceBundleIdentifiers.default.witness)
        XCTAssertNil(manifest.installedWitnessBundleID)
        XCTAssertNil(manifest.witnessExpiration)
        XCTAssertFalse(manifest.artifacts.contains { $0.role == "locationWitness" })
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
            sourceUITestBundleID: manifest.sourceUITestBundleID,
            installedUITestBundleID: manifest.installedUITestBundleID,
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

    func testRefreshUsesSameDerivedMainAndRunnerIdentifiers() {
        let original = makeManifest(
            teamIdentifier: "5337SALD55",
            deviceIdentifierHash: "device-hash",
            mainExpiration: Date(timeIntervalSince1970: 1_000),
            runnerExpiration: Date(timeIntervalSince1970: 1_000)
        )
        let refreshed = makeManifest(
            teamIdentifier: "5337SALD55",
            deviceIdentifierHash: "device-hash",
            mainExpiration: Date(timeIntervalSince1970: 2_000),
            runnerExpiration: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(original.installedMainBundleID, refreshed.installedMainBundleID)
        XCTAssertEqual(original.installedUITestBundleID, refreshed.installedUITestBundleID)
        XCTAssertEqual(original.installedRunnerBundleID, refreshed.installedRunnerBundleID)
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
            sourceUITestBundleID: source.uiTests,
            installedUITestBundleID: installed.uiTests,
            sourceRunnerBundleID: source.runner,
            installedRunnerBundleID: installed.runner,
            sourceWitnessBundleID: source.witness,
            installedWitnessBundleID: nil,
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
