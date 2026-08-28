import CoreLocation
import Foundation

public struct AppleLocationControlObservation: Codable, Equatable, Sendable {
    public let sequence: Int
    public let wallClockTimestamp: Date
    public let monotonicTimestamp: TimeInterval
    public let locationTimestamp: Date
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double
    public let altitude: Double
    public let altitudeValid: Bool
    public let rawSpeed: Double
    public let speedValid: Bool
    public let normalizedSpeed: Double?
    public let speedAccuracy: Double?
    public let rawCourse: Double
    public let courseValid: Bool
    public let normalizedCourse: Double?
    public let courseAccuracy: Double?
    public let isSimulatedBySoftware: Bool?
    public let isProducedByAccessory: Bool?

    public init(
        sequence: Int,
        wallClockTimestamp: Date = Date(),
        monotonicTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        location: CLLocation
    ) {
        self.sequence = sequence
        self.wallClockTimestamp = wallClockTimestamp
        self.monotonicTimestamp = monotonicTimestamp
        self.locationTimestamp = location.timestamp
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
        self.altitude = location.altitude
        self.altitudeValid = location.verticalAccuracy >= 0
        self.rawSpeed = location.speed
        self.speedValid = location.speed.isFinite && location.speed >= 0
        self.normalizedSpeed = self.speedValid ? location.speed : nil
        if #available(iOS 10.0, macOS 10.15, *) {
            self.speedAccuracy = location.speedAccuracy
        } else {
            self.speedAccuracy = nil
        }
        self.rawCourse = location.course
        self.courseValid = location.course.isFinite && location.course >= 0
        self.normalizedCourse = self.courseValid ? location.course : nil
        if #available(iOS 13.4, macOS 10.15, *) {
            self.courseAccuracy = location.courseAccuracy
        } else {
            self.courseAccuracy = nil
        }
        if #available(iOS 15.0, macOS 12.0, *) {
            self.isSimulatedBySoftware = location.sourceInformation?.isSimulatedBySoftware
            self.isProducedByAccessory = location.sourceInformation?.isProducedByAccessory
        } else {
            self.isSimulatedBySoftware = nil
            self.isProducedByAccessory = nil
        }
    }

    public init(
        sequence: Int,
        wallClockTimestamp: Date,
        monotonicTimestamp: TimeInterval,
        locationTimestamp: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        altitude: Double,
        rawSpeed: Double,
        speedAccuracy: Double?,
        rawCourse: Double,
        courseAccuracy: Double?,
        isSimulatedBySoftware: Bool?,
        isProducedByAccessory: Bool?
    ) {
        self.sequence = sequence
        self.wallClockTimestamp = wallClockTimestamp
        self.monotonicTimestamp = monotonicTimestamp
        self.locationTimestamp = locationTimestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.altitude = altitude
        self.altitudeValid = verticalAccuracy >= 0
        self.rawSpeed = rawSpeed
        self.speedValid = rawSpeed.isFinite && rawSpeed >= 0
        self.normalizedSpeed = self.speedValid ? rawSpeed : nil
        self.speedAccuracy = speedAccuracy
        self.rawCourse = rawCourse
        self.courseValid = rawCourse.isFinite && rawCourse >= 0
        self.normalizedCourse = self.courseValid ? rawCourse : nil
        self.courseAccuracy = courseAccuracy
        self.isSimulatedBySoftware = isSimulatedBySoftware
        self.isProducedByAccessory = isProducedByAccessory
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

public struct AppleLocationControlPairMeasurement: Codable, Equatable, Sendable {
    public let fromSequence: Int
    public let toSequence: Int
    public let callbackIntervalMs: Double
    public let locationTimestampIntervalMs: Double
    public let distanceMeters: Double
    public let geometricSpeedFromCallbackTimestampsMps: Double?
    public let geometricSpeedFromLocationTimestampsMps: Double?
    public let bearingDegrees: Double?
    public let nativeSpeedMinusCallbackGeometricSpeedMps: Double?
    public let nativeSpeedMinusLocationGeometricSpeedMps: Double?
}

public struct AppleLocationControlStatistics: Codable, Equatable, Sendable {
    public let count: Int
    public let mean: Double?
    public let median: Double?
    public let p95: Double?
    public let max: Double?

    public static let empty = AppleLocationControlStatistics(
        count: 0,
        mean: nil,
        median: nil,
        p95: nil,
        max: nil
    )
}

public struct AppleLocationControlSummary: Codable, Equatable, Sendable {
    public let observationCount: Int
    public let durationSeconds: Double?
    public let requestedVelocityMps: Double
    public let effectiveObservationHz: Double?
    public let callbackIntervalMs: AppleLocationControlStatistics
    public let locationTimestampIntervalMs: AppleLocationControlStatistics
    public let distanceMeters: AppleLocationControlStatistics
    public let geometricSpeedFromCallbackTimestampsMps: AppleLocationControlStatistics
    public let geometricSpeedFromLocationTimestampsMps: AppleLocationControlStatistics
    public let nativeSpeedValidCount: Int
    public let nativeSpeedValidityPercent: Double?
    public let nativeCourseValidCount: Int
    public let nativeCourseValidityPercent: Double?
    public let meanNativeSpeedWhenValidMps: Double?
    public let meanNativeSpeedMinusCallbackGeometricSpeedMps: Double?
    public let meanNativeSpeedMinusLocationGeometricSpeedMps: Double?
    public let altitudeValidityPercent: Double?
    public let simulatedBySoftwareTruePercent: Double?
    public let producedByAccessoryTruePercent: Double?
}

public enum AppleLocationControlAnalysis {
    public static func pairMeasurements(
        for observations: [AppleLocationControlObservation]
    ) -> [AppleLocationControlPairMeasurement] {
        guard observations.count > 1 else { return [] }
        return zip(observations, observations.dropFirst()).map { previous, current in
            let callbackIntervalMs = max(0, current.monotonicTimestamp - previous.monotonicTimestamp) * 1000
            let locationTimestampIntervalMs = max(
                0,
                current.locationTimestamp.timeIntervalSince(previous.locationTimestamp)
            ) * 1000
            let distance = Self.distanceMeters(from: previous.coordinate, to: current.coordinate)
            let callbackSpeed = speedMetersPerSecond(distanceMeters: distance, intervalMs: callbackIntervalMs)
            let locationSpeed = speedMetersPerSecond(distanceMeters: distance, intervalMs: locationTimestampIntervalMs)
            return AppleLocationControlPairMeasurement(
                fromSequence: previous.sequence,
                toSequence: current.sequence,
                callbackIntervalMs: callbackIntervalMs,
                locationTimestampIntervalMs: locationTimestampIntervalMs,
                distanceMeters: distance,
                geometricSpeedFromCallbackTimestampsMps: callbackSpeed,
                geometricSpeedFromLocationTimestampsMps: locationSpeed,
                bearingDegrees: bearingDegrees(from: previous.coordinate, to: current.coordinate),
                nativeSpeedMinusCallbackGeometricSpeedMps: difference(current.normalizedSpeed, callbackSpeed),
                nativeSpeedMinusLocationGeometricSpeedMps: difference(current.normalizedSpeed, locationSpeed)
            )
        }
    }

    public static func summary(
        for observations: [AppleLocationControlObservation],
        requestedVelocityMps: Double
    ) -> AppleLocationControlSummary {
        let pairs = pairMeasurements(for: observations)
        let durationSeconds: Double?
        if let first = observations.first, let last = observations.last, last.sequence != first.sequence {
            durationSeconds = max(0, last.monotonicTimestamp - first.monotonicTimestamp)
        } else {
            durationSeconds = nil
        }
        let nativeSpeeds = observations.compactMap(\.normalizedSpeed)
        let speedValidity = percentage(count: nativeSpeeds.count, total: observations.count)
        let nativeCourseValidCount = observations.filter(\.courseValid).count
        let courseValidity = percentage(count: nativeCourseValidCount, total: observations.count)
        return AppleLocationControlSummary(
            observationCount: observations.count,
            durationSeconds: durationSeconds,
            requestedVelocityMps: requestedVelocityMps,
            effectiveObservationHz: hz(observationCount: observations.count, durationSeconds: durationSeconds),
            callbackIntervalMs: statistics(pairs.map(\.callbackIntervalMs)),
            locationTimestampIntervalMs: statistics(pairs.map(\.locationTimestampIntervalMs)),
            distanceMeters: statistics(pairs.map(\.distanceMeters)),
            geometricSpeedFromCallbackTimestampsMps: statistics(
                pairs.compactMap(\.geometricSpeedFromCallbackTimestampsMps)
            ),
            geometricSpeedFromLocationTimestampsMps: statistics(
                pairs.compactMap(\.geometricSpeedFromLocationTimestampsMps)
            ),
            nativeSpeedValidCount: nativeSpeeds.count,
            nativeSpeedValidityPercent: speedValidity,
            nativeCourseValidCount: nativeCourseValidCount,
            nativeCourseValidityPercent: courseValidity,
            meanNativeSpeedWhenValidMps: mean(nativeSpeeds),
            meanNativeSpeedMinusCallbackGeometricSpeedMps: mean(
                pairs.compactMap(\.nativeSpeedMinusCallbackGeometricSpeedMps)
            ),
            meanNativeSpeedMinusLocationGeometricSpeedMps: mean(
                pairs.compactMap(\.nativeSpeedMinusLocationGeometricSpeedMps)
            ),
            altitudeValidityPercent: percentage(
                count: observations.filter(\.altitudeValid).count,
                total: observations.count
            ),
            simulatedBySoftwareTruePercent: percentage(
                count: observations.filter { $0.isSimulatedBySoftware == true }.count,
                total: observations.count
            ),
            producedByAccessoryTruePercent: percentage(
                count: observations.filter { $0.isProducedByAccessory == true }.count,
                total: observations.count
            )
        )
    }

    public static func statistics(_ values: [Double]) -> AppleLocationControlStatistics {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return .empty }
        return AppleLocationControlStatistics(
            count: sorted.count,
            mean: mean(sorted),
            median: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            max: sorted.last
        )
    }

    public static func percentage(count: Int, total: Int) -> Double? {
        guard total > 0 else { return nil }
        return Double(count) / Double(total) * 100
    }

    public static func distanceMeters(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    public static func bearingDegrees(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double? {
        guard CLLocationCoordinate2DIsValid(from), CLLocationCoordinate2DIsValid(to) else { return nil }
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLongitude = (to.longitude - from.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    public static func jsonLines(
        observations: [AppleLocationControlObservation],
        summary: AppleLocationControlSummary
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let observationLines = try observations.map { observation in
            try encodedLine(["type": "observation"], value: observation, encoder: encoder)
        }
        let pairLines = try pairMeasurements(for: observations).map { pair in
            try encodedLine(["type": "pair_measurement"], value: pair, encoder: encoder)
        }
        let summaryLine = try encodedLine(["type": "summary"], value: summary, encoder: encoder)
        return (observationLines + pairLines + [summaryLine]).joined(separator: "\n") + "\n"
    }

    public static func summaryText(_ summary: AppleLocationControlSummary) -> String {
        [
            "Apple GPX Core Location Control Summary",
            "observation_count=\(summary.observationCount)",
            "duration_s=\(format(summary.durationSeconds))",
            "requested_velocity_mps=\(format(summary.requestedVelocityMps))",
            "effective_observation_hz=\(format(summary.effectiveObservationHz))",
            "mean_callback_interval_ms=\(format(summary.callbackIntervalMs.mean))",
            "median_callback_interval_ms=\(format(summary.callbackIntervalMs.median))",
            "p95_callback_interval_ms=\(format(summary.callbackIntervalMs.p95))",
            "max_callback_interval_ms=\(format(summary.callbackIntervalMs.max))",
            "mean_location_timestamp_interval_ms=\(format(summary.locationTimestampIntervalMs.mean))",
            "mean_distance_m=\(format(summary.distanceMeters.mean))",
            "median_distance_m=\(format(summary.distanceMeters.median))",
            "p95_distance_m=\(format(summary.distanceMeters.p95))",
            "mean_geometric_speed_callback_mps=\(format(summary.geometricSpeedFromCallbackTimestampsMps.mean))",
            "median_geometric_speed_callback_mps=\(format(summary.geometricSpeedFromCallbackTimestampsMps.median))",
            "p95_geometric_speed_callback_mps=\(format(summary.geometricSpeedFromCallbackTimestampsMps.p95))",
            "mean_geometric_speed_location_timestamp_mps=\(format(summary.geometricSpeedFromLocationTimestampsMps.mean))",
            "native_speed_valid_count=\(summary.nativeSpeedValidCount)",
            "native_speed_validity_percent=\(format(summary.nativeSpeedValidityPercent))",
            "native_course_valid_count=\(summary.nativeCourseValidCount)",
            "native_course_validity_percent=\(format(summary.nativeCourseValidityPercent))",
            "mean_native_speed_when_valid_mps=\(format(summary.meanNativeSpeedWhenValidMps))",
            "mean_native_speed_minus_callback_geometric_speed_mps=\(format(summary.meanNativeSpeedMinusCallbackGeometricSpeedMps))",
            "mean_native_speed_minus_location_geometric_speed_mps=\(format(summary.meanNativeSpeedMinusLocationGeometricSpeedMps))",
            "altitude_validity_percent=\(format(summary.altitudeValidityPercent))",
            "simulated_by_software_true_percent=\(format(summary.simulatedBySoftwareTruePercent))",
            "produced_by_accessory_true_percent=\(format(summary.producedByAccessoryTruePercent))"
        ].joined(separator: "\n") + "\n"
    }

    private static func speedMetersPerSecond(distanceMeters: Double, intervalMs: Double) -> Double? {
        guard intervalMs > 0 else { return nil }
        return distanceMeters / (intervalMs / 1000)
    }

    private static func difference(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func hz(observationCount: Int, durationSeconds: Double?) -> Double? {
        guard observationCount > 1, let durationSeconds, durationSeconds > 0 else { return nil }
        return Double(observationCount - 1) / durationSeconds
    }

    private static func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        if sortedValues.count == 1 { return sortedValues[0] }
        let clamped = min(max(0, percentile), 1)
        let index = clamped * Double(sortedValues.count - 1)
        let lower = Int(index.rounded(.down))
        let upper = Int(index.rounded(.up))
        if lower == upper { return sortedValues[lower] }
        let fraction = index - Double(lower)
        return sortedValues[lower] + (sortedValues[upper] - sortedValues[lower]) * fraction
    }

    private static func encodedLine<T: Encodable>(
        _ envelope: [String: String],
        value: T,
        encoder: JSONEncoder
    ) throws -> String {
        let data = try encoder.encode(JSONLineEnvelope(type: envelope["type"] ?? "unknown", payload: value))
        return String(decoding: data, as: UTF8.self)
    }

    private static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "null" }
        return String(format: "%.3f", value)
    }
}

public final class AppleLocationControlRecorder: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    public typealias ObservationHandler = @Sendable (AppleLocationControlObservation) -> Void
    public typealias AuthorizationHandler = @Sendable (CLAuthorizationStatus) -> Void

    private let manager: CLLocationManager
    private let lock = NSLock()
    private var sequence = 0
    private var observations: [AppleLocationControlObservation] = []
    private var observationHandler: ObservationHandler?
    private var authorizationHandler: AuthorizationHandler?

    public init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        #endif
    }

    public func setObservationHandler(_ handler: ObservationHandler?) {
        lock.lock()
        observationHandler = handler
        lock.unlock()
    }

    public func setAuthorizationHandler(_ handler: AuthorizationHandler?) {
        lock.lock()
        authorizationHandler = handler
        lock.unlock()
    }

    public func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    public func stop() {
        manager.stopUpdatingLocation()
    }

    public func allObservations() -> [AppleLocationControlObservation] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }

    public var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        currentAuthorizationHandler()?(manager.authorizationStatus)
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            let observedAt = Date()
            let monotonicTimestamp = ProcessInfo.processInfo.systemUptime
            let observation = AppleLocationControlObservation(
                sequence: nextSequence(),
                wallClockTimestamp: observedAt,
                monotonicTimestamp: monotonicTimestamp,
                location: location
            )
            lock.lock()
            observations.append(observation)
            let handler = observationHandler
            lock.unlock()
            handler?(observation)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        return sequence
    }

    private func currentAuthorizationHandler() -> AuthorizationHandler? {
        lock.lock()
        defer { lock.unlock() }
        return authorizationHandler
    }
}

private struct JSONLineEnvelope<Payload: Encodable>: Encodable {
    let type: String
    let payload: Payload
}
