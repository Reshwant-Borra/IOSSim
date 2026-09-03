import Foundation

public struct DevelopmentCLIEngine: IOSSimSetupEngine {
    public let cliURL: URL
    public let repositoryRoot: URL
    private let runner: ProcessRunner

    public init(cliURL: URL, repositoryRoot: URL, runner: ProcessRunner = ProcessRunner()) {
        self.cliURL = cliURL
        self.repositoryRoot = repositoryRoot
        self.runner = runner
    }

    public static func live() throws -> DevelopmentCLIEngine {
        if let explicit = ProcessInfo.processInfo.environment["IOSSIM_CLI_PATH"] {
            let cli = URL(fileURLWithPath: explicit)
            return DevelopmentCLIEngine(cliURL: cli, repositoryRoot: cli.deletingLastPathComponent())
        }

        if let explicitRoot = ProcessInfo.processInfo.environment["IOSSIM_REPOSITORY_ROOT"] {
            let root = URL(fileURLWithPath: explicitRoot)
            return DevelopmentCLIEngine(cliURL: root.appendingPathComponent("iossim"), repositoryRoot: root)
        }

        let starts = [
            Bundle.main.bundleURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]
        for start in starts {
            if let root = findRepositoryRoot(startingAt: start) {
                return DevelopmentCLIEngine(cliURL: root.appendingPathComponent("iossim"), repositoryRoot: root)
            }
        }

        throw NSError(
            domain: "IOSSimMac",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The development IOSSim CLI could not be found."]
        )
    }

    public func doctor() async throws -> DoctorStatus {
        let result = try await runCLI(arguments: ["doctor", "--json"], commandName: "doctor")
        guard result.exitCode == 0 else {
            throw ProcessFailure(commandName: "doctor", result: result)
        }
        return try DoctorStatus.decode(from: Data(result.stdout.utf8))
    }

    public func setup() async throws -> ProcessResult {
        try await checkedRun(arguments: ["setup"], commandName: "setup")
    }

    public func build() async throws -> ProcessResult {
        try await checkedRun(arguments: ["build"], commandName: "build")
    }

    public func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        var arguments = ["device"]
        if let selectedDeviceIdentifier, !selectedDeviceIdentifier.isEmpty {
            arguments.append(contentsOf: ["--device", selectedDeviceIdentifier])
        }
        return try await checkedRun(arguments: arguments, commandName: "device")
    }

    private func checkedRun(arguments: [String], commandName: String) async throws -> ProcessResult {
        let result = try await runCLI(arguments: arguments, commandName: commandName)
        if result.exitCode != 0 {
            throw ProcessFailure(commandName: commandName, result: result)
        }
        return result
    }

    private func runCLI(arguments: [String], commandName: String) async throws -> ProcessResult {
        try await runner.run(executableURL: cliURL, arguments: arguments, workingDirectory: repositoryRoot)
    }

    private static func findRepositoryRoot(startingAt start: URL) -> URL? {
        var current = start
        if current.pathExtension == "app" {
            current.deleteLastPathComponent()
        }
        for _ in 0..<12 {
            if FileManager.default.isExecutableFile(atPath: current.appendingPathComponent("iossim").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
        return nil
    }
}
