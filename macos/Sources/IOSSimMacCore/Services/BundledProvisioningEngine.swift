import Foundation

public struct BundledProvisioningEngine: IOSSimSetupEngine {
    public let consumerProvisioningEnabled = true
    public let automaticPairingEnabled = true
    public let helperURL: URL
    public let resourcesURL: URL
    private let runner: ProcessRunner

    public init(helperURL: URL, resourcesURL: URL, runner: ProcessRunner = ProcessRunner()) {
        self.helperURL = helperURL
        self.resourcesURL = resourcesURL
        self.runner = runner
    }

    public static func live(bundle: Bundle = .main) throws -> BundledProvisioningEngine {
        let bundleURL = bundle.bundleURL
        let helperURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("IOSSimProvisioner")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw NSError(
                domain: "IOSSimMac",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Bundled runtime damaged: IOSSimProvisioner is missing from this application."]
            )
        }
        guard let resourcesURL = bundle.resourceURL else {
            throw NSError(
                domain: "IOSSimMac",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Bundled runtime damaged: this application has no Resources directory."]
            )
        }
        return BundledProvisioningEngine(helperURL: helperURL, resourcesURL: resourcesURL)
    }

    public var launchDiagnostics: String {
        """
        Stage: Environment Check
        Helper: Bundled IOSSimProvisioner
        Executable: \(helperURL.path)
        Executable available: \(FileManager.default.isExecutableFile(atPath: helperURL.path) ? "Yes" : "No")
        Resources: \(resourcesURL.path)
        Repository fallback: disabled
        Arguments: direct Process invocation
        """
    }

    public func doctor() async throws -> DoctorStatus {
        let result = try await runHelper(arguments: ["doctor", "--json"], commandName: "doctor")
        guard result.exitCode == 0 else {
            throw ProcessFailure(commandName: "doctor", result: redacted(result))
        }
        return try DoctorStatus.decode(from: Data(result.stdout.utf8))
    }

    public func setup() async throws -> ProcessResult {
        try await checkedRun(arguments: ["setup"], commandName: "setup")
    }

    public func build() async throws -> ProcessResult {
        try await checkedRun(arguments: ["verify-artifacts", "--json"], commandName: "verify-artifacts")
    }

    public func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        var arguments = ["install"]
        if let selectedDeviceIdentifier, !selectedDeviceIdentifier.isEmpty {
            arguments.append(contentsOf: ["--device", selectedDeviceIdentifier])
        }
        return try await checkedRun(arguments: arguments, commandName: "install")
    }

    public func discoverPersonalTeams(selectedDeviceIdentifier: String?) async throws -> [PersonalTeamCandidate] {
        var arguments = ["consumer-teams", "--json"]
        if let selectedDeviceIdentifier, !selectedDeviceIdentifier.isEmpty {
            arguments += ["--device", selectedDeviceIdentifier]
        }
        let result = try await runHelper(arguments: arguments, commandName: "consumer-teams")
        guard result.exitCode == 0 else {
            throw ProcessFailure(commandName: "consumer-teams", result: redacted(result))
        }
        return try decodeEnvelope([PersonalTeamCandidate].self, from: result.stdout)
    }

    public func consumerProvision(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        var arguments = [
            "consumer-provision",
            "--operation", request.operation.rawValue.lowercased(),
            "--device", request.selectedDeviceIdentifier,
            "--team", request.selectedTeamIdentifier,
            "--backend", request.backend.rawValue
        ]
        if request.allowFreshInstallAfterCrossTeamConflict {
            arguments.append("--confirm-fresh-install")
        }
        if let generation = request.generation {
            arguments += ["--generation", String(generation)]
        }
        let result = try await runHelper(
            arguments: arguments,
            commandName: "consumer-provision"
        )
        guard result.exitCode == 0 else {
            if let failure = try? decodeFailure(from: result.stdout) { throw failure }
            throw ProcessFailure(commandName: "consumer-provision", result: redacted(result))
        }
        return try decodeEnvelope(ConsumerProvisioningResult.self, from: result.stdout)
    }

    public func resumeConsumerSetup(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        var arguments = [
            "consumer-resume-setup",
            "--operation", request.operation.rawValue.lowercased(),
            "--device", request.selectedDeviceIdentifier,
            "--team", request.selectedTeamIdentifier,
            "--backend", request.backend.rawValue
        ]
        if let generation = request.generation {
            arguments += ["--generation", String(generation)]
        }
        let result = try await runHelper(arguments: arguments, commandName: "consumer-resume-setup")
        guard result.exitCode == 0 else {
            if let failure = try? decodeFailure(from: result.stdout) { throw failure }
            throw ProcessFailure(commandName: "consumer-resume-setup", result: redacted(result))
        }
        return try decodeEnvelope(ConsumerProvisioningResult.self, from: result.stdout)
    }

    public func consumerProvisioningStatus() async throws -> ConsumerProvisioningManifest? {
        let result = try await runHelper(arguments: ["consumer-status", "--json"], commandName: "consumer-status")
        guard result.exitCode == 0 else {
            throw ProcessFailure(commandName: "consumer-status", result: redacted(result))
        }
        return try decodeEnvelope(ConsumerProvisioningManifest?.self, from: result.stdout)
    }

    public func confirmRuntimeSetup() async throws -> ConsumerProvisioningManifest {
        let result = try await runHelper(arguments: ["consumer-runtime-ready", "--json"], commandName: "consumer-runtime-ready")
        guard result.exitCode == 0 else {
            throw ProcessFailure(commandName: "consumer-runtime-ready", result: redacted(result))
        }
        return try decodeEnvelope(ConsumerProvisioningManifest.self, from: result.stdout)
    }

    public func prepareAutomaticPairing(
        selectedDeviceIdentifier: String,
        generation: UInt64
    ) async throws -> AutomaticPairingReceipt {
        let result = try await runHelper(
            arguments: [
                "prepare-pairing", "--json",
                "--device", selectedDeviceIdentifier,
                "--generation", String(generation)
            ],
            commandName: "prepare-pairing"
        )
        guard result.exitCode == 0 else {
            throw ProcessFailure(commandName: "prepare-pairing", result: redacted(result))
        }
        return try decodeEnvelope(AutomaticPairingReceipt.self, from: result.stdout)
    }

    public func exportSupportBundle() async throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let output = downloads.appendingPathComponent("IOSSim-Support-\(Int(Date().timeIntervalSince1970)).zip")
        let result = try await runHelper(
            arguments: ["support-bundle", "--output", output.path, "--json"],
            commandName: "support-bundle"
        )
        guard result.exitCode == 0 else {
            throw ProcessFailure(commandName: "support-bundle", result: redacted(result))
        }
        return try decodeEnvelope(SupportBundleExportResult.self, from: result.stdout).url
    }

    private func checkedRun(arguments: [String], commandName: String) async throws -> ProcessResult {
        let result = try await runHelper(arguments: arguments, commandName: commandName)
        if result.exitCode != 0 {
            throw ProcessFailure(commandName: commandName, result: redacted(result))
        }
        return result
    }

    private func runHelper(arguments: [String], commandName: String) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ProcessFailure(
                commandName: commandName,
                result: ProcessResult(
                    exitCode: 127,
                    stdout: "",
                    stderr: "Bundled runtime damaged: required IOSSim setup helper is missing. Reinstall IOSSim."
                )
            )
        }
        do {
            return try await runner.run(
                executableURL: helperURL,
                arguments: arguments,
                workingDirectory: resourcesURL,
                environment: RuntimeProvisioning.deterministicEnvironment(),
                redactOutput: false
            )
        } catch {
            throw ProcessFailure(
                commandName: commandName,
                result: ProcessResult(
                    exitCode: 126,
                    stdout: "",
                    stderr: Redactor.redact("\(launchDiagnostics)\n\(String(describing: error))")
                )
            )
        }
    }

    private func decodeEnvelope<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HelperEnvelope<T>.self, from: Data(text.utf8)).data
    }

    private func decodeFailure(from text: String) throws -> ConsumerProvisioningFailure {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HelperFailureEnvelope.self, from: Data(text.utf8)).error
    }

    private func redacted(_ result: ProcessResult) -> ProcessResult {
        ProcessResult(
            exitCode: result.exitCode,
            stdout: Redactor.redact(result.stdout),
            stderr: Redactor.redact(result.stderr)
        )
    }
}

private struct HelperEnvelope<T: Decodable>: Decodable {
    let data: T
}

private struct HelperFailureEnvelope: Decodable {
    let error: ConsumerProvisioningFailure
}
