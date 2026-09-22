import Foundation
@testable import IOSSimMacCore
import XCTest

/// M3: the qualification harness drives the packaged helper's canonical engine, never its own.
final class VeyaQualifyTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testEveryM3ScenarioPassesThroughTheHelperEngine() async throws {
        let fixtures = try scenarioFixtures().filter { $0.lastPathComponent.hasPrefix("m3-") }
        XCTAssertGreaterThanOrEqual(fixtures.count, 7)
        for fixture in fixtures {
            let report = try await ScenarioRunner(transport: client()).run(fixtureURL: fixture, stateRoot: makeRoot())
            XCTAssertTrue(report.passed, "\(fixture.lastPathComponent): \(report.mismatches + report.steps.flatMap(\.mismatches))")
            try assertSecretFree(QualificationResult.encoder().encode(report))
        }
    }

    func testScenarioTraceIsByteEquivalentForUIClientAndCLI() async throws {
        let fixture = try XCTUnwrap(scenarioFixtures().first { $0.lastPathComponent == "m3-crash-after-certificate-issue-resume.json" })
        let uiReport = try await ScenarioRunner(transport: client()).run(fixtureURL: fixture, stateRoot: makeRoot())
        let uiBytes = try QualificationResult.encoder().encode(uiReport)

        let cli = try run(qualify(), ["scenario", fixture.path, "--state-root", makeRoot().path, "--json"])
        XCTAssertEqual(cli.status, 0)
        XCTAssertEqual(cli.stdout, uiBytes + Data("\n".utf8), "CLI and UI-client scenario traces diverged")
    }

    func testExitCodesAreStableAcrossCLIAndHelper() throws {
        XCTAssertEqual(try run(qualify(), []).status, 64)
        XCTAssertEqual(try run(qualify(), ["bogus"]).status, 64)
        XCTAssertEqual(try run(qualify(), ["reconcile"]).status, 64, "mutation without a capability manifest is a usage error")
        XCTAssertEqual(try run(qualify(), ["inspect", "--helper", "/nonexistent/IOSSimProvisioner"]).status, 70)
        XCTAssertEqual(try run(helper(), ["engine"]).status, 64)
        XCTAssertEqual(try run(helper(), ["engine", "--request", "{not json"]).status, 64)
    }

    func testHelperRefusesMutationWithoutCapabilityManifest() async throws {
        let request = EngineRequest(command: .reconcile, scenario: try binding(for: "m3-fresh-install-trust-then-ready.json"))
        guard case .result(let result, _) = try await client().send(request) else { return XCTFail("helper terminated") }
        XCTAssertEqual(result.exitCode, .refused)
        XCTAssertEqual(result.firstFailure?.code, "VEYA-SEC-010")
        XCTAssertTrue(result.events.isEmpty)
    }

    func testHelperRefusesTamperedScenarioFixture() async throws {
        let good = try binding(for: "m3-fresh-install-trust-then-ready.json")
        let tampered = ScenarioBinding(
            fixturePath: good.fixturePath,
            fixtureDigest: "sha256:" + String(repeating: "0", count: 64),
            stateRoot: good.stateRoot,
            seed: good.seed
        )
        guard case .result(let result, _) = try await client().send(EngineRequest(command: .inspect, scenario: tampered)) else {
            return XCTFail("helper terminated")
        }
        XCTAssertEqual(result.exitCode, .refused)
        XCTAssertEqual(result.firstFailure?.code, "VEYA-SEC-012")
    }

    func testInspectAndPlanNeverCreateTheJournal() async throws {
        let scenario = try binding(for: "m3-fresh-install-trust-then-ready.json")
        for command in [EngineCommand.inspect, .plan, .verify] {
            let request = EngineRequest(command: command, stage: command == .verify ? .runtime : nil, scenario: scenario)
            guard case .result = try await client().send(request) else { return XCTFail("helper terminated") }
        }
        let journal = URL(fileURLWithPath: scenario.stateRoot).appendingPathComponent("journal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path), "read-only commands created installation state")
    }

    func testJSONResultIsDeterministicForIdenticalRequests() async throws {
        let first = try binding(for: "m3-fresh-install-trust-then-ready.json")
        let second = ScenarioBinding(fixturePath: first.fixturePath, fixtureDigest: first.fixtureDigest, stateRoot: makeRoot().path, seed: first.seed)
        var outputs: [Data] = []
        for scenario in [first, second] {
            let request = EngineRequest(
                command: .reconcile,
                runID: RunID(rawValue: UUID(uuidString: "6f1c1f86-4a1d-4f0e-9d51-3b3d0f1f7a10")!),
                capabilities: CapabilityManifest(allowedDomains: InstallationDomain.allCases, maximumTransitions: 64),
                connectionGeneration: 1,
                scenario: scenario
            )
            guard case .result(_, let raw) = try await client().send(request) else { return XCTFail("helper terminated") }
            outputs.append(raw)
        }
        XCTAssertEqual(outputs[0], outputs[1])
    }

    /// Structural guard: qualification clients must never become an orchestration implementation.
    func testQualificationClientsContainNoEngineImplementation() throws {
        let sources = packageRoot().appendingPathComponent("Sources")
        let clientFiles = [
            sources.appendingPathComponent("VeyaQualify/main.swift"),
            sources.appendingPathComponent("IOSSimMacCore/Installation/ProvisionerEngineClient.swift"),
        ]
        let forbidden = [
            "VeyaReconciliationEngine(", "ReconciliationPlanner(", "InstallationJournalRepository(",
            "InstallationTransition", "InstallationObserver", "EngineHost", "ScenarioComposition",
            "putCandidate", "promote(", "attachEvidence", "codesign", "SecIdentity",
        ]
        for file in clientFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) references \(token)")
            }
        }
        // The engine is constructed in exactly one production place: the helper-side EngineHost.
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var constructors: [String] = []
        for url in files {
            if try String(contentsOf: url, encoding: .utf8).contains("VeyaReconciliationEngine(") {
                constructors.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(constructors, ["ProvisionerProtocol.swift"])
    }

    // MARK: - Helpers

    private func assertSecretFree(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for marker in ["password", "private_key", "-----begin", "cookie", "pairing_psk", "x-apple-gs-token"] {
            XCTAssertFalse(text.contains(marker), "qualification output contains \(marker)")
        }
    }

    private func binding(for name: String) throws -> ScenarioBinding {
        let fixture = try XCTUnwrap(scenarioFixtures().first { $0.lastPathComponent == name })
        let (_, digest) = try ScenarioFixture.load(fixture)
        return ScenarioBinding(fixturePath: fixture.path, fixtureDigest: digest, stateRoot: makeRoot().path, seed: "test")
    }

    private func client() -> ProvisionerEngineClient { ProvisionerEngineClient(helperURL: helper()) }

    private func products() -> URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }
    private func helper() -> URL { products().appendingPathComponent("IOSSimProvisioner") }
    private func qualify() -> URL { products().appendingPathComponent("VeyaQualify") }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func scenarioFixtures() throws -> [URL] {
        let directory = packageRoot().appendingPathComponent("Tests/IOSSimMacCoreTests/Fixtures/scenarios")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("veya-qualify-tests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
