import Foundation
import IOSSimMacCore

// VeyaQualify is a thin client of the packaged IOSSimProvisioner. It parses arguments, sends one
// EngineRequest per command, and reports the helper's result. It contains no setup logic: all
// observation, planning, mutation, proof, and promotion happen in the helper's canonical engine.

struct UsageError: Error { let message: String }

struct Options {
    var command = ""
    var positional: [String] = []
    var json = false
    var helper: String?
    var stage: InstallationDomain?
    var capabilities: String?
    var run: String?
    var connection: UInt64?
    var stateRoot: String?
    var isolatedRoot: String?
    var eventsFD: Int32?
    var deviceUDID: String?
    var deviceName: String?

    var device: EngineDeviceSelection? {
        deviceUDID.map { EngineDeviceSelection(udid: $0, name: deviceName ?? "iPhone") }
    }

    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        guard let command = iterator.next() else { throw UsageError(message: "missing command") }
        self.command = command
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw UsageError(message: "\(flag) requires a value") }
            return next
        }
        while let argument = iterator.next() {
            switch argument {
            case "--json": json = true
            case "--helper": helper = try value(argument)
            case "--stage":
                let raw = try value(argument)
                guard let domain = InstallationDomain(rawValue: raw) else { throw UsageError(message: "unknown stage \(raw)") }
                stage = domain
            case "--capabilities": capabilities = try value(argument)
            case "--run", "--resume": run = try value(argument)
            case "--connection":
                guard let parsed = UInt64(try value(argument)) else { throw UsageError(message: "invalid --connection") }
                connection = parsed
            case "--state-root": stateRoot = try value(argument)
            case "--isolated-root": isolatedRoot = try value(argument)
            case "--device-udid": deviceUDID = try value(argument)
            case "--device-name": deviceName = try value(argument)
            case "--events-fd":
                guard let parsed = Int32(try value(argument)) else { throw UsageError(message: "invalid --events-fd") }
                eventsFD = parsed
            default:
                if argument.hasPrefix("--") { throw UsageError(message: "unknown option \(argument)") }
                positional.append(argument)
            }
        }
    }
}

let usage = """
usage: veya-qualify <command> [options]
  inspect  [--stage DOMAIN] [--connection N]
  plan     [--stage DOMAIN] [--capabilities FILE]
  reconcile --capabilities FILE [--stage DOMAIN] [--resume RUN]
  resume   --run RUN --capabilities FILE
  verify   DOMAIN
  scenario FIXTURE --state-root DIR
  full     --capabilities FILE
verify domains: any installation domain, or key-store (signingKey)
options: --json  --helper PATH  --events-fd FD  --device-udid UDID [--device-name NAME]
         --isolated-root DIR (qualification helpers only)
exit: 0 ok, 2 user action, 3 retryable, 4 assertion, 5 product failure, 6 refused, 64 usage, 70 protocol
"""

func helperURL(_ options: Options) -> URL {
    if let helper = options.helper { return URL(fileURLWithPath: helper) }
    return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("IOSSimProvisioner")
}

func loadCapabilities(_ path: String?) throws -> CapabilityManifest? {
    guard let path else { return nil }
    return try JSONDecoder().decode(CapabilityManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func write(_ data: Data) { FileHandle.standardOutput.write(data + Data("\n".utf8)) }

func emitEvents(_ events: [InstallationEvent], fd: Int32?) {
    guard let fd else { return }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let encoder = QualificationResult.encoder()
    for event in events {
        if let line = try? encoder.encode(event) { handle.write(line + Data("\n".utf8)) }
    }
}

func report(_ result: QualificationResult, raw: Data, options: Options) {
    emitEvents(result.events, fd: options.eventsFD)
    if options.json {
        write(raw)
        return
    }
    var line = "\(result.command.rawValue): \(result.status) (exit \(result.exitCode.rawValue))"
    if let run = result.runID { line += " run \(run)" }
    print(line)
    for observation in result.observations {
        print("  \(observation.domain.rawValue): \(observation.state.rawValue)")
    }
    if let action = result.userAction { print("  user action: \(action)") }
    if let failure = result.firstFailure { print("  first failure: \(failure.code) \(failure.safeMessage)") }
    for skipped in result.skippedProofs { print("  skipped proof: \(skipped.domain.rawValue) - \(skipped.reason)") }
}

func run() async -> Int32 {
    let options: Options
    do {
        options = try Options(Array(CommandLine.arguments.dropFirst()))
    } catch let error as UsageError {
        FileHandle.standardError.write(Data("\(error.message)\n\(usage)\n".utf8))
        return QualificationExitCode.usage.rawValue
    } catch {
        return QualificationExitCode.usage.rawValue
    }
    let client = ProvisionerEngineClient(helperURL: helperURL(options))
    do {
        let request: EngineRequest
        switch options.command {
        case "inspect":
            request = EngineRequest(command: .inspect, stage: options.stage, connectionGeneration: options.connection, device: options.device, isolatedStateRoot: options.isolatedRoot)
        case "plan":
            request = EngineRequest(
                command: .plan, stage: options.stage, capabilities: try loadCapabilities(options.capabilities),
                connectionGeneration: options.connection, device: options.device, isolatedStateRoot: options.isolatedRoot
            )
        case "reconcile", "full", "resume":
            let isResume = options.command == "resume" || options.run != nil
            guard let manifest = try loadCapabilities(options.capabilities) else {
                throw UsageError(message: "\(options.command) requires --capabilities FILE")
            }
            var runID: RunID?
            if let raw = options.run {
                guard let uuid = UUID(uuidString: raw) else { throw UsageError(message: "invalid run id") }
                runID = RunID(rawValue: uuid)
            } else if isResume {
                throw UsageError(message: "resume requires --run RUN")
            }
            request = EngineRequest(
                command: isResume ? .resume : .reconcile,
                stage: options.command == "full" ? nil : options.stage,
                runID: runID,
                capabilities: manifest,
                connectionGeneration: options.connection,
                device: options.device,
                isolatedStateRoot: options.isolatedRoot
            )
        case "verify":
            let aliases: [String: InstallationDomain] = ["key-store": .signingKey, "ddi": .developerSupport, "signature": .payload, "device": .application]
            guard let raw = options.positional.first, let domain = aliases[raw] ?? InstallationDomain(rawValue: raw) else {
                throw UsageError(message: "verify requires a domain")
            }
            request = EngineRequest(command: .verify, stage: domain, connectionGeneration: options.connection, device: options.device, isolatedStateRoot: options.isolatedRoot)
        case "scenario":
            guard let fixture = options.positional.first, let stateRoot = options.stateRoot else {
                throw UsageError(message: "scenario requires FIXTURE and --state-root DIR")
            }
            let report = try await ScenarioRunner(transport: client).run(
                fixtureURL: URL(fileURLWithPath: fixture),
                stateRoot: URL(fileURLWithPath: stateRoot, isDirectory: true)
            )
            for step in report.steps { emitEvents(step.result?.events ?? [], fd: options.eventsFD) }
            if options.json {
                write(try QualificationResult.encoder().encode(report))
            } else {
                print("scenario \(report.scenario): \(report.passed ? "PASS" : "FAIL")")
                for step in report.steps {
                    let outcome = step.helperTerminated ? "helper terminated (\(step.helperExitCode))" : (step.result?.status ?? "-")
                    print("  step \(step.index) \(step.command.rawValue): \(outcome)")
                    step.mismatches.forEach { print("    mismatch: \($0)") }
                }
                report.mismatches.forEach { print("  mismatch: \($0)") }
            }
            return report.passed ? QualificationExitCode.success.rawValue : QualificationExitCode.assertionFailed.rawValue
        case "help", "--help":
            print(usage)
            return QualificationExitCode.success.rawValue
        default:
            throw UsageError(message: "unknown command \(options.command)")
        }
        switch try await client.send(request) {
        case .result(let result, let raw):
            report(result, raw: raw, options: options)
            return result.exitCode.rawValue
        case .terminated(let code):
            FileHandle.standardError.write(Data("helper terminated without a result (exit \(code))\n".utf8))
            return QualificationExitCode.internalProtocol.rawValue
        }
    } catch let error as UsageError {
        FileHandle.standardError.write(Data("\(error.message)\n\(usage)\n".utf8))
        return QualificationExitCode.usage.rawValue
    } catch {
        FileHandle.standardError.write(Data("qualification protocol failure\n".utf8))
        return QualificationExitCode.internalProtocol.rawValue
    }
}

exit(await run())
