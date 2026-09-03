import Foundation

public struct BundledProvisioningEngine: IOSSimSetupEngine {
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
            throw ProcessFailure(commandName: "doctor", result: result)
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

    private func checkedRun(arguments: [String], commandName: String) async throws -> ProcessResult {
        let result = try await runHelper(arguments: arguments, commandName: commandName)
        if result.exitCode != 0 {
            throw ProcessFailure(commandName: commandName, result: result)
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
                environment: RuntimeProvisioning.deterministicEnvironment()
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
}
