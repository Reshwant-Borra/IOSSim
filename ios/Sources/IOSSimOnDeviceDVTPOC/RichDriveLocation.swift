import CoreLocation
import Foundation

public struct RichDriveSample: Codable, Equatable, Sendable {
  public static let provenAltitudeMeters = 123.0
  public static let provenHorizontalAccuracyMeters = 4.0
  public static let provenVerticalAccuracyMeters = 2.0

  public let latitude: Double
  public let longitude: Double
  public let speedMetersPerSecond: Double
  public let courseDegrees: Double
  public let altitude: Double
  public let horizontalAccuracy: Double
  public let verticalAccuracy: Double
  public let timestamp: Date

  public init(
    latitude: Double,
    longitude: Double,
    speedMetersPerSecond: Double,
    courseDegrees: Double,
    altitude: Double = Self.provenAltitudeMeters,
    horizontalAccuracy: Double = Self.provenHorizontalAccuracyMeters,
    verticalAccuracy: Double = Self.provenVerticalAccuracyMeters,
    timestamp: Date = Date()
  ) {
    self.latitude = latitude
    self.longitude = longitude
    self.speedMetersPerSecond = max(0, speedMetersPerSecond)
    self.courseDegrees = Self.normalizedCourse(courseDegrees)
    self.altitude = altitude
    self.horizontalAccuracy = horizontalAccuracy
    self.verticalAccuracy = verticalAccuracy
    self.timestamp = timestamp
  }

  public var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  public static func normalizedCourse(_ degrees: Double) -> Double {
    guard degrees.isFinite else { return 0 }
    let value = degrees.truncatingRemainder(dividingBy: 360)
    return value >= 0 ? value : value + 360
  }
}

public enum RichDriveSampleBuilder {
  public static let defaultCourseLookaheadMeters = 5.0

  public static func sample(
    position: DrivePosition,
    route: RouteResampler,
    speedMetersPerSecond: Double,
    previousCourseDegrees: Double?,
    timestamp: Date = Date(),
    courseLookaheadMeters: CLLocationDistance = defaultCourseLookaheadMeters
  ) -> RichDriveSample {
    let course =
      route.courseDegrees(
        atDistance: position.expectedDistanceMeters,
        lookaheadMeters: courseLookaheadMeters,
        previousCourseDegrees: previousCourseDegrees
      ) ?? previousCourseDegrees ?? 0
    return RichDriveSample(
      latitude: position.coordinate.latitude,
      longitude: position.coordinate.longitude,
      speedMetersPerSecond: speedMetersPerSecond,
      courseDegrees: course,
      timestamp: timestamp
    )
  }
}

extension RouteResampler {
  public func courseDegrees(
    atDistance meters: CLLocationDistance,
    lookaheadMeters: CLLocationDistance = RichDriveSampleBuilder.defaultCourseLookaheadMeters,
    previousCourseDegrees: Double? = nil
  ) -> Double? {
    guard totalDistanceMeters > 0 else { return previousCourseDegrees }
    let clamped = min(max(0, meters), totalDistanceMeters)
    let forwardDistance = min(totalDistanceMeters, clamped + max(0.5, lookaheadMeters))
    if forwardDistance > clamped {
      let current = coordinate(atDistance: clamped)
      let forward = coordinate(atDistance: forwardDistance)
      if let bearing = DriveTraceMetrics.bearingDegrees(from: current, to: forward) {
        return RichDriveSample.normalizedCourse(bearing)
      }
    }

    let backwardDistance = max(0, clamped - max(0.5, lookaheadMeters))
    if clamped > backwardDistance {
      let backward = coordinate(atDistance: backwardDistance)
      let current = coordinate(atDistance: clamped)
      if let bearing = DriveTraceMetrics.bearingDegrees(from: backward, to: current) {
        return RichDriveSample.normalizedCourse(bearing)
      }
    }

    return previousCourseDegrees.map(RichDriveSample.normalizedCourse)
  }
}

public enum RichDriveIPCMessageType: String, Codable, Sendable {
  case startSession = "START_SESSION"
  case setLocation = "SET_LOCATION"
  case stopSession = "STOP_SESSION"
  case ping = "PING"
}

public struct RichDriveIPCMessage: Codable, Equatable, Sendable {
  public let type: RichDriveIPCMessageType
  public let sequence: Int
  public let sessionID: String?
  public let sample: RichDriveSample?

  public init(
    type: RichDriveIPCMessageType, sequence: Int, sessionID: String? = nil,
    sample: RichDriveSample? = nil
  ) {
    self.type = type
    self.sequence = sequence
    self.sessionID = sessionID
    self.sample = sample
  }
}

public struct RichDriveIPCAcknowledgement: Codable, Equatable, Sendable {
  public let type: String
  public let sequence: Int
  public let status: String
  public let message: String?

  public init(type: String = "ACK", sequence: Int, status: String = "OK", message: String? = nil) {
    self.type = type
    self.sequence = sequence
    self.status = status
    self.message = message
  }
}

public enum RichDriveIPCCodec {
  public static func encodeLine(_ message: RichDriveIPCMessage) throws -> Data {
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)
    return data
  }

  public static func decodeMessageLine(_ data: Data) throws -> RichDriveIPCMessage {
    try JSONDecoder().decode(RichDriveIPCMessage.self, from: data)
  }

  public static func decodeAcknowledgementLine(_ data: Data) throws -> RichDriveIPCAcknowledgement {
    try JSONDecoder().decode(RichDriveIPCAcknowledgement.self, from: data)
  }
}

public struct RichDriveLatestSampleBuffer: Sendable {
  private var inFlightSequence: Int?
  private var latestPending: RichDriveSample?
  private var replacedCount = 0

  public init() {}

  public mutating func markInFlight(sequence: Int) {
    inFlightSequence = sequence
  }

  public mutating func offerWhileInFlight(_ sample: RichDriveSample) {
    if latestPending != nil {
      replacedCount += 1
    }
    latestPending = sample
  }

  public mutating func completeInFlight() -> RichDriveSample? {
    inFlightSequence = nil
    defer { latestPending = nil }
    return latestPending
  }

  public var droppedOrReplacedCount: Int {
    replacedCount
  }
}
