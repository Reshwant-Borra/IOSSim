import Foundation

public struct DevelopmentCLIEngine: IOSSimSetupEngine {
    public let cliURL: URL
    public let repositoryRoot: URL
    public let executableURL: URL
    private let runner: ProcessRunner

    public init(
        cliURL: URL,
        repositoryRoot: URL,
        executableURL: URL = URL(fileURLWithPath: "/bin/bash"),
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.cliURL = cliURL
        self.repositoryRoot = repositoryRoot
        self.executableURL = executableURL
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

        if let configuredRoot = bundledDevelopmentRepositoryRoot() {
            return DevelopmentCLIEngine(
                cliURL: configuredRoot.appendingPathComponent("iossim"),
                repositoryRoot: configuredRoot
            )
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

    public var launchDiagnostics: String {
        let fm = FileManager.default
        var cliIsDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: cliURL.path, isDirectory: &cliIsDirectory)
        let executableExists = fm.isExecutableFile(atPath: executableURL.path)
        let cliExecutable = fm.isExecutableFile(atPath: cliURL.path)
        var cwdIsDirectory: ObjCBool = false
        let cwdExists = fm.fileExists(atPath: repositoryRoot.path, isDirectory: &cwdIsDirectory)
        return """
        Stage: Environment Check
        Helper: Development CLI
        Executable: \(executableURL.path)
        Executable available: \(executableExists ? "Yes" : "No")
        Launcher: \(cliURL.path)
        Launcher exists: \(exists ? "Yes" : "No")
        Launcher executable: \(cliExecutable ? "Yes" : "No")
        Launcher is directory: \(cliIsDirectory.boolValue ? "Yes" : "No")
        Working directory: \(repositoryRoot.path)
        Working directory exists: \(cwdExists ? "Yes" : "No")
        Working directory is directory: \(cwdIsDirectory.boolValue ? "Yes" : "No")
        Arguments prefix: \(launchArguments(for: []).joined(separator: " "))
        """
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
        do {
            appendDevelopmentLog("launch \(commandName)\n\(launchDiagnostics)")
            let result = try await runner.run(
                executableURL: executableURL,
                arguments: launchArguments(for: arguments),
                workingDirectory: repositoryRoot,
                environment: Self.guiSafeEnvironment(repositoryRoot: repositoryRoot)
            )
            appendDevelopmentLog("complete \(commandName): exit \(result.exitCode)")
            return result
        } catch {
            let details = "\(launchDiagnostics)\n\(String(describing: error))"
            appendDevelopmentLog("failed \(commandName): \(details)")
            throw ProcessFailure(
                commandName: commandName,
                result: ProcessResult(exitCode: 126, stdout: "", stderr: Redactor.redact(details))
            )
        }
    }

    public func launchArguments(for arguments: [String]) -> [String] {
        [cliURL.path] + arguments
    }

    public static func guiSafeEnvironment(repositoryRoot: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let fallbackPath = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        if env["PATH", default: ""].isEmpty {
            env["PATH"] = fallbackPath
        } else {
            let existing = env["PATH"] ?? ""
            for part in fallbackPath.split(separator: ":") where !existing.split(separator: ":").contains(part) {
                env["PATH"] = (env["PATH"] ?? "") + ":\(part)"
            }
        }
        if env["HOME", default: ""].isEmpty {
            env["HOME"] = NSHomeDirectory()
        }
        env["IOSSIM_REPOSITORY_ROOT"] = repositoryRoot.path
        return env
    }

    private static func bundledDevelopmentRepositoryRoot() -> URL? {
        guard let url = Bundle.main.url(forResource: "DevelopmentRepositoryRoot", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let root = URL(fileURLWithPath: path)
        return FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("iossim").path) ? root : nil
    }

    private func appendDevelopmentLog(_ text: String) {
        let manager = FileManager.default
        guard let libraryURL = manager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return
        }
        let logsDirectory = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("IOSSimMac", isDirectory: true)
        do {
            try manager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let url = logsDirectory.appendingPathComponent("development-engine.log")
            let entry = "[\(Date())]\n\(Redactor.redact(text))\n\n"
            if manager.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
                try handle.close()
            } else {
                try entry.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            return
        }
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
