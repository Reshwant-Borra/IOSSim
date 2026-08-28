import Foundation
import CoreLocation
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
        try routeInterpolation()
        try constantSpeedDistanceCalculations()
        try pauseDoesNotAdvanceRouteProgress()
        try resumeUsesActiveElapsedTime()
        try suspensionTickSkipsMissedPoints()
        try monotonicRouteProgression()
        try completedHoldingDoesNotClearSimulation()
        try await staleWriterCannotSendAfterOwnershipChanges()
        try await staleGenerationCallbackCannotAffectCurrentConnection()
        try await reconnectRestoresCurrentDrivePosition()
        try await stopPreventsDelayedWrites()
        try routeDistanceClamping()
        try await driveDiagnosticsSerialize()
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

    static func routeInterpolation() throws {
        let route = try testRoute()
        let midpoint = route.coordinate(atDistance: route.totalDistanceMeters / 2)
        try require(abs(midpoint.longitude - 0.005) < 0.001, "route midpoint should interpolate by distance")
        let projection = route.nearestProjection(to: CLLocationCoordinate2D(latitude: 0.001, longitude: 0.005))
        try require(abs(projection.distanceAlongRouteMeters - route.totalDistanceMeters / 2) < 25, "projection returns nearest route progress")
    }

    static func constantSpeedDistanceCalculations() throws {
        let controller = DriveSessionController(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let route = try driveRoute()
        controller.prepareRoute(route, speedMPH: 60)
        try controller.startDrive(now: 0)
        let position = try requireValue(controller.expectedPosition(now: 10), "position exists")
        try require(abs(position.expectedDistanceMeters - 268.224) < 1, "60 mph for 10s advances constant distance")
    }

    static func pauseDoesNotAdvanceRouteProgress() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 30)
        try controller.startDrive(now: 0)
        let paused = try requireValue(controller.pause(now: 10), "paused position")
        let later = try requireValue(controller.expectedPosition(now: 30), "paused later")
        try require(abs(paused.expectedDistanceMeters - later.expectedDistanceMeters) < 0.1, "paused progress must not advance")
    }

    static func resumeUsesActiveElapsedTime() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 30)
        try controller.startDrive(now: 0)
        _ = controller.pause(now: 10)
        controller.resume(now: 30)
        let position = try requireValue(controller.expectedPosition(now: 40), "resumed position")
        let expected = DriveSpeed.metersPerSecond(fromMPH: 30) * 20
        try require(abs(position.expectedDistanceMeters - expected) < 1, "resume excludes paused duration")
    }

    static func suspensionTickSkipsMissedPoints() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 45)
        try controller.startDrive(now: 0)
        let first = try requireValue(controller.expectedPosition(now: 1), "first")
        let delayed = try requireValue(controller.expectedPosition(now: 9), "delayed")
        let expected = DriveSpeed.metersPerSecond(fromMPH: 45) * 9
        try require(delayed.expectedDistanceMeters > first.expectedDistanceMeters, "delayed tick advances")
        try require(abs(delayed.expectedDistanceMeters - expected) < 1, "delayed tick jumps to elapsed-time position")
    }

    static func monotonicRouteProgression() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 45)
        try controller.startDrive(now: 10)
        let later = try requireValue(controller.expectedPosition(now: 20), "later")
        let earlier = try requireValue(controller.expectedPosition(now: 12), "earlier")
        try require(earlier.expectedDistanceMeters >= later.expectedDistanceMeters, "route progress never regresses while driving")
    }

    static func completedHoldingDoesNotClearSimulation() throws {
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 70)
        try controller.startDrive(now: 0)
        let complete = try requireValue(controller.expectedPosition(now: 10_000), "complete")
        try require(complete.completed, "route completes")
        _ = controller.completeHolding(now: 10_000)
        try require(controller.currentState() == .completedHolding, "destination held after completion")
    }

    static func staleWriterCannotSendAfterOwnershipChanges() async throws {
        let tunnel = MockTunnelClient()
        let store = InMemoryRPPairingStore(data: try makePairingPlist())
        let coordinator = LocationCoordinator(pairingStore: store, tunnelClient: tunnel, recorder: testRecorder())
        try await coordinator.startSimulation(writerID: "static:old", mode: .staticLocation(nil))
        try await coordinator.startSimulation(writerID: "drive:new", mode: .drive(sessionID: UUID(), current: nil))
        do {
            try await coordinator.updateLocation(latitude: 1, longitude: 1, writerID: "static:old")
            throw CheckError("expected stale writer")
        } catch let error as POCError {
            try require(error.code == .staleWriter, "stale writer rejected")
        }
        let count = await tunnel.setCount()
        try require(count == 0, "stale writer did not issue native set")
    }

    static func staleGenerationCallbackCannotAffectCurrentConnection() async throws {
        let tunnel = MockTunnelClient()
        let coordinator = LocationCoordinator(
            pairingStore: InMemoryRPPairingStore(data: try makePairingPlist()),
            tunnelClient: tunnel,
            recorder: testRecorder()
        )
        try await coordinator.startSimulation(writerID: "drive:1", mode: .drive(sessionID: UUID(), current: nil))
        let firstGeneration = await coordinator.currentConnectionGeneration()
        await tunnel.forceState(.disconnected)
        await coordinator.reconnectIfNeeded()
        let secondGeneration = await coordinator.currentConnectionGeneration()
        try require(secondGeneration > firstGeneration, "reconnect increments generation")
        await coordinator.handleConnectionLost(generation: firstGeneration, reason: "unit stale callback")
        let currentGeneration = await coordinator.currentConnectionGeneration()
        let currentState = await coordinator.currentConnectionState()
        try require(currentGeneration == secondGeneration, "stale generation ignored")
        try require(currentState == .connected, "current connection remains connected")
    }

    static func reconnectRestoresCurrentDrivePosition() async throws {
        let tunnel = MockTunnelClient()
        let coordinator = LocationCoordinator(
            pairingStore: InMemoryRPPairingStore(data: try makePairingPlist()),
            tunnelClient: tunnel,
            recorder: testRecorder()
        )
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 60)
        try controller.startDrive(now: 0)
        try await coordinator.startSimulation(writerID: controller.writerID, mode: .drive(sessionID: controller.sessionID, current: nil))
        await coordinator.setReconnectRestoreProvider(writerID: controller.writerID) {
            SimulatedCoordinate(controller.expectedPosition(now: 20)!.coordinate)
        }
        await tunnel.forceState(.disconnected)
        await coordinator.reconnectIfNeeded()
        let set = try requireValue(await tunnel.sets.last, "restored set exists")
        let restored = controller.expectedPosition(now: 20)!.coordinate
        try require(abs(set.latitude - restored.latitude) < 0.0001, "reconnect restores current route latitude")
        try require(abs(set.longitude - restored.longitude) < 0.0001, "reconnect restores current route longitude")
    }

    static func stopPreventsDelayedWrites() async throws {
        let tunnel = MockTunnelClient()
        let coordinator = LocationCoordinator(
            pairingStore: InMemoryRPPairingStore(data: try makePairingPlist()),
            tunnelClient: tunnel,
            recorder: testRecorder()
        )
        let controller = DriveSessionController()
        controller.prepareRoute(try driveRoute(), speedMPH: 30)
        try controller.startDrive(now: 0)
        try await coordinator.startSimulation(writerID: controller.writerID, mode: .drive(sessionID: controller.sessionID, current: nil))
        try await coordinator.stopSimulation(writerID: controller.writerID, clearLocation: true)
        do {
            try await coordinator.updateLocation(latitude: 0, longitude: 0.001, writerID: controller.writerID)
            throw CheckError("expected stopped writer failure")
        } catch let error as POCError {
            try require(error.code == .staleWriter, "stopped writer cannot write")
        }
        let setCount = await tunnel.setCount()
        let clearCount = await tunnel.totalClearCount()
        try require(setCount == 0, "no delayed set after stop")
        try require(clearCount == 1, "stop clears exactly once")
    }

    static func routeDistanceClamping() throws {
        let route = try testRoute()
        let before = route.coordinate(atDistance: -100)
        let after = route.coordinate(atDistance: route.totalDistanceMeters + 10_000)
        try require(abs(before.longitude) < 0.0001, "negative distance clamps to origin")
        try require(abs(after.longitude - 0.01) < 0.0001, "overshoot clamps to destination")
    }

    static func driveDiagnosticsSerialize() async throws {
        let recorder = testRecorder()
        let diagnostics = DriveDiagnostics(recorder: recorder)
        let route = try testRoute()
        await diagnostics.start(sessionID: UUID(), writerID: "drive:unit", route: route)
        await diagnostics.recordRequestedUpdate(
            sequenceNumber: 1,
            tickNumber: 1,
            monotonicElapsedTime: 1,
            connectionGeneration: 3,
            expectedRouteDistanceMeters: 10,
            expectedCoordinate: route.coordinate(atDistance: 10),
            requestedCoordinate: route.coordinate(atDistance: 10),
            calculatedRouteSpeedMetersPerSecond: 10,
            observed: LocationObservation(
                latitude: 0,
                longitude: 0.0001,
                horizontalAccuracy: 5,
                verticalAccuracy: 8,
                speed: 10,
                speedAccuracy: 1,
                course: 90,
                courseAccuracy: 3,
                locationTimestamp: Date(),
                isSimulatedBySoftware: true,
                isProducedByAccessory: false
            ),
            applicationLifecycleState: "foreground",
            backgroundSessionActive: true
        )
        let urls = await diagnostics.exportURLs()
        let jsonl = try requireValue(urls.first(where: { $0.pathExtension == "jsonl" }), "drive jsonl")
        let text = try String(contentsOf: jsonl, encoding: .utf8)
        try require(text.contains("DRIVE_LOCATION_UPDATE"), "drive event serialized")
        try require(text.contains("connection_generation"), "generation serialized")
        try require(text.contains("cllocation_speed_mps"), "speed serialized")
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

    static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw CheckError(message)
        }
        return value
    }

    static func testRoute() throws -> RouteResampler {
        try RouteResampler(coordinates: [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.01)
        ])
    }

    static func driveRoute() throws -> DriveRoute {
        let resampler = try testRoute()
        return DriveRoute(
            origin: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            destination: CLLocationCoordinate2D(latitude: 0, longitude: 0.01),
            resampler: resampler,
            expectedTravelTime: 120
        )
    }

    static func testRecorder() -> SessionDiagnosticRecorder {
        SessionDiagnosticRecorder(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("iossim-drive-unit-\(UUID().uuidString)", isDirectory: true)
        )
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

private actor MockTunnelClient: OnDeviceTunnelClient {
    private var state: TunnelState = .disconnected
    private(set) var sets: [(latitude: Double, longitude: Double)] = []
    private(set) var clearCount = 0
    private var connectCount = 0

    func connect(pairingData: Data, endpoint: DeveloperEndpoint) async throws {
        connectCount += 1
        state = .locationSimulationConnected
    }

    func set(latitude: Double, longitude: Double) async throws {
        guard state == .locationSimulationConnected || state == .simulating else {
            throw POCError(.disconnected, "mock disconnected")
        }
        sets.append((latitude, longitude))
        state = .simulating
    }

    func clear() async throws {
        clearCount += 1
        state = .disconnected
    }

    func disconnect() async {
        state = .disconnected
    }

    func status() async -> DvtBridgeStatus {
        DvtBridgeStatus(
            state: state,
            endpoint: DeveloperEndpoint(),
            ideviceLinked: true,
            timings: [],
            lastError: nil
        )
    }

    func forceState(_ state: TunnelState) {
        self.state = state
    }

    func setCount() -> Int {
        sets.count
    }

    func totalClearCount() -> Int {
        clearCount
    }
}
