import CoreLocation
import SwiftUI
import UIKit

@MainActor
final class LocationWitnessViewModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var authorizationText = "notDetermined"
    @Published private(set) var statusText = "Idle"
    @Published private(set) var rawCallbackCount = 0
    @Published private(set) var rawLocationCount = 0
    @Published private(set) var latestRawMetadataSummaryText = LocationWitnessViewModel.unknownObservationText
    @Published private(set) var persistedObservationsText = ""
    @Published private(set) var metricsExportFileURL: URL?
    @Published private(set) var exportAvailabilityText = "No recording data to export."

    private let recorder = LocationWitnessRecorder()

    init() {
        recorder.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func reset() {
        recorder.reset()
        statusText = "Reset"
        refresh()
    }

    func start() {
        recorder.start()
        isRecording = true
        statusText = "Recording"
        refresh()
    }

    func stop() {
        recorder.stop()
        isRecording = false
        statusText = "Stopped"
        refresh()
    }

    func refresh() {
        let observations = recorder.observations
        rawCallbackCount = recorder.callbackCount
        rawLocationCount = observations.count
        authorizationText = Self.authorizationString(recorder.authorizationStatus)
        isRecording = recorder.isRecording
        latestRawMetadataSummaryText = observations.last?.wireText ?? Self.unknownObservationText
        persistedObservationsText = observations.map(\.wireText).joined(separator: "|")
        metricsExportFileURL = Self.writeMetricsExport(
            observations: observations,
            callbackCount: recorder.callbackCount,
            isRecording: recorder.isRecording,
            recordingStartTimestamp: recorder.recordingStartTimestamp,
            recordingStopTimestamp: recorder.recordingStopTimestamp
        )
        if observations.isEmpty {
            exportAvailabilityText = "No recording data to export."
        } else if recorder.isRecording {
            exportAvailabilityText = "Stop recording to export metrics."
        } else if metricsExportFileURL == nil {
            exportAvailabilityText = "Metrics export could not be prepared."
        } else {
            exportAvailabilityText = "Metrics export ready."
        }
    }

    private static func writeMetricsExport(
        observations: [LocationWitnessObservation],
        callbackCount: Int,
        isRecording: Bool,
        recordingStartTimestamp: Date?,
        recordingStopTimestamp: Date?
    ) -> URL? {
        guard !observations.isEmpty, !isRecording else { return nil }
        let generatedAt = Date()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(LocationWitnessMetricsExporter.fileName(generatedAt: generatedAt))
        let document = LocationWitnessMetricsExporter.document(
            observations: observations,
            rawCallbackCount: callbackCount,
            isRecording: isRecording,
            recordingStartTimestamp: recordingStartTimestamp,
            recordingStopTimestamp: recordingStopTimestamp,
            generatedAt: generatedAt
        )
        do {
            let data = try LocationWitnessMetricsExporter.jsonData(for: document)
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private static var unknownObservationText: String {
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

    private static func authorizationString(_ status: CLAuthorizationStatus) -> String {
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

struct LocationWitnessView: View {
    @StateObject private var model = LocationWitnessViewModel()

    var body: some View {
        List {
            Section("Recorder") {
                HStack {
                    Button("Reset") {
                        model.reset()
                    }
                    .accessibilityIdentifier("LocationWitness.Reset")

                    Button("Start") {
                        model.start()
                    }
                    .disabled(model.isRecording)
                    .accessibilityIdentifier("LocationWitness.Start")

                    Button("Stop") {
                        model.stop()
                    }
                    .disabled(!model.isRecording)
                    .accessibilityIdentifier("LocationWitness.Stop")

                    if let metricsExportFileURL = model.metricsExportFileURL {
                        ShareLink("Export Metrics", item: metricsExportFileURL)
                            .accessibilityIdentifier("LocationWitness.ExportMetrics")
                    } else {
                        Button("Export Metrics") {}
                            .disabled(true)
                            .accessibilityIdentifier("LocationWitness.ExportMetrics")
                    }
                }

                Text(model.statusText)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("LocationWitness.Status")
                Text(model.exportAvailabilityText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("LocationWitness.ExportAvailability")
            }

            Section("Metrics") {
                Text("authorization=\(model.authorizationText)")
                    .font(.caption2.monospaced())
                    .accessibilityIdentifier("LocationWitness.AuthorizationValue")
                Text("raw_callbacks=\(model.rawCallbackCount)")
                    .font(.caption2.monospaced())
                    .accessibilityIdentifier("LocationWitness.RawCallbackValue")
                Text("raw_locations=\(model.rawLocationCount)")
                    .font(.caption2.monospaced())
                    .accessibilityIdentifier("LocationWitness.RawLocationValue")
                Text(model.latestRawMetadataSummaryText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("LocationWitness.LatestRawLocationMetadataValue")
                Text(model.persistedObservationsText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("LocationWitness.PersistedRawLocationsValue")
            }
        }
        .navigationTitle("Location Witness")
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            model.refresh()
        }
    }
}

final class LocationWitnessRecorder: NSObject, CLLocationManagerDelegate {
    var onChange: (() -> Void)?
    private(set) var observations: [LocationWitnessObservation] = []
    private(set) var callbackCount = 0
    private(set) var isRecording = false
    private(set) var recordingStartTimestamp: Date?
    private(set) var recordingStopTimestamp: Date?

    private let manager = CLLocationManager()
    private let storeKey = "LocationWitness.persistedObservations.v1"
    private let callbackCountKey = "LocationWitness.callbackCount.v1"
    private let recordingStartKey = "LocationWitness.recordingStartTimestamp.v1"
    private let recordingStopKey = "LocationWitness.recordingStopTimestamp.v1"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        load()
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func reset() {
        observations.removeAll()
        callbackCount = 0
        recordingStartTimestamp = nil
        recordingStopTimestamp = nil
        persist()
        onChange?()
    }

    func start() {
        if recordingStartTimestamp == nil {
            recordingStartTimestamp = Date()
        }
        recordingStopTimestamp = nil
        isRecording = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        }
        manager.startUpdatingLocation()
        onChange?()
    }

    func stop() {
        manager.stopUpdatingLocation()
        isRecording = false
        recordingStopTimestamp = Date()
        persist()
        onChange?()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isRecording, manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
        onChange?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording else { return }
        callbackCount += 1
        let wallClockTimestamp = Date()
        for location in locations {
            observations.append(LocationWitnessObservation(
                sequence: observations.count + 1,
                location: location,
                wallClockTimestamp: wallClockTimestamp
            ))
        }
        persist()
        onChange?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onChange?()
    }

    private func load() {
        callbackCount = UserDefaults.standard.integer(forKey: callbackCountKey)
        recordingStartTimestamp = UserDefaults.standard.object(forKey: recordingStartKey) as? Date
        recordingStopTimestamp = UserDefaults.standard.object(forKey: recordingStopKey) as? Date
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([LocationWitnessObservation].self, from: data) else {
            observations = []
            return
        }
        observations = decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(observations) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
        UserDefaults.standard.set(callbackCount, forKey: callbackCountKey)
        UserDefaults.standard.set(recordingStartTimestamp, forKey: recordingStartKey)
        UserDefaults.standard.set(recordingStopTimestamp, forKey: recordingStopKey)
    }
}

extension LocationWitnessObservation {
    init(sequence: Int, location: CLLocation, wallClockTimestamp: Date) {
        var simulatedBySoftware: Bool?
        var producedByAccessory: Bool?
        if #available(iOS 15.0, *) {
            simulatedBySoftware = location.sourceInformation?.isSimulatedBySoftware
            producedByAccessory = location.sourceInformation?.isProducedByAccessory
        }
        self.init(
            sequence: sequence,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speed: location.speed,
            course: location.course,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            altitude: location.altitude,
            locationTimestamp: location.timestamp,
            wallClockTimestamp: wallClockTimestamp,
            isSimulatedBySoftware: simulatedBySoftware,
            isProducedByAccessory: producedByAccessory
        )
    }

    var wireText: String {
        [
            "sequence=\(sequence)",
            String(format: "latitude=%.8f", latitude),
            String(format: "longitude=%.8f", longitude),
            String(format: "speed=%.6f", speed),
            String(format: "course=%.6f", course),
            String(format: "horizontalAccuracy=%.6f", horizontalAccuracy),
            String(format: "verticalAccuracy=%.6f", verticalAccuracy),
            String(format: "altitude=%.6f", altitude),
            "locationTimestamp=\(Self.iso8601String(from: locationTimestamp))",
            "wallClockTimestamp=\(Self.iso8601String(from: wallClockTimestamp))",
            "isSimulatedBySoftware=\(Self.optionalBoolText(isSimulatedBySoftware))",
            "isProducedByAccessory=\(Self.optionalBoolText(isProducedByAccessory))"
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
}
