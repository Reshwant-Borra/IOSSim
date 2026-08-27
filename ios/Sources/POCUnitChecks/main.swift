import Foundation
import IOSSimOnDeviceDVTPOC

@main
struct POCUnitChecks {
    static func main() async throws {
        try validSemanticRPPairingPlistPasses()
        try missingPrivateKeyFailsWithoutLeakingValues()
        try wrongAltIRKLengthFails()
        try topLevelArrayIsRejected()
        try inMemoryStoreValidatesBeforeSaving()
        try deleteRemovesPairing()
        try localDevVPNRouteDetection()
        await routeProbeSurfacesEndpointAndTCPResult()
        try await diagnosticStateRecordsStatusAndTiming()
        try await sessionRecorderRedactsAndClassifies()
        try await bridgeReportsUnavailableWhenIdeviceIsNotLinked()
        print("POCUnitChecks passed")
    }

    static func validSemanticRPPairingPlistPasses() throws {
        let data = try makePairingPlist(identifier: "12345678-1234-1234-1234-123456789abc")
        let summary = try RPPairingValidator.validate(data)
        try require(summary.pairingLoaded, "pairing should be loaded")
        try require(summary.publicKeyPresent, "public key present")
        try require(summary.privateKeyPresent, "private key present")
        try require(summary.altIRKPresent, "alt_irk present")
        try require(summary.identifierRedacted == "1234...9abc (36 chars)", "identifier redacted")
    }

    static func missingPrivateKeyFailsWithoutLeakingValues() throws {
        let data = try makePairingPlist(omit: "private_key")
        do {
            _ = try RPPairingValidator.validate(data)
            throw CheckError("expected validation failure")
        } catch let error as POCError {
            try require(error.code == .pairingCredentialMissing, "missing key error code")
            try require(!error.message.contains("12345678"), "error should not leak identifier")
        }
    }

    static func wrongAltIRKLengthFails() throws {
        let data = try plistData([
            "public_key": Data(repeating: 1, count: 32),
            "private_key": Data(repeating: 2, count: 32),
            "identifier": "12345678-1234-1234-1234-123456789abc",
            "alt_irk": Data(repeating: 3, count: 15)
        ])
        do {
            _ = try RPPairingValidator.validate(data)
            throw CheckError("expected validation failure")
        } catch let error as POCError {
            try require(error.code == .pairingCredentialMissing, "wrong alt_irk error code")
        }
    }

    static func topLevelArrayIsRejected() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [["not": "a pairing"]], format: .xml, options: 0)
        do {
            _ = try RPPairingValidator.validate(data)
            throw CheckError("expected validation failure")
        } catch let error as POCError {
            try require(error.code == .pairingFileInvalid, "array rejected")
        }
    }

    static func inMemoryStoreValidatesBeforeSaving() throws {
        let store = InMemoryRPPairingStore()
        try expectThrows { _ = try store.importPairingData(Data("not plist".utf8)) }
        try expectThrows { _ = try store.loadPairingData() }

        let data = try makePairingPlist()
        _ = try store.importPairingData(data)
        let loaded = try store.loadPairingData()
        let summary = try store.pairingSummary()
        try require(loaded == data, "store returns imported data")
        try require(summary != nil, "store returns summary")
    }

    static func deleteRemovesPairing() throws {
        let store = InMemoryRPPairingStore(data: try makePairingPlist())
        try store.deletePairingData()
        let summary = try store.pairingSummary()
        try require(summary == nil, "delete removes pairing")
    }

    static func localDevVPNRouteDetection() throws {
        try require(DeveloperRouteProbe.localDevVPNAppearsActive(in: [
            NetworkInterfaceSnapshot(name: "utun7", address: "10.7.0.0", family: "IPv4")
        ]), "10.7.0.0 route visible")
        try require(!DeveloperRouteProbe.localDevVPNAppearsActive(in: [
            NetworkInterfaceSnapshot(name: "en0", address: "192.168.1.10", family: "IPv4")
        ]), "normal LAN is not LocalDevVPN")
    }

    static func routeProbeSurfacesEndpointAndTCPResult() async {
        let probe = DeveloperRouteProbe(
            interfaceProvider: FakeInterfaces(values: [
                NetworkInterfaceSnapshot(name: "utun2", address: "10.7.0.1", family: "IPv4")
            ]),
            tcpProber: FakeTCPProber(result: TCPProbeResult(
                endpoint: DeveloperEndpoint(),
                connected: true,
                latencyMs: 12.5,
                error: nil
            ))
        )
        let result = await probe.run()
        precondition(result.localDevVPNAppearsActive)
        precondition(result.tcpResult.connected)
        precondition(result.tcpResult.latencyMs == 12.5)
    }

    static func diagnosticStateRecordsStatusAndTiming() async throws {
        let state = DiagnosticState()
        await state.start(.endpointReachable)
        await state.succeed(.endpointReachable, message: "connected")

        let snapshot = await state.snapshot()
        guard let record = snapshot.stages.first(where: { $0.stage == .endpointReachable }) else {
            throw CheckError("missing endpoint record")
        }
        try require(record.status == .success, "endpoint should be success")
        try require(record.durationMs != nil, "duration should be recorded")
        try require(snapshot.events.contains { $0.message == "connected" }, "event should be recorded")
    }

    static func sessionRecorderRedactsAndClassifies() async throws {
        let recorder = SessionDiagnosticRecorder(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("iossim-poc-unit-\(UUID().uuidString)", isDirectory: true)
        )
        _ = await recorder.startSession(prefix: "UNIT")
        await recorder.record(
            category: "ERROR",
            component: "Pairing",
            previousState: "validating",
            newState: "failed",
            errorCode: "PAIRING_CREDENTIAL_MISSING",
            message: "private_key should not be persisted",
            metadata: ["detail": "psk material hidden"]
        )

        let snapshot = await recorder.snapshot()
        try require(snapshot.firstAbnormalEvent?.component == "Pairing", "first abnormal event recorded")
        let urls = await recorder.exportURLs()
        try require(urls.contains { $0.pathExtension == "jsonl" }, "jsonl export available")
        guard let logURL = urls.first(where: { $0.pathExtension == "jsonl" }) else {
            throw CheckError("missing jsonl url")
        }
        let text = try String(contentsOf: logURL, encoding: .utf8)
        try require(text.contains("[REDACTED]"), "sensitive message redacted")
        try require(!text.contains("private_key should not be persisted"), "raw sensitive message absent")
        try require(!text.contains("psk material hidden"), "raw sensitive metadata absent")
    }

    static func bridgeReportsUnavailableWhenIdeviceIsNotLinked() async throws {
        guard !IdeviceOnDeviceTunnelClient.ideviceLinked else {
            return
        }

        let bridge = IdeviceOnDeviceTunnelClient()
        do {
            try await bridge.connect(pairingData: try makePairingPlist(), endpoint: DeveloperEndpoint())
            throw CheckError("expected bridge unavailable error")
        } catch let error as POCError {
            try require(error.code == .ideviceBridgeUnavailable, "bridge unavailable error code")
        }
    }

    static func makePairingPlist(identifier: String = "12345678-1234-1234-1234-123456789abc", omit: String? = nil) throws -> Data {
        var plist: [String: Any] = [
            "public_key": Data(repeating: 1, count: 32),
            "private_key": Data(repeating: 2, count: 32),
            "identifier": identifier,
            "alt_irk": Data(repeating: 3, count: 16)
        ]
        if let omit {
            plist.removeValue(forKey: omit)
        }
        return try plistData(plist)
    }

    static func plistData(_ plist: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func expectThrows(_ body: () throws -> Void) throws {
        do {
            try body()
            throw CheckError("expected throw")
        } catch is CheckError {
            throw CheckError("expected throw")
        } catch {
            return
        }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw CheckError(message)
        }
    }
}

struct CheckError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct FakeInterfaces: InterfaceSnapshotProvider {
    let values: [NetworkInterfaceSnapshot]

    func snapshots() -> [NetworkInterfaceSnapshot] {
        values
    }
}

private struct FakeTCPProber: TCPProbing {
    let result: TCPProbeResult

    func probe(endpoint: DeveloperEndpoint, timeout: TimeInterval) async -> TCPProbeResult {
        result
    }
}
