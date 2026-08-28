import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class POCViewModel: ObservableObject {
    @Published var log: [String] = []
    @Published var pairingSummary = "pairing_loaded=false"
    @Published var stateText = "NOT_STARTED"
    @Published var actionStatus = "Ready. Import RPPairing, enable LocalDevVPN, then run diagnostics."
    @Published var stageRows: [StageRow] = StageRow.initialRows
    @Published var sessionID = "NO_SESSION"
    @Published var sessionElapsed = "00:00:00"
    @Published var requestedCoordinate = "UNKNOWN"
    @Published var observedCoordinate = "UNKNOWN"
    @Published var coreLocationState = "NO_LOCATION"
    @Published var lastDVTEvent = "never"
    @Published var lastCoreLocationUpdate = "never"
    @Published var timeline: [String] = []
    @Published var exportURLs: [URL] = []

    private let store = POCAppDependencies.store
    private let runner = POCAppDependencies.runner
    private var refreshLoopStarted = false
    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.recordAppLifecycle("memory_warning")
            }
        }
        #endif
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func refresh() async {
        do {
            if let summary = try store.pairingSummary() {
                pairingSummary = redactedSummary(summary)
            } else {
                pairingSummary = "pairing_loaded=false"
            }
            await updateState()
            await updateSessionSummary()
        } catch {
            append("refresh failed: \(error)")
        }
    }

    func startRefreshLoop() {
        guard !refreshLoopStarted else { return }
        refreshLoopStarted = true
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func importPairing(_ result: Result<[URL], Error>) {
        Task {
            do {
                actionStatus = "Importing RPPairing..."
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let summary = try await runner.importPairing(data)
                pairingSummary = redactedSummary(summary)
                actionStatus = "PASS: Pairing loaded, valid, and stored securely."
                append("pairing imported: \(summary.identifierRedacted)")
                await updateState()
            } catch {
                actionStatus = "FAIL: \(display(error))"
                append("pairing import failed: \(error)")
                await updateState()
            }
        }
    }

    func runDiagnostics() {
        Task {
            actionStatus = "RUN DIAGNOSTICS: checking pairing, LocalDevVPN route, and \(DeveloperEndpoint().host):\(DeveloperEndpoint().port)..."
            append("diagnostics started")
            let result = await runner.runDiagnostics()
            await updateState()
            actionStatus = diagnosticsStatus(result)
            append("localdevvpn_active=\(result.localDevVPNAppearsActive) tcp_connected=\(result.tcpResult.connected) latency_ms=\(format(result.tcpResult.latencyMs)) error=\(result.tcpResult.error ?? "none")")
        }
    }

    func connect() {
        Task {
            do {
                actionStatus = "CONNECT: establishing tunnel/RSD/DVT..."
                append("connect started")
                try await runner.connect()
                actionStatus = "PASS: Tunnel, RSD, DVT, and LocationSimulation connected."
                append("connect succeeded")
            } catch {
                actionStatus = "FAIL: \(display(error))"
                append("connect failed: \(error)")
            }
            await updateState()
            await updateSessionSummary()
        }
    }

    func setTestLocation() {
        Task {
            do {
                actionStatus = "SET TEST LOCATION: sending 40.7580,-73.9855..."
                append("set test location started")
                let observation = try await runner.setTestLocationAndVerify()
                actionStatus = "PASS: Core Location observed test coordinate."
                append("verified lat=\(observation.latitude) lon=\(observation.longitude) simulated=\(String(describing: observation.isSimulatedBySoftware)) accessory=\(String(describing: observation.isProducedByAccessory))")
            } catch {
                actionStatus = "FAIL: \(display(error))"
                append("set/verify failed: \(error)")
            }
            await updateState()
            await updateSessionSummary()
        }
    }

    func runRepeatedChanges() {
        Task {
            append("E2 started")
            let result = await runner.runRepeatedCoordinateChanges()
            append("E2 \(result.softwareTestVerdict) commands=\(result.commandCount) failures=\(result.failures.count)")
            await updateState()
            await updateSessionSummary()
        }
    }

    func clear() {
        Task {
            do {
                actionStatus = "CLEAR SIMULATION: sending clear..."
                append("clear started")
                try await runner.clear()
                actionStatus = "PASS: Clear command sent."
                append("clear succeeded")
            } catch {
                actionStatus = "FAIL: \(display(error))"
                append("clear failed: \(error)")
            }
            await updateState()
            await updateSessionSummary()
        }
    }

    func disconnect() {
        Task {
            await runner.disconnect()
            actionStatus = "Disconnected."
            append("disconnected")
            await updateState()
            await updateSessionSummary()
        }
    }

    func addMarker() {
        Task {
            await runner.addMarker("user marker")
            append("marker added")
            await updateSessionSummary()
        }
    }

    func prepareExport() {
        Task {
            exportURLs = await runner.diagnosticExportURLs()
            if exportURLs.isEmpty {
                append("export unavailable: no diagnostic files yet")
            } else {
                append("export ready: \(exportURLs.map { $0.lastPathComponent }.joined(separator: ", "))")
            }
        }
    }

    func recordScenePhase(_ phase: String) {
        Task {
            await recordAppLifecycle("scene_\(phase)")
        }
    }

    func recordAppLifecycle(_ state: String) async {
        await runner.recordAppLifecycle(state)
        await updateSessionSummary()
    }

    private func updateState() async {
        let snapshot = await runner.snapshot()
        let failed = snapshot.stages.filter { $0.status == .failed }.map { $0.stage.rawValue }
        let success = snapshot.stages.filter { $0.status == .success }.map { $0.stage.rawValue }
        stateText = "bridge=\(snapshot.bridgeState.rawValue)\nsuccess=\(success.joined(separator: ","))\nfailed=\(failed.joined(separator: ","))"
        stageRows = StageRow.rows(from: snapshot)
    }

    private func updateSessionSummary() async {
        let summary = await runner.sessionSummary()
        sessionID = summary.sessionID
        sessionElapsed = SessionDiagnosticRecorder.formatDuration(summary.elapsed)
        requestedCoordinate = coordinate(summary.requestedLatitude, summary.requestedLongitude)
        observedCoordinate = coordinate(summary.observedLatitude, summary.observedLongitude)
        coreLocationState = summary.coreLocationState
        lastDVTEvent = age(summary.lastDVTEventElapsed, now: summary.elapsed)
        lastCoreLocationUpdate = age(summary.lastCoreLocationElapsed, now: summary.elapsed)
        timeline = await runner.sessionTimeline(limit: 20)
        exportURLs = await runner.diagnosticExportURLs()
    }

    private func append(_ message: String) {
        log.append("\(Date()) \(message)")
    }

    private func diagnosticsStatus(_ result: DeveloperRouteDiagnostics) -> String {
        if stageRows.first(where: { $0.id == "pairing" })?.status == "FAIL" {
            return "FAIL: PAIRING_MISSING. Import a valid RPPairing file first."
        }
        if !result.localDevVPNAppearsActive {
            return "FAIL: LOCALDEVVPN_ROUTE_MISSING. Start LocalDevVPN and confirm iOS shows VPN active."
        }
        if !result.tcpResult.connected {
            return "FAIL: ENDPOINT_UNREACHABLE. LocalDevVPN route exists, but \(result.endpoint.host):\(result.endpoint.port) did not accept TCP: \(result.tcpResult.error ?? "unknown error")"
        }
        return "PASS: LocalDevVPN route and developer endpoint are reachable. Next step: CONNECT."
    }

    private func display(_ error: Error) -> String {
        if let error = error as? POCError {
            return "\(error.code.rawValue): \(error.message)"
        }
        return String(describing: error)
    }

    private func redactedSummary(_ summary: RPPairingSummary) -> String {
        "pairing_loaded=\(summary.pairingLoaded) identifier=\(summary.identifierRedacted) public_key_present=\(summary.publicKeyPresent) private_key_present=\(summary.privateKeyPresent) alt_irk_present=\(summary.altIRKPresent)"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.1f", value)
    }

    private func coordinate(_ latitude: Double?, _ longitude: Double?) -> String {
        guard let latitude, let longitude else { return "UNKNOWN" }
        return String(format: "%.6f, %.6f", latitude, longitude)
    }

    private func age(_ elapsed: TimeInterval?, now: TimeInterval) -> String {
        guard let elapsed else { return "never" }
        let delta = max(0, now - elapsed)
        if delta < 1 {
            return "now"
        }
        return "\(Int(delta.rounded()))s ago"
    }
}

struct StageRow: Identifiable {
    let id: String
    let label: String
    let status: String
    let detail: String?

    static let ordered: [(String, String, [POCStage])] = [
        ("pairing", "Pairing", [.pairingImported, .pairingValidated]),
        ("localdevvpn", "LocalDevVPN", [.localDevVPNRouteVisible]),
        ("endpoint", "Endpoint", [.endpointReachable]),
        ("tunnel", "Tunnel", [.tunnelEstablished]),
        ("rsd", "RSD", [.rsdConnected]),
        ("dvt", "DVT", [.dvtConnected]),
        ("location", "LocationSimulation", [.locationSimulationConnected, .setCommandSent]),
        ("verification", "CoreLocation Verification", [.coreLocationVerified])
    ]

    static var initialRows: [StageRow] {
        ordered.map { StageRow(id: $0.0, label: $0.1, status: "NOT STARTED", detail: nil) }
    }

    static func rows(from snapshot: DiagnosticSnapshot) -> [StageRow] {
        let recordsByStage = Dictionary(uniqueKeysWithValues: snapshot.stages.map { ($0.stage, $0) })
        return ordered.map { id, label, stages in
            let records = stages.compactMap { recordsByStage[$0] }
            let status = displayStatus(records)
            let detail = records.reversed().first { ($0.message ?? "").isEmpty == false || $0.errorCode != nil }.map { record in
                if let errorCode = record.errorCode {
                    return "\(errorCode.rawValue): \(record.message ?? "")"
                }
                return record.message ?? ""
            }
            return StageRow(id: id, label: label, status: status, detail: detail)
        }
    }

    private static func displayStatus(_ records: [POCStageRecord]) -> String {
        guard !records.isEmpty else { return "NOT STARTED" }
        if records.contains(where: { $0.status == .failed }) {
            return "FAIL"
        }
        if records.contains(where: { $0.status == .inProgress }) {
            return "CONNECTING"
        }
        if records.allSatisfy({ $0.status == .success }) {
            return "PASS"
        }
        if records.contains(where: { $0.status == .success }) {
            return "PASS"
        }
        return "NOT STARTED"
    }
}
