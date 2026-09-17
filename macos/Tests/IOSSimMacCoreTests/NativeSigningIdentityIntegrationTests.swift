import CryptoKit
import Foundation
import Security
import XCTest
@testable import IOSSimMacCore

final class NativeSigningIdentityIntegrationTests: XCTestCase {
    func testCertificateWithoutPrivateKeyIsPreciselyClassified() async throws {
        try requireIntegrationTests()
        let fixture = try KeychainSigningFixture()
        defer { fixture.cleanup() }
        fixture.deletePrivateKey()

        do {
            _ = try await fixture.resolver.resolve(
                certificateDER: fixture.certificateDER,
                expectedSHA256: fixture.certificateSHA256,
                expectedKeyApplicationTagIdentifier: fixture.applicationTagIdentifier,
                teamIdentifier: fixture.teamIdentifier,
                workingDirectory: fixture.root
            )
            XCTFail("Expected missing private key")
        } catch let error as NativeSigningIdentityResolutionFailure {
            XCTAssertEqual(error.failure.code, .signingPrivateKeyNotFound)
            XCTAssertTrue(error.diagnostics.keychainCertificateFound)
            XCTAssertFalse(error.diagnostics.keychainPrivateKeyFound)
            XCTAssertEqual(error.diagnostics.privateKeyQueryStatus, errSecItemNotFound)
        }
    }

    func testPermanentKeyCertificateIdentityCodesignAndRestart() async throws {
        try requireIntegrationTests()
        let fixture = try KeychainSigningFixture()
        defer { fixture.cleanup() }

        let first = try await fixture.resolver.resolve(
            certificateDER: fixture.certificateDER,
            expectedSHA256: fixture.certificateSHA256,
            expectedKeyApplicationTagIdentifier: fixture.applicationTagIdentifier,
            teamIdentifier: fixture.teamIdentifier,
            workingDirectory: fixture.root
        )

        XCTAssertTrue(first.diagnostics.profileCertificatePresent)
        XCTAssertTrue(first.diagnostics.keychainCertificateFound)
        XCTAssertTrue(first.diagnostics.certificateInserted)
        XCTAssertTrue(first.diagnostics.keychainPrivateKeyFound)
        XCTAssertTrue(first.diagnostics.certificatePublicKeyMatch)
        XCTAssertTrue(first.diagnostics.keychainIdentityFound)
        XCTAssertTrue(first.diagnostics.secIdentityResolutionSucceeded)
        XCTAssertFalse(
            first.diagnostics.codesignIdentityVisible,
            "The isolated leaf is intentionally not Apple-trusted; actual usability is proved by the sign test."
        )
        XCTAssertTrue(first.diagnostics.codesignSignTestSucceeded)

        let restartedStore = IOSSimIdentityMetadataStore(
            service: fixture.service,
            keyLabel: fixture.keyLabel
        )
        XCTAssertEqual(
            restartedStore.lookupPrivateKey(applicationTag: Data(fixture.applicationTagIdentifier.utf8)).status,
            errSecSuccess
        )
        let restartedResolver = NativeSigningIdentityResolver(runner: ProcessRunner())
        let restarted = try await restartedResolver.resolve(
            certificateDER: fixture.certificateDER,
            expectedSHA256: fixture.certificateSHA256,
            expectedKeyApplicationTagIdentifier: fixture.applicationTagIdentifier,
            teamIdentifier: fixture.teamIdentifier,
            workingDirectory: fixture.root
        )
        XCTAssertEqual(restarted.certificateSHA1, first.certificateSHA1)
        XCTAssertFalse(restarted.diagnostics.certificateInserted)

        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, fixture.certificateDER as CFData))
        let duplicateStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary, nil)
        XCTAssertEqual(duplicateStatus, errSecDuplicateItem)
    }

    func testCleanConsumerMacIOSSimOwnedKeyIsUsableFromPackagedHelperWithoutInteraction() async throws {
        try requireIntegrationTests()
        let helper = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("IOSSimSigningKeyTestHelper", isDirectory: false)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path), "The separate helper process must be built for this regression")
        let policy = IOSSimSigningKeyAccessPolicy(trustedExecutablePaths: [
            IOSSimSigningKeyAccessPolicy.codesignPath,
            helper.path,
        ])
        let fixture = try KeychainSigningFixture(signingAccessPolicy: policy)
        defer { fixture.cleanup() }

        let resolution = try await fixture.resolver.resolve(
            certificateDER: fixture.certificateDER,
            expectedSHA256: fixture.certificateSHA256,
            expectedKeyApplicationTagIdentifier: fixture.applicationTagIdentifier,
            teamIdentifier: fixture.teamIdentifier,
            workingDirectory: fixture.root
        )
        let helperResult = try await ProcessRunner().run(
            executableURL: helper,
            arguments: [resolution.certificateSHA1, fixture.root.path],
            workingDirectory: fixture.root,
            environment: RuntimeProvisioning.deterministicEnvironment(),
            redactOutput: false
        )

        XCTAssertEqual(helperResult.exitCode, 0, helperResult.combinedOutput)
        XCTAssertFalse(helperResult.combinedOutput.lowercased().contains("errsecinternalcomponent"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent("CleanConsumerSigningProbe.app/_CodeSignature/CodeResources").path))
    }

    func testCertificateKeyMismatchIsPreciselyClassified() async throws {
        try requireIntegrationTests()
        let certificateFixture = try KeychainSigningFixture()
        let otherFixture = try KeychainSigningFixture(teamIdentifier: certificateFixture.teamIdentifier)
        defer {
            certificateFixture.cleanup()
            otherFixture.cleanup()
        }

        do {
            _ = try await certificateFixture.resolver.resolve(
                certificateDER: certificateFixture.certificateDER,
                expectedSHA256: certificateFixture.certificateSHA256,
                expectedKeyApplicationTagIdentifier: otherFixture.applicationTagIdentifier,
                teamIdentifier: certificateFixture.teamIdentifier,
                workingDirectory: certificateFixture.root
            )
            XCTFail("Expected certificate/private-key mismatch")
        } catch let error as NativeSigningIdentityResolutionFailure {
            XCTAssertEqual(error.failure.code, .signingCertificateKeyMismatch)
            XCTAssertTrue(error.diagnostics.keychainPrivateKeyFound)
            XCTAssertFalse(error.diagnostics.certificatePublicKeyMatch)
        }
    }

    func testCurrentPreparedAppleIdentityIsVisibleAndCanSignWhenAvailable() async throws {
        try requireIntegrationTests()
        let artifactURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IOSSim/native-provisioning-artifacts.json")
        guard FileManager.default.fileExists(atPath: artifactURL.path) else {
            throw XCTSkip("No current native Personal Team artifact is present on this Mac.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artifacts = try decoder.decode(
            NativeProvisioningArtifacts.self,
            from: Data(contentsOf: artifactURL)
        )
        let profile = try XCTUnwrap(artifacts.profiles.first)
        let certificateDER = try developerCertificate(
            in: profile.profileData,
            sha256: artifacts.certificateFingerprint
        )
        let resolution = try await NativeSigningIdentityResolver(runner: ProcessRunner()).resolve(
            certificateDER: certificateDER,
            expectedSHA256: artifacts.certificateFingerprint,
            expectedKeyApplicationTagIdentifier: artifacts.keyApplicationTagIdentifier,
            teamIdentifier: artifacts.teamIdentifier,
            workingDirectory: artifactURL.deletingLastPathComponent()
        )

        XCTAssertTrue(resolution.diagnostics.codesignIdentityVisible)
        XCTAssertTrue(resolution.diagnostics.codesignSignTestSucceeded)
        XCTAssertTrue(resolution.diagnostics.keyApplicationTagIdentifier?.hasPrefix(
            "com.iossim.personal-team.\(artifacts.teamIdentifier)."
        ) == true)
    }

    func testCurrentPackagedMainAndRunnerCompleteLocalPipelineWithRealCodesign() async throws {
        try requireIntegrationTests()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let artifactDirectory = home.appendingPathComponent("Library/Application Support/IOSSim")
        let artifactURL = artifactDirectory.appendingPathComponent(NativeProvisioningArtifactStore.fileName)
        let resources = URL(fileURLWithPath: "/Applications/IOSSim.app/Contents/Resources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: artifactURL.path),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("DeviceArtifacts/manifest.json").path) else {
            throw XCTSkip("Current prepared profiles and packaged device artifacts are required.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artifacts = try decoder.decode(NativeProvisioningArtifacts.self, from: Data(contentsOf: artifactURL))
        let profile = try XCTUnwrap(artifacts.profiles.first)
        let plist = try profilePlist(profile.profileData)
        let physicalUDID = try XCTUnwrap((plist["ProvisionedDevices"] as? [String])?.first)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-real-artifact-pipeline-\(UUID().uuidString)", isDirectory: true)
        let state = root.appendingPathComponent("State", isDirectory: true)
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let deviceRunner = ActualArtifactPipelineRunner(
            physicalUDID: physicalUDID,
            identifiers: artifacts.identifiers,
            captureRoot: captures
        )
        let processRunner = ProcessRunner { executable, arguments, workingDirectory, environment, redactOutput in
            try await deviceRunner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                redactOutput: redactOutput
            )
        }
        let stateStore = ConsumerProvisioningStateStore(directoryURL: state)
        let provisioner = ConsumerArtifactProvisioner(
            context: RuntimeProvisioningContext(resourcesURL: resources, runner: processRunner),
            stateStore: stateStore,
            nativeArtifactStore: NativeProvisioningArtifactStore(directoryURL: artifactDirectory),
            nativeIdentityResolver: NativeSigningIdentityResolver(runner: processRunner),
            workspaceRootURL: root.appendingPathComponent("Workspaces", isDirectory: true),
            inventoryReader: DevicectlApplicationInventoryReader(),
            deviceBackend: DevicectlProvisioningBackend()
        )
        let result = try await provisioner.provision(.init(
            operation: .install,
            selectedDeviceIdentifier: physicalUDID,
            selectedTeamIdentifier: artifacts.teamIdentifier,
            allowFreshInstallAfterCrossTeamConflict: false,
            backend: .nativePersonalTeam
        ))
        XCTAssertEqual(result.finalStage, .complete)

        let evidence = await deviceRunner.evidence()
        XCTAssertEqual(evidence.installedIdentifiers, [artifacts.identifiers.main, artifacts.identifiers.runner])
        let installCommands = evidence.commands.filter {
            $0.executable.path == "/usr/bin/xcrun"
                && $0.arguments.starts(with: ["devicectl", "device", "install", "app"])
        }
        XCTAssertEqual(installCommands.count, 2)
        XCTAssertTrue(installCommands.allSatisfy {
            guard let deviceIndex = $0.arguments.firstIndex(of: "--device"),
                  $0.arguments.indices.contains(deviceIndex + 1) else { return false }
            return $0.arguments[deviceIndex + 1] == physicalUDID
        })
        XCTAssertTrue(installCommands[0].arguments.contains(where: { $0.hasSuffix("IOSSim DVT POC.app") }))
        XCTAssertTrue(installCommands[1].arguments.contains(where: { $0.hasSuffix("IOSSimLocationControlUITests-Runner.app") }))
        XCTAssertFalse(evidence.commands.contains(where: {
            $0.executable.lastPathComponent == "xcodebuild"
                || $0.arguments.contains("-allowProvisioningUpdates")
                || $0.arguments.contains("CODE_SIGN_STYLE=Automatic")
        }))
        let signCommands = evidence.commands.filter {
            $0.executable.path == "/usr/bin/codesign" && $0.arguments.contains("--sign")
        }
        let mainIndex = try XCTUnwrap(signCommands.firstIndex(where: { $0.arguments.last?.hasSuffix("IOSSim DVT POC.app") == true }))
        let runnerIndex = try XCTUnwrap(signCommands.firstIndex(where: { $0.arguments.last?.hasSuffix("IOSSimLocationControlUITests-Runner.app") == true }))
        XCTAssertTrue(signCommands[..<mainIndex].contains(where: {
            let path = $0.arguments.last ?? ""
            return path.hasSuffix(".xctest") || path.hasSuffix(".framework") || path.hasSuffix(".dylib")
        }))
        XCTAssertLessThan(mainIndex, runnerIndex)

        let localStages = await stateStore.loadEvents().filter { $0.result == .passed }.map(\.stage)
        for required in [
            ConsumerProvisioningStage.preparedNativeContextReused,
            .profileCertificatePresent, .keychainCertificateFound, .keychainPrivateKeyFound,
            .certificatePublicKeyMatch, .keychainIdentityFound, .secIdentityResolutionSucceeded,
            .codesignIdentityVisible, .codesignSignTestSucceeded, .signingIdentityResolved,
            .preparingArtifacts, .signingNestedComponents, .signingMain, .signingRunner,
            .verifyingSignatures, .artifactValidationComplete, .installCommandsPrepared,
            .runtimeConfigurationPrepared, .installingMain, .installingRunner,
            .verifyingInstallation, .writingRuntimeConfiguration,
            .verifyingRuntimeConfiguration, .complete,
        ] {
            XCTAssertTrue(localStages.contains(required), "Missing local checkpoint \(required.rawValue)")
        }

        for app in [evidence.mainCapture, evidence.runnerCapture].compactMap({ $0 }) {
            let verification = try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", app.path],
                workingDirectory: captures
            )
            XCTAssertEqual(verification.exitCode, 0, verification.combinedOutput)
            for nested in nestedSignedBundles(in: app) {
                let nestedVerification = try await ProcessRunner().run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--verify", "--strict", nested.path],
                    workingDirectory: captures
                )
                XCTAssertEqual(nestedVerification.exitCode, 0, nestedVerification.combinedOutput)
            }

            let info = try profilePlist(Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")))
            let appInfo = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appendingPathComponent("Info.plist")),
                options: [], format: nil
            ) as! [String: Any]
            let bundleIdentifier = try XCTUnwrap(appInfo["CFBundleIdentifier"] as? String)
            let profileEntitlements = try XCTUnwrap(info["Entitlements"] as? [String: Any])
            XCTAssertEqual((info["TeamIdentifier"] as? [String])?.first, artifacts.teamIdentifier)
            XCTAssertEqual(profileEntitlements["application-identifier"] as? String,
                           "\(artifacts.teamIdentifier).\(bundleIdentifier)")
            XCTAssertEqual(profileEntitlements["com.apple.developer.team-identifier"] as? String,
                           artifacts.teamIdentifier)
            XCTAssertEqual(profileEntitlements["get-task-allow"] as? Bool, true)
            XCTAssertTrue((info["ProvisionedDevices"] as? [String])?.contains(physicalUDID) == true)
            XCTAssertTrue((info["ExpirationDate"] as? Date).map { $0 > Date() } == true)
            let profileCertificates = info["DeveloperCertificates"] as? [Data] ?? []
            XCTAssertTrue(profileCertificates.contains(where: {
                SHA256.hash(data: $0).map { String(format: "%02X", $0) }.joined()
                    == artifacts.certificateFingerprint
            }))

            let signed = try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["-d", "--entitlements", ":-", app.path],
                workingDirectory: captures,
                redactOutput: false
            )
            let signedEntitlements = try XCTUnwrap(plistDictionary(in: signed.combinedOutput))
            XCTAssertEqual(signedEntitlements["application-identifier"] as? String,
                           profileEntitlements["application-identifier"] as? String)
            XCTAssertEqual(signedEntitlements["com.apple.developer.team-identifier"] as? String,
                           artifacts.teamIdentifier)
            XCTAssertEqual(signedEntitlements["get-task-allow"] as? Bool, true)
            XCTAssertEqual(signedEntitlements["keychain-access-groups"] as? [String],
                           profileEntitlements["keychain-access-groups"] as? [String])
        }

        let storedManifest = try await stateStore.loadManifest()
        let manifest = try XCTUnwrap(storedManifest)
        XCTAssertEqual(manifest.teamID, artifacts.teamIdentifier)
        XCTAssertEqual(manifest.deviceIdentifierHash, PersonalTeamProvisioningPOC.deviceIdentifierHash(physicalUDID))
        XCTAssertEqual(manifest.installedMainBundleID, artifacts.identifiers.main)
        XCTAssertEqual(manifest.installedRunnerBundleID, artifacts.identifiers.runner)
        XCTAssertFalse(evidence.commands.flatMap(\.arguments).contains(where: { $0.contains("5337SALD55") }))
    }

    private func requireIntegrationTests() throws {
        guard ProcessInfo.processInfo.environment["IOSSIM_RUN_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set IOSSIM_RUN_KEYCHAIN_INTEGRATION=1 for isolated Keychain/codesign tests.")
        }
    }

    private func nestedSignedBundles(in app: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter {
            ["xctest", "framework", "appex", "app", "dylib"].contains($0.pathExtension)
        }
    }

    private func plistDictionary(in output: String) -> [String: Any]? {
        guard let start = output.range(of: "<?xml")?.lowerBound,
              let end = output.range(of: "</plist>", options: .backwards)?.upperBound else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: Data(output[start..<end].utf8), options: [], format: nil
        ) as? [String: Any]
    }
}

private func developerCertificate(in profileData: Data, sha256 expected: String) throws -> Data {
    var decoder: CMSDecoder?
    guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
          profileData.withUnsafeBytes({ bytes in
              CMSDecoderUpdateMessage(decoder, bytes.baseAddress!, profileData.count)
          }) == errSecSuccess,
          CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
        throw NSError(domain: "IOSSimKeychainIntegration", code: 2)
    }
    var content: CFData?
    guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
          let content = content as Data?,
          let plist = try PropertyListSerialization.propertyList(from: content, options: [], format: nil) as? [String: Any],
          let certificates = plist["DeveloperCertificates"] as? [Data],
          let certificate = certificates.first(where: {
              SHA256.hash(data: $0).map { String(format: "%02X", $0) }.joined() == expected
          }) else {
        throw NSError(domain: "IOSSimKeychainIntegration", code: 3)
    }
    return certificate
}

private func profilePlist(_ profileData: Data) throws -> [String: Any] {
    var decoder: CMSDecoder?
    guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
          profileData.withUnsafeBytes({ CMSDecoderUpdateMessage(decoder, $0.baseAddress!, profileData.count) }) == errSecSuccess,
          CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
        throw NSError(domain: "IOSSimKeychainIntegration", code: 4)
    }
    var content: CFData?
    guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
          let data = content as Data?,
          let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        throw NSError(domain: "IOSSimKeychainIntegration", code: 5)
    }
    return plist
}

private actor ActualArtifactPipelineRunner {
    struct Command: Sendable {
        let executable: URL
        let arguments: [String]
    }

    struct Evidence: Sendable {
        let commands: [Command]
        let installedIdentifiers: [String]
        let mainCapture: URL?
        let runnerCapture: URL?
    }

    private let physicalUDID: String
    private let identifiers: PersonalTeamBundleIdentifierSet
    private let captureRoot: URL
    private var commands: [Command] = []
    private var installedIdentifiers: [String] = []
    private var mainCapture: URL?
    private var runnerCapture: URL?

    init(physicalUDID: String, identifiers: PersonalTeamBundleIdentifierSet, captureRoot: URL) {
        self.physicalUDID = physicalUDID
        self.identifiers = identifiers
        self.captureRoot = captureRoot
    }

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]?,
        redactOutput: Bool
    ) async throws -> ProcessResult {
        commands.append(Command(executable: executable, arguments: arguments))
        guard executable.path == "/usr/bin/xcrun", arguments.first == "devicectl" else {
            return try await ProcessRunner().run(
                executableURL: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                redactOutput: redactOutput
            )
        }
        if arguments.starts(with: ["devicectl", "list", "devices"]) {
            try writeJSON([
                "result": ["devices": [[
                    "identifier": physicalUDID,
                    "deviceProperties": ["name": "Fixture iPhone", "developerModeStatus": "enabled"],
                    "hardwareProperties": ["deviceType": "iPhone", "platform": "iOS", "udid": physicalUDID],
                    "connectionProperties": ["pairingState": "paired"],
                ]]],
            ], toOption: "--json-output", arguments: arguments)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        if arguments.starts(with: ["devicectl", "device", "info", "lockState"]) {
            try writeJSON(["result": ["passcodeRequired": false]], toOption: "--json-output", arguments: arguments)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        if arguments.starts(with: ["devicectl", "device", "info", "apps"]) {
            let requested = option("--bundle-id", arguments: arguments)
            let apps = installedIdentifiers
                .filter { requested == nil || requested == $0 }
                .map { ["bundleIdentifier": $0] }
            try writeJSON(["result": ["apps": apps]], toOption: "--json-output", arguments: arguments)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        if arguments.starts(with: ["devicectl", "device", "install", "app"]),
           let path = arguments.first(where: { $0.hasSuffix(".app") }) {
            let source = URL(fileURLWithPath: path, isDirectory: true)
            let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: source.appendingPathComponent("Info.plist")),
                options: [], format: nil
            ) as! [String: Any]
            let identifier = info["CFBundleIdentifier"] as! String
            installedIdentifiers.append(identifier)
            let destination = captureRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            if identifier == identifiers.main { mainCapture = destination }
            if identifier == identifiers.runner { runnerCapture = destination }
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        if arguments.starts(with: ["devicectl", "device", "process", "launch"]) {
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        if arguments.starts(with: ["devicectl", "device", "copy", "from"]),
           let destination = option("--destination", arguments: arguments) {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["IOSSimGate3RunnerBundleIdentifier": identifiers.runner],
                format: .xml,
                options: 0
            )
            try data.write(to: directory.appendingPathComponent("preferences.plist"), options: .atomic)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        return .init(exitCode: 1, stdout: "", stderr: "Unexpected mocked device command")
    }

    func evidence() -> Evidence {
        Evidence(
            commands: commands,
            installedIdentifiers: installedIdentifiers,
            mainCapture: mainCapture,
            runnerCapture: runnerCapture
        )
    }

    private func option(_ name: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func writeJSON(_ object: Any, toOption name: String, arguments: [String]) throws {
        guard let path = option(name, arguments: arguments) else { return }
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private final class KeychainSigningFixture {
    private static let cleanupLock = NSLock()
    private static var didCleanAbandonedMaterial = false
    let root: URL
    let service: String
    let keyLabel: String
    let teamIdentifier: String
    let applicationTagIdentifier: String
    let certificateDER: Data
    let caCertificateDER: Data
    let certificateSHA256: String
    let resolver: NativeSigningIdentityResolver

    init(
        teamIdentifier requestedTeamIdentifier: String? = nil,
        signingAccessPolicy: IOSSimSigningKeyAccessPolicy? = nil
    ) throws {
        Self.cleanupAbandonedMaterialOnce()
        let identifier = UUID().uuidString.uppercased()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iossim-keychain-integration-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = "com.iossim.tests.signing.\(identifier)"
        keyLabel = "IOSSim Test Signing Key \(identifier)"
        teamIdentifier = requestedTeamIdentifier
            ?? "IT\(identifier.replacingOccurrences(of: "-", with: "").prefix(8))"
        applicationTagIdentifier = "com.iossim.personal-team.\(teamIdentifier).\(identifier)"
        let store: IOSSimIdentityMetadataStore
        if let signingAccessPolicy {
            store = IOSSimIdentityMetadataStore(
                service: service,
                keyLabel: keyLabel,
                signingAccessPolicy: signingAccessPolicy
            )
        } else {
            store = IOSSimIdentityMetadataStore(service: service, keyLabel: keyLabel)
        }
        let tag = Data(applicationTagIdentifier.utf8)
        let key = try store.createPrivateKey(applicationTag: tag)
        try store.save(IOSSimIdentityMetadata(
            teamIdentifier: teamIdentifier,
            certificateFingerprint: nil,
            certificateSerial: nil,
            certificateExpiration: nil,
            keyApplicationTag: tag,
            createdAt: Date(),
            generatedByIOSSim: true
        ))
        let csrURL = root.appendingPathComponent("leaf.csr")
        let caKeyURL = root.appendingPathComponent("ca-key.pem")
        let caCertificateURL = root.appendingPathComponent("ca.pem")
        let caCertificateDERURL = root.appendingPathComponent("ca.der")
        let certificateURL = root.appendingPathComponent("leaf.der")
        let extensionsURL = root.appendingPathComponent("extensions.cnf")
        let csr = try createCertificateSigningRequest(key: key, teamIdentifier: teamIdentifier)
            .replacingOccurrences(of: "-----END CERTIFICATE REQUEST-----", with: "\n-----END CERTIFICATE REQUEST-----")
        try Data(csr.utf8)
            .write(to: csrURL, options: [.atomic, .completeFileProtection])
        try Data("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n".utf8)
            .write(to: extensionsURL, options: [.atomic, .completeFileProtection])
        try Self.openssl([
            "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", caKeyURL.path, "-out", caCertificateURL.path,
            "-days", "2", "-subj", "/C=US/O=IOSSim Tests/CN=IOSSim Test CA",
        ], in: root)
        try Self.openssl([
            "x509", "-in", caCertificateURL.path, "-outform", "DER", "-out", caCertificateDERURL.path,
        ], in: root)
        try Self.openssl([
            "x509", "-req", "-in", csrURL.path,
            "-CA", caCertificateURL.path, "-CAkey", caKeyURL.path, "-CAcreateserial",
            "-outform", "DER", "-out", certificateURL.path, "-days", "2",
            "-extfile", extensionsURL.path,
        ], in: root)
        certificateDER = try Data(contentsOf: certificateURL)
        caCertificateDER = try Data(contentsOf: caCertificateDERURL)
        if let caCertificate = SecCertificateCreateWithData(nil, caCertificateDER as CFData) {
            let status = SecItemAdd([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: caCertificate,
                kSecAttrSynchronizable as String: false,
            ] as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
        certificateSHA256 = SHA256.hash(data: certificateDER)
            .map { String(format: "%02X", $0) }.joined()
        resolver = NativeSigningIdentityResolver(runner: ProcessRunner())
    }

    func cleanup() {
        let tag = Data(applicationTagIdentifier.utf8)
        _ = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: teamIdentifier,
        ] as CFDictionary)
        _ = SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
        if let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) {
            _ = SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrSynchronizable as String: false,
            ] as CFDictionary)
        }
        if let certificate = SecCertificateCreateWithData(nil, caCertificateDER as CFData) {
            _ = SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrSynchronizable as String: false,
            ] as CFDictionary)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func deletePrivateKey() {
        _ = SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(applicationTagIdentifier.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }

    private static func cleanupAbandonedMaterialOnce() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        guard !didCleanAbandonedMaterial else { return }
        didCleanAbandonedMaterial = true

        var keyResult: CFTypeRef?
        if SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &keyResult) == errSecSuccess,
           let keys = keyResult as? [[String: Any]] {
            for attributes in keys {
                guard let tag = attributes[kSecAttrApplicationTag as String] as? Data,
                      let identifier = String(data: tag, encoding: .utf8),
                      identifier.hasPrefix("com.iossim.personal-team.IT") else { continue }
                _ = SecItemDelete([
                    kSecClass as String: kSecClassKey,
                    kSecAttrApplicationTag as String: tag,
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                    kSecAttrSynchronizable as String: false,
                ] as CFDictionary)
            }
        }

        var certificateResult: CFTypeRef?
        if SecItemCopyMatching([
            kSecClass as String: kSecClassCertificate,
            kSecAttrSynchronizable as String: false,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &certificateResult) == errSecSuccess,
           let certificates = certificateResult as? [SecCertificate] {
            for certificate in certificates {
                let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
                let testLeaf = summary == "IOSSim"
                    && certificateTeamIdentifiers(certificate).contains(where: { $0.hasPrefix("IT") })
                guard testLeaf || summary == "IOSSim Test CA" else { continue }
                _ = SecItemDelete([
                    kSecClass as String: kSecClassCertificate,
                    kSecValueRef as String: certificate,
                    kSecAttrSynchronizable as String: false,
                ] as CFDictionary)
            }
        }

        var passwordResult: CFTypeRef?
        if SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &passwordResult) == errSecSuccess,
           let passwords = passwordResult as? [[String: Any]] {
            for attributes in passwords {
                guard let service = attributes[kSecAttrService as String] as? String,
                      service.hasPrefix("com.iossim.tests.signing.") else { continue }
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrSynchronizable as String: false,
                ]
                if let account = attributes[kSecAttrAccount as String] as? String {
                    query[kSecAttrAccount as String] = account
                }
                _ = SecItemDelete(query as CFDictionary)
            }
        }

        if let items = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        ) {
            for item in items where item.lastPathComponent.hasPrefix("iossim-keychain-integration-") {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private static func openssl(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "IOSSimKeychainIntegration",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: Redactor.redact(String(
                    decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ))]
            )
        }
    }
}
