import CoreLocation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AppleLocationControlsViewModel: ObservableObject {
    @Published var selectedLabel: AppleLocationControlMetadataLabel = .realDevice
    @Published private(set) var isRecording = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var elapsedText = "0.0 s"
    @Published private(set) var rawCallbackCount = 0
    @Published private(set) var rawLocationCount = 0
    @Published private(set) var latestRawMetadataSummaryText = AppleLocationControlsViewModel.unknownLatestRawMetadataSummaryText
    @Published private(set) var latestSequenceText = "sequence=UNKNOWN"
    @Published private(set) var latestLatitudeText = "latitude=UNKNOWN"
    @Published private(set) var latestLongitudeText = "longitude=UNKNOWN"
    @Published private(set) var latestSpeedText = "speed=UNKNOWN"
    @Published private(set) var latestCourseText = "course=UNKNOWN"
    @Published private(set) var latestHorizontalAccuracyText = "horizontalAccuracy=UNKNOWN"
    @Published private(set) var latestVerticalAccuracyText = "verticalAccuracy=UNKNOWN"
    @Published private(set) var latestAltitudeText = "altitude=UNKNOWN"
    @Published private(set) var latestLocationTimestampText = "locationTimestamp=UNKNOWN"
    @Published private(set) var latestWallClockTimestampText = "wallClockTimestamp=UNKNOWN"
    @Published private(set) var latestSimulatedBySoftwareText = "isSimulatedBySoftware=UNKNOWN"
    @Published private(set) var latestProducedByAccessoryText = "isProducedByAccessory=UNKNOWN"
    @Published private(set) var effectiveHzText = "UNKNOWN"
    @Published private(set) var coordinateText = "UNKNOWN"
    @Published private(set) var nativeSpeedText = "UNKNOWN"
    @Published private(set) var nativeCourseText = "UNKNOWN"
    @Published private(set) var geometricSpeedText = "UNKNOWN"
    @Published private(set) var horizontalAccuracyText = "UNKNOWN"
    @Published private(set) var simulatedBySoftwareText = "UNKNOWN"
    @Published private(set) var exportURLs: [URL] = []
    @Published private(set) var statusText = "Idle"

    private let recorder: AppleLocationControlRecorder
    private var startedAt: Date?
    private var timer: Timer?
    private let requestedVelocityMps = 15.646

    init(recorder: AppleLocationControlRecorder = AppleLocationControlRecorder()) {
        self.recorder = recorder
        self.authorizationStatus = recorder.authorizationStatus
        recorder.setAuthorizationHandler { [weak self] status in
            Task { @MainActor in self?.authorizationStatus = status }
        }
        recorder.setObservationHandler { [weak self] _ in
            Task { @MainActor in self?.refreshMetrics() }
        }
    }

    deinit {
        timer?.invalidate()
        recorder.stop()
    }

    func startRecording() {
        exportURLs.removeAll()
        startedAt = Date()
        isRecording = true
        statusText = "Recording \(selectedLabel.rawValue)"
        recorder.start()
        scheduleTimer()
        refreshMetrics()
    }

    func stopRecording() {
        recorder.stop()
        isRecording = false
        timer?.invalidate()
        timer = nil
        refreshMetrics()
        do {
            exportURLs = try writeExport()
            statusText = "Stopped. Export files ready."
        } catch {
            statusText = "Export failed: \(error.localizedDescription)"
        }
    }

    func refreshMetrics() {
        let observations = recorder.allObservations()
        let callbackBatches = recorder.allCallbackBatches()
        rawCallbackCount = callbackBatches.count
        rawLocationCount = observations.count
        authorizationStatus = recorder.authorizationStatus

        let summary = AppleLocationControlAnalysis.summary(
            for: observations,
            callbackBatches: callbackBatches,
            requestedVelocityMps: requestedVelocityMps,
            metadataLabel: selectedLabel
        )
        effectiveHzText = format(summary.effectiveRawCallbackHz, suffix: " Hz")
        geometricSpeedText = format(summary.geometricSpeedFromCallbackTimestampsMps.mean, suffix: " m/s")

        if let start = startedAt {
            elapsedText = String(format: "%.1f s", Date().timeIntervalSince(start))
        } else {
            elapsedText = "0.0 s"
        }

        guard let latest = observations.last else {
            coordinateText = "UNKNOWN"
            nativeSpeedText = "UNKNOWN"
            nativeCourseText = "UNKNOWN"
            horizontalAccuracyText = "UNKNOWN"
            simulatedBySoftwareText = "UNKNOWN"
            resetLatestRawMetadataText()
            return
        }

        updateLatestRawMetadataText(with: latest)
        coordinateText = String(format: "%.6f, %.6f", latest.latitude, latest.longitude)
        nativeSpeedText = latest.speedValid
            ? String(format: "%.3f m/s", latest.rawSpeed)
            : String(format: "INVALID raw=%.3f", latest.rawSpeed)
        nativeCourseText = latest.courseValid
            ? String(format: "%.1f deg", latest.rawCourse)
            : String(format: "INVALID raw=%.3f", latest.rawCourse)
        horizontalAccuracyText = String(format: "%.2f m", latest.horizontalAccuracy)
        simulatedBySoftwareText = latest.isSimulatedBySoftware.map(String.init(describing:)) ?? "UNKNOWN"
    }

    func copyLatestJSONLToPasteboard() {
        guard let jsonlURL = exportURLs.first(where: { $0.pathExtension == "jsonl" }),
              let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else {
            statusText = "No JSONL export is available yet."
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        statusText = "Copied JSONL to pasteboard."
        #else
        statusText = "Pasteboard export is unavailable."
        #endif
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMetrics() }
        }
    }

    private func writeExport() throws -> [URL] {
        let observations = recorder.allObservations()
        let callbackBatches = recorder.allCallbackBatches()
        let summary = AppleLocationControlAnalysis.summary(
            for: observations,
            callbackBatches: callbackBatches,
            requestedVelocityMps: requestedVelocityMps,
            metadataLabel: selectedLabel
        )
        let timestamp = Self.fileTimestamp()
        let directory = try exportDirectory()
        let base = "APPLE-\(selectedLabel.rawValue)-\(timestamp)"
        let jsonlURL = directory.appendingPathComponent("\(base).jsonl")
        let summaryURL = directory.appendingPathComponent("\(base)-summary.txt")
        let jsonl = try AppleLocationControlAnalysis.jsonLines(
            observations: observations,
            callbackBatches: callbackBatches,
            summary: summary
        )
        try jsonl.write(to: jsonlURL, atomically: true, encoding: .utf8)
        try AppleLocationControlAnalysis.summaryText(summary)
            .write(to: summaryURL, atomically: true, encoding: .utf8)
        return [jsonlURL, summaryURL]
    }

    private func exportDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("AppleLocationControls", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func updateLatestRawMetadataText(with latest: AppleLocationControlObservation) {
        latestSequenceText = "sequence=\(latest.sequence)"
        latestLatitudeText = String(format: "latitude=%.8f", latest.latitude)
        latestLongitudeText = String(format: "longitude=%.8f", latest.longitude)
        latestSpeedText = String(format: "speed=%.6f", latest.rawSpeed)
        latestCourseText = String(format: "course=%.6f", latest.rawCourse)
        latestHorizontalAccuracyText = String(format: "horizontalAccuracy=%.6f", latest.horizontalAccuracy)
        latestVerticalAccuracyText = String(format: "verticalAccuracy=%.6f", latest.verticalAccuracy)
        latestAltitudeText = String(format: "altitude=%.6f", latest.altitude)
        latestLocationTimestampText = "locationTimestamp=\(Self.iso8601String(from: latest.locationTimestamp))"
        latestWallClockTimestampText = "wallClockTimestamp=\(Self.iso8601String(from: latest.wallClockTimestamp))"
        latestSimulatedBySoftwareText = "isSimulatedBySoftware=\(Self.optionalBoolText(latest.isSimulatedBySoftware))"
        latestProducedByAccessoryText = "isProducedByAccessory=\(Self.optionalBoolText(latest.isProducedByAccessory))"
        latestRawMetadataSummaryText = [
            latestSequenceText,
            latestLatitudeText,
            latestLongitudeText,
            latestSpeedText,
            latestCourseText,
            latestHorizontalAccuracyText,
            latestVerticalAccuracyText,
            latestAltitudeText,
            latestLocationTimestampText,
            latestWallClockTimestampText,
            latestSimulatedBySoftwareText,
            latestProducedByAccessoryText
        ].joined(separator: " ")
    }

    private func resetLatestRawMetadataText() {
        latestRawMetadataSummaryText = Self.unknownLatestRawMetadataSummaryText
        latestSequenceText = "sequence=UNKNOWN"
        latestLatitudeText = "latitude=UNKNOWN"
        latestLongitudeText = "longitude=UNKNOWN"
        latestSpeedText = "speed=UNKNOWN"
        latestCourseText = "course=UNKNOWN"
        latestHorizontalAccuracyText = "horizontalAccuracy=UNKNOWN"
        latestVerticalAccuracyText = "verticalAccuracy=UNKNOWN"
        latestAltitudeText = "altitude=UNKNOWN"
        latestLocationTimestampText = "locationTimestamp=UNKNOWN"
        latestWallClockTimestampText = "wallClockTimestamp=UNKNOWN"
        latestSimulatedBySoftwareText = "isSimulatedBySoftware=UNKNOWN"
        latestProducedByAccessoryText = "isProducedByAccessory=UNKNOWN"
    }

    private static var unknownLatestRawMetadataSummaryText: String {
        [
            "sequence=UNKNOWN",
            "latitude=UNKNOWN",
            "longitude=UNKNOWN",
            "speed=UNKNOWN",
            "course=UNKNOWN",
            "horizontalAccuracy=UNKNOWN",
            "verticalAccuracy=UNKNOWN",
            "altitude=UNKNOWN",
            "locationTimestamp=UNKNOWN",
            "wallClockTimestamp=UNKNOWN",
            "isSimulatedBySoftware=UNKNOWN",
            "isProducedByAccessory=UNKNOWN"
        ].joined(separator: " ")
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func optionalBoolText(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "UNKNOWN"
    }

    private func format(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite else { return "UNKNOWN" }
        return String(format: "%.3f%@", value, suffix)
    }
}

struct AppleLocationControlsView: View {
    @StateObject private var model = AppleLocationControlsViewModel()
    @State private var showingExporter = false

    var body: some View {
        List {
            Section("Passive Core Location Recorder") {
                Picker("Metadata label", selection: $model.selectedLabel) {
                    ForEach(AppleLocationControlMetadataLabel.allCases) { label in
                        Text(label.rawValue).tag(label)
                    }
                }
                .disabled(model.isRecording)
                .accessibilityIdentifier("AppleLocationControls.LabelPicker")

                HStack {
                    Button {
                        model.startRecording()
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
                    }
                    .disabled(model.isRecording)
                    .accessibilityIdentifier("AppleLocationControls.StartRecording")

                    Button {
                        model.stopRecording()
                    } label: {
                        Label("Stop Recording", systemImage: "stop.circle")
                    }
                    .disabled(!model.isRecording)
                    .accessibilityIdentifier("AppleLocationControls.StopRecording")
                }

                Button {
                    showingExporter = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.exportURLs.isEmpty)
                .accessibilityIdentifier("AppleLocationControls.Export")

                Button {
                    model.copyLatestJSONLToPasteboard()
                } label: {
                    Label("Copy JSONL", systemImage: "doc.on.doc")
                }
                .disabled(model.exportURLs.isEmpty)
                .accessibilityIdentifier("AppleLocationControls.CopyJSONL")

                Text(model.latestRawMetadataSummaryText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("AppleLocationControls.LatestRawLocationMetadataValue")
            }

            Section("Live Metrics") {
                LabeledContent("Elapsed", value: model.elapsedText)
                LabeledContent("Raw callbacks", value: "\(model.rawCallbackCount)")
                    .accessibilityIdentifier("AppleLocationControls.RawCallbacks")
                Text("raw_callbacks=\(model.rawCallbackCount)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.RawCallbackValue")
                LabeledContent("Raw CLLocation count", value: "\(model.rawLocationCount)")
                    .accessibilityIdentifier("AppleLocationControls.RawLocations")
                Text("raw_locations=\(model.rawLocationCount)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.RawLocationValue")
                LabeledContent("Effective Hz", value: model.effectiveHzText)
                LabeledContent("Coordinate", value: model.coordinateText)
                LabeledContent("Native speed", value: model.nativeSpeedText)
                LabeledContent("Native course", value: model.nativeCourseText)
                LabeledContent("Geometric speed", value: model.geometricSpeedText)
                LabeledContent("Horizontal accuracy", value: model.horizontalAccuracyText)
                LabeledContent("Simulated by software", value: model.simulatedBySoftwareText)
                Text(model.latestSequenceText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestSequenceValue")
                Text(model.latestLatitudeText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestLatitudeValue")
                Text(model.latestLongitudeText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestLongitudeValue")
                Text(model.latestSpeedText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestSpeedValue")
                Text(model.latestCourseText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestCourseValue")
                Text(model.latestHorizontalAccuracyText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestHorizontalAccuracyValue")
                Text(model.latestVerticalAccuracyText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestVerticalAccuracyValue")
                Text(model.latestAltitudeText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestAltitudeValue")
                Text(model.latestLocationTimestampText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestLocationTimestampValue")
                Text(model.latestWallClockTimestampText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestWallClockTimestampValue")
                Text(model.latestSimulatedBySoftwareText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestSimulatedBySoftwareValue")
                Text(model.latestProducedByAccessoryText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AppleLocationControls.LatestProducedByAccessoryValue")
            }

            Section("State") {
                LabeledContent("Authorization", value: authorizationText(model.authorizationStatus))
                Text(model.statusText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("AppleLocationControls.Status")
            }
        }
        .navigationTitle("Apple Location Controls")
        .sheet(isPresented: $showingExporter) {
            ShareSheet(activityItems: model.exportURLs)
        }
    }

    private func authorizationText(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }
}
