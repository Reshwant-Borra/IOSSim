import Foundation

public protocol IOSSimSetupEngine: Sendable {
    var consumerProvisioningEnabled: Bool { get }
    func doctor() async throws -> DoctorStatus
    func setup() async throws -> ProcessResult
    func build() async throws -> ProcessResult
    func provisionDevice(selectedDeviceIdentifier: String?) async throws -> ProcessResult
    func discoverPersonalTeams(selectedDeviceIdentifier: String?) async throws -> [PersonalTeamCandidate]
    func consumerProvision(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult
    func resumeConsumerSetup(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult
    func consumerProvisioningStatus() async throws -> ConsumerProvisioningManifest?
    func confirmRuntimeSetup() async throws -> ConsumerProvisioningManifest
    func exportSupportBundle() async throws -> URL
}

public extension IOSSimSetupEngine {
    var consumerProvisioningEnabled: Bool { false }
    func discoverPersonalTeams(selectedDeviceIdentifier: String?) async throws -> [PersonalTeamCandidate] { [] }

    func consumerProvision(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        throw ConsumerProvisioningFailure(
            code: .unsupported,
            stage: .preparingArtifacts,
            userMessage: "Consumer Personal Team provisioning is unavailable in this build.",
            remediation: "Use the packaged production IOSSim Mac app.",
            developerDetail: "The selected setup engine does not implement consumer provisioning."
        )
    }

    func resumeConsumerSetup(_ request: ConsumerProvisioningRequest) async throws -> ConsumerProvisioningResult {
        throw ConsumerProvisioningFailure(
            code: .unsupported,
            stage: .failed,
            userMessage: "This IOSSim build cannot resume device setup.",
            remediation: "Use the packaged IOSSim Mac app.",
            developerDetail: "The selected setup engine does not implement checkpoint resume."
        )
    }

    func consumerProvisioningStatus() async throws -> ConsumerProvisioningManifest? { nil }

    func confirmRuntimeSetup() async throws -> ConsumerProvisioningManifest {
        throw ConsumerProvisioningFailure(
            code: .unsupported,
            stage: .verifyingRuntimeReadiness,
            userMessage: "Runtime confirmation is unavailable in this build.",
            remediation: "Use the packaged production IOSSim Mac app.",
            developerDetail: "The selected setup engine does not implement runtime confirmation."
        )
    }

    func exportSupportBundle() async throws -> URL {
        throw ConsumerProvisioningFailure(
            code: .unsupported,
            stage: .idle,
            userMessage: "Support export is unavailable in this build.",
            remediation: "Use the packaged production IOSSim Mac app.",
            developerDetail: "The selected setup engine does not implement support export."
        )
    }
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
