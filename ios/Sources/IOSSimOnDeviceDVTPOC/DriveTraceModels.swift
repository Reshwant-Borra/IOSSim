import CoreLocation
import Foundation

public struct DriveTraceContext: Sendable {
    public let tickTraceID: String
    public let driveSessionID: String
    public let tickSequence: Int
    public let requestSequence: Int
    public let updateRequestMonotonicTime: TimeInterval
    public let expectedRouteDistanceMeters: CLLocationDistance
    public let previousExpectedRouteDistanceMeters: CLLocationDistance?
    public let expectedCoordinate: CLLocationCoordinate2D
    public let selectedSpeedMetersPerSecond: Double
    public let lifecycleState: String

    public init(
        tickTraceID: String,
        driveSessionID: String,
        tickSequence: Int,
        requestSequence: Int,
        updateRequestMonotonicTime: TimeInterval,
        expectedRouteDistanceMeters: CLLocationDistance,
        previousExpectedRouteDistanceMeters: CLLocationDistance?,
        expectedCoordinate: CLLocationCoordinate2D,
        selectedSpeedMetersPerSecond: Double,
        lifecycleState: String
    ) {
        self.tickTraceID = tickTraceID
        self.driveSessionID = driveSessionID
        self.tickSequence = tickSequence
        self.requestSequence = requestSequence
        self.updateRequestMonotonicTime = updateRequestMonotonicTime
        self.expectedRouteDistanceMeters = expectedRouteDistanceMeters
        self.previousExpectedRouteDistanceMeters = previousExpectedRouteDistanceMeters
        self.expectedCoordinate = expectedCoordinate
        self.selectedSpeedMetersPerSecond = selectedSpeedMetersPerSecond
        self.lifecycleState = lifecycleState
    }
}
public struct DriveDVTSetTrace: Sendable {
    public let tickTraceID: String?
    public let requestSequence: Int?
    public let driveSessionID: String?
    public let writerID: String
    public let connectionGeneration: Int
    public let beginMonotonicTime: TimeInterval
    public let endMonotonicTime: TimeInterval
    public let success: Bool
    public let nativeErrorCategory: String?

    public var durationMs: Double {
        max(0, endMonotonicTime - beginMonotonicTime) * 1000
    }
}

public struct DriveTimingStatistics: Codable, Equatable, Sendable {
    public let count: Int
    public let meanMs: Double?
    public let medianMs: Double?
    public let p95Ms: Double?
    public let maxMs: Double?

    public static let empty = DriveTimingStatistics(count: 0, meanMs: nil, medianMs: nil, p95Ms: nil, maxMs: nil)
}

public struct DriveCharacterizationSummary: Codable, Equatable, Sendable {
    public let totalDriveDuration: TimeInterval
    public let totalSchedulerTicks: Int
    public let totalDVTSetCalls: Int
    public let totalObservedCLLocations: Int
    public let schedulerIntervals: DriveTimingStatistics
    public let schedulerWakeJitter: DriveTimingStatistics
    public let dvtSetDurations: DriveTimingStatistics
    public let coreLocationPropagationLatencies: DriveTimingStatistics
    public let selectedSpeedMps: Double?
    public let meanRequestedGeometricSpeedMps: Double?
    public let meanObservedGeometricSpeedMps: Double?
    public let percentageOfCLLocationsWithValidSpeed: Double?
    public let meanCLLocationSpeedWhenValid: Double?
    public let foregroundSchedulerIntervals: DriveTimingStatistics
    public let backgroundSchedulerIntervals: DriveTimingStatistics
    public let lockedSchedulerIntervals: DriveTimingStatistics
    public let schedulerStallCount: Int
    public let dvtSetStallCount: Int
    public let coreLocationObservationStallCount: Int
    public let burstyProgressCount: Int
    public let snapBackCount: Int
}

public enum DriveTraceMetrics {
    public static func timingStatistics(milliseconds values: [Double]) -> DriveTimingStatistics {
        let values = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !values.isEmpty else { return .empty }
        let mean = values.reduce(0, +) / Double(values.count)
        return DriveTimingStatistics(
            count: values.count,
            meanMs: mean,
            medianMs: percentile(values, percentile: 0.50),
            p95Ms: percentile(values, percentile: 0.95),
            maxMs: values.last
        )
    }

    public static func percentile(_ sortedValues: [Double], percentile: Double) -> Double? {
        let values = sortedValues.sorted()
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values[0] }
        let clamped = min(max(0, percentile), 1)
        let index = clamped * Double(values.count - 1)
        let lower = Int(index.rounded(.down))
        let upper = Int(index.rounded(.up))
        if lower == upper { return values[lower] }
        let fraction = index - Double(lower)
        return values[lower] + (values[upper] - values[lower]) * fraction
    }

    public static func schedulerWakeJitterMs(expectedWake: TimeInterval, actualWake: TimeInterval) -> Double {
        (actualWake - expectedWake) * 1000
    }

    public static func durationMs(begin: TimeInterval, end: TimeInterval) -> Double {
        max(0, end - begin) * 1000
    }

    public static func speedMetersPerSecond(distanceDeltaMeters: Double, elapsedSeconds: TimeInterval) -> Double? {
        guard elapsedSeconds > 0 else { return nil }
        return distanceDeltaMeters / elapsedSeconds
    }

    public static func bearingDegrees(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double? {
        guard CLLocationCoordinate2DIsValid(from), CLLocationCoordinate2DIsValid(to) else { return nil }
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLongitude = (to.longitude - from.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    public static func validCLLocationSpeed(_ speed: Double?) -> Bool {
        guard let speed else { return false }
        return speed.isFinite && speed >= 0
    }

    public static func isSchedulerStall(intervalMs: Double, targetIntervalMs: Double) -> Bool {
        intervalMs > targetIntervalMs * 2.5
    }

    public static func isDVTSetStall(durationMs: Double, thresholdMs: Double = 750) -> Bool {
        durationMs > thresholdMs
    }

    public static func isCoreLocationObservationStall(intervalMs: Double, thresholdMs: Double = 3_000) -> Bool {
        intervalMs > thresholdMs
    }

    public static func isBurstyProgress(
        actualDistanceDelta: Double,
        expectedDistanceDelta: Double,
        previousTickIntervalMs: Double,
        targetIntervalMs: Double
    ) -> Bool {
        previousTickIntervalMs > targetIntervalMs * 2.5 && actualDistanceDelta > expectedDistanceDelta * 1.8
    }
}
