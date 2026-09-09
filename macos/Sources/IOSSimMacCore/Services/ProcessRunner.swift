import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public struct ProcessFailure: Error, Equatable, Sendable {
    public let commandName: String
    public let result: ProcessResult
}

public final class ProcessRunner: @unchecked Sendable {
    public typealias RunHandler = @Sendable (
        URL,
        [String],
        URL,
        [String: String]?,
        Bool
    ) async throws -> ProcessResult

    private let runHandler: RunHandler?

    public init() {
        self.runHandler = nil
    }

    public init(runHandler: @escaping RunHandler) {
        self.runHandler = runHandler
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil,
        redactOutput: Bool = true
    ) async throws -> ProcessResult {
        if let runHandler {
            return try await runHandler(executableURL, arguments, workingDirectory, environment, redactOutput)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reads = DispatchGroup()
                let output = ProcessOutputBuffer()
                reads.enter()
                reads.enter()
                process.terminationHandler = { proc in
                    reads.notify(queue: .global(qos: .utility)) {
                        let (stdoutData, stderrData) = output.values()
                        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        continuation.resume(returning: ProcessResult(
                            exitCode: proc.terminationStatus,
                            stdout: redactOutput ? Redactor.redact(stdout) : stdout,
                            stderr: redactOutput ? Redactor.redact(stderr) : stderr
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    reads.leave()
                    reads.leave()
                    continuation.resume(throwing: error)
                    return
                }
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                DispatchQueue.global(qos: .utility).async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    output.setStdout(data)
                    reads.leave()
                }
                DispatchQueue.global(qos: .utility).async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    output.setStderr(data)
                    reads.leave()
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) {
        lock.lock()
        stdout = data
        lock.unlock()
    }

    func setStderr(_ data: Data) {
        lock.lock()
        stderr = data
        lock.unlock()
    }

    func values() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}
