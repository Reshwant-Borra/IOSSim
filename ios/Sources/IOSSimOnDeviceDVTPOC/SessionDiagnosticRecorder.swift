import Foundation

public struct SessionDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let monotonicTimestamp: Double
    public let wallClockTimestamp: Date
    public let sessionID: String
    public let category: String
    public let component: String
    public let previousState: String?
    public let newState: String?
    public let elapsedSessionTime: Double
    public let errorCode: String?
    public let redactedMessage: String?
    public let metadata: [String: String]
}

public struct SessionDiagnosticSummary: Codable, Equatable, Sendable {
    public let sessionID: String
    public let startedAt: Date?
    public let elapsed: TimeInterval
    public let jsonlURL: URL?
    public let summaryURL: URL?
    public let eventCount: Int
    public let componentStates: [String: String]
    public let firstAbnormalEvent: SessionDiagnosticEvent?
    public let requestedLatitude: Double?
    public let requestedLongitude: Double?
    public let observedLatitude: Double?
    public let observedLongitude: Double?
    public let coreLocationState: String
    public let lastDVTEventElapsed: TimeInterval?
    public let lastCoreLocationElapsed: TimeInterval?
    public let diagnosticEventsWritten: Int
    public let diagnosticFlushCount: Int
    public let diagnosticMeanWriteDurationMs: Double?
    public let diagnosticMaxWriteDurationMs: Double?
    public let retainedJSONLHandleOpen: Bool
}

public struct SessionDiagnosticRecorderMetrics: Codable, Equatable, Sendable {
    public let eventCount: Int
    public let eventsWritten: Int
    public let flushCount: Int
    public let meanWriteDurationMs: Double?
    public let maxWriteDurationMs: Double?
    public let retainedJSONLHandleOpen: Bool
}

public actor SessionDiagnosticRecorder {
    public static let shared = SessionDiagnosticRecorder()

    private let encoder = JSONEncoder()
    private let fileManager: FileManager
    private let processInfo: ProcessInfo
    private let baseDirectory: URL?
    private let eventLimit: Int
    private let flushEveryEvents: Int

    private var sessionID = "NO_SESSION"
    private var startedAt: Date?
    private var startedUptime: TimeInterval?
    private var events: [SessionDiagnosticEvent] = []
    private var totalEventCount = 0
    private var componentStates: [String: String] = [:]
    private var firstAbnormalEvent: SessionDiagnosticEvent?
    private var jsonlURL: URL?
    private var summaryURL: URL?
    private var jsonlHandle: FileHandle?
    private var requestedLatitude: Double?
    private var requestedLongitude: Double?
    private var observedLatitude: Double?
    private var observedLongitude: Double?
    private var coreLocationState = "NO_LOCATION"
    private var lastDVTEventElapsed: TimeInterval?
    private var lastCoreLocationElapsed: TimeInterval?
    private var diagnosticEventsWritten = 0
    private var diagnosticFlushCount = 0
    private var diagnosticWriteDurationsMs: [Double] = []
    private var unflushedEventCount = 0

    public init(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo,
        baseDirectory: URL? = nil,
        eventLimit: Int = 4096,
        flushEveryEvents: Int = 32
    ) {
        self.fileManager = fileManager
        self.processInfo = processInfo
        self.baseDirectory = baseDirectory
        self.eventLimit = max(1, eventLimit)
        self.flushEveryEvents = max(1, flushEveryEvents)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    public func startSession(prefix: String = "E1") -> SessionDiagnosticSummary {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        closeJSONLHandle()
        sessionID = "\(prefix)-\(formatter.string(from: now))"
        startedAt = now
        startedUptime = processInfo.systemUptime
        events = []
        totalEventCount = 0
        componentStates = [:]
        firstAbnormalEvent = nil
        requestedLatitude = nil
        requestedLongitude = nil
        observedLatitude = nil
        observedLongitude = nil
        coreLocationState = "NO_LOCATION"
        lastDVTEventElapsed = nil
        lastCoreLocationElapsed = nil
        diagnosticEventsWritten = 0
        diagnosticFlushCount = 0
        diagnosticWriteDurationsMs = []
        unflushedEventCount = 0

        let directory = diagnosticsDirectory()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        jsonlURL = directory.appendingPathComponent("\(sessionID).jsonl")
        summaryURL = directory.appendingPathComponent("\(sessionID)-summary.txt")
        if let jsonlURL {
            fileManager.createFile(atPath: jsonlURL.path, contents: nil)
            jsonlHandle = try? FileHandle(forWritingTo: jsonlURL)
        }

        record(
            category: "SESSION",
            component: "session",
            previousState: nil,
            newState: "created",
            message: "diagnostic session created",
            metadata: ["format": "jsonl"]
        )
        writeSummary()
        return snapshot()
    }

    public func endSession(reason: String) {
        record(
            category: "SESSION",
            component: "session",
            previousState: componentStates["session"],
            newState: "ended",
            message: reason
        )
        flushJSONL(force: true)
        writeSummary()
        closeJSONLHandle()
    }

    public func setRequestedCoordinate(latitude: Double, longitude: Double) {
        requestedLatitude = latitude
        requestedLongitude = longitude
        record(
            category: "LOCATION_SET",
            component: "LocationSimulation",
            previousState: componentStates["LocationSimulation"],
            newState: "requested",
            message: "requested coordinate recorded",
            metadata: [
                "latitude": String(format: "%.6f", latitude),
                "longitude": String(format: "%.6f", longitude)
            ]
        )
    }

    public func record(
        category: String,
        component: String,
        previousState: String? = nil,
        newState: String? = nil,
        errorCode: String? = nil,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let now = Date()
        let uptime = processInfo.systemUptime
        let elapsed = startedUptime.map { uptime - $0 } ?? 0
        let oldState = previousState ?? componentStates[component]
        if let newState {
            componentStates[component] = newState
        }

        let event = SessionDiagnosticEvent(
            id: UUID(),
            monotonicTimestamp: uptime,
            wallClockTimestamp: now,
            sessionID: sessionID,
            category: category,
            component: component,
            previousState: oldState,
            newState: newState,
            elapsedSessionTime: elapsed,
            errorCode: errorCode,
            redactedMessage: message.map(Self.redact),
            metadata: Self.redacted(metadata)
        )
        totalEventCount += 1
        events.append(event)
        if events.count > eventLimit {
            events.removeFirst(events.count - eventLimit)
        }

        if isAbnormal(event), firstAbnormalEvent == nil {
            firstAbnormalEvent = event
        }
        if component == "DeveloperTunnel" || component == "RSD" || component == "DVT" || component == "LocationSimulation" {
            lastDVTEventElapsed = elapsed
        }
        if component == "CoreLocation" {
            lastCoreLocationElapsed = elapsed
        }

        persist(event)
        if shouldUpdateSummary(for: event) {
            writeSummary()
        }
    }

    public func recordLocation(_ observation: LocationObservation) {
        observedLatitude = observation.latitude
        observedLongitude = observation.longitude
        coreLocationState = observation.classification ?? "NO_LOCATION"

        var metadata: [String: String] = [
            "latitude": String(format: "%.6f", observation.latitude),
            "longitude": String(format: "%.6f", observation.longitude),
            "horizontal_accuracy_m": String(format: "%.1f", observation.horizontalAccuracy),
            "vertical_accuracy_m": String(format: "%.1f", observation.verticalAccuracy),
            "location_timestamp": ISO8601DateFormatter().string(from: observation.locationTimestamp),
            "is_simulated_by_software": String(describing: observation.isSimulatedBySoftware),
            "is_produced_by_accessory": String(describing: observation.isProducedByAccessory)
        ]
        if let speed = observation.speed {
            metadata["cllocation_speed_mps"] = String(format: "%.3f", speed)
        }
        if let speedAccuracy = observation.speedAccuracy {
            metadata["cllocation_speed_accuracy_mps"] = String(format: "%.3f", speedAccuracy)
        }
        if let course = observation.course {
            metadata["cllocation_course_deg"] = String(format: "%.3f", course)
        }
        if let courseAccuracy = observation.courseAccuracy {
            metadata["cllocation_course_accuracy_deg"] = String(format: "%.3f", courseAccuracy)
        }
        if let distance = observation.distanceMetersFromRequested {
            metadata["distance_from_requested_m"] = String(format: "%.1f", distance)
        }

        record(
            category: "CORELOCATION",
            component: "CoreLocation",
            previousState: componentStates["CoreLocation"],
            newState: coreLocationState,
            message: "core location observation",
            metadata: metadata
        )
    }

    public func snapshot() -> SessionDiagnosticSummary {
        let elapsed = startedUptime.map { processInfo.systemUptime - $0 } ?? 0
        return SessionDiagnosticSummary(
            sessionID: sessionID,
            startedAt: startedAt,
            elapsed: elapsed,
            jsonlURL: jsonlURL,
            summaryURL: summaryURL,
            eventCount: totalEventCount,
            componentStates: componentStates,
            firstAbnormalEvent: firstAbnormalEvent,
            requestedLatitude: requestedLatitude,
            requestedLongitude: requestedLongitude,
            observedLatitude: observedLatitude,
            observedLongitude: observedLongitude,
            coreLocationState: coreLocationState,
            lastDVTEventElapsed: lastDVTEventElapsed,
            lastCoreLocationElapsed: lastCoreLocationElapsed,
            diagnosticEventsWritten: diagnosticEventsWritten,
            diagnosticFlushCount: diagnosticFlushCount,
            diagnosticMeanWriteDurationMs: mean(diagnosticWriteDurationsMs),
            diagnosticMaxWriteDurationMs: diagnosticWriteDurationsMs.max(),
            retainedJSONLHandleOpen: jsonlHandle != nil
        )
    }

    public func exportURLs() -> [URL] {
        flushJSONL(force: true)
        writeSummary()
        return [jsonlURL, summaryURL].compactMap { $0 }.filter { fileManager.fileExists(atPath: $0.path) }
    }

    public func flushAndWriteSummary() {
        flushJSONL(force: true)
        writeSummary()
    }

    public func finalizeCurrentSession() {
        flushJSONL(force: true)
        writeSummary()
        closeJSONLHandle()
    }

    public func metrics() -> SessionDiagnosticRecorderMetrics {
        SessionDiagnosticRecorderMetrics(
            eventCount: totalEventCount,
            eventsWritten: diagnosticEventsWritten,
            flushCount: diagnosticFlushCount,
            meanWriteDurationMs: mean(diagnosticWriteDurationsMs),
            maxWriteDurationMs: diagnosticWriteDurationsMs.max(),
            retainedJSONLHandleOpen: jsonlHandle != nil
        )
    }

    public func recentTimeline(limit: Int = 40) -> [String] {
        events.suffix(limit).map { event in
            let elapsed = String(format: "+%.3fs", event.elapsedSessionTime)
            let state = event.newState.map { " \($0)" } ?? ""
            let error = event.errorCode.map { " \($0)" } ?? ""
            return "\(elapsed) \(event.category) \(event.component)\(state)\(error)"
        }
    }

    private func diagnosticsDirectory() -> URL {
        if let baseDirectory {
            return baseDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        }
        let root = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private func persist(_ event: SessionDiagnosticEvent) {
        guard let data = try? encoder.encode(event) else { return }
        guard let newline = "\n".data(using: .utf8) else { return }
        guard let handle = jsonlHandle else { return }
        let begin = processInfo.systemUptime
        handle.write(data)
        handle.write(newline)
        let duration = max(0, processInfo.systemUptime - begin) * 1000
        diagnosticEventsWritten += 1
        unflushedEventCount += 1
        diagnosticWriteDurationsMs.append(duration)
        if diagnosticWriteDurationsMs.count > 256 {
            diagnosticWriteDurationsMs.removeFirst(diagnosticWriteDurationsMs.count - 256)
        }
        flushJSONL(force: shouldFlushImmediately(event))
    }

    private func writeSummary() {
        guard let summaryURL else { return }
        let text = renderSummary()
        try? text.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    private func renderSummary() -> String {
        let snapshot = snapshot()
        let duration = Self.formatDuration(snapshot.elapsed)
        var lines: [String] = [
            "SESSION \(snapshot.sessionID)",
            "SESSION DURATION \(duration)",
            "",
            "REQUESTED \(coordinate(snapshot.requestedLatitude, snapshot.requestedLongitude))",
            "OBSERVED \(coordinate(snapshot.observedLatitude, snapshot.observedLongitude))",
            "CORE LOCATION \(snapshot.coreLocationState)",
            "EVENTS WRITTEN \(snapshot.diagnosticEventsWritten)",
            "JSONL FLUSHES \(snapshot.diagnosticFlushCount)",
            "JSONL MEAN WRITE MS \(snapshot.diagnosticMeanWriteDurationMs.map { String(format: "%.3f", $0) } ?? "UNKNOWN")",
            "JSONL MAX WRITE MS \(snapshot.diagnosticMaxWriteDurationMs.map { String(format: "%.3f", $0) } ?? "UNKNOWN")",
            "",
            "COMPONENT STATES"
        ]

        let components = [
            "Pairing",
            "LocalDevVPN",
            "Endpoint",
            "DeveloperTunnel",
            "RSD",
            "DVT",
            "DeviceInfo",
            "LocationSimulation",
            "CoreLocation",
            "AppLifecycle"
        ]
        for component in components {
            lines.append("\(component) \(snapshot.componentStates[component] ?? "UNKNOWN")")
        }

        lines.append("")
        lines.append("FIRST ABNORMAL EVENT")
        if let event = snapshot.firstAbnormalEvent {
            lines.append("\(String(format: "+%.3fs", event.elapsedSessionTime)) \(event.category) \(event.component) \(event.errorCode ?? "") \(event.redactedMessage ?? "")")
        } else {
            lines.append("NONE RECORDED")
        }

        lines.append("")
        lines.append("SESSION TIMELINE")
        lines.append(contentsOf: recentTimeline(limit: 80))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func flushJSONL(force: Bool) {
        guard force || unflushedEventCount >= flushEveryEvents else { return }
        guard unflushedEventCount > 0, let jsonlHandle else { return }
        try? jsonlHandle.synchronize()
        diagnosticFlushCount += 1
        unflushedEventCount = 0
    }

    private func closeJSONLHandle() {
        flushJSONL(force: true)
        try? jsonlHandle?.close()
        jsonlHandle = nil
    }

    private func shouldFlushImmediately(_ event: SessionDiagnosticEvent) -> Bool {
        event.category == "SESSION" || event.category == "DRIVE_CHARACTERIZATION_SUMMARY"
    }

    private func shouldUpdateSummary(for event: SessionDiagnosticEvent) -> Bool {
        shouldFlushImmediately(event) || event.errorCode != nil
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func coordinate(_ latitude: Double?, _ longitude: Double?) -> String {
        guard let latitude, let longitude else { return "UNKNOWN" }
        return String(format: "%.6f, %.6f", latitude, longitude)
    }

    private func isAbnormal(_ event: SessionDiagnosticEvent) -> Bool {
        if event.errorCode != nil { return true }
        if let state = event.newState {
            return [
                "failed",
                "lost",
                "unreachable",
                "missing",
                "cancelled",
                "expired",
                "REAL_LOCATION",
                "OTHER_LOCATION"
            ].contains(state)
        }
        return false
    }

    private static func redacted(_ metadata: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: metadata.map { key, value in
            (redact(key), redact(value))
        })
    }

    public static func redact(_ value: String) -> String {
        let sensitiveTokens = [
            "private_key",
            "privatekey",
            "pairingdata",
            "pairing plist",
            "rppairing plist",
            "psk",
            "secret",
            "auth tag",
            "authtag"
        ]
        let lowered = value.lowercased()
        if sensitiveTokens.contains(where: { lowered.contains($0) }) {
            return "[REDACTED]"
        }
        if value.count > 240 {
            return String(value.prefix(240)) + "...[truncated]"
        }
        return value
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
