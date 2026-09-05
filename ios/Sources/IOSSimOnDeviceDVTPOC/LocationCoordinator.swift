import CoreLocation
import Foundation

public struct SimulatedCoordinate: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    public var coreLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

public enum SimulationMode: Equatable, Sendable {
    case none
    case staticLocation(SimulatedCoordinate?)
    case drive(sessionID: UUID, current: SimulatedCoordinate?)
}

public enum LocationCoordinatorConnectionState: String, Codable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed
}

public struct LocationCoordinatorSnapshot: Codable, Equatable, Sendable {
    public let connectionState: LocationCoordinatorConnectionState
    public let connectionGeneration: Int
    public let activeWriterID: String?
    public let modeDescription: String
    public let desiredLatitude: Double?
    public let desiredLongitude: Double?
    public let bridgeState: TunnelState
    public let lastError: POCError?
}

public actor LocationCoordinator {
    private let pairingStore: RPPairingStore
    private let tunnelClient: OnDeviceTunnelClient
    private let endpoint: DeveloperEndpoint
    private let recorder: SessionDiagnosticRecorder

    private var mode: SimulationMode = .none
    private var connectionState: LocationCoordinatorConnectionState = .disconnected
    private var connectionGeneration = 0
    private var activeWriterID: String?
    private var desiredCoordinate: SimulatedCoordinate?
    private var reconnectTaskGeneration: Int?
    private var restoreProvider: (@Sendable () async -> SimulatedCoordinate?)?

    public init(
        pairingStore: RPPairingStore = KeychainRPPairingStore(),
        tunnelClient: OnDeviceTunnelClient = IdeviceOnDeviceTunnelClient(),
        endpoint: DeveloperEndpoint = DeveloperEndpoint(),
        recorder: SessionDiagnosticRecorder = .shared
    ) {
        self.pairingStore = pairingStore
        self.tunnelClient = tunnelClient
        self.endpoint = endpoint
        self.recorder = recorder
    }

    public func startSimulation(writerID: String, mode requestedMode: SimulationMode) async throws {
        let previousWriterID = activeWriterID
        activeWriterID = writerID
        mode = requestedMode
        desiredCoordinate = requestedMode.coordinate ?? desiredCoordinate
        await recorder.record(
            category: "SIMULATION_OWNER_CHANGED",
            component: "LocationCoordinator",
            previousState: previousWriterID ?? "none",
            newState: "claimed",
            message: "simulation writer claimed",
            metadata: writerMetadata(writerID: writerID).merging([
                "old_writer_id": previousWriterID ?? "none",
                "new_writer_id": writerID,
                "reason": "start_simulation"
            ]) { _, new in new }
        )
        try await ensureConnected(reconnecting: false)
    }

    public func updateLocation(
        latitude: Double,
        longitude: Double,
        writerID: String,
        mode requestedMode: SimulationMode? = nil,
        traceContext: DriveTraceContext? = nil,
        driveDiagnostics: DriveDiagnostics? = nil
    ) async throws {
        let actorEntryTime = ProcessInfo.processInfo.systemUptime
        if let traceContext, let driveDiagnostics {
            await driveDiagnostics.recordCoordinatorUpdateEntered(
                context: traceContext,
                writerID: writerID,
                connectionGeneration: connectionGeneration,
                enteredMonotonicTime: actorEntryTime
            )
        }
        guard writerID == activeWriterID else {
            await recordStaleWriter(writerID)
            throw POCError(.staleWriter, "Ignoring stale writer \(writerID).")
        }
        let coordinate = SimulatedCoordinate(latitude: latitude, longitude: longitude)
        desiredCoordinate = coordinate
        if let requestedMode {
            mode = requestedMode
        } else {
            mode = mode.replacingCoordinate(coordinate)
        }
        try await ensureConnected(reconnecting: false)
        guard writerID == activeWriterID else {
            await recordStaleWriter(writerID)
            throw POCError(.staleWriter, "Ignoring stale writer \(writerID).")
        }
        let dvtSetBegin = ProcessInfo.processInfo.systemUptime
        if let driveDiagnostics {
            await driveDiagnostics.recordDVTSetBegin(
                context: traceContext,
                writerID: writerID,
                connectionGeneration: connectionGeneration,
                beginMonotonicTime: dvtSetBegin
            )
        }
        do {
            try await tunnelClient.set(latitude: latitude, longitude: longitude)
            if let driveDiagnostics {
                await driveDiagnostics.recordDVTSetEnd(
                    context: traceContext,
                    writerID: writerID,
                    connectionGeneration: connectionGeneration,
                    beginMonotonicTime: dvtSetBegin,
                    endMonotonicTime: ProcessInfo.processInfo.systemUptime,
                    success: true,
                    nativeErrorCategory: nil
                )
            }
        } catch {
            if let driveDiagnostics {
                await driveDiagnostics.recordDVTSetEnd(
                    context: traceContext,
                    writerID: writerID,
                    connectionGeneration: connectionGeneration,
                    beginMonotonicTime: dvtSetBegin,
                    endMonotonicTime: ProcessInfo.processInfo.systemUptime,
                    success: false,
                    nativeErrorCategory: (error as? POCError)?.code.rawValue ?? "unknown"
                )
            }
            throw error
        }
        await recorder.record(
            category: "LOCATION_SET",
            component: "LocationCoordinator",
            previousState: nil,
            newState: "set_succeeded",
            message: "authoritative writer set location",
            metadata: writerMetadata(writerID: writerID).merging([
                "latitude": String(format: "%.6f", latitude),
                "longitude": String(format: "%.6f", longitude),
                "connection_generation": "\(connectionGeneration)"
            ]) { _, new in new }
        )
    }

    public func holdSimulation(writerID: String, mode requestedMode: SimulationMode) async throws {
        guard writerID == activeWriterID else {
            await recordStaleWriter(writerID)
            throw POCError(.staleWriter, "Ignoring hold from stale writer \(writerID).")
        }
        mode = requestedMode
        desiredCoordinate = requestedMode.coordinate ?? desiredCoordinate
        await recorder.record(
            category: "LOCATION_HELD",
            component: "LocationCoordinator",
            previousState: nil,
            newState: "held",
            message: "authoritative writer retained simulated coordinate",
            metadata: writerMetadata(writerID: writerID)
        )
    }

    public func stopSimulation(writerID: String, clearLocation: Bool = true) async throws {
        guard writerID == activeWriterID else {
            await recordStaleWriter(writerID)
            throw POCError(.staleWriter, "Ignoring stop from stale writer \(writerID).")
        }
        if clearLocation {
            do {
                try await tunnelClient.clear()
                await recorder.record(
                    category: "CLEAR",
                    component: "LocationCoordinator",
                    previousState: nil,
                    newState: "cleared",
                    message: "authoritative writer explicitly cleared simulation",
                    metadata: writerMetadata(writerID: writerID)
                )
            } catch let error as POCError where error.code == .disconnected {
                await recorder.record(
                    category: "CLEAR",
                    component: "LocationCoordinator",
                    previousState: nil,
                    newState: "already_disconnected",
                    errorCode: error.code.rawValue,
                    message: error.message,
                    metadata: writerMetadata(writerID: writerID)
                )
            }
        } else {
            await tunnelClient.disconnect()
        }
        restoreProvider = nil
        reconnectTaskGeneration = nil
        activeWriterID = nil
        desiredCoordinate = nil
        mode = .none
        connectionState = .disconnected
    }

    public func disconnect(writerID: String) async throws {
        try await stopSimulation(writerID: writerID, clearLocation: false)
    }

    public func setReconnectRestoreProvider(
        writerID: String,
        provider: (@Sendable () async -> SimulatedCoordinate?)?
    ) async {
        guard writerID == activeWriterID else {
            await recordStaleWriter(writerID)
            return
        }
        restoreProvider = provider
    }

    public func reconnectIfNeeded() async {
        guard let reconnectWriterID = activeWriterID else { return }
        guard reconnectTaskGeneration != connectionGeneration else { return }
        reconnectTaskGeneration = connectionGeneration
        let reconnectBegin = ProcessInfo.processInfo.systemUptime
        await recorder.record(
            category: "RECONNECT_TRIGGER",
            component: "LocationCoordinator",
            previousState: connectionState.rawValue,
            newState: "triggered",
            message: "reconnect triggered",
            metadata: ["connection_generation": "\(connectionGeneration)", "writer_id": reconnectWriterID]
        )
        await recorder.record(
            category: "RECONNECT_BEGIN",
            component: "LocationCoordinator",
            previousState: connectionState.rawValue,
            newState: "started",
            message: "reconnect started",
            metadata: [
                "connection_generation": "\(connectionGeneration)",
                "writer_id": reconnectWriterID,
                "monotonic_timestamp": String(format: "%.3f", reconnectBegin)
            ]
        )

        await tunnelClient.disconnect()
        guard activeWriterID == reconnectWriterID else {
            reconnectTaskGeneration = nil
            await recorder.record(
                category: "RECONNECT",
                component: "LocationCoordinator",
                previousState: "started",
                newState: "cancelled",
                message: "reconnect cancelled because writer ownership changed",
                metadata: ["writer_id": reconnectWriterID]
            )
            return
        }
        connectionState = .reconnecting
        do {
            try await ensureConnected(reconnecting: true)
            guard activeWriterID == reconnectWriterID else {
                await tunnelClient.disconnect()
                reconnectTaskGeneration = nil
                await recorder.record(
                    category: "RECONNECT",
                    component: "LocationCoordinator",
                    previousState: "connected",
                    newState: "cancelled",
                    message: "reconnect result discarded because writer ownership changed",
                    metadata: ["writer_id": reconnectWriterID]
                )
                return
            }
            if let coordinate = await currentRestoreCoordinate() {
                await recorder.record(
                    category: "CURRENT_POSITION_CALCULATED",
                    component: "LocationCoordinator",
                    previousState: nil,
                    newState: "calculated",
                    message: "current restore position calculated",
                    metadata: [
                        "connection_generation": "\(connectionGeneration)",
                        "writer_id": reconnectWriterID,
                        "latitude": String(format: "%.6f", coordinate.latitude),
                        "longitude": String(format: "%.6f", coordinate.longitude)
                    ]
                )
                guard activeWriterID == reconnectWriterID else {
                    reconnectTaskGeneration = nil
                    return
                }
                desiredCoordinate = coordinate
                try await tunnelClient.set(latitude: coordinate.latitude, longitude: coordinate.longitude)
                await recorder.record(
                    category: "CURRENT_POSITION_RESTORED",
                    component: "LocationCoordinator",
                    previousState: "connected",
                    newState: "restored",
                    message: "current desired route position restored after reconnect",
                    metadata: [
                        "connection_generation": "\(connectionGeneration)",
                        "latitude": String(format: "%.6f", coordinate.latitude),
                        "longitude": String(format: "%.6f", coordinate.longitude)
                    ]
                )
            }
            await recorder.record(
                category: "RECONNECT_COMPLETE",
                component: "LocationCoordinator",
                previousState: "started",
                newState: "succeeded",
                message: "reconnect succeeded",
                metadata: [
                    "connection_generation": "\(connectionGeneration)",
                    "total_reconnect_duration_ms": String(format: "%.3f", max(0, ProcessInfo.processInfo.systemUptime - reconnectBegin) * 1000)
                ]
            )
        } catch let error as POCError {
            connectionState = .failed
            await recorder.record(
                category: "RECONNECT",
                component: "LocationCoordinator",
                previousState: "started",
                newState: "failed",
                errorCode: error.code.rawValue,
                message: error.message,
                metadata: ["connection_generation": "\(connectionGeneration)"]
            )
        } catch {
            connectionState = .failed
            await recorder.record(
                category: "RECONNECT",
                component: "LocationCoordinator",
                previousState: "started",
                newState: "failed",
                errorCode: POCErrorCode.unknown.rawValue,
                message: String(describing: error),
                metadata: ["connection_generation": "\(connectionGeneration)"]
            )
        }
        reconnectTaskGeneration = nil
    }

    public func rebuildRuntimeSession(reason: String) async throws {
        guard let rebuildWriterID = activeWriterID else {
            throw POCError(
                .disconnected,
                "Cannot rebuild developer runtime session without an active simulation writer."
            )
        }
        reconnectTaskGeneration = nil
        let rebuildBegin = ProcessInfo.processInfo.systemUptime
        await recorder.record(
            category: "RUNTIME_SESSION_REBUILD",
            component: "LocationCoordinator",
            previousState: connectionState.rawValue,
            newState: "started",
            message: reason,
            metadata: [
                "connection_generation": "\(connectionGeneration)",
                "writer_id": rebuildWriterID,
                "mode": mode.description,
                "monotonic_timestamp": String(format: "%.3f", rebuildBegin)
            ]
        )

        await tunnelClient.disconnect()
        guard activeWriterID == rebuildWriterID else {
            await recorder.record(
                category: "RUNTIME_SESSION_REBUILD",
                component: "LocationCoordinator",
                previousState: "started",
                newState: "cancelled",
                message: "rebuild cancelled because writer ownership changed",
                metadata: ["writer_id": rebuildWriterID]
            )
            throw POCError(.staleWriter, "Runtime rebuild cancelled for stale writer \(rebuildWriterID).")
        }

        connectionState = .reconnecting
        do {
            try await ensureConnected(reconnecting: true)
            guard activeWriterID == rebuildWriterID else {
                await tunnelClient.disconnect()
                await recorder.record(
                    category: "RUNTIME_SESSION_REBUILD",
                    component: "LocationCoordinator",
                    previousState: "connected",
                    newState: "cancelled",
                    message: "rebuild result discarded because writer ownership changed",
                    metadata: ["writer_id": rebuildWriterID]
                )
                throw POCError(.staleWriter, "Runtime rebuild completed for stale writer \(rebuildWriterID).")
            }
            if let coordinate = await currentRestoreCoordinate() {
                desiredCoordinate = coordinate
                try await tunnelClient.set(latitude: coordinate.latitude, longitude: coordinate.longitude)
                await recorder.record(
                    category: "CURRENT_POSITION_RESTORED",
                    component: "LocationCoordinator",
                    previousState: "connected",
                    newState: "restored",
                    message: "current desired position restored after runtime rebuild",
                    metadata: [
                        "connection_generation": "\(connectionGeneration)",
                        "latitude": String(format: "%.6f", coordinate.latitude),
                        "longitude": String(format: "%.6f", coordinate.longitude)
                    ]
                )
            }
            await recorder.record(
                category: "RUNTIME_SESSION_REBUILD",
                component: "LocationCoordinator",
                previousState: "started",
                newState: "succeeded",
                message: "runtime session rebuild succeeded",
                metadata: [
                    "connection_generation": "\(connectionGeneration)",
                    "total_rebuild_duration_ms": String(format: "%.3f", max(0, ProcessInfo.processInfo.systemUptime - rebuildBegin) * 1000)
                ]
            )
        } catch let error as POCError {
            connectionState = .failed
            await recorder.record(
                category: "RUNTIME_SESSION_REBUILD",
                component: "LocationCoordinator",
                previousState: "started",
                newState: "failed",
                errorCode: error.code.rawValue,
                message: error.message,
                metadata: ["connection_generation": "\(connectionGeneration)"]
            )
            throw error
        } catch {
            connectionState = .failed
            let pocError = POCError(.unknown, String(describing: error))
            await recorder.record(
                category: "RUNTIME_SESSION_REBUILD",
                component: "LocationCoordinator",
                previousState: "started",
                newState: "failed",
                errorCode: pocError.code.rawValue,
                message: pocError.message,
                metadata: ["connection_generation": "\(connectionGeneration)"]
            )
            throw pocError
        }
    }

    public func handleConnectionLost(generation: Int, reason: String) async {
        guard generation == connectionGeneration else {
            await recorder.record(
                category: "STALE_GENERATION_EVENT_IGNORED",
                component: "LocationCoordinator",
                previousState: nil,
                newState: "stale_generation_ignored",
                errorCode: POCErrorCode.staleGeneration.rawValue,
                message: "stale generation callback ignored",
                metadata: [
                    "callback_generation": "\(generation)",
                    "current_generation": "\(connectionGeneration)",
                    "reason": reason
                ]
            )
            return
        }
        connectionState = .disconnected
        await reconnectIfNeeded()
    }

    public func currentConnectionState() -> LocationCoordinatorConnectionState {
        connectionState
    }

    public func currentConnectionGeneration() -> Int {
        connectionGeneration
    }

    public func snapshot() async -> LocationCoordinatorSnapshot {
        let status = await tunnelClient.status()
        return LocationCoordinatorSnapshot(
            connectionState: connectionState,
            connectionGeneration: connectionGeneration,
            activeWriterID: activeWriterID,
            modeDescription: mode.description,
            desiredLatitude: desiredCoordinate?.latitude,
            desiredLongitude: desiredCoordinate?.longitude,
            bridgeState: status.state,
            lastError: status.lastError
        )
    }

    public func bridgeStatus() async -> DvtBridgeStatus {
        await tunnelClient.status()
    }

    private func ensureConnected(reconnecting: Bool) async throws {
        let status = await tunnelClient.status()
        if status.state == .locationSimulationConnected || status.state == .simulating {
            connectionState = .connected
            return
        }

        connectionState = reconnecting ? .reconnecting : .connecting
        connectionGeneration += 1
        let generation = connectionGeneration
        let pairingData = try pairingStore.loadPairingData()
        try await tunnelClient.connect(pairingData: pairingData, endpoint: endpoint)
        guard generation == connectionGeneration else {
            await recorder.record(
                category: "STALE_GENERATION_EVENT_IGNORED",
                component: "LocationCoordinator",
                previousState: nil,
                newState: "stale_generation_ignored",
                errorCode: POCErrorCode.staleGeneration.rawValue,
                message: "connect result ignored because a newer generation exists",
                metadata: ["callback_generation": "\(generation)", "current_generation": "\(connectionGeneration)"]
            )
            throw POCError(.staleGeneration, "Connect completed for stale generation \(generation).")
        }
        connectionState = .connected
        await recorder.record(
            category: "DVT_CONNECTION",
            component: "LocationCoordinator",
            previousState: reconnecting ? "reconnecting" : "connecting",
            newState: "connected",
            message: "authoritative DVT session connected",
            metadata: ["connection_generation": "\(generation)"]
        )
    }

    private func currentRestoreCoordinate() async -> SimulatedCoordinate? {
        if case .drive = mode, let restoreProvider {
            return await restoreProvider()
        }
        return desiredCoordinate
    }

    private func recordStaleWriter(_ writerID: String) async {
        await recorder.record(
            category: "STALE_WRITER_UPDATE_IGNORED",
            component: "LocationCoordinator",
            previousState: nil,
            newState: "stale_writer_ignored",
            errorCode: POCErrorCode.staleWriter.rawValue,
            message: "stale writer ignored",
            metadata: writerMetadata(writerID: writerID)
        )
    }

    private func writerMetadata(writerID: String) -> [String: String] {
        [
            "writer_id": writerID,
            "active_writer_id": activeWriterID ?? "none",
            "mode": mode.description,
            "connection_generation": "\(connectionGeneration)"
        ]
    }
}

private extension SimulationMode {
    var coordinate: SimulatedCoordinate? {
        switch self {
        case .none:
            return nil
        case .staticLocation(let coordinate):
            return coordinate
        case .drive(_, let current):
            return current
        }
    }

    func replacingCoordinate(_ coordinate: SimulatedCoordinate) -> SimulationMode {
        switch self {
        case .none:
            return .none
        case .staticLocation:
            return .staticLocation(coordinate)
        case .drive(let sessionID, _):
            return .drive(sessionID: sessionID, current: coordinate)
        }
    }

    var description: String {
        switch self {
        case .none:
            return "none"
        case .staticLocation:
            return "static"
        case .drive(let sessionID, _):
            return "drive:\(sessionID.uuidString)"
        }
    }
}
