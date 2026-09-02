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
            isRecording: recorder.isRecording
        )
    }

    private static func writeMetricsExport(
        observations: [LocationWitnessObservation],
        callbackCount: Int,
        isRecording: Bool
    ) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSSimLocationWitness-metrics.txt")
        let simulatedCount = observations.filter { $0.isSimulatedBySoftware == true }.count
        let validSpeedCount = observations.filter { $0.speed >= 0 }.count
        let validCourseCount = observations.filter { $0.course >= 0 }.count
        let body = [
            "IOSSimLocationWitness metrics export",
            "isRecording=\(isRecording)",
            "rawCallbackCount=\(callbackCount)",
            "rawLocationCount=\(observations.count)",
            "simulatedBySoftwareCount=\(simulatedCount)",
            "validSpeedCount=\(validSpeedCount)",
            "validCourseCount=\(validCourseCount)",
            "",
            observations.map(\.wireText).joined(separator: "\n")
        ].joined(separator: "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
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
                    }
                }

                Text(model.statusText)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("LocationWitness.Status")
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

    private let manager = CLLocationManager()
    private let storeKey = "LocationWitness.persistedObservations.v1"
    private let callbackCountKey = "LocationWitness.callbackCount.v1"

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
        persist()
        onChange?()
    }

    func start() {
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
    }
}

struct LocationWitnessObservation: Codable, Equatable {
    let sequence: Int
    let latitude: Double
    let longitude: Double
    let speed: Double
    let course: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let altitude: Double
    let locationTimestamp: Date
    let wallClockTimestamp: Date
    let isSimulatedBySoftware: Bool?
    let isProducedByAccessory: Bool?

    init(sequence: Int, location: CLLocation, wallClockTimestamp: Date) {
        self.sequence = sequence
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.speed = location.speed
        self.course = location.course
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
        self.altitude = location.altitude
        self.locationTimestamp = location.timestamp
        self.wallClockTimestamp = wallClockTimestamp
        if #available(iOS 15.0, *) {
            self.isSimulatedBySoftware = location.sourceInformation?.isSimulatedBySoftware
            self.isProducedByAccessory = location.sourceInformation?.isProducedByAccessory
        } else {
            self.isSimulatedBySoftware = nil
            self.isProducedByAccessory = nil
        }
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
