import CryptoKit
import Foundation

public enum EngineTransportResponse: Sendable {
    /// The helper returned a versioned result. `raw` is the exact stdout bytes.
    case result(QualificationResult, raw: Data)
    /// The helper exited without a result (crash, injected crash point, or kill).
    case terminated(exitCode: Int32)
}

public protocol EngineTransport: Sendable {
    func send(_ request: EngineRequest) async throws -> EngineTransportResponse
}

/// Client used by the Veya UI and `VeyaQualify`. It never runs the engine itself: every command is
/// executed by the packaged `IOSSimProvisioner` helper through `engine --request <json>`.
public struct ProvisionerEngineClient: EngineTransport {
    public let helperURL: URL
    private let runner: ProcessRunner

    public init(helperURL: URL, runner: ProcessRunner = ProcessRunner()) {
        self.helperURL = helperURL
        self.runner = runner
    }

    public func send(_ request: EngineRequest) async throws -> EngineTransportResponse {
        let body = String(decoding: try QualificationResult.encoder().encode(request), as: UTF8.self)
        let result = try await runner.run(
            executableURL: helperURL,
            arguments: [ProvisionerEngineProtocol.helperCommand, "--request", body],
            workingDirectory: helperURL.deletingLastPathComponent(),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            redactOutput: false
        )
        let raw = Data(result.stdout.utf8)
        guard let decoded = try? QualificationResult.decoder().decode(QualificationResult.self, from: raw) else {
            return .terminated(exitCode: result.exitCode)
        }
        guard decoded.exitCode.rawValue == result.exitCode else {
            throw InstallationStateFailure.unsafeValue("helper exit mismatch")
        }
        return .result(decoded, raw: raw)
    }
}

// MARK: - Scenario fixtures (data only; the fixture world is compiled only into qualification builds)

public enum ScenarioInjectionAction: String, Codable, Sendable {
    case retryableFailure
    case terminalFailure
    /// Terminate the helper before the boundary call has any effect.
    case crashBefore
    /// Perform the boundary effect, persist the simulated world, then terminate the helper.
    case crashAfter
}

public enum ScenarioBoundaryOperation: String, Codable, Sendable {
    case observe
    case execute
    case prove
}

public struct ScenarioInjection: Codable, Equatable, Sendable {
    public let domain: InstallationDomain
    public let operation: ScenarioBoundaryOperation
    /// 1-based count of calls to this boundary across the whole scenario.
    public let ordinal: Int
    public let action: ScenarioInjectionAction
}

public struct ScenarioDomainFixture: Codable, Equatable, Sendable {
    public let domain: InstallationDomain
    /// External state before Veya acts: `missing`, `satisfied`, `waitingForUser`, `retryableFailure`, `terminalFailure`, `invalid`.
    public let initial: DomainObservationState
    public let connectionBound: Bool
    public let userAction: String?
}

public struct ScenarioExpectation: Codable, Equatable, Sendable {
    public let status: String?
    public let exitCode: QualificationExitCode?
    public let helperTerminated: Bool?
    public let satisfiedDomains: [InstallationDomain]?
    public let transitionsCompleted: Int?
    public let firstFailureCode: String?
}

public struct ScenarioStep: Codable, Equatable, Sendable {
    public let command: EngineCommand
    /// Index of an earlier step whose run this step resumes.
    public let resumeStep: Int?
    public let completeUserActions: [InstallationDomain]?
    public let advanceClockSeconds: Int?
    public let connectionGeneration: UInt64?
    public let expect: ScenarioExpectation
}

public struct ScenarioFixture: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let name: String
    public let clockStartMilliseconds: Int64
    public let stage: InstallationDomain?
    public let capabilities: CapabilityManifest
    public let domains: [ScenarioDomainFixture]
    public let injections: [ScenarioInjection]
    public let steps: [ScenarioStep]
    /// Expected boundary call counts at the end (subset check): domain -> operation -> count.
    public let expectedCalls: [String: [String: Int]]?

    public static func load(_ url: URL) throws -> (ScenarioFixture, digest: String) {
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(ScenarioFixture.self, from: data)
        guard fixture.schemaVersion == currentSchemaVersion else {
            throw InstallationStateFailure.unsupportedSchema(fixture.schemaVersion)
        }
        try InstallationSafeValue.validate(fixture.name, field: "scenario name", maximumLength: 96)
        return (fixture, ScenarioDigest.sha256(data))
    }
}

enum ScenarioDigest {
    static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic UUID derived from a seed and counter.
    static func uuid(seed: String, counter: Int) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(seed)#\(counter)".utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], (bytes[6] & 0x0f) | 0x50, bytes[7],
            (bytes[8] & 0x3f) | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct ScenarioStepReport: Codable, Equatable, Sendable {
    public let index: Int
    public let command: EngineCommand
    public let helperTerminated: Bool
    public let helperExitCode: Int32
    public let result: QualificationResult?
    public let mismatches: [String]
}

public struct ScenarioReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let scenario: String
    public let fixtureDigest: String
    public let steps: [ScenarioStepReport]
    public let externalCalls: [String: [String: Int]]
    public let mismatches: [String]

    public var passed: Bool { mismatches.isEmpty && steps.allSatisfy { $0.mismatches.isEmpty } }
}

/// Drives a scenario fixture through any `EngineTransport` (normally the packaged helper). It sequences
/// client commands and compares results with expectations; it contains no setup logic.
public struct ScenarioRunner: Sendable {
    public let transport: any EngineTransport

    public init(transport: any EngineTransport) {
        self.transport = transport
    }

    public func run(fixtureURL: URL, stateRoot: URL) async throws -> ScenarioReport {
        let (fixture, digest) = try ScenarioFixture.load(fixtureURL)
        var reports: [ScenarioStepReport] = []
        var runs: [Int: RunID] = [:]
        for (index, step) in fixture.steps.enumerated() {
            let seed = "\(digest)|step-\(index)"
            var runID: RunID?
            if step.command == .resume {
                guard let resumeStep = step.resumeStep, let prior = runs[resumeStep] else {
                    throw InstallationStateFailure.unsafeValue("scenario resume step")
                }
                runID = prior
            } else if step.command == .reconcile {
                runID = RunID(rawValue: ScenarioDigest.uuid(seed: seed, counter: -1))
            }
            if let runID { runs[index] = runID }
            let request = EngineRequest(
                command: step.command,
                stage: fixture.stage,
                runID: runID,
                capabilities: [.plan, .reconcile, .resume].contains(step.command) ? fixture.capabilities : nil,
                connectionGeneration: step.connectionGeneration,
                scenario: ScenarioBinding(
                    fixturePath: fixtureURL.path,
                    fixtureDigest: digest,
                    stateRoot: stateRoot.path,
                    seed: seed,
                    completedUserActions: step.completeUserActions ?? [],
                    advanceClockSeconds: step.advanceClockSeconds ?? 0
                )
            )
            let response = try await transport.send(request)
            reports.append(Self.evaluate(index: index, step: step, response: response))
        }
        let calls = ScenarioWorldFile.calls(stateRoot: stateRoot)
        var mismatches: [String] = []
        for (domain, operations) in fixture.expectedCalls ?? [:] {
            for (operation, count) in operations where calls[domain]?[operation, default: 0] ?? 0 != count {
                mismatches.append("\(domain).\(operation) calls expected \(count) observed \(calls[domain]?[operation] ?? 0)")
            }
        }
        return ScenarioReport(
            schemaVersion: ScenarioReport.currentSchemaVersion,
            scenario: fixture.name,
            fixtureDigest: digest,
            steps: reports,
            externalCalls: calls,
            mismatches: mismatches
        )
    }

    static func evaluate(index: Int, step: ScenarioStep, response: EngineTransportResponse) -> ScenarioStepReport {
        let expect = step.expect
        var mismatches: [String] = []
        switch response {
        case .terminated(let code):
            if expect.helperTerminated != true { mismatches.append("helper terminated with \(code)") }
            return ScenarioStepReport(
                index: index, command: step.command, helperTerminated: true,
                helperExitCode: code, result: nil, mismatches: mismatches
            )
        case .result(let result, _):
            if expect.helperTerminated == true { mismatches.append("helper was expected to terminate") }
            if let status = expect.status, status != result.status {
                mismatches.append("status expected \(status) observed \(result.status)")
            }
            if let code = expect.exitCode, code != result.exitCode {
                mismatches.append("exit expected \(code.rawValue) observed \(result.exitCode.rawValue)")
            }
            if let domains = expect.satisfiedDomains {
                let satisfied = result.observations.filter { $0.state == .satisfied }.map(\.domain)
                if Set(domains) != Set(satisfied) {
                    mismatches.append("satisfied expected \(domains.map(\.rawValue).sorted()) observed \(satisfied.map(\.rawValue).sorted())")
                }
            }
            if let count = expect.transitionsCompleted, count != result.transitionsCompleted {
                mismatches.append("transitions expected \(count) observed \(result.transitionsCompleted)")
            }
            if let code = expect.firstFailureCode, code != result.firstFailure?.code {
                mismatches.append("first failure expected \(code) observed \(result.firstFailure?.code ?? "none")")
            }
            return ScenarioStepReport(
                index: index, command: step.command, helperTerminated: false,
                helperExitCode: result.exitCode.rawValue, result: result, mismatches: mismatches
            )
        }
    }
}

/// Read-only view of the simulated external world's call counters.
public enum ScenarioWorldFile {
    public static let fileName = "scenario-world.json"

    public static func calls(stateRoot: URL) -> [String: [String: Int]] {
        guard let data = try? Data(contentsOf: stateRoot.appendingPathComponent(fileName)),
              let world = try? JSONDecoder().decode(ScenarioWorldState.self, from: data) else { return [:] }
        return world.domains.mapValues(\.calls).filter { !$0.value.isEmpty }
    }
}

struct ScenarioWorldState: Codable, Equatable {
    struct Domain: Codable, Equatable {
        var calls: [String: Int] = [:]
        var resources: [String] = []
        /// resourceID -> connection generation of the proof (-1 when not connection-bound).
        var proofs: [String: Int64] = [:]
        var effects = 0
        var userActionCompleted = false
    }

    var clockOffsetSeconds: Int = 0
    var domains: [String: Domain] = [:]
}
