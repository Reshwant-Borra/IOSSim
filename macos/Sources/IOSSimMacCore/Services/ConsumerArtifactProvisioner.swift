import CryptoKit
import Foundation

public actor ConsumerArtifactProvisioner {
    public static let provisionerVersion = "2"

    private let context: RuntimeProvisioningContext
    private let stateStore: ConsumerProvisioningStateStore
    private let refreshCoordinator: ConsumerRefreshCoordinator
    private let nativeArtifactStore: NativeProvisioningArtifactStore
    private let fileManager: FileManager
    private let workspaceRootURL: URL?

    public init(
        context: RuntimeProvisioningContext,
        stateStore: ConsumerProvisioningStateStore = ConsumerProvisioningStateStore(),
        refreshCoordinator: ConsumerRefreshCoordinator = ConsumerRefreshCoordinator(),
        nativeArtifactStore: NativeProvisioningArtifactStore = NativeProvisioningArtifactStore(),
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) {
        self.context = context
        self.stateStore = stateStore
        self.refreshCoordinator = refreshCoordinator
        self.nativeArtifactStore = nativeArtifactStore
        self.fileManager = fileManager
        self.workspaceRootURL = workspaceRootURL
    }

    static func installedIdentifiers(
        teamIdentifier: String,
        operation: ConsumerProvisioningOperation
    ) throws -> PersonalTeamBundleIdentifierSet {
        switch operation {
        case .install, .refresh, .repair:
            return try PersonalTeamProvisioningPOC.derivedBundleIdentifiers(teamIdentifier: teamIdentifier)
        }
    }

    public func provision(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        try await refreshCoordinator.begin()
        defer { Task { await refreshCoordinator.end() } }

        let started = Date()
        do {
            if request.operation == .refresh,
               let prior = try await stateStore.loadManifest() {
                try await stateStore.saveManifest(prior.recordingRefreshAttempt(at: started))
            }
            _ = try context.verifyArtifacts()
            let rawDeviceIdentifier = try await resolveDevice(request.selectedDeviceIdentifier)
            guard let signingDeviceIdentifier = await AppleDeviceTool.signingDeviceIdentifier(
                matching: rawDeviceIdentifier,
                context: context
            ) else {
                throw ConsumerProvisioningFailure(
                    code: .deviceUnavailable,
                    stage: .preparingIdentities,
                    userMessage: "IOSSim could not prepare signing for the selected iPhone.",
                    remediation: "Reconnect and unlock that iPhone, then try again.",
                    developerDetail: "Hardware UDID could not be resolved from the selected CoreDevice identifier."
                )
            }
            let nativeArtifacts: NativeProvisioningArtifacts?
            if request.backend == .nativePersonalTeam {
                nativeArtifacts = try await nativeArtifactStore.load(
                    teamIdentifier: request.selectedTeamIdentifier,
                    selectedDeviceIdentifier: signingDeviceIdentifier
                )
            } else {
                nativeArtifacts = nil
            }
            let team = try await resolveTeam(
                request.selectedTeamIdentifier,
                deviceIdentifier: rawDeviceIdentifier,
                nativeArtifacts: nativeArtifacts
            )
            let nativeSigningIdentity: String?
            if let nativeArtifacts {
                nativeSigningIdentity = try await preflightNativeArtifacts(
                    nativeArtifacts,
                    teamIdentifier: team.teamIdentifier,
                    signingDeviceIdentifier: signingDeviceIdentifier
                )
            } else {
                nativeSigningIdentity = nil
            }
            try await validateExistingState(
                request: request,
                selectedTeam: team,
                rawDeviceIdentifier: rawDeviceIdentifier
            )
            let prepared = try await prepareArtifacts(
                team: team,
                rawDeviceIdentifier: rawDeviceIdentifier,
                signingDeviceIdentifier: signingDeviceIdentifier,
                operation: request.operation,
                nativeArtifacts: nativeArtifacts,
                nativeSigningIdentity: nativeSigningIdentity
            )
            defer { try? fileManager.removeItem(at: prepared.workspaceURL) }
            try await installAndVerify(prepared, rawDeviceIdentifier: rawDeviceIdentifier)
            try await launchMain(
                rawDeviceIdentifier: rawDeviceIdentifier,
                expectedMainBundleIdentifier: prepared.identifiers.main,
                expectedRunnerBundleIdentifier: prepared.identifiers.runner
            )

            let previous = try? await stateStore.loadManifest()
            let now = Date()
            let selectedDevice = await AppleDeviceTool.discoverDevices(context: context)
                .first(where: { $0.selectionIdentifier == rawDeviceIdentifier })
            let manifest = ConsumerProvisioningManifest(
                deviceIdentifierSafe: RuntimeProvisioning.shortIdentifier(rawDeviceIdentifier),
                deviceIdentifierHash: PersonalTeamProvisioningPOC.deviceIdentifierHash(rawDeviceIdentifier),
                deviceName: selectedDevice?.name,
                deviceModel: selectedDevice?.model,
                deviceOSVersion: selectedDevice?.osVersion,
                teamID: team.teamIdentifier,
                sourceMainBundleID: ProtectedSourceBundleIdentifiers.default.main,
                installedMainBundleID: prepared.identifiers.main,
                sourceUITestBundleID: ProtectedSourceBundleIdentifiers.default.uiTests,
                installedUITestBundleID: prepared.identifiers.uiTests,
                sourceRunnerBundleID: ProtectedSourceBundleIdentifiers.default.runner,
                installedRunnerBundleID: prepared.identifiers.runner,
                mainProfile: prepared.mainProfile,
                runnerProfile: prepared.runnerProfile,
                lastInstallDate: previous?.lastInstallDate ?? now,
                lastRefreshAttempt: request.operation == .refresh ? now : previous?.lastRefreshAttempt,
                lastRefreshSuccess: request.operation == .refresh ? now : previous?.lastRefreshSuccess,
                runtimeSetupStatus: previous?.runtimeSetupStatus ?? .userActionRequired,
                lastRuntimeHealthCheck: previous?.lastRuntimeHealthCheck,
                appVersion: prepared.appVersion,
                provisionerVersion: Self.provisionerVersion,
                trueRenewalPhysicallyValidated: false
            )
            try await stateStore.saveManifest(manifest)
            try await record(
                stage: .complete,
                device: rawDeviceIdentifier,
                result: .passed,
                duration: started,
                detail: "\(request.operation.rawValue) completed with deterministic main and runner identities."
            )
            return ConsumerProvisioningResult(
                operation: request.operation,
                finalStage: .complete,
                manifest: manifest,
                installedBundleIdentifiers: [manifest.installedMainBundleID, manifest.installedRunnerBundleID],
                runtimeRecoveryRecommended: request.operation != .install
            )
        } catch let failure as ConsumerProvisioningFailure {
            try? await record(
                stage: failure.stage,
                result: .failed,
                errorCode: failure.code,
                duration: started,
                detail: failure.developerDetail
            )
            throw failure
        } catch {
            let failure = ConsumerProvisioningFailure(
                code: .unknown,
                stage: .failed,
                userMessage: "IOSSim could not finish setup.",
                remediation: "Open Diagnostics for details, then try Repair.",
                developerDetail: String(describing: error)
            )
            try? await record(
                stage: failure.stage,
                result: .failed,
                errorCode: failure.code,
                duration: started,
                detail: failure.developerDetail
            )
            throw failure
        }
    }

    public func currentManifest() async throws -> ConsumerProvisioningManifest? {
        try await stateStore.loadManifest()
    }

    public func availableTeams(selectedDeviceIdentifier: String?) async -> [PersonalTeamCandidate] {
        let profileDeviceIdentifier: String?
        if let selectedDeviceIdentifier,
           let rawDeviceIdentifier = await AppleDeviceTool.rawDeviceIdentifier(
               matching: selectedDeviceIdentifier,
               context: context
           ) {
            profileDeviceIdentifier = await AppleDeviceTool.signingDeviceIdentifier(
                matching: rawDeviceIdentifier,
                context: context
            )
        } else {
            profileDeviceIdentifier = nil
        }
        return await ApplePersonalTeamDiscovery.discover(
            selectedDeviceIdentifier: profileDeviceIdentifier,
            runner: context.runner,
            fileManager: fileManager
        )
    }

    private func resolveDevice(_ selector: String) async throws -> String {
        guard let raw = await AppleDeviceTool.rawDeviceIdentifier(matching: selector, context: context) else {
            throw ConsumerProvisioningFailure(
                code: .deviceUnavailable,
                stage: .checkingDevice,
                userMessage: "The selected iPhone is not available.",
                remediation: "Reconnect and unlock that iPhone, then try again.",
                developerDetail: "Selected device could not be resolved uniquely: \(RuntimeProvisioning.shortIdentifier(selector))."
            )
        }
        return raw
    }

    private func resolveTeam(
        _ identifier: String,
        deviceIdentifier: String,
        nativeArtifacts: NativeProvisioningArtifacts?
    ) async throws -> PersonalTeamCandidate {
        if let nativeArtifacts {
            guard nativeArtifacts.teamIdentifier == identifier else {
                throw ConsumerProvisioningFailure(
                    code: .accountTeamMismatch,
                    stage: .validatingTeam,
                    userMessage: "IOSSim could not use its prepared signing identity.",
                    remediation: "Try Personal Team provisioning again; your Apple authorization remains valid.",
                    developerDetail: "Prepared native artifacts belong to a different team."
                )
            }
            return PersonalTeamCandidate(
                teamIdentifier: identifier,
                teamDisplayName: "Personal Team",
                signingIdentityCommonName: "IOSSim managed",
                signingIdentityFingerprint: nativeArtifacts.certificateFingerprint,
                certificateSubjectTeamIdentifier: identifier,
                profileTeamIdentifiers: [identifier],
                matchingProfileCount: nativeArtifacts.profiles.count,
                selectedDeviceIncluded: true,
                personalTeam: true
            )
        }
        let teams = await availableTeams(selectedDeviceIdentifier: deviceIdentifier)
        guard let team = teams.first(where: { $0.teamIdentifier == identifier }) else {
            throw ConsumerProvisioningFailure(
                code: teams.isEmpty ? .personalTeamUnavailable : .accountTeamMismatch,
                stage: .validatingTeam,
                userMessage: "IOSSim couldn't prepare Apple authorization.",
                remediation: "Continue Apple authorization in IOSSim, then try again.",
                developerDetail: "No profile-backed signing identity matched DEVELOPMENT_TEAM \(RuntimeProvisioning.shortIdentifier(identifier))."
            )
        }
        guard team.certificateSubjectTeamIdentifier == team.teamIdentifier,
              team.profileTeamIdentifiers.allSatisfy({ $0 == team.teamIdentifier }) else {
            throw ConsumerProvisioningFailure(
                code: .accountTeamMismatch,
                stage: .validatingTeam,
                userMessage: "IOSSim couldn't validate Apple authorization.",
                remediation: "Refresh Apple authorization in IOSSim, then try again.",
                developerDetail: "Certificate subject OU and provisioning profile TeamIdentifier disagree."
            )
        }
        return team
    }

    private func validateExistingState(
        request: ConsumerProvisioningRequest,
        selectedTeam: PersonalTeamCandidate,
        rawDeviceIdentifier: String
    ) async throws {
        let prior = try await stateStore.loadManifest()
        let expected = try Self.installedIdentifiers(
            teamIdentifier: selectedTeam.teamIdentifier,
            operation: request.operation
        )
        let appliesToSelectedDevice = prior.map {
            $0.deviceIdentifierHash == PersonalTeamProvisioningPOC.deviceIdentifierHash(rawDeviceIdentifier)
        } ?? false
        let priorUsesExpectedIdentifiers = prior.map {
            $0.installedMainBundleID == expected.main
                && $0.installedUITestBundleID == expected.uiTests
                && $0.installedRunnerBundleID == expected.runner
        } ?? false
        if appliesToSelectedDevice,
           prior?.teamID == selectedTeam.teamIdentifier,
           priorUsesExpectedIdentifiers {
            return
        }
        if appliesToSelectedDevice,
           prior?.teamID != selectedTeam.teamIdentifier,
           !request.allowFreshInstallAfterCrossTeamConflict {
            throw ConsumerProvisioningFailure(
                code: .crossTeamUpgradeBlocked,
                stage: .validatingTeam,
                userMessage: "This iPhone already has IOSSim installed from a different signing account. A fresh install is required.",
                remediation: "Choose Fresh Install only after reviewing which IOSSim data will be removed.",
                developerDetail: "MismatchedApplicationIdentifierEntitlement: existing team \(RuntimeProvisioning.shortIdentifier(prior?.teamID)), requested \(RuntimeProvisioning.shortIdentifier(selectedTeam.teamIdentifier))."
            )
        }
        if appliesToSelectedDevice,
           prior?.teamID == selectedTeam.teamIdentifier,
           !priorUsesExpectedIdentifiers,
           !request.allowFreshInstallAfterCrossTeamConflict {
            throw installedIdentityMigrationFailure()
        }

        let installedOwnedIdentifiers = await installedIOSSimMainAndRunnerBundleIdentifiers(
            rawDeviceIdentifier: rawDeviceIdentifier
        )
        let expectedIdentifiers = Set([expected.main, expected.runner])
        let unexpectedInstalledIdentifiers = installedOwnedIdentifiers.filter { !expectedIdentifiers.contains($0) }
        if !unexpectedInstalledIdentifiers.isEmpty,
           !request.allowFreshInstallAfterCrossTeamConflict {
            throw installedIdentityMigrationFailure()
        }
        if request.allowFreshInstallAfterCrossTeamConflict {
            try await uninstallIOSSimOwnedComponents(
                priorMainBundleIdentifier: appliesToSelectedDevice ? prior?.installedMainBundleID : nil,
                priorRunnerBundleIdentifier: appliesToSelectedDevice ? prior?.installedRunnerBundleID : nil,
                rawDeviceIdentifier: rawDeviceIdentifier
            )
        }
    }

    private func installedIdentityMigrationFailure() -> ConsumerProvisioningFailure {
        ConsumerProvisioningFailure(
            code: .installedIdentityMigrationRequired,
            stage: .validatingTeam,
            userMessage: "This iPhone has an earlier IOSSim app identity.",
            remediation: "Use Fresh Install only if you accept removing that IOSSim app and its local data.",
            developerDetail: "The installed main/runner identifiers do not match the deterministic identifiers for the selected Personal Team."
        )
    }

    private func uninstallIOSSimOwnedComponents(
        priorMainBundleIdentifier: String?,
        priorRunnerBundleIdentifier: String?,
        rawDeviceIdentifier: String
    ) async throws {
        var identifiers = await installedIOSSimMainAndRunnerBundleIdentifiers(rawDeviceIdentifier: rawDeviceIdentifier)
        if let priorMainBundleIdentifier,
           ConsumerInstalledIdentityPolicy.isIOSSimOwnedMain(priorMainBundleIdentifier) {
            identifiers.append(priorMainBundleIdentifier)
        }
        if let priorRunnerBundleIdentifier,
           ConsumerInstalledIdentityPolicy.isIOSSimOwnedRunner(priorRunnerBundleIdentifier) {
            identifiers.append(priorRunnerBundleIdentifier)
        }
        identifiers.append(ProtectedSourceBundleIdentifiers.default.main)
        identifiers.append(ProtectedSourceBundleIdentifiers.default.runner)
        let orderedIdentifiers = Array(Set(identifiers)).sorted()
        for bundleIdentifier in orderedIdentifiers {
            let result = try await context.runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "devicectl", "device", "uninstall", "app",
                    "--device", rawDeviceIdentifier,
                    bundleIdentifier,
                    "--timeout", "30", "--quiet"
                ],
                workingDirectory: context.resourcesURL,
                environment: RuntimeProvisioning.deterministicEnvironment()
            )
            let missing = result.combinedOutput.localizedCaseInsensitiveContains("not installed")
            guard result.exitCode == 0 || missing else {
                throw ConsumerProvisioningFailure(
                    code: .crossTeamUpgradeBlocked,
                    stage: .validatingTeam,
                    userMessage: "IOSSim could not complete the confirmed fresh install.",
                    remediation: "Keep the iPhone connected and unlocked, then try again.",
                    developerDetail: result.combinedOutput
                )
            }
        }
        try await record(
            stage: .validatingTeam,
            device: rawDeviceIdentifier,
            result: .passed,
            detail: "Explicit fresh install removed only IOSSim-owned main and runner components."
        )
    }

    private func installedIOSSimMainAndRunnerBundleIdentifiers(rawDeviceIdentifier: String) async -> [String] {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("iossim-installed-apps-\(UUID().uuidString)", isDirectory: true)
        do { try fileManager.createDirectory(at: root, withIntermediateDirectories: true) } catch { return [] }
        defer { try? fileManager.removeItem(at: root) }
        let output = root.appendingPathComponent("apps.json")
        guard let result = try? await context.runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "device", "info", "apps",
                "--device", rawDeviceIdentifier,
                "--timeout", "15",
                "--json-output", output.path,
                "--quiet"
            ],
            workingDirectory: root,
            environment: RuntimeProvisioning.deterministicEnvironment()
        ), result.exitCode == 0,
        let data = try? Data(contentsOf: output),
        let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let resultObject = raw["result"] as? [String: Any],
        let apps = resultObject["apps"] as? [[String: Any]] else {
            return []
        }
        return apps.compactMap { $0["bundleIdentifier"] as? String }
            .filter(ConsumerInstalledIdentityPolicy.isIOSSimOwnedMainOrRunner)
    }

    private func prepareArtifacts(
        team: PersonalTeamCandidate,
        rawDeviceIdentifier: String,
        signingDeviceIdentifier: String,
        operation: ConsumerProvisioningOperation,
        nativeArtifacts: NativeProvisioningArtifacts?,
        nativeSigningIdentity: String?
    ) async throws -> PreparedConsumerArtifacts {
        try await record(stage: .preparingIdentities, device: rawDeviceIdentifier, result: .started)
        let identifiers = try Self.installedIdentifiers(
            teamIdentifier: team.teamIdentifier,
            operation: operation
        )
        let manifest = try context.loadManifest()
        guard manifest.components.count == 2,
              let mainComponent = manifest.components.first(where: { $0.role == "iosMain" }),
              let runnerComponent = manifest.components.first(where: { $0.role == "locationControlRunner" }),
              !manifest.components.contains(where: { $0.role == "locationWitness" }) else {
            throw ConsumerProvisioningFailure(
                code: .artifactInvalid,
                stage: .preparingArtifacts,
                userMessage: "IOSSim’s installation components are damaged.",
                remediation: "Reinstall the IOSSim Mac app.",
                developerDetail: "Consumer artifact manifest must contain only iosMain and locationControlRunner."
            )
        }

        let workspace = try makeWorkspace(teamIdentifier: team.teamIdentifier)
        let mainProfileURL: URL
        let runnerProfileURL: URL
        if let nativeArtifacts {
            let profilesURL = workspace.appendingPathComponent("NativeProfiles", isDirectory: true)
            try fileManager.createDirectory(
                at: profilesURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let main = nativeArtifacts.profiles.first(where: { $0.bundleIdentifier == identifiers.main }),
                  let runner = nativeArtifacts.profiles.first(where: { $0.bundleIdentifier == identifiers.runner }) else {
                throw nativeProfileFailure("Prepared native profile set does not contain the exact main and runner bundle IDs.")
            }
            mainProfileURL = profilesURL.appendingPathComponent("main.mobileprovision")
            runnerProfileURL = profilesURL.appendingPathComponent("runner.mobileprovision")
            try main.profileData.write(to: mainProfileURL, options: [.atomic, .completeFileProtection])
            try runner.profileData.write(to: runnerProfileURL, options: [.atomic, .completeFileProtection])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mainProfileURL.path)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runnerProfileURL.path)
        } else {
            let derivedData = workspace.appendingPathComponent("SigningDerivedData", isDirectory: true)
            try SigningShellProjectGenerator.generate(
                at: workspace.appendingPathComponent("SigningShell", isDirectory: true),
                teamIdentifier: team.teamIdentifier,
                mainBundleIdentifier: identifiers.main,
                uiTestBundleIdentifier: identifiers.uiTests
            )
            try await buildSigningShell(
                projectURL: workspace.appendingPathComponent("SigningShell/IOSSimSigningShell.xcodeproj"),
                derivedDataURL: derivedData,
                teamIdentifier: team.teamIdentifier
            )
            let products = derivedData.appendingPathComponent("Build/Products/Debug-iphoneos", isDirectory: true)
            mainProfileURL = products
                .appendingPathComponent("IOSSimSigningShell.app", isDirectory: true)
                .appendingPathComponent("embedded.mobileprovision")
            runnerProfileURL = products
                .appendingPathComponent("IOSSimSigningShellUITests-Runner.app", isDirectory: true)
                .appendingPathComponent("embedded.mobileprovision")
        }
        guard fileManager.fileExists(atPath: mainProfileURL.path), fileManager.fileExists(atPath: runnerProfileURL.path) else {
            throw ConsumerProvisioningFailure(
                code: .profileUnavailable,
                stage: .preparingIdentities,
                userMessage: "IOSSim could not prepare its iPhone signing profiles.",
                remediation: nativeArtifacts == nil
                    ? "Refresh the selected account in Xcode and try again."
                    : "Try Personal Team provisioning again; your Apple authorization remains valid.",
                developerDetail: "Signing input did not contain both embedded provisioning profiles."
            )
        }

        let preparedURL = workspace.appendingPathComponent("Prepared", isDirectory: true)
        try fileManager.createDirectory(at: preparedURL, withIntermediateDirectories: true)
        let mainURL = preparedURL.appendingPathComponent(mainComponent.relativePath.lastPathComponent)
        let runnerURL = preparedURL.appendingPathComponent(runnerComponent.relativePath.lastPathComponent)
        try fileManager.copyItem(at: context.resourcesURL.appendingPathComponent(mainComponent.relativePath), to: mainURL)
        try fileManager.copyItem(at: context.resourcesURL.appendingPathComponent(runnerComponent.relativePath), to: runnerURL)

        try updateBundleInfo(
            appURL: mainURL,
            bundleIdentifier: identifiers.main,
            runnerBundleIdentifier: identifiers.runner
        )
        try updateRunnerInfo(runnerURL: runnerURL, identifiers: identifiers)
        try fileManager.copyItem(at: mainProfileURL, to: mainURL.appendingPathComponent("embedded.mobileprovision"), replacing: true)
        try fileManager.copyItem(at: runnerProfileURL, to: runnerURL.appendingPathComponent("embedded.mobileprovision"), replacing: true)

        let mainProfile = try profileState(
            url: mainProfileURL,
            artifact: "main",
            expectedTeam: team.teamIdentifier,
            expectedBundleIdentifier: identifiers.main,
            selectedDeviceIdentifier: signingDeviceIdentifier,
            expectedCertificateFingerprint: nativeArtifacts?.certificateFingerprint
        )
        let runnerProfile = try profileState(
            url: runnerProfileURL,
            artifact: "runner",
            expectedTeam: team.teamIdentifier,
            expectedBundleIdentifier: identifiers.runner,
            selectedDeviceIdentifier: signingDeviceIdentifier,
            expectedCertificateFingerprint: nativeArtifacts?.certificateFingerprint
        )

        let signingIdentity: String
        if nativeArtifacts != nil {
            guard let nativeSigningIdentity else {
                throw nativeProfileFailure("Native signing identity preflight was not completed.")
            }
            signingIdentity = nativeSigningIdentity
        } else {
            signingIdentity = team.signingIdentityFingerprint
        }
        try await record(
            stage: .preparingIdentities,
            device: rawDeviceIdentifier,
            result: .passed,
            detail: nativeArtifacts == nil
                ? "Xcode-managed signing profiles prepared for the legacy backend."
                : "Validated native Personal Team profiles and reused the matching IOSSim-managed keychain identity."
        )
        try await record(
            stage: .preparingArtifacts,
            device: rawDeviceIdentifier,
            result: .passed,
            detail: "Prepared bundled main and XCTest runner artifacts with deterministic identifiers and exact profiles."
        )

        try await signMain(mainURL, profileURL: mainProfileURL, identity: signingIdentity)
        try await signRunner(runnerURL, profileURL: runnerProfileURL, identity: signingIdentity)
        try await verifySignature(
            mainURL,
            profileURL: mainProfileURL,
            expectedIdentifier: identifiers.main,
            expectedTeam: team.teamIdentifier,
            artifact: "main"
        )
        try await verifySignature(
            runnerURL,
            profileURL: runnerProfileURL,
            expectedIdentifier: identifiers.runner,
            expectedTeam: team.teamIdentifier,
            artifact: "runner"
        )
        try await verifyNestedSignatures(runnerURL, expectedTeam: team.teamIdentifier)
        try verifyPreparedRunnerRelationship(runnerURL, identifiers: identifiers)
        try await record(
            stage: .verifyingSignatures,
            device: rawDeviceIdentifier,
            result: .passed,
            detail: "Main, runner, nested code, embedded profiles, entitlements, identifiers, and team continuity verified."
        )

        let appInfo = try? readPlist(mainURL.appendingPathComponent("Info.plist"))
        let appVersion = (appInfo?["CFBundleShortVersionString"] as? String) ?? "unknown"
        return PreparedConsumerArtifacts(
            workspaceURL: workspace,
            mainURL: mainURL,
            runnerURL: runnerURL,
            identifiers: identifiers,
            team: team,
            mainProfile: mainProfile,
            runnerProfile: runnerProfile,
            appVersion: appVersion,
            operation: operation
        )
    }

    private func buildSigningShell(
        projectURL: URL,
        derivedDataURL: URL,
        teamIdentifier: String
    ) async throws {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let result = try await context.runner.run(
            executableURL: xcrun,
            arguments: SigningShellBuildPlan.arguments(
                projectURL: projectURL,
                derivedDataURL: derivedDataURL,
                teamIdentifier: teamIdentifier
            ),
            workingDirectory: projectURL.deletingLastPathComponent(),
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result.exitCode == 0 else {
            let code = ConsumerProvisioningErrorClassifier.signingErrorCode(output: result.combinedOutput)
            throw ConsumerProvisioningFailure(
                code: code,
                stage: .preparingIdentities,
                userMessage: "IOSSim couldn't prepare Apple authorization.",
                remediation: "Refresh Apple authorization in IOSSim, then try again.",
                developerDetail: result.combinedOutput
            )
        }
    }

    private func signMain(_ url: URL, profileURL: URL, identity: String) async throws {
        do {
            let entitlements = try entitlementFile(profileURL: profileURL, in: url.deletingLastPathComponent())
            try await codesign(url, identity: identity, entitlements: entitlements)
            try await record(stage: .signingMain, artifact: "main", result: .passed)
        } catch {
            throw signingFailure(error, code: .mainSigningFailure, stage: .signingMain, artifact: "main")
        }
    }

    private func signRunner(_ url: URL, profileURL: URL, identity: String) async throws {
        let nested = nestedSignables(in: url)
        do {
            for item in nested {
                try await codesign(item, identity: identity, entitlements: nil)
            }
        } catch {
            throw signingFailure(error, code: .runnerNestedSignatureFailure, stage: .signingRunner, artifact: "runner nested code")
        }
        do {
            let entitlements = try entitlementFile(profileURL: profileURL, in: url.deletingLastPathComponent())
            try await codesign(url, identity: identity, entitlements: entitlements)
            try await record(stage: .signingRunner, artifact: "runner", result: .passed)
        } catch {
            throw signingFailure(error, code: .runnerSigningFailure, stage: .signingRunner, artifact: "runner")
        }
    }

    private func codesign(_ url: URL, identity: String, entitlements: URL?) async throws {
        var arguments = ["--force", "--sign", identity, "--timestamp=none", "--generate-entitlement-der"]
        if let entitlements { arguments += ["--entitlements", entitlements.path] }
        arguments.append(url.path)
        let result = try await context.runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: arguments,
            workingDirectory: url.deletingLastPathComponent(),
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result.exitCode == 0 else { throw ProcessFailure(commandName: "codesign", result: result) }
    }

    private func verifySignature(
        _ url: URL,
        profileURL: URL,
        expectedIdentifier: String,
        expectedTeam: String,
        artifact: String
    ) async throws {
        let verification = try await context.runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", url.path],
            workingDirectory: url.deletingLastPathComponent(),
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard verification.exitCode == 0 else {
            throw signingFailure(
                ProcessFailure(commandName: "codesign-verify", result: verification),
                code: artifact == "main" ? .mainSigningFailure : .runnerNestedSignatureFailure,
                stage: .verifyingSignatures,
                artifact: artifact
            )
        }
        let display = try await context.runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dvv", url.path],
            workingDirectory: url.deletingLastPathComponent(),
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        let summary = CodeSignatureSummary.parseCodesignDisplayOutput(display.combinedOutput)
        guard summary.identifier == expectedIdentifier, summary.teamIdentifier == expectedTeam else {
            throw ConsumerProvisioningFailure(
                code: artifact == "main" ? .mainSigningFailure : .runnerSigningFailure,
                stage: .verifyingSignatures,
                userMessage: "IOSSim could not verify a signed component.",
                remediation: "Refresh the selected Apple account in Xcode and try again.",
                developerDetail: "\(artifact) signature identifier/team mismatch: \(summary.identifier ?? "missing") / \(summary.teamIdentifier ?? "missing")."
            )
        }
        let entitlementResult = try await context.runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--entitlements", ":-", url.path],
            workingDirectory: url.deletingLastPathComponent(),
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard entitlementResult.exitCode == 0,
              let signedEntitlements = plistDictionary(in: entitlementResult.combinedOutput),
              let profileEntitlements = try decodedProfile(profileURL)["Entitlements"] as? [String: Any],
              NSDictionary(dictionary: signedEntitlements).isEqual(to: profileEntitlements) else {
            throw signingFailure(
                ProcessFailure(commandName: "codesign-entitlements", result: entitlementResult),
                code: artifact == "main" ? .mainSigningFailure : .runnerSigningFailure,
                stage: .verifyingSignatures,
                artifact: "\(artifact) entitlements"
            )
        }
    }

    private func verifyNestedSignatures(_ runnerURL: URL, expectedTeam: String) async throws {
        for item in nestedSignables(in: runnerURL) {
            let verification = try await context.runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--strict", item.path],
                workingDirectory: item.deletingLastPathComponent(),
                environment: RuntimeProvisioning.deterministicEnvironment()
            )
            guard verification.exitCode == 0 else {
                throw signingFailure(
                    ProcessFailure(commandName: "codesign-nested-verify", result: verification),
                    code: .runnerNestedSignatureFailure,
                    stage: .verifyingSignatures,
                    artifact: "runner nested code"
                )
            }
            let display = try await context.runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["-dvv", item.path],
                workingDirectory: item.deletingLastPathComponent(),
                environment: RuntimeProvisioning.deterministicEnvironment()
            )
            guard display.exitCode == 0,
                  CodeSignatureSummary.parseCodesignDisplayOutput(display.combinedOutput).teamIdentifier == expectedTeam else {
                throw signingFailure(
                    ProcessFailure(commandName: "codesign-nested-display", result: display),
                    code: .runnerNestedSignatureFailure,
                    stage: .verifyingSignatures,
                    artifact: "runner nested team"
                )
            }
        }
    }

    private func installAndVerify(_ prepared: PreparedConsumerArtifacts, rawDeviceIdentifier: String) async throws {
        let installedBefore = await AppleDeviceTool.isAppInstalled(
            bundleIdentifier: prepared.identifiers.main,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        ) == true
        try await install(
            url: prepared.mainURL,
            bundleIdentifier: prepared.identifiers.main,
            role: "iosMain",
            stage: .installingMain,
            failureCode: .mainInstallFailure,
            rawDeviceIdentifier: rawDeviceIdentifier
        )
        try await install(
            url: prepared.runnerURL,
            bundleIdentifier: prepared.identifiers.runner,
            role: "locationControlRunner",
            stage: .installingRunner,
            failureCode: .runnerInstallFailure,
            rawDeviceIdentifier: rawDeviceIdentifier
        )

        let mainInstalled = await AppleDeviceTool.isAppInstalled(
            bundleIdentifier: prepared.identifiers.main,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        ) == true
        let runnerCount = await AppleDeviceTool.installedAppCount(
            bundleIdentifier: prepared.identifiers.runner,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        )
        let canonicalRunnerInstalled = await AppleDeviceTool.isAppInstalled(
            bundleIdentifier: ProtectedSourceBundleIdentifiers.default.runner,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: context
        ) == true
        guard mainInstalled else {
            throw installFailure(.mainInstallFailure, stage: .verifyingInstallation, detail: "Main app lookup failed after install.")
        }
        guard runnerCount == 1 else {
            throw installFailure(.runnerNotInstalled, stage: .verifyingInstallation, detail: "Derived runner lookup failed after install.")
        }
        guard !canonicalRunnerInstalled else {
            throw installFailure(.duplicateRunner, stage: .verifyingInstallation, detail: "Canonical runner is installed alongside the derived runner.")
        }
        if prepared.operation != .install, !installedBefore {
            throw installFailure(
                .mainInstallFailure,
                stage: .verifyingInstallation,
                detail: "Refresh requested but prior main installation was not detected; refusing to claim in-place update."
            )
        }
        try await record(stage: .verifyingInstallation, device: rawDeviceIdentifier, result: .passed)
    }

    private func install(
        url: URL,
        bundleIdentifier: String,
        role: String,
        stage: ConsumerProvisioningStage,
        failureCode: ConsumerProvisioningErrorCode,
        rawDeviceIdentifier: String
    ) async throws {
        let component = DeviceArtifactComponent(
            role: role,
            bundleIdentifier: bundleIdentifier,
            version: "prepared",
            relativePath: url.path,
            sha256: "prepared"
        )
        let installContext = RuntimeProvisioningContext(resourcesURL: URL(fileURLWithPath: "/"), runner: context.runner)
        let result = try await AppleDeviceTool.install(
            component: component,
            rawDeviceIdentifier: rawDeviceIdentifier,
            context: installContext
        )
        guard result.exitCode == 0 else {
            let classified = ConsumerProvisioningErrorClassifier.installErrorCode(output: result.combinedOutput, artifact: role == "iosMain" ? "main" : "runner")
            if classified == .crossTeamUpgradeBlocked {
                throw ConsumerProvisioningFailure(
                    code: .crossTeamUpgradeBlocked,
                    stage: stage,
                    userMessage: "This iPhone already has IOSSim installed from a different signing account. A fresh install is required.",
                    remediation: "Return to setup and choose the explicit Fresh Install option after reviewing data loss.",
                    developerDetail: result.combinedOutput
                )
            }
            throw ConsumerProvisioningFailure(
                code: classified == .deviceNotIncluded ? classified : failureCode,
                stage: stage,
                userMessage: role == "iosMain" ? "IOSSim could not be installed." : "IOSSim’s support component could not be installed.",
                remediation: "Keep the selected iPhone connected and unlocked, then try Repair.",
                developerDetail: result.combinedOutput
            )
        }
        try await record(stage: stage, artifact: role, device: rawDeviceIdentifier, result: .passed)
    }

    private func launchMain(
        rawDeviceIdentifier: String,
        expectedMainBundleIdentifier: String,
        expectedRunnerBundleIdentifier: String
    ) async throws {
        let result = try await context.runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "device", "process", "launch",
                "--device", rawDeviceIdentifier,
                expectedMainBundleIdentifier,
                "--timeout", "15", "--quiet"
            ],
            workingDirectory: context.resourcesURL,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result.exitCode == 0 else {
            throw ConsumerProvisioningFailure(
                code: .runtimeVerificationFailed,
                stage: .verifyingRuntimeConfiguration,
                userMessage: "IOSSim was installed but could not be opened on your iPhone.",
                remediation: "Unlock the iPhone, open IOSSim once, then choose Check Again.",
                developerDetail: result.combinedOutput
            )
        }
        try await verifyPersistedRunnerMapping(
            rawDeviceIdentifier: rawDeviceIdentifier,
            expectedMainBundleIdentifier: expectedMainBundleIdentifier,
            expectedRunnerBundleIdentifier: expectedRunnerBundleIdentifier
        )
        try await record(stage: .verifyingRuntimeConfiguration, device: rawDeviceIdentifier, result: .passed)
    }

    private func verifyPersistedRunnerMapping(
        rawDeviceIdentifier: String,
        expectedMainBundleIdentifier: String,
        expectedRunnerBundleIdentifier: String
    ) async throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("iossim-runner-mapping-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        var detail = "Preference readback did not complete."

        for attempt in 0..<3 {
            let destination = root.appendingPathComponent("attempt-\(attempt)", isDirectory: true)
            let result = try await context.runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "devicectl", "device", "copy", "from",
                    "--device", rawDeviceIdentifier,
                    "--domain-type", "appDataContainer",
                    "--domain-identifier", expectedMainBundleIdentifier,
                    "--source", "Library/Preferences",
                    "--destination", destination.path,
                    "--timeout", "30",
                    "--quiet"
                ],
                workingDirectory: root,
                environment: RuntimeProvisioning.deterministicEnvironment()
            )
            if result.exitCode == 0,
               let enumerator = fileManager.enumerator(at: destination, includingPropertiesForKeys: nil),
               let preferenceURL = enumerator.compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "plist" }),
               let preferences = try? readPlist(preferenceURL),
               let installedRunner = preferences["IOSSimGate3RunnerBundleIdentifier"] as? String {
                guard installedRunner == expectedRunnerBundleIdentifier else {
                    throw ConsumerProvisioningFailure(
                        code: .runnerMappingMissing,
                        stage: .verifyingRuntimeConfiguration,
                        userMessage: "IOSSim’s support configuration does not match the installed component.",
                        remediation: "Keep the iPhone unlocked and choose Repair.",
                        developerDetail: "Persisted runner mapping does not equal the expected deterministic runner identifier."
                    )
                }
                try await record(
                    stage: .writingRuntimeConfiguration,
                    artifact: "runnerMapping",
                    device: rawDeviceIdentifier,
                    result: .passed
                )
                return
            }
            detail = result.combinedOutput
            if attempt < 2 { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        throw ConsumerProvisioningFailure(
            code: .runnerMappingMissing,
            stage: .verifyingRuntimeConfiguration,
            userMessage: "IOSSim could not verify its support configuration on the iPhone.",
            remediation: "Keep the iPhone unlocked, open IOSSim once, then choose Repair.",
            developerDetail: detail
        )
    }

    private func updateBundleInfo(appURL: URL, bundleIdentifier: String, runnerBundleIdentifier: String) throws {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        var info = try readPlist(infoURL)
        info["CFBundleIdentifier"] = bundleIdentifier
        info["IOSSimGate3RunnerBundleIdentifier"] = runnerBundleIdentifier
        try writePlist(info, to: infoURL)
    }

    private func updateRunnerInfo(runnerURL: URL, identifiers: PersonalTeamBundleIdentifierSet) throws {
        let runnerInfoURL = runnerURL.appendingPathComponent("Info.plist")
        var runnerInfo = try readPlist(runnerInfoURL)
        runnerInfo["CFBundleIdentifier"] = identifiers.runner
        try writePlist(runnerInfo, to: runnerInfoURL)
        guard let testBundle = nestedTestBundle(in: runnerURL) else {
            throw installFailure(.runnerNestedSignatureFailure, stage: .preparingArtifacts, detail: "Runner contains no embedded .xctest bundle.")
        }
        let testInfoURL = testBundle.appendingPathComponent("Info.plist")
        var testInfo = try readPlist(testInfoURL)
        testInfo["CFBundleIdentifier"] = identifiers.uiTests
        try writePlist(testInfo, to: testInfoURL)
    }

    private func verifyPreparedRunnerRelationship(_ runnerURL: URL, identifiers: PersonalTeamBundleIdentifierSet) throws {
        guard identifiers.runner == identifiers.uiTests + ".xctrunner",
              let testBundle = nestedTestBundle(in: runnerURL),
              fileManager.fileExists(atPath: runnerURL.appendingPathComponent((try readPlist(runnerURL.appendingPathComponent("Info.plist"))["CFBundleExecutable"] as? String) ?? "").path),
              fileManager.fileExists(atPath: testBundle.appendingPathComponent((try readPlist(testBundle.appendingPathComponent("Info.plist"))["CFBundleExecutable"] as? String) ?? "").path) else {
            throw installFailure(
                .runnerNestedSignatureFailure,
                stage: .verifyingSignatures,
                detail: "Runner/test identifier relationship or executable is invalid."
            )
        }
    }

    private func profileState(
        url: URL,
        artifact: String,
        expectedTeam: String,
        expectedBundleIdentifier: String,
        selectedDeviceIdentifier: String,
        expectedCertificateFingerprint: String? = nil
    ) throws -> ConsumerProfileState {
        let plist = try decodedProfile(url)
        let team = (plist["TeamIdentifier"] as? [String])?.first
        let entitlements = plist["Entitlements"] as? [String: Any]
        let applicationIdentifier = entitlements?["application-identifier"] as? String
        let developerTeamIdentifier = entitlements?["com.apple.developer.team-identifier"] as? String
        let applicationIdentifierPrefix = (plist["ApplicationIdentifierPrefix"] as? [String])?.first
        let getTaskAllow = entitlements?["get-task-allow"] as? Bool
        let devices = plist["ProvisionedDevices"] as? [String] ?? []
        guard team == expectedTeam,
              applicationIdentifier == "\(expectedTeam).\(expectedBundleIdentifier)",
              developerTeamIdentifier == expectedTeam,
              applicationIdentifierPrefix == expectedTeam,
              getTaskAllow == true else {
            throw ConsumerProvisioningFailure(
                code: .accountTeamMismatch,
                stage: .validatingTeam,
                userMessage: "IOSSim could not validate its prepared signing profile.",
                remediation: "Try Personal Team provisioning again; your Apple authorization remains valid.",
                developerDetail: "Profile team, application identifier, prefix, or development entitlement mismatch for \(artifact)."
            )
        }
        if let groups = entitlements?["keychain-access-groups"] as? [String],
           !groups.allSatisfy({ $0 == applicationIdentifier || $0 == "\(expectedTeam).*" }) {
            throw nativeProfileFailure("Profile keychain access groups are incompatible with \(expectedBundleIdentifier).")
        }
        if let expectedCertificateFingerprint {
            let certificates = plist["DeveloperCertificates"] as? [Data] ?? []
            guard certificates.contains(where: {
                sha256Hex($0).caseInsensitiveCompare(expectedCertificateFingerprint) == .orderedSame
            }) else {
                throw nativeProfileFailure("Profile certificate does not match the IOSSim-managed signing identity for \(artifact).")
            }
        }
        guard devices.contains(selectedDeviceIdentifier) else {
            throw ConsumerProvisioningFailure(
                code: .deviceNotIncluded,
                stage: .preparingIdentities,
                userMessage: "The selected iPhone is not included in the signing profile.",
                remediation: "Reconnect the iPhone, confirm it appears in Xcode, then try again.",
                developerDetail: "ProvisionedDevices does not contain \(RuntimeProvisioning.shortIdentifier(selectedDeviceIdentifier))."
            )
        }
        let creation = plist["CreationDate"] as? Date
        let expiration = plist["ExpirationDate"] as? Date
        let now = Date()
        guard let creation, let expiration, creation <= now, expiration > now else {
            throw ConsumerProvisioningFailure(
                code: .profileExpired,
                stage: .preparingIdentities,
                userMessage: "IOSSim's prepared iPhone signing profile is no longer valid.",
                remediation: "Refresh Personal Team provisioning; your Apple authorization remains valid.",
                developerDetail: "Profile validity interval is missing or invalid for \(artifact)."
            )
        }
        let data = try Data(contentsOf: url)
        return ConsumerProfileState(
            artifact: artifact,
            teamIdentifier: expectedTeam,
            bundleIdentifier: expectedBundleIdentifier,
            creationDate: creation,
            expirationDate: expiration,
            remainingValidity: expiration.timeIntervalSince(now),
            selectedDeviceIncluded: true,
            personalTeam: ProvisioningExpiration(creationDate: creation, expirationDate: expiration)
                .remainingInterval(now: creation).map { $0 <= 8.25 * 24 * 60 * 60 } ?? false,
            profileIdentifier: plist["UUID"] as? String,
            profileFingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            refreshRecommended: [.dueNow, .expired].contains(
                ConsumerRefreshPolicy.recommended.dueState(expiration: expiration)
            )
        )
    }

    private func entitlementFile(profileURL: URL, in directory: URL) throws -> URL {
        let profile = try decodedProfile(profileURL)
        guard let entitlements = profile["Entitlements"] as? [String: Any] else {
            throw ConsumerProvisioningFailure(
                code: .profileUnavailable,
                stage: .preparingIdentities,
                userMessage: "IOSSim could not prepare signing entitlements.",
                remediation: "Try provisioning again; your Apple authorization remains valid.",
                developerDetail: "Profile has no Entitlements dictionary."
            )
        }
        let url = directory.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        try writePlist(entitlements, to: url)
        return url
    }

    private func decodedProfile(_ url: URL) throws -> [String: Any] {
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            return plist
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ConsumerProvisioningFailure(
                code: .profileUnavailable,
                stage: .preparingIdentities,
                userMessage: "IOSSim could not validate its prepared signing profile.",
                remediation: "Try provisioning again; your Apple authorization remains valid.",
                developerDetail: "security cms failed for generated profile."
            )
        }
        return plist
    }

    private func nestedSignables(in appURL: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var values: [URL] = []
        for case let url as URL in enumerator {
            if ["framework", "xctest", "appex", "app", "bundle", "dylib"].contains(url.pathExtension) {
                values.append(url)
            }
        }
        return values.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    private func nestedTestBundle(in runnerURL: URL) -> URL? {
        let plugins = runnerURL.appendingPathComponent("PlugIns", isDirectory: true)
        return (try? fileManager.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "xctest" })
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return value
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: url, options: [.atomic])
    }

    private func developmentCertificateSHA1(
        profileURL: URL,
        expectedSHA256: String
    ) throws -> String {
        let profile = try decodedProfile(profileURL)
        let certificates = profile["DeveloperCertificates"] as? [Data] ?? []
        guard let certificate = certificates.first(where: {
            sha256Hex($0).caseInsensitiveCompare(expectedSHA256) == .orderedSame
        }) else {
            throw nativeProfileFailure("Prepared profile does not contain the IOSSim-managed certificate.")
        }
        return Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
    }

    /// Validates every native input before a confirmed Fresh Install removes an
    /// existing IOSSim app. This keeps the destructive step behind profile,
    /// device, team, certificate, and keychain-identity continuity checks.
    private func preflightNativeArtifacts(
        _ artifacts: NativeProvisioningArtifacts,
        teamIdentifier: String,
        signingDeviceIdentifier: String
    ) async throws -> String {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("iossim-native-preflight-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: directory) }
        let expected = try PersonalTeamBundleIdentifierSet(teamIdentifier: teamIdentifier)
        var identities: [String] = []
        for (artifact, bundleIdentifier) in [("main", expected.main), ("runner", expected.runner)] {
            guard let profile = artifacts.profiles.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                throw nativeProfileFailure("Native preflight is missing the \(artifact) profile.")
            }
            let url = directory.appendingPathComponent("\(artifact).mobileprovision")
            try profile.profileData.write(to: url, options: [.atomic, .completeFileProtection])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            _ = try profileState(
                url: url,
                artifact: artifact,
                expectedTeam: teamIdentifier,
                expectedBundleIdentifier: bundleIdentifier,
                selectedDeviceIdentifier: signingDeviceIdentifier,
                expectedCertificateFingerprint: artifacts.certificateFingerprint
            )
            identities.append(try developmentCertificateSHA1(
                profileURL: url,
                expectedSHA256: artifacts.certificateFingerprint
            ))
        }
        guard Set(identities).count == 1, let identity = identities.first else {
            throw nativeProfileFailure("Main and runner profiles do not contain the same development certificate.")
        }
        try await verifyKeychainSigningIdentity(identity, expectedTeam: teamIdentifier)
        return identity
    }

    private func verifyKeychainSigningIdentity(_ sha1: String, expectedTeam: String) async throws {
        let result = try await context.runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            workingDirectory: context.resourcesURL,
            environment: RuntimeProvisioning.deterministicEnvironment()
        )
        guard result.exitCode == 0, result.combinedOutput.uppercased().contains(sha1.uppercased()) else {
            throw ConsumerProvisioningFailure(
                code: .signingIdentityMissing,
                stage: .preparingIdentities,
                userMessage: "IOSSim could not use its managed signing identity.",
                remediation: "Restore IOSSim's managed signing key, then try Personal Team provisioning again.",
                developerDetail: "The keychain has no codesigning identity matching the prepared profile for team \(expectedTeam)."
            )
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private func plistDictionary(in output: String) -> [String: Any]? {
        guard let start = output.range(of: "<?xml")?.lowerBound,
              let end = output.range(of: "</plist>", options: .backwards)?.upperBound else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: Data(output[start..<end].utf8),
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private func nativeProfileFailure(_ detail: String) -> ConsumerProvisioningFailure {
        ConsumerProvisioningFailure(
            code: .profileUnavailable,
            stage: .preparingIdentities,
            userMessage: "IOSSim could not use its prepared iPhone signing profiles.",
            remediation: "Try Personal Team provisioning again; your Apple authorization remains valid.",
            developerDetail: detail
        )
    }

    private func makeWorkspace(teamIdentifier: String) throws -> URL {
        let root: URL
        if let workspaceRootURL {
            root = workspaceRootURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            root = support.appendingPathComponent("IOSSim/ProvisioningWork", isDirectory: true)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let token = PersonalTeamProvisioningPOC.deviceIdentifierHash(teamIdentifier).prefix(12)
        let workspace = root.appendingPathComponent("\(token)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func signingFailure(
        _ error: Error,
        code: ConsumerProvisioningErrorCode,
        stage: ConsumerProvisioningStage,
        artifact: String
    ) -> ConsumerProvisioningFailure {
        ConsumerProvisioningFailure(
            code: code,
            stage: stage,
            userMessage: "IOSSim could not sign its \(artifact) component.",
            remediation: "Try provisioning again; your Apple authorization remains valid.",
            developerDetail: String(describing: error)
        )
    }

    private func installFailure(
        _ code: ConsumerProvisioningErrorCode,
        stage: ConsumerProvisioningStage,
        detail: String
    ) -> ConsumerProvisioningFailure {
        ConsumerProvisioningFailure(
            code: code,
            stage: stage,
            userMessage: "IOSSim could not verify the iPhone installation.",
            remediation: "Keep the selected iPhone connected and unlocked, then choose Repair.",
            developerDetail: detail
        )
    }

    private func record(
        stage: ConsumerProvisioningStage,
        artifact: String? = nil,
        device: String? = nil,
        result: ProvisioningLogResult,
        errorCode: ConsumerProvisioningErrorCode? = nil,
        duration: Date? = nil,
        detail: String? = nil
    ) async throws {
        try await stateStore.append(ProvisioningLogEvent(
            stage: stage,
            artifact: artifact,
            selectedDevice: device,
            result: result,
            errorCode: errorCode,
            durationMilliseconds: duration.map { Int(Date().timeIntervalSince($0) * 1_000) },
            detail: detail
        ))
    }
}

enum SigningShellBuildPlan {
    /// Compatibility path for explicitly Xcode-managed provisioning. Native
    /// Personal Team requests never call this plan.
    static func arguments(projectURL: URL, derivedDataURL: URL, teamIdentifier: String) -> [String] {
        [
            "xcodebuild",
            "-project", projectURL.path,
            "-scheme", "IOSSimSigningShell",
            "-configuration", "Debug",
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", derivedDataURL.path,
            "-allowProvisioningUpdates",
            "build-for-testing",
            "DEVELOPMENT_TEAM=\(teamIdentifier)",
            "CODE_SIGN_STYLE=Automatic"
        ]
    }
}

private struct PreparedConsumerArtifacts: Sendable {
    let workspaceURL: URL
    let mainURL: URL
    let runnerURL: URL
    let identifiers: PersonalTeamBundleIdentifierSet
    let team: PersonalTeamCandidate
    let mainProfile: ConsumerProfileState
    let runnerProfile: ConsumerProfileState
    let appVersion: String
    let operation: ConsumerProvisioningOperation
}

enum SigningShellProjectGenerator {
    static func generate(
        at root: URL,
        teamIdentifier: String,
        mainBundleIdentifier: String,
        uiTestBundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws {
        let project = root.appendingPathComponent("IOSSimSigningShell.xcodeproj", isDirectory: true)
        let schemes = project.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try fileManager.createDirectory(at: schemes, withIntermediateDirectories: true)

        let mainSource = """
        #import <UIKit/UIKit.h>
        @interface IOSSimSigningAppDelegate : UIResponder <UIApplicationDelegate>
        @property (strong, nonatomic) UIWindow *window;
        @end
        @implementation IOSSimSigningAppDelegate
        @end
        int main(int argc, char *argv[]) {
            @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([IOSSimSigningAppDelegate class])); }
        }
        """
        let testSource = """
        #import <XCTest/XCTest.h>
        @interface IOSSimSigningShellUITests : XCTestCase @end
        @implementation IOSSimSigningShellUITests
        - (void)testSigningShell { XCTAssertTrue(YES); }
        @end
        """
        try mainSource.write(to: root.appendingPathComponent("main.m"), atomically: true, encoding: .utf8)
        try testSource.write(to: root.appendingPathComponent("SigningShellUITests.m"), atomically: true, encoding: .utf8)
        try projectFile(
            teamIdentifier: teamIdentifier,
            mainBundleIdentifier: mainBundleIdentifier,
            uiTestBundleIdentifier: uiTestBundleIdentifier
        ).write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try schemeFile.write(
            to: schemes.appendingPathComponent("IOSSimSigningShell.xcscheme"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func projectFile(
        teamIdentifier: String,
        mainBundleIdentifier: String,
        uiTestBundleIdentifier: String
    ) -> String {
        """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            classes = {};
            objectVersion = 60;
            objects = {
                A10000000000000000000001 = {isa = PBXBuildFile; fileRef = A10000000000000000000011; };
                A10000000000000000000002 = {isa = PBXBuildFile; fileRef = A10000000000000000000012; };
                A10000000000000000000003 = {isa = PBXBuildFile; fileRef = A10000000000000000000021; settings = {ATTRIBUTES = (Required, ); }; };
                A10000000000000000000004 = {isa = PBXContainerItemProxy; containerPortal = A10000000000000000000030; proxyType = 1; remoteGlobalIDString = A10000000000000000000040; remoteInfo = IOSSimSigningShell; };
                A10000000000000000000011 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = main.m; sourceTree = "<group>"; };
                A10000000000000000000012 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = SigningShellUITests.m; sourceTree = "<group>"; };
                A10000000000000000000021 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = IOSSimSigningShell.app; sourceTree = BUILT_PRODUCTS_DIR; };
                A10000000000000000000022 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = IOSSimSigningShellUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
                A10000000000000000000050 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
                A10000000000000000000051 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
                A10000000000000000000060 = {isa = PBXGroup; children = (A10000000000000000000011, A10000000000000000000012, A10000000000000000000061, ); sourceTree = "<group>"; };
                A10000000000000000000061 = {isa = PBXGroup; children = (A10000000000000000000021, A10000000000000000000022, ); name = Products; sourceTree = "<group>"; };
                A10000000000000000000040 = {isa = PBXNativeTarget; buildConfigurationList = A10000000000000000000070; buildPhases = (A10000000000000000000080, A10000000000000000000050, A10000000000000000000090, ); buildRules = (); dependencies = (); name = IOSSimSigningShell; productName = IOSSimSigningShell; productReference = A10000000000000000000021; productType = "com.apple.product-type.application"; };
                A10000000000000000000041 = {isa = PBXNativeTarget; buildConfigurationList = A10000000000000000000071; buildPhases = (A10000000000000000000081, A10000000000000000000051, A10000000000000000000091, ); buildRules = (); dependencies = (A10000000000000000000092, ); name = IOSSimSigningShellUITests; productName = IOSSimSigningShellUITests; productReference = A10000000000000000000022; productType = "com.apple.product-type.bundle.ui-testing"; };
                A10000000000000000000030 = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2660; TargetAttributes = {A10000000000000000000040 = {CreatedOnToolsVersion = 26.6; ProvisioningStyle = Automatic; }; A10000000000000000000041 = {CreatedOnToolsVersion = 26.6; ProvisioningStyle = Automatic; TestTargetID = A10000000000000000000040; }; }; }; buildConfigurationList = A10000000000000000000072; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = A10000000000000000000060; productRefGroup = A10000000000000000000061; projectDirPath = ""; projectRoot = ""; targets = (A10000000000000000000040, A10000000000000000000041, ); };
                A10000000000000000000090 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
                A10000000000000000000091 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
                A10000000000000000000080 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000001, ); runOnlyForDeploymentPostprocessing = 0; };
                A10000000000000000000081 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000002, ); runOnlyForDeploymentPostprocessing = 0; };
                A10000000000000000000092 = {isa = PBXTargetDependency; target = A10000000000000000000040; targetProxy = A10000000000000000000004; };
                A10000000000000000000100 = {isa = XCBuildConfiguration; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = \(teamIdentifier); GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \(mainBundleIdentifier); PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = iphoneos; TARGETED_DEVICE_FAMILY = 1; }; name = Debug; };
                A10000000000000000000101 = {isa = XCBuildConfiguration; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = \(teamIdentifier); GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \(mainBundleIdentifier); PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = iphoneos; TARGETED_DEVICE_FAMILY = 1; }; name = Release; };
                A10000000000000000000102 = {isa = XCBuildConfiguration; buildSettings = {BUNDLE_LOADER = ""; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = \(teamIdentifier); GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \(uiTestBundleIdentifier); PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = iphoneos; TARGETED_DEVICE_FAMILY = 1; TEST_TARGET_NAME = IOSSimSigningShell; }; name = Debug; };
                A10000000000000000000103 = {isa = XCBuildConfiguration; buildSettings = {BUNDLE_LOADER = ""; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = \(teamIdentifier); GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \(uiTestBundleIdentifier); PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = iphoneos; TARGETED_DEVICE_FAMILY = 1; TEST_TARGET_NAME = IOSSimSigningShell; }; name = Release; };
                A10000000000000000000104 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos; }; name = Debug; };
                A10000000000000000000105 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos; }; name = Release; };
                A10000000000000000000070 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000100, A10000000000000000000101, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
                A10000000000000000000071 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000102, A10000000000000000000103, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
                A10000000000000000000072 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000104, A10000000000000000000105, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
            };
            rootObject = A10000000000000000000030;
        }
        """
    }

    private static let schemeFile = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion="2660" version="1.7">
      <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        <BuildActionEntries>
          <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A10000000000000000000040" BuildableName="IOSSimSigningShell.app" BlueprintName="IOSSimSigningShell" ReferencedContainer="container:IOSSimSigningShell.xcodeproj"/>
          </BuildActionEntry>
          <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A10000000000000000000041" BuildableName="IOSSimSigningShellUITests.xctest" BlueprintName="IOSSimSigningShellUITests" ReferencedContainer="container:IOSSimSigningShell.xcodeproj"/>
          </BuildActionEntry>
        </BuildActionEntries>
      </BuildAction>
      <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
        <Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A10000000000000000000041" BuildableName="IOSSimSigningShellUITests.xctest" BlueprintName="IOSSimSigningShellUITests" ReferencedContainer="container:IOSSimSigningShell.xcodeproj"/></TestableReference></Testables>
      </TestAction>
      <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
        <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A10000000000000000000040" BuildableName="IOSSimSigningShell.app" BlueprintName="IOSSimSigningShell" ReferencedContainer="container:IOSSimSigningShell.xcodeproj"/></BuildableProductRunnable>
      </LaunchAction>
      <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
      <AnalyzeAction buildConfiguration="Debug"/>
      <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
    </Scheme>
    """
}

private extension FileManager {
    func copyItem(at sourceURL: URL, to destinationURL: URL, replacing: Bool) throws {
        if replacing, fileExists(atPath: destinationURL.path) { try removeItem(at: destinationURL) }
        try copyItem(at: sourceURL, to: destinationURL)
    }
}

private extension String {
    var lastPathComponent: String { URL(fileURLWithPath: self).lastPathComponent }
}
