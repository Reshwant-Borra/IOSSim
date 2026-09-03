import Foundation

public protocol IOSSimSetupEngine: Sendable {
    func doctor() async throws -> DoctorStatus
    func setup() async throws -> ProcessResult
    func build() async throws -> ProcessResult
    func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult
}

public struct EngineLogEntry: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let date: Date
    public let stage: String
    public let result: ProcessResult

    public init(date: Date = Date(), stage: String, result: ProcessResult) {
        self.date = date
        self.stage = stage
        self.result = result
    }
}

public struct UnavailableIOSSimSetupEngine: IOSSimSetupEngine {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public func doctor() async throws -> DoctorStatus {
        throw unavailableFailure(commandName: "doctor")
    }

    public func setup() async throws -> ProcessResult {
        throw unavailableFailure(commandName: "setup")
    }

    public func build() async throws -> ProcessResult {
        throw unavailableFailure(commandName: "build")
    }

    public func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult {
        throw unavailableFailure(commandName: "device")
    }

    private func unavailableFailure(commandName: String) -> ProcessFailure {
        ProcessFailure(
            commandName: commandName,
            result: ProcessResult(exitCode: 127, stdout: "", stderr: message)
        )
    }
}
