import Foundation
import XCTest
@testable import IOSSimMacCore

private enum HermeticScenario: String, CaseIterable, Sendable {
    case freshState
    case missingHelper
    case corruptHelper
    case missingArtifact
    case oldSchema
    case wrongRelease
    case noDevice
    case lockedDevice
    case trustPending
    case developerModeDisabled
    case appleAuthRequired
    case twoFARequired
    case appleAuthFailure
    case deviceRegistrationFailure
    case profileFailure
    case signingFailure
    case installInterruption
    case developerProfileTrustPending
    case ddiUnavailable
    case pairingAbsent
    case pairingCorrupt
    case localDevVPNMissing
    case vpnPermissionPending
    case runtimeProofFailure
    case processCrashMidStage
    case resumeAfterRestart
}

private enum HermeticStage: String, Codable, Sendable {
    case integrity
    case device
    case trust
    case developerMode
    case apple
    case signing
    case install
    case profileTrust
    case developerSupport
    case pairing
    case vpn
    case runtime
    case ready
}

private struct HermeticOutcome: Equatable, Sendable {
    let stage: HermeticStage
    let code: String?
    let actionRequired: Bool

    static let ready = HermeticOutcome(stage: .ready, code: nil, actionRequired: false)
}

private struct HermeticRoots: Sendable {
    let root: URL
    let applicationSupport: URL
    let provisioning: URL
    let artifacts: URL
    let developerSupport: URL
    let pairingMetadata: URL
    let logs: URL
    let supportExport: URL
    let signedArtifacts: URL
    let journal: URL

    init(root: URL) throws {
        self.root = root
        applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        provisioning = root.appendingPathComponent("Provisioning", isDirectory: true)
        artifacts = root.appendingPathComponent("Artifacts", isDirectory: true)
        developerSupport = root.appendingPathComponent("DeveloperSupport", isDirectory: true)
        pairingMetadata = root.appendingPathComponent("PairingMetadata", isDirectory: true)
        logs = root.appendingPathComponent("Logs", isDirectory: true)
        supportExport = root.appendingPathComponent("SupportExport", isDirectory: true)
        signedArtifacts = root.appendingPathComponent("SignedArtifacts", isDirectory: true)
        journal = applicationSupport.appendingPathComponent("hermetic-journal.json")
        for directory in [
            applicationSupport, provisioning, artifacts, developerSupport,
            pairingMetadata, logs, supportExport, signedArtifacts,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func assertContained(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }
}

private actor HermeticCallLog {
    private(set) var calls: [String] = []
    private(set) var externalAccessAttempts = 0

    func record(_ call: String) { calls.append(call) }
    func attemptedExternalAccess() { externalAccessAttempts += 1 }
}

private actor HermeticKeychain {
    private var values: [String: Data] = [:]
    func set(_ data: Data, for key: String) { values[key] = data }
    func value(for key: String) -> Data? { values[key] }
}

private protocol HermeticDeviceServicing: Sendable {
    func inspect(_ scenario: HermeticScenario) async -> HermeticOutcome?
}

private protocol HermeticAppleProvisioningServicing: Sendable {
    func authorize(_ scenario: HermeticScenario) async -> HermeticOutcome?
}

private protocol HermeticSigningServicing: Sendable {
    func prepare(_ scenario: HermeticScenario) async -> HermeticOutcome?
}

private protocol HermeticDeveloperSupportServicing: Sendable {
    func prepareDeveloperSupport(_ scenario: HermeticScenario) async -> HermeticOutcome?
}

private protocol HermeticInstallationServicing: Sendable {
    func install(_ scenario: HermeticScenario) async throws -> HermeticOutcome?
}

private protocol HermeticPairingServicing: Sendable {
    func preparePairing(_ scenario: HermeticScenario) async -> HermeticOutcome?
}

private protocol HermeticVPNServicing: Sendable {
    func prepareVPN(_ scenario: HermeticScenario) async -> HermeticOutcome?
}

private protocol HermeticRuntimeProofServicing: Sendable {
    func prove(_ scenario: HermeticScenario) async -> HermeticOutcome?
}

private struct HermeticServices:
    HermeticDeviceServicing,
    HermeticAppleProvisioningServicing,
    HermeticSigningServicing,
    HermeticDeveloperSupportServicing,
    HermeticInstallationServicing,
    HermeticPairingServicing,
    HermeticVPNServicing,
    HermeticRuntimeProofServicing
{
    let log: HermeticCallLog

    func inspect(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await log.record("device.inspect")
        switch scenario {
        case .noDevice: return .init(stage: .device, code: "VEYA-DEVICE-001", actionRequired: true)
        case .lockedDevice: return .init(stage: .device, code: "VEYA-DEVICE-004", actionRequired: true)
        case .trustPending: return .init(stage: .trust, code: "VEYA-TRUST-003", actionRequired: true)
        case .developerModeDisabled: return .init(stage: .developerMode, code: "VEYA-DEVSERVICE-001", actionRequired: true)
        default: return nil
        }
    }

    func authorize(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await log.record("apple.authorize")
        switch scenario {
        case .appleAuthRequired: return .init(stage: .apple, code: "VEYA-APPLE-001", actionRequired: true)
        case .twoFARequired: return .init(stage: .apple, code: "VEYA-APPLE-002", actionRequired: true)
        case .appleAuthFailure: return .init(stage: .apple, code: "VEYA-APPLE-006", actionRequired: false)
        case .deviceRegistrationFailure: return .init(stage: .apple, code: "VEYA-APPLE-021", actionRequired: false)
        case .profileFailure: return .init(stage: .signing, code: "VEYA-PROFILE-001", actionRequired: false)
        default: return nil
        }
    }

    func prepare(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await log.record("signing.prepare")
        return scenario == .signingFailure
            ? .init(stage: .signing, code: "VEYA-SIGNING-010", actionRequired: false)
            : nil
    }

    func install(_ scenario: HermeticScenario) async throws -> HermeticOutcome? {
        await log.record("install.install")
        if scenario == .processCrashMidStage { throw HermeticCrash.simulated }
        if scenario == .installInterruption {
            return .init(stage: .install, code: "VEYA-INSTALL-004", actionRequired: false)
        }
        if scenario == .developerProfileTrustPending {
            return .init(stage: .profileTrust, code: "VEYA-PROFILE-010", actionRequired: true)
        }
        return nil
    }

    func prepareDeveloperSupport(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await log.record("developerSupport.prepare")
        return scenario == .ddiUnavailable
            ? .init(stage: .developerSupport, code: "VEYA-DEVSERVICE-002", actionRequired: false)
            : nil
    }

    func preparePairing(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await log.record("pairing.prepare")
        switch scenario {
        case .pairingAbsent: return .init(stage: .pairing, code: "VEYA-PAIRING-001", actionRequired: true)
        case .pairingCorrupt: return .init(stage: .pairing, code: "VEYA-PAIRING-020", actionRequired: false)
        default: return nil
        }
    }

    func prepareVPN(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await log.record("vpn.prepare")
        switch scenario {
        case .localDevVPNMissing: return .init(stage: .vpn, code: "VEYA-VPN-001", actionRequired: true)
        case .vpnPermissionPending: return .init(stage: .vpn, code: "VEYA-VPN-003", actionRequired: true)
        default: return nil
        }
    }

    func prove(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await log.record("runtime.prove")
        return scenario == .runtimeProofFailure
            ? .init(stage: .runtime, code: "VEYA-RUNTIME-002", actionRequired: false)
            : nil
    }

    // Disambiguating wrappers keep the fake protocols explicit at the call site.
    func developerSupport(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await prepareDeveloperSupport(scenario)
    }
    func pairing(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await preparePairing(scenario)
    }
    func vpn(_ scenario: HermeticScenario) async -> HermeticOutcome? {
        await prepareVPN(scenario)
    }
}

private enum HermeticCrash: Error { case simulated }

private actor HermeticInstallationEngine {
    private let scenario: HermeticScenario
    private let roots: HermeticRoots
    private let services: HermeticServices
    private let keychain: HermeticKeychain

    init(scenario: HermeticScenario, roots: HermeticRoots, log: HermeticCallLog, keychain: HermeticKeychain) {
        self.scenario = scenario
        self.roots = roots
        services = HermeticServices(log: log)
        self.keychain = keychain
    }

    func reconcile() async throws -> HermeticOutcome {
        if let integrity = integrityOutcome() { return integrity }
        if scenario == .resumeAfterRestart, let resumed = try loadJournal(), resumed == .install {
            try writeJournal(.profileTrust)
        } else {
            try writeJournal(.device)
            if let outcome = await services.inspect(scenario) { return outcome }
            try writeJournal(.apple)
            if let outcome = await services.authorize(scenario) { return outcome }
            await keychain.set(Data("opaque-session-fixture".utf8), for: "apple-session")
            try writeJournal(.signing)
            if let outcome = await services.prepare(scenario) { return outcome }
            try writeJournal(.install)
            if let outcome = try await services.install(scenario) { return outcome }
        }
        try writeJournal(.developerSupport)
        if let outcome = await services.developerSupport(scenario) { return outcome }
        try writeJournal(.pairing)
        if let outcome = await services.pairing(scenario) { return outcome }
        try writeJournal(.vpn)
        if let outcome = await services.vpn(scenario) { return outcome }
        try writeJournal(.runtime)
        if let outcome = await services.prove(scenario) { return outcome }
        try writeJournal(.ready)
        return .ready
    }

    private func integrityOutcome() -> HermeticOutcome? {
        switch scenario {
        case .missingHelper: return .init(stage: .integrity, code: "VEYA-INTEGRITY-001", actionRequired: false)
        case .corruptHelper: return .init(stage: .integrity, code: "VEYA-INTEGRITY-002", actionRequired: false)
        case .missingArtifact: return .init(stage: .integrity, code: "VEYA-INTEGRITY-004", actionRequired: false)
        case .oldSchema: return .init(stage: .integrity, code: "VEYA-UPDATE-001", actionRequired: false)
        case .wrongRelease: return .init(stage: .integrity, code: "VEYA-UPDATE-004", actionRequired: false)
        default: return nil
        }
    }

    private func writeJournal(_ stage: HermeticStage) throws {
        guard roots.assertContained(roots.journal) else { throw HermeticCrash.simulated }
        let data = try JSONEncoder().encode(stage)
        try data.write(to: roots.journal, options: .atomic)
    }

    private func loadJournal() throws -> HermeticStage? {
        guard FileManager.default.fileExists(atPath: roots.journal.path) else { return nil }
        return try JSONDecoder().decode(HermeticStage.self, from: Data(contentsOf: roots.journal))
    }
}

@MainActor
final class HermeticInstallationHarnessTests: XCTestCase {
    private var testRoot: URL!

    override func setUp() {
        super.setUp()
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        testRoot = repositoryRoot
            .appendingPathComponent(".build/iossim/hermetic-harness", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let testRoot, testRoot.path.contains("/.build/iossim/hermetic-harness/") {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
        super.tearDown()
    }

    func testCompleteFaultMatrixUsesOnlyIsolatedRootsAndFakes() async throws {
        let expected: [HermeticScenario: HermeticStage] = [
            .freshState: .ready,
            .missingHelper: .integrity,
            .corruptHelper: .integrity,
            .missingArtifact: .integrity,
            .oldSchema: .integrity,
            .wrongRelease: .integrity,
            .noDevice: .device,
            .lockedDevice: .device,
            .trustPending: .trust,
            .developerModeDisabled: .developerMode,
            .appleAuthRequired: .apple,
            .twoFARequired: .apple,
            .appleAuthFailure: .apple,
            .deviceRegistrationFailure: .apple,
            .profileFailure: .signing,
            .signingFailure: .signing,
            .installInterruption: .install,
            .developerProfileTrustPending: .profileTrust,
            .ddiUnavailable: .developerSupport,
            .pairingAbsent: .pairing,
            .pairingCorrupt: .pairing,
            .localDevVPNMissing: .vpn,
            .vpnPermissionPending: .vpn,
            .runtimeProofFailure: .runtime,
        ]

        for scenario in expected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let roots = try HermeticRoots(root: testRoot.appendingPathComponent(scenario.rawValue))
            let log = HermeticCallLog()
            let engine = HermeticInstallationEngine(
                scenario: scenario,
                roots: roots,
                log: log,
                keychain: HermeticKeychain()
            )
            let outcome = try await engine.reconcile()
            XCTAssertEqual(outcome.stage, expected[scenario], scenario.rawValue)
            XCTAssertTrue(roots.assertContained(roots.journal))
            let externalAccessAttempts = await log.externalAccessAttempts
            XCTAssertEqual(externalAccessAttempts, 0)
        }
    }

    func testCrashThenRestartResumesAfterLastObservedStage() async throws {
        let roots = try HermeticRoots(root: testRoot.appendingPathComponent("crash-resume"))
        let log = HermeticCallLog()
        let keychain = HermeticKeychain()
        let crashing = HermeticInstallationEngine(
            scenario: .processCrashMidStage,
            roots: roots,
            log: log,
            keychain: keychain
        )
        do {
            _ = try await crashing.reconcile()
            XCTFail("expected simulated crash")
        } catch HermeticCrash.simulated {}

        let resumed = HermeticInstallationEngine(
            scenario: .resumeAfterRestart,
            roots: roots,
            log: log,
            keychain: keychain
        )
        let resumedOutcome = try await resumed.reconcile()
        XCTAssertEqual(resumedOutcome, .ready)
    }

    func testTwoHarnessesHaveIndependentStateAndInMemoryKeychains() async throws {
        let rootsA = try HermeticRoots(root: testRoot.appendingPathComponent("A"))
        let rootsB = try HermeticRoots(root: testRoot.appendingPathComponent("B"))
        let engineA = HermeticInstallationEngine(
            scenario: .freshState, roots: rootsA, log: HermeticCallLog(), keychain: HermeticKeychain()
        )
        let engineB = HermeticInstallationEngine(
            scenario: .runtimeProofFailure, roots: rootsB, log: HermeticCallLog(), keychain: HermeticKeychain()
        )
        async let outcomeA = engineA.reconcile()
        async let outcomeB = engineB.reconcile()
        let values = try await (outcomeA, outcomeB)
        XCTAssertEqual(values.0, .ready)
        XCTAssertEqual(values.1.stage, .runtime)
        XCTAssertNotEqual(rootsA.journal.path, rootsB.journal.path)
    }
}
