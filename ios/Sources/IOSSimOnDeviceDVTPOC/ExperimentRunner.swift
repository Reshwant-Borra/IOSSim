import Foundation

public enum POCExperimentID: String, CaseIterable, Codable, Equatable, Sendable {
    case e1MacOffWifiColdStart = "E1"
    case e2RepeatedCoordinates = "E2"
    case e3WifiToCellularContinuation = "E3"
    case e4CellularColdStart = "E4"
    case e5NoExternalNetwork = "E5"
    case e6RebootPersistence = "E6"
    case e7AppForceQuit = "E7"
    case e8LocalDevVPNRestart = "E8"
    case e9SourceClassification = "E9"
    case e10DriveUpdateRate = "E10"
}

public struct ExperimentResult: Codable, Equatable, Sendable {
    public let testID: POCExperimentID
    public let startedAt: Date
    public let finishedAt: Date
    public let commandCount: Int
    public let failures: [POCError]
    public let observations: [LocationObservation]
    public let snapshot: DiagnosticSnapshot

    public var softwareTestVerdict: String {
        failures.isEmpty ? "SOFTWARE TEST PASS" : "SOFTWARE TEST FAIL"
    }
}

public final class OnDeviceDVTExperimentRunner: @unchecked Sendable {
    public static let testCoordinate = (latitude: 40.7580, longitude: -73.9855)
    public static let repeatedCoordinates: [(latitude: Double, longitude: Double)] = [
        (40.7580, -73.9855),
        (40.7527, -73.9772),
        (40.7484, -73.9857),
        (40.7614, -73.9776),
        (40.7505, -73.9934)
    ]

    private let pairingStore: RPPairingStore
    private let routeProbe: DeveloperRouteProbe
    private let locationCoordinator: LocationCoordinator
    private let verifier: CoreLocationVerifier
    private let diagnostics: DiagnosticState
    private let endpoint: DeveloperEndpoint
    private let recorder: SessionDiagnosticRecorder
    private let backgroundKeeper: BackgroundSessionKeeper
    private var monitorTask: Task<Void, Never>?
    private let staticWriterID = "static:\(UUID().uuidString)"

    public init(
        pairingStore: RPPairingStore = KeychainRPPairingStore(),
        routeProbe: DeveloperRouteProbe = DeveloperRouteProbe(),
        tunnelClient: OnDeviceTunnelClient = IdeviceOnDeviceTunnelClient(),
        locationCoordinator: LocationCoordinator? = nil,
        verifier: CoreLocationVerifier = CoreLocationVerifier(),
        diagnostics: DiagnosticState = DiagnosticState(),
        recorder: SessionDiagnosticRecorder = .shared,
        backgroundKeeper: BackgroundSessionKeeper? = nil,
        endpoint: DeveloperEndpoint = DeveloperEndpoint()
    ) {
        self.pairingStore = pairingStore
        self.routeProbe = routeProbe
        self.locationCoordinator = locationCoordinator ?? LocationCoordinator(
            pairingStore: pairingStore,
            tunnelClient: tunnelClient,
            endpoint: endpoint,
            recorder: recorder
        )
        self.verifier = verifier
        self.diagnostics = diagnostics
        self.recorder = recorder
        self.backgroundKeeper = backgroundKeeper ?? BackgroundSessionKeeper(recorder: recorder)
        self.endpoint = endpoint
        self.verifier.setObservationHandler { observation in
            Task {
                await recorder.recordLocation(observation)
            }
        }
    }

    public func importPairing(_ data: Data) async throws -> RPPairingSummary {
        await diagnostics.start(.pairingImported, message: "importing rppairing")
        do {
            let summary = try pairingStore.importPairingData(data)
            await diagnostics.succeed(.pairingImported, message: "pairing stored")
            await diagnostics.succeed(.pairingValidated, message: "identifier=\(summary.identifierRedacted)")
            return summary
        } catch let error as POCError {
            await diagnostics.fail(error.stage ?? .pairingImported, error: error)
            throw error
        }
    }

    public func runDiagnostics() async -> DeveloperRouteDiagnostics {
        do {
            if let summary = try pairingStore.pairingSummary() {
                await diagnostics.succeed(.pairingImported, message: "pairing loaded")
                await diagnostics.succeed(.pairingValidated, message: "identifier=\(summary.identifierRedacted)")
                await recorder.record(
                    category: "PAIRING",
                    component: "Pairing",
                    previousState: nil,
                    newState: "valid",
                    message: "stored RPPairing summary valid",
                    metadata: ["identifier": summary.identifierRedacted]
                )
            } else {
                let error = POCError(
                    .pairingMissing,
                    "Import a valid RPPairing file before running E1.",
                    stage: .pairingImported
                )
                await diagnostics.fail(.pairingImported, error: error)
                await diagnostics.fail(.pairingValidated, error: error)
                await record(error: error, component: "Pairing", newState: "missing")
            }
        } catch let error as POCError {
            await diagnostics.fail(error.stage ?? .pairingImported, error: error)
            await record(error: error, component: "Pairing", newState: "failed")
        } catch {
            let pocError = POCError(
                .pairingFileInvalid,
                String(describing: error),
                stage: .pairingImported
            )
            await diagnostics.fail(.pairingImported, error: pocError)
            await record(error: pocError, component: "Pairing", newState: "failed")
        }

        await diagnostics.start(.localDevVPNRouteVisible)
        let result = await routeProbe.run(endpoint: endpoint)
        if result.localDevVPNAppearsActive {
            await diagnostics.succeed(.localDevVPNRouteVisible, message: "localdevvpn route appears active")
            await recorder.record(
                category: "ROUTE",
                component: "LocalDevVPN",
                previousState: nil,
                newState: "present",
                message: "LocalDevVPN route visible",
                metadata: ["interfaces": routeInterfaceSummary(result.interfaces)]
            )
        } else {
            let error = POCError(
                .localDevVPNRouteMissing,
                "No 10.7.0.0/24 interface address is visible to the app.",
                stage: .localDevVPNRouteVisible
            )
            await diagnostics.fail(.localDevVPNRouteVisible, error: error)
            await record(error: error, component: "LocalDevVPN", newState: "missing")
        }

        if result.tcpResult.connected {
            await diagnostics.succeed(.endpointReachable, message: "tcp connected in \(formatMs(result.tcpResult.latencyMs))")
            await recorder.record(
                category: "ENDPOINT",
                component: "Endpoint",
                previousState: nil,
                newState: "reachable",
                message: "developer endpoint reachable",
                metadata: endpointMetadata(result.tcpResult)
            )
        } else {
            let error = POCError(
                .endpointUnreachable,
                result.tcpResult.error ?? "TCP connect to \(endpoint.host):\(endpoint.port) failed. Confirm LocalDevVPN is active.",
                stage: .endpointReachable
            )
            await diagnostics.fail(.endpointReachable, error: error)
            await record(error: error, component: "Endpoint", newState: "unreachable")
        }
        return result
    }

    public func connect() async throws {
        _ = await recorder.startSession(prefix: "E1")
        startMonitors()
        let pairingData: Data
        let summary: RPPairingSummary
        do {
            pairingData = try pairingStore.loadPairingData()
            summary = try RPPairingValidator.validate(pairingData)
        } catch let error as POCError {
            await record(error: error, component: "Pairing", newState: "failed")
            stopMonitors()
            throw error
        } catch {
            let pocError = POCError(.pairingFileInvalid, String(describing: error), stage: .pairingValidated)
            await record(error: pocError, component: "Pairing", newState: "failed")
            stopMonitors()
            throw pocError
        }
        await recorder.record(
            category: "PAIRING",
            component: "Pairing",
            previousState: nil,
            newState: "valid",
            message: "RPPairing credentials loaded from secure store",
            metadata: ["identifier": summary.identifierRedacted]
        )
        verifier.start(backgroundCapable: false)

        await diagnostics.start(.tunnelEstablished)
        do {
            try await locationCoordinator.startSimulation(writerID: staticWriterID, mode: .staticLocation(nil))
            let status = await locationCoordinator.bridgeStatus()
            await diagnostics.setBridgeState(status.state)
            await diagnostics.succeed(.tunnelEstablished)
            await diagnostics.succeed(.rsdConnected)
            await diagnostics.succeed(.dvtConnected)
            await diagnostics.succeed(.deviceInfoWarmup)
            await diagnostics.succeed(.locationSimulationConnected)
        } catch let error as POCError {
            await diagnostics.fail(error.stage ?? .tunnelEstablished, error: error)
            await record(error: error, component: "DeveloperTunnel", newState: "failed")
            stopMonitors()
            throw error
        } catch {
            let pocError = POCError(.unknown, String(describing: error), stage: .tunnelEstablished)
            await record(error: pocError, component: "DeveloperTunnel", newState: "failed")
            stopMonitors()
            throw error
        }
    }

    public func disconnect() async {
        stopMonitors()
        try? await locationCoordinator.disconnect(writerID: staticWriterID)
        backgroundKeeper.end(reason: "disconnect")
        verifier.stop()
        await diagnostics.setBridgeState(.disconnected)
        await recorder.endSession(reason: "disconnect")
    }

    public func setTestLocationAndVerify(timeout: TimeInterval = 8) async throws -> LocationObservation {
        try await setAndVerify(
            latitude: Self.testCoordinate.latitude,
            longitude: Self.testCoordinate.longitude,
            timeout: timeout
        )
    }

    public func setAndVerify(latitude: Double, longitude: Double, timeout: TimeInterval = 8) async throws -> LocationObservation {
        verifier.setRequestedCoordinate(latitude: latitude, longitude: longitude)
        await recorder.setRequestedCoordinate(latitude: latitude, longitude: longitude)
        await diagnostics.start(.setCommandSent)
        do {
            try await locationCoordinator.updateLocation(
                latitude: latitude,
                longitude: longitude,
                writerID: staticWriterID,
                mode: .staticLocation(SimulatedCoordinate(latitude: latitude, longitude: longitude))
            )
            await diagnostics.succeed(.setCommandSent)
            backgroundKeeper.begin()
            verifier.start(backgroundCapable: true)
        } catch let error as POCError {
            await diagnostics.fail(.setCommandSent, error: error)
            await record(error: error, component: "LocationSimulation", newState: "failed")
            throw error
        }

        await diagnostics.start(.coreLocationVerified)
        guard let observation = await verifier.waitForCoordinate(latitude: latitude, longitude: longitude, timeout: timeout) else {
            let error = POCError(
                .coreLocationVerificationFailed,
                "Core Location did not observe the expected coordinate within \(timeout)s.",
                stage: .coreLocationVerified
            )
            await diagnostics.fail(.coreLocationVerified, error: error)
            throw error
        }
        await diagnostics.succeed(.coreLocationVerified, message: sourceFlags(observation))
        return observation
    }

    public func clear() async throws {
        await diagnostics.start(.clearCommandSent)
        do {
            try await locationCoordinator.stopSimulation(writerID: staticWriterID, clearLocation: true)
            await diagnostics.succeed(.clearCommandSent)
            backgroundKeeper.end(reason: "clear simulation")
        } catch let error as POCError {
            await diagnostics.fail(.clearCommandSent, error: error)
            await record(error: error, component: "LocationSimulation", newState: "failed")
            throw error
        }
    }

    public func runRepeatedCoordinateChanges(count: Int = 50, delayNanoseconds: UInt64 = 250_000_000) async -> ExperimentResult {
        let started = Date()
        var failures: [POCError] = []
        var commands = 0
        do {
            try await connect()
            for index in 0..<count {
                let coordinate = Self.repeatedCoordinates[index % Self.repeatedCoordinates.count]
                do {
                    _ = try await setAndVerify(latitude: coordinate.latitude, longitude: coordinate.longitude, timeout: 5)
                    commands += 1
                } catch let error as POCError {
                    failures.append(error)
                    await reconnectOnceIfNeeded(failures: &failures)
                } catch {
                    failures.append(POCError(.unknown, String(describing: error)))
                }
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        } catch let error as POCError {
            failures.append(error)
        } catch {
            failures.append(POCError(.unknown, String(describing: error)))
        }

        let snapshot = await diagnostics.snapshot()
        return ExperimentResult(
            testID: .e2RepeatedCoordinates,
            startedAt: started,
            finishedAt: Date(),
            commandCount: commands,
            failures: failures,
            observations: verifier.allObservations(),
            snapshot: snapshot
        )
    }

    public func snapshot() async -> DiagnosticSnapshot {
        await diagnostics.snapshot()
    }

    public func sessionSummary() async -> SessionDiagnosticSummary {
        await recorder.snapshot()
    }

    public func sessionTimeline(limit: Int = 40) async -> [String] {
        await recorder.recentTimeline(limit: limit)
    }

    public func diagnosticExportURLs() async -> [URL] {
        await recorder.exportURLs()
    }

    public func addMarker(_ message: String = "user marker") async {
        await recorder.record(
            category: "USER_MARKER",
            component: "User",
            previousState: nil,
            newState: "marked",
            message: message
        )
    }

    public func recordAppLifecycle(_ state: String) async {
        await recorder.record(
            category: "APP_LIFECYCLE",
            component: "AppLifecycle",
            previousState: nil,
            newState: state,
            message: "app lifecycle transition"
        )
    }

    private func reconnectOnceIfNeeded(failures: inout [POCError]) async {
        await disconnect()
        do {
            try await connect()
        } catch let error as POCError {
            failures.append(error)
        } catch {
            failures.append(POCError(.unknown, String(describing: error)))
        }
    }

    private func sourceFlags(_ observation: LocationObservation) -> String {
        "isSimulatedBySoftware=\(String(describing: observation.isSimulatedBySoftware)) isProducedByAccessory=\(String(describing: observation.isProducedByAccessory))"
    }

    private func formatMs(_ value: Double?) -> String {
        guard let value else { return "unknown ms" }
        return String(format: "%.1f ms", value)
    }

    private func startMonitors() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await self.recorder.record(
                category: "TASK",
                component: "SessionMonitor",
                previousState: nil,
                newState: "started",
                message: "diagnostic monitor task started"
            )
            var iteration = 0
            while !Task.isCancelled {
                await self.recordBridgeStatus()
                if iteration % 2 == 0 {
                    await self.recordRouteAndEndpoint()
                } else {
                    await self.recordRouteOnly()
                }
                iteration += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            await self.recorder.record(
                category: "TASK",
                component: "SessionMonitor",
                previousState: "started",
                newState: "cancelled",
                message: "diagnostic monitor task cancelled"
            )
        }
    }

    private func stopMonitors() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func recordBridgeStatus() async {
        let status = await locationCoordinator.bridgeStatus()
        await recorder.record(
            category: "TUNNEL",
            component: "DeveloperTunnel",
            previousState: nil,
            newState: status.state.rawValue,
            errorCode: status.lastError?.code.rawValue,
            message: "bridge status sampled",
            metadata: ["timings": "\(status.timings.count)"]
        )
    }

    private func recordRouteOnly() async {
        let interfaces = SystemInterfaceSnapshotProvider().snapshots()
        let present = DeveloperRouteProbe.localDevVPNAppearsActive(in: interfaces)
        await recorder.record(
            category: "ROUTE",
            component: "LocalDevVPN",
            previousState: nil,
            newState: present ? "present" : "missing",
            errorCode: present ? nil : POCErrorCode.localDevVPNRouteMissing.rawValue,
            message: present ? "LocalDevVPN route visible" : "LocalDevVPN route missing",
            metadata: ["interfaces": routeInterfaceSummary(interfaces)]
        )
    }

    private func recordRouteAndEndpoint() async {
        let result = await routeProbe.run(endpoint: endpoint, timeout: 1.5)
        await recorder.record(
            category: "ROUTE",
            component: "LocalDevVPN",
            previousState: nil,
            newState: result.localDevVPNAppearsActive ? "present" : "missing",
            errorCode: result.localDevVPNAppearsActive ? nil : POCErrorCode.localDevVPNRouteMissing.rawValue,
            message: result.localDevVPNAppearsActive ? "LocalDevVPN route visible" : "LocalDevVPN route missing",
            metadata: ["interfaces": routeInterfaceSummary(result.interfaces)]
        )
        await recorder.record(
            category: "ENDPOINT",
            component: "Endpoint",
            previousState: nil,
            newState: result.tcpResult.connected ? "reachable" : "unreachable",
            errorCode: result.tcpResult.connected ? nil : POCErrorCode.endpointUnreachable.rawValue,
            message: result.tcpResult.connected ? "developer endpoint reachable" : (result.tcpResult.error ?? "developer endpoint unreachable"),
            metadata: endpointMetadata(result.tcpResult)
        )
    }

    private func routeInterfaceSummary(_ interfaces: [NetworkInterfaceSnapshot]) -> String {
        let matches = interfaces
            .filter { $0.family == "IPv4" && $0.address.hasPrefix("10.7.0.") }
            .map { "\($0.name)=\($0.address)" }
        return matches.isEmpty ? "none" : matches.joined(separator: ",")
    }

    private func endpointMetadata(_ result: TCPProbeResult) -> [String: String] {
        var metadata = [
            "endpoint": "\(result.endpoint.host):\(result.endpoint.port)",
            "connected": String(result.connected)
        ]
        if let latencyMs = result.latencyMs {
            metadata["latency_ms"] = String(format: "%.1f", latencyMs)
        }
        return metadata
    }

    private func record(error: POCError, component: String, newState: String) async {
        await recorder.record(
            category: "ERROR",
            component: component,
            previousState: nil,
            newState: newState,
            errorCode: error.code.rawValue,
            message: error.message
        )
    }
}
