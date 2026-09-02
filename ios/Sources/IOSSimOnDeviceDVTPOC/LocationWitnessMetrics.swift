import Foundation

public struct LocationWitnessObservation: Codable, Equatable, Sendable {
  public let sequence: Int
  public let latitude: Double
  public let longitude: Double
  public let speed: Double
  public let course: Double
  public let horizontalAccuracy: Double
  public let verticalAccuracy: Double
  public let altitude: Double
  public let locationTimestamp: Date
  public let wallClockTimestamp: Date
  public let isSimulatedBySoftware: Bool?
  public let isProducedByAccessory: Bool?

  public init(
    sequence: Int,
    latitude: Double,
    longitude: Double,
    speed: Double,
    course: Double,
    horizontalAccuracy: Double,
    verticalAccuracy: Double,
    altitude: Double,
    locationTimestamp: Date,
    wallClockTimestamp: Date,
    isSimulatedBySoftware: Bool?,
    isProducedByAccessory: Bool?
  ) {
    self.sequence = sequence
    self.latitude = latitude
    self.longitude = longitude
    self.speed = speed
    self.course = course
    self.horizontalAccuracy = horizontalAccuracy
    self.verticalAccuracy = verticalAccuracy
    self.altitude = altitude
    self.locationTimestamp = locationTimestamp
    self.wallClockTimestamp = wallClockTimestamp
    self.isSimulatedBySoftware = isSimulatedBySoftware
    self.isProducedByAccessory = isProducedByAccessory
  }

  public var sourceSegment: String {
    switch isSimulatedBySoftware {
    case .some(true): return "simulated"
    case .some(false): return "real_device"
    case .none: return "unknown"
    }
  }
}

public struct LocationWitnessExportObservation: Codable, Equatable, Sendable {
  public let sequence: Int
  public let latitude: Double
  public let longitude: Double
  public let speed: Double
  public let course: Double
  public let horizontalAccuracy: Double
  public let verticalAccuracy: Double
  public let altitude: Double
  public let locationTimestamp: Date
  public let wallClockTimestamp: Date
  public let isSimulatedBySoftware: Bool?
  public let isProducedByAccessory: Bool?
  public let sourceSegment: String

  public init(_ observation: LocationWitnessObservation) {
    sequence = observation.sequence
    latitude = observation.latitude
    longitude = observation.longitude
    speed = observation.speed
    course = observation.course
    horizontalAccuracy = observation.horizontalAccuracy
    verticalAccuracy = observation.verticalAccuracy
    altitude = observation.altitude
    locationTimestamp = observation.locationTimestamp
    wallClockTimestamp = observation.wallClockTimestamp
    isSimulatedBySoftware = observation.isSimulatedBySoftware
    isProducedByAccessory = observation.isProducedByAccessory
    sourceSegment = observation.sourceSegment
  }
}

public struct LocationWitnessCoordinate: Codable, Equatable, Sendable {
  public let latitude: Double
  public let longitude: Double
}

public struct LocationWitnessExportMetadata: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let formatVersion: Int
  public let app: String
  public let isRecording: Bool
  public let rawCallbackCount: Int

  enum CodingKeys: String, CodingKey {
    case generatedAt = "generated_at"
    case formatVersion = "format_version"
    case app
    case isRecording = "is_recording"
    case rawCallbackCount = "raw_callback_count"
  }
}

public struct LocationWitnessMetricsSummary: Codable, Equatable, Sendable {
  public let recordingStartTimestamp: Date?
  public let recordingStopTimestamp: Date?
  public let recordingDurationSeconds: Double
  public let totalObservationCount: Int
  public let simulatedObservationCount: Int
  public let realDeviceObservationCount: Int
  public let unknownSourceObservationCount: Int
  public let speedValidCount: Int
  public let speedValidPercent: Double
  public let courseValidCount: Int
  public let courseValidPercent: Double
  public let speedMinMps: Double?
  public let speedMedianMps: Double?
  public let speedMeanMps: Double?
  public let speedMaxMps: Double?
  public let courseMinDeg: Double?
  public let courseMaxDeg: Double?
  public let simulatedBySoftwareCount: Int
  public let simulatedBySoftwarePercent: Double
  public let producedByAccessoryCount: Int
  public let producedByAccessoryPercent: Double
  public let callbackIntervalCount: Int
  public let callbackIntervalMinS: Double?
  public let callbackIntervalMedianS: Double?
  public let callbackIntervalMeanS: Double?
  public let callbackIntervalP95S: Double?
  public let callbackIntervalMaxS: Double?
  public let effectiveCallbackHz: Double?
  public let firstSimulatedCoordinate: LocationWitnessCoordinate?
  public let lastSimulatedCoordinate: LocationWitnessCoordinate?
  public let duplicateCoordinateCount: Int
  public let obviousOutlierOrSnapbackCount: Int
  public let simulatedSpeedValidCount: Int
  public let simulatedSpeedValidPercent: Double
  public let simulatedCourseValidCount: Int
  public let simulatedCourseValidPercent: Double
  public let simulatedSpeedMinMps: Double?
  public let simulatedSpeedMedianMps: Double?
  public let simulatedSpeedMeanMps: Double?
  public let simulatedSpeedMaxMps: Double?
  public let simulatedEffectiveCallbackHz: Double?

  enum CodingKeys: String, CodingKey {
    case recordingStartTimestamp = "recording_start_timestamp"
    case recordingStopTimestamp = "recording_stop_timestamp"
    case recordingDurationSeconds = "recording_duration_seconds"
    case totalObservationCount = "total_observation_count"
    case simulatedObservationCount = "simulated_observation_count"
    case realDeviceObservationCount = "real_device_observation_count"
    case unknownSourceObservationCount = "unknown_source_observation_count"
    case speedValidCount = "speed_valid_count"
    case speedValidPercent = "speed_valid_percent"
    case courseValidCount = "course_valid_count"
    case courseValidPercent = "course_valid_percent"
    case speedMinMps = "speed_min_mps"
    case speedMedianMps = "speed_median_mps"
    case speedMeanMps = "speed_mean_mps"
    case speedMaxMps = "speed_max_mps"
    case courseMinDeg = "course_min_deg"
    case courseMaxDeg = "course_max_deg"
    case simulatedBySoftwareCount = "simulated_by_software_count"
    case simulatedBySoftwarePercent = "simulated_by_software_percent"
    case producedByAccessoryCount = "produced_by_accessory_count"
    case producedByAccessoryPercent = "produced_by_accessory_percent"
    case callbackIntervalCount = "callback_interval_count"
    case callbackIntervalMinS = "callback_interval_min_s"
    case callbackIntervalMedianS = "callback_interval_median_s"
    case callbackIntervalMeanS = "callback_interval_mean_s"
    case callbackIntervalP95S = "callback_interval_p95_s"
    case callbackIntervalMaxS = "callback_interval_max_s"
    case effectiveCallbackHz = "effective_callback_hz"
    case firstSimulatedCoordinate = "first_simulated_coordinate"
    case lastSimulatedCoordinate = "last_simulated_coordinate"
    case duplicateCoordinateCount = "duplicate_coordinate_count"
    case obviousOutlierOrSnapbackCount = "obvious_outlier_or_snapback_count"
    case simulatedSpeedValidCount = "simulated_speed_valid_count"
    case simulatedSpeedValidPercent = "simulated_speed_valid_percent"
    case simulatedCourseValidCount = "simulated_course_valid_count"
    case simulatedCourseValidPercent = "simulated_course_valid_percent"
    case simulatedSpeedMinMps = "simulated_speed_min_mps"
    case simulatedSpeedMedianMps = "simulated_speed_median_mps"
    case simulatedSpeedMeanMps = "simulated_speed_mean_mps"
    case simulatedSpeedMaxMps = "simulated_speed_max_mps"
    case simulatedEffectiveCallbackHz = "simulated_effective_callback_hz"
  }
}

public struct LocationWitnessSpeedPlateau: Codable, Equatable, Sendable {
  public let approximateMps: Double
  public let approximateMph: Double
  public let startSequence: Int
  public let endSequence: Int
  public let duration: Double
  public let observationCount: Int

  enum CodingKeys: String, CodingKey {
    case approximateMps = "approximate_mps"
    case approximateMph = "approximate_mph"
    case startSequence = "start_sequence"
    case endSequence = "end_sequence"
    case duration
    case observationCount = "observation_count"
  }
}

public struct LocationWitnessMetricsDocument: Codable, Equatable, Sendable {
  public let metadata: LocationWitnessExportMetadata
  public let summary: LocationWitnessMetricsSummary
  public let simulatedSummary: LocationWitnessMetricsSummary
  public let speedPlateaus: [LocationWitnessSpeedPlateau]
  public let observations: [LocationWitnessExportObservation]

  enum CodingKeys: String, CodingKey {
    case metadata
    case summary
    case simulatedSummary = "simulated_summary"
    case speedPlateaus = "speed_plateaus"
    case observations
  }
}

public enum LocationWitnessMetricsExporter {
  public static func document(
    observations: [LocationWitnessObservation],
    rawCallbackCount: Int,
    isRecording: Bool,
    recordingStartTimestamp: Date?,
    recordingStopTimestamp: Date?,
    generatedAt: Date = Date()
  ) -> LocationWitnessMetricsDocument {
    let sorted = observations.sorted { $0.sequence < $1.sequence }
    let simulated = sorted.filter { $0.isSimulatedBySoftware == true }
    return LocationWitnessMetricsDocument(
      metadata: LocationWitnessExportMetadata(
        generatedAt: generatedAt,
        formatVersion: 1,
        app: "IOSSimLocationWitness",
        isRecording: isRecording,
        rawCallbackCount: rawCallbackCount
      ),
      summary: summary(
        observations: sorted,
        fullRecordingObservations: sorted,
        recordingStartTimestamp: recordingStartTimestamp,
        recordingStopTimestamp: recordingStopTimestamp
      ),
      simulatedSummary: summary(
        observations: simulated,
        fullRecordingObservations: sorted,
        recordingStartTimestamp: recordingStartTimestamp,
        recordingStopTimestamp: recordingStopTimestamp
      ),
      speedPlateaus: speedPlateaus(in: simulated),
      observations: sorted.map(LocationWitnessExportObservation.init)
    )
  }

  public static func jsonData(for document: LocationWitnessMetricsDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(document)
  }

  public static func fileName(generatedAt: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "IOSSim-Witness-Metrics-\(formatter.string(from: generatedAt)).json"
  }

  private static func summary(
    observations: [LocationWitnessObservation],
    fullRecordingObservations: [LocationWitnessObservation],
    recordingStartTimestamp: Date?,
    recordingStopTimestamp: Date?
  ) -> LocationWitnessMetricsSummary {
    let validSpeeds = observations.map(\.speed).filter(isValidSpeed)
    let validCourses = observations.map(\.course).filter(isValidCourse)
    let simulated = observations.filter { $0.isSimulatedBySoftware == true }
    let validSimulatedSpeeds = simulated.map(\.speed).filter(isValidSpeed)
    let validSimulatedCourses = simulated.map(\.course).filter(isValidCourse)
    let callbackIntervals = intervals(in: observations)
    let simulatedCoordinates = fullRecordingObservations.filter { $0.isSimulatedBySoftware == true }
    let start = recordingStartTimestamp ?? fullRecordingObservations.first?.wallClockTimestamp
    let stop = recordingStopTimestamp ?? fullRecordingObservations.last?.wallClockTimestamp ?? start

    return LocationWitnessMetricsSummary(
      recordingStartTimestamp: start,
      recordingStopTimestamp: stop,
      recordingDurationSeconds: durationSeconds(start: start, stop: stop),
      totalObservationCount: observations.count,
      simulatedObservationCount: simulated.count,
      realDeviceObservationCount: observations.filter { $0.isSimulatedBySoftware == false }.count,
      unknownSourceObservationCount: observations.filter { $0.isSimulatedBySoftware == nil }.count,
      speedValidCount: validSpeeds.count,
      speedValidPercent: percent(validSpeeds.count, observations.count),
      courseValidCount: validCourses.count,
      courseValidPercent: percent(validCourses.count, observations.count),
      speedMinMps: validSpeeds.min(),
      speedMedianMps: median(validSpeeds),
      speedMeanMps: mean(validSpeeds),
      speedMaxMps: validSpeeds.max(),
      courseMinDeg: validCourses.min(),
      courseMaxDeg: validCourses.max(),
      simulatedBySoftwareCount: simulated.count,
      simulatedBySoftwarePercent: percent(simulated.count, observations.count),
      producedByAccessoryCount: observations.filter { $0.isProducedByAccessory == true }.count,
      producedByAccessoryPercent: percent(
        observations.filter { $0.isProducedByAccessory == true }.count, observations.count),
      callbackIntervalCount: callbackIntervals.count,
      callbackIntervalMinS: callbackIntervals.min(),
      callbackIntervalMedianS: median(callbackIntervals),
      callbackIntervalMeanS: mean(callbackIntervals),
      callbackIntervalP95S: percentile(callbackIntervals, 0.95),
      callbackIntervalMaxS: callbackIntervals.max(),
      effectiveCallbackHz: effectiveHz(for: observations),
      firstSimulatedCoordinate: simulatedCoordinates.first.map {
        LocationWitnessCoordinate(latitude: $0.latitude, longitude: $0.longitude)
      },
      lastSimulatedCoordinate: simulatedCoordinates.last.map {
        LocationWitnessCoordinate(latitude: $0.latitude, longitude: $0.longitude)
      },
      duplicateCoordinateCount: duplicateCoordinateCount(in: observations),
      obviousOutlierOrSnapbackCount: obviousOutlierOrSnapbackCount(in: observations),
      simulatedSpeedValidCount: validSimulatedSpeeds.count,
      simulatedSpeedValidPercent: percent(validSimulatedSpeeds.count, simulated.count),
      simulatedCourseValidCount: validSimulatedCourses.count,
      simulatedCourseValidPercent: percent(validSimulatedCourses.count, simulated.count),
      simulatedSpeedMinMps: validSimulatedSpeeds.min(),
      simulatedSpeedMedianMps: median(validSimulatedSpeeds),
      simulatedSpeedMeanMps: mean(validSimulatedSpeeds),
      simulatedSpeedMaxMps: validSimulatedSpeeds.max(),
      simulatedEffectiveCallbackHz: effectiveHz(for: simulated)
    )
  }

  private static func intervals(in observations: [LocationWitnessObservation]) -> [Double] {
    guard observations.count >= 2 else { return [] }
    return zip(observations.dropFirst(), observations).compactMap { current, previous in
      let interval = current.wallClockTimestamp.timeIntervalSince(previous.wallClockTimestamp)
      return interval.isFinite && interval >= 0 ? interval : nil
    }
  }

  private static func effectiveHz(for observations: [LocationWitnessObservation]) -> Double? {
    guard observations.count >= 2,
      let first = observations.first?.wallClockTimestamp,
      let last = observations.last?.wallClockTimestamp
    else { return nil }
    let duration = last.timeIntervalSince(first)
    guard duration > 0 else { return nil }
    return Double(observations.count - 1) / duration
  }

  private static func duplicateCoordinateCount(in observations: [LocationWitnessObservation])
    -> Int
  {
    guard observations.count >= 2 else { return 0 }
    return zip(observations.dropFirst(), observations).filter { current, previous in
      abs(current.latitude - previous.latitude) <= 0.00000001
        && abs(current.longitude - previous.longitude) <= 0.00000001
    }.count
  }

  private static func obviousOutlierOrSnapbackCount(in observations: [LocationWitnessObservation])
    -> Int
  {
    guard observations.count >= 3 else { return 0 }
    var count = 0
    for index in 1..<(observations.count - 1) {
      let before = observations[index - 1]
      let current = observations[index]
      let after = observations[index + 1]
      let jumpOut = approximateDistanceMeters(from: before, to: current)
      let snapBack = approximateDistanceMeters(from: before, to: after)
      if jumpOut > 1_000 && snapBack < 25 {
        count += 1
      }
    }
    return count
  }

  private static func speedPlateaus(in observations: [LocationWitnessObservation])
    -> [LocationWitnessSpeedPlateau]
  {
    let toleranceMps = 0.75
    var plateaus: [LocationWitnessSpeedPlateau] = []
    var current: [LocationWitnessObservation] = []

    func finish(_ points: [LocationWitnessObservation]) -> LocationWitnessSpeedPlateau? {
      guard points.count >= 2 else { return nil }
      let speeds = points.map(\.speed).filter(isValidSpeed)
      guard let approximateMps = mean(speeds), let first = points.first, let last = points.last
      else { return nil }
      return LocationWitnessSpeedPlateau(
        approximateMps: approximateMps,
        approximateMph: approximateMps / 0.44704,
        startSequence: first.sequence,
        endSequence: last.sequence,
        duration: max(0, last.wallClockTimestamp.timeIntervalSince(first.wallClockTimestamp)),
        observationCount: points.count
      )
    }

    for observation in observations where isValidSpeed(observation.speed) {
      if current.isEmpty {
        current = [observation]
        continue
      }
      let currentMean = mean(current.map(\.speed).filter(isValidSpeed)) ?? observation.speed
      if abs(observation.speed - currentMean) <= toleranceMps {
        current.append(observation)
      } else {
        if let plateau = finish(current) {
          plateaus.append(plateau)
        }
        current = [observation]
      }
    }
    if let plateau = finish(current) {
      plateaus.append(plateau)
    }
    return plateaus
  }

  private static func isValidSpeed(_ value: Double) -> Bool {
    value.isFinite && value >= 0
  }

  private static func isValidCourse(_ value: Double) -> Bool {
    value.isFinite && value >= 0 && value < 360
  }

  private static func percent(_ numerator: Int, _ denominator: Int) -> Double {
    guard denominator > 0 else { return 0 }
    return Double(numerator) / Double(denominator) * 100
  }

  private static func durationSeconds(start: Date?, stop: Date?) -> Double {
    guard let start, let stop else { return 0 }
    return max(0, stop.timeIntervalSince(start))
  }

  private static func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  private static func median(_ values: [Double]) -> Double? {
    percentile(values, 0.5)
  }

  private static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return nil }
    guard sorted.count > 1 else { return sorted[0] }
    let clamped = min(max(percentile, 0), 1)
    let rank = clamped * Double(sorted.count - 1)
    let lower = Int(floor(rank))
    let upper = Int(ceil(rank))
    if lower == upper {
      return sorted[lower]
    }
    let fraction = rank - Double(lower)
    return sorted[lower] + ((sorted[upper] - sorted[lower]) * fraction)
  }

  private static func approximateDistanceMeters(
    from first: LocationWitnessObservation,
    to second: LocationWitnessObservation
  ) -> Double {
    let earthRadiusMeters = 6_371_000.0
    let lat1 = first.latitude * .pi / 180
    let lat2 = second.latitude * .pi / 180
    let deltaLat = (second.latitude - first.latitude) * .pi / 180
    let deltaLon = (second.longitude - first.longitude) * .pi / 180
    let a =
      sin(deltaLat / 2) * sin(deltaLat / 2)
      + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return earthRadiusMeters * c
  }
}
