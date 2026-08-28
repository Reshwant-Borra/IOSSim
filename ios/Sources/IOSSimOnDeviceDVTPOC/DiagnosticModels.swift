import Foundation

public enum POCStageStatus: String, Codable, Equatable, Sendable {
    case notStarted = "NOT_STARTED"
    case inProgress = "IN_PROGRESS"
    case success = "SUCCESS"
    case failed = "FAILED"
}

public enum POCStage: String, CaseIterable, Codable, Equatable, Sendable {
    case pairingImported = "pairing_imported"
    case pairingValidated = "pairing_validated"
    case localDevVPNRouteVisible = "localdevvpn_route_visible"
    case endpointReachable = "endpoint_reachable"
    case tunnelEstablished = "tunnel_established"
    case rsdConnected = "rsd_connected"
    case dvtConnected = "dvt_connected"
    case deviceInfoWarmup = "device_info_warmup"
    case locationSimulationConnected = "location_simulation_connected"
    case setCommandSent = "set_command_sent"
    case coreLocationVerified = "core_location_verified"
    case clearCommandSent = "clear_command_sent"
}

public enum POCErrorCode: String, Codable, Equatable, Sendable {
    case pairingMissing = "PAIRING_MISSING"
    case pairingFileInvalid = "PAIRING_FILE_INVALID"
    case pairingCredentialMissing = "PAIRING_CREDENTIAL_MISSING"
    case pairingStorageFailed = "PAIRING_STORAGE_FAILED"
    case localDevVPNRouteMissing = "LOCALDEVVPN_ROUTE_MISSING"
    case endpointUnreachable = "ENDPOINT_UNREACHABLE"
    case ideviceBridgeUnavailable = "IDEVICE_BRIDGE_UNAVAILABLE"
    case invalidEndpoint = "INVALID_ENDPOINT"
    case pairingReadFailed = "PAIRING_READ_FAILED"
    case tlsPskFailed = "TLS_PSK_FAILED"
    case rsdFailed = "RSD_FAILED"
    case dvtFailed = "DVT_FAILED"
    case deviceInfoWarmupFailed = "DEVICE_INFO_WARMUP_FAILED"
    case locationServiceFailed = "LOCATION_SERVICE_FAILED"
    case setCommandFailed = "SET_COMMAND_FAILED"
    case clearCommandFailed = "CLEAR_COMMAND_FAILED"
    case coreLocationVerificationFailed = "CORELOCATION_VERIFICATION_FAILED"
    case disconnected = "DISCONNECTED"
    case invalidRoute = "INVALID_ROUTE"
    case routeCalculationFailed = "ROUTE_CALCULATION_FAILED"
    case invalidDriveState = "INVALID_DRIVE_STATE"
    case staleWriter = "STALE_WRITER"
    case staleGeneration = "STALE_GENERATION"
    case unknown = "UNKNOWN"
}

public struct POCError: Error, Codable, Equatable, Sendable {
    public let code: POCErrorCode
    public let message: String
    public let stage: POCStage?

    public init(_ code: POCErrorCode, _ message: String, stage: POCStage? = nil) {
        self.code = code
        self.message = message
        self.stage = stage
    }
}

public struct POCStageRecord: Codable, Equatable, Sendable {
    public let stage: POCStage
    public var status: POCStageStatus
    public var startedAt: Date?
    public var finishedAt: Date?
    public var durationMs: Double?
    public var errorCode: POCErrorCode?
    public var message: String?

    public init(stage: POCStage) {
        self.stage = stage
        self.status = .notStarted
    }
}

public struct POCEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let stage: POCStage?
    public let status: POCStageStatus?
    public let errorCode: POCErrorCode?
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stage: POCStage? = nil,
        status: POCStageStatus? = nil,
        errorCode: POCErrorCode? = nil,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stage = stage
        self.status = status
        self.errorCode = errorCode
        self.message = message
        self.metadata = metadata
    }
}

public struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let stages: [POCStageRecord]
    public let events: [POCEvent]
    public let bridgeState: TunnelState
    public let lastError: POCError?
}

public actor DiagnosticState {
    private var records: [POCStage: POCStageRecord] = Dictionary(
        uniqueKeysWithValues: POCStage.allCases.map { ($0, POCStageRecord(stage: $0)) }
    )
    private var events: [POCEvent] = []
    private var bridgeState: TunnelState = .disconnected
    private var lastError: POCError?

    public init() {}

    public func start(_ stage: POCStage, message: String? = nil) {
        var record = records[stage] ?? POCStageRecord(stage: stage)
        record.status = .inProgress
        record.startedAt = Date()
        record.finishedAt = nil
        record.durationMs = nil
        record.errorCode = nil
        record.message = message
        records[stage] = record
        append(stage: stage, status: .inProgress, message: message ?? "stage started")
    }

    public func succeed(_ stage: POCStage, message: String? = nil) {
        finish(stage, status: .success, error: nil, message: message)
    }

    public func fail(_ stage: POCStage, error: POCError) {
        lastError = error
        finish(stage, status: .failed, error: error, message: error.message)
    }

    public func setBridgeState(_ state: TunnelState) {
        bridgeState = state
        append(message: "bridge_state=\(state.rawValue)")
    }

    public func append(
        stage: POCStage? = nil,
        status: POCStageStatus? = nil,
        errorCode: POCErrorCode? = nil,
        message: String,
        metadata: [String: String] = [:]
    ) {
        events.append(POCEvent(stage: stage, status: status, errorCode: errorCode, message: message, metadata: metadata))
    }

    public func snapshot() -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            generatedAt: Date(),
            stages: POCStage.allCases.compactMap { records[$0] },
            events: events,
            bridgeState: bridgeState,
            lastError: lastError
        )
    }

    private func finish(_ stage: POCStage, status: POCStageStatus, error: POCError?, message: String?) {
        var record = records[stage] ?? POCStageRecord(stage: stage)
        let now = Date()
        record.status = status
        record.finishedAt = now
        if record.startedAt == nil {
            record.startedAt = now
        }
        if let startedAt = record.startedAt {
            record.durationMs = now.timeIntervalSince(startedAt) * 1000
        }
        record.errorCode = error?.code
        record.message = message
        records[stage] = record
        append(stage: stage, status: status, errorCode: error?.code, message: message ?? "stage finished")
    }
}

public enum TunnelState: String, Codable, Equatable, Sendable {
    case disconnected = "DISCONNECTED"
    case connecting = "CONNECTING"
    case tunnelEstablished = "TUNNEL_ESTABLISHED"
    case rsdConnected = "RSD_CONNECTED"
    case dvtConnected = "DVT_CONNECTED"
    case deviceInfoWarmed = "DEVICEINFO_WARMED"
    case locationSimulationConnected = "LOCATIONSIMULATION_CONNECTED"
    case simulating = "SIMULATING"
    case failed = "FAILED"
}
