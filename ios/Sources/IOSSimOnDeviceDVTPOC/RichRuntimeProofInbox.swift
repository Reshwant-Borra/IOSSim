import CoreLocation
import CryptoKit
import Foundation

public struct RichRuntimeProofInboxRequest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let requestID: String
  public let deviceUDID: String
  public let teamIdentifier: String
  public let releaseIdentity: String
  public let artifactSetIdentity: String
  public let profileSetIdentity: String
  public let pairingGeneration: UInt64
  public let developerServicesSession: String
  public let developerSupportIdentity: String
  public let runnerBundleIdentifier: String
  public let createdAt: Date
}

public struct RichRuntimeProofInboxReceipt: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let requestID: String
  public let deviceUDIDHash: String
  public let teamIdentifier: String
  public let releaseIdentity: String
  public let artifactSetIdentity: String
  public let profileSetIdentity: String
  public let pairingGeneration: UInt64
  public let developerServicesSession: String
  public let developerSupportIdentity: String
  public let runnerBundleIdentifier: String
  public let testManagerControlReady: Bool
  public let runnerLaunched: Bool
  public let xctestHandshakeReady: Bool
  public let testPlanStarted: Bool
  public let richLocationProbeCompleted: Bool
  /// Core Location in Veya observed the DVT LocationSimulation coordinate (Set Location path).
  public let dvtLocationVerified: Bool
  /// Core Location in Veya observed the Rich Drive runner's XCUILocation coordinate (default Drive path).
  public let richLocationVerified: Bool
  public let locationCleared: Bool
  public let sessionCleanedUp: Bool
  public let completedAt: Date
}

/// Setup-only bounded proof of the product location paths: one DVT coordinate
/// and one Rich Drive runner coordinate, each confirmed by Core Location in this
/// app, then cleared. It reuses the product's coordinator and Rich transport and
/// never starts a Drive route.
public actor RichRuntimeProofInboxController {
  public static let schemaVersion = 2
  static let dvtProbeCoordinate = (latitude: 40.758_000, longitude: -73.985_500)
  static let richProbeCoordinate = (latitude: 37.334_900, longitude: -122.009_020)

  public static let requestPath = "Library/Application Support/IOSSim/SetupInbox/rich-runtime-proof.request"
  public static let receiptPath = "Library/Application Support/IOSSim/SetupInbox/rich-runtime-proof.receipt"

  private let appSupportURL: URL
  private let locationCoordinator: LocationCoordinator
  private let tunnelClient: IdeviceOnDeviceTunnelClient
  private let verifier: CoreLocationVerifier
  private let verificationTimeout: TimeInterval
  private let now: @Sendable () -> Date

  /// `verifier` must be created on the main thread so Core Location can deliver callbacks.
  public init(
    appSupportURL: URL? = nil,
    locationCoordinator: LocationCoordinator,
    tunnelClient: IdeviceOnDeviceTunnelClient,
    verifier: CoreLocationVerifier,
    verificationTimeout: TimeInterval = 20,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.appSupportURL = appSupportURL ?? FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("IOSSim", isDirectory: true)
    self.locationCoordinator = locationCoordinator
    self.tunnelClient = tunnelClient
    self.verifier = verifier
    self.verificationTimeout = verificationTimeout
    self.now = now
  }

  public func reconcileIfRequested() async throws -> RichRuntimeProofInboxReceipt? {
    let requestURL = appSupportURL.appendingPathComponent("SetupInbox/rich-runtime-proof.request")
    guard FileManager.default.fileExists(atPath: requestURL.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let request = try decoder.decode(
      RichRuntimeProofInboxRequest.self, from: Data(contentsOf: requestURL))
    guard request.schemaVersion == Self.schemaVersion,
      UUID(uuidString: request.requestID) != nil,
      request.pairingGeneration > 0,
      !request.deviceUDID.isEmpty,
      !request.teamIdentifier.isEmpty,
      !request.releaseIdentity.isEmpty,
      now().timeIntervalSince(request.createdAt) <= 300,
      request.createdAt <= now().addingTimeInterval(5),
      Gate3XCTestRunnerBundleIdentifierResolver.validConfiguredRunnerBundleID(
        request.runnerBundleIdentifier) != nil
    else { throw POCError(.xctestRunnerFailed, "Invalid or expired runtime proof request.") }

    let configuredRunner = Gate3XCTestRunnerBundleIdentifierResolver()
      .resolvedInstalledRunnerBundleID()
    guard configuredRunner == request.runnerBundleIdentifier else {
      throw POCError(.xctestRunnerFailed, "Runtime proof request does not match installed runner identity.")
    }

    let writerID = "setup-proof:\(request.requestID)"
    var dvtVerified = false
    var richVerified = false
    var locationCleared = false
    var sessionCleanedUp = false
    let rich = XCTestRichDriveLocationTransport(
      locationCoordinator: locationCoordinator, runnerClient: tunnelClient,
      runnerTimeoutSeconds: 120)

    verifier.start(backgroundCapable: false)
    do {
      let dvt = Self.dvtProbeCoordinate
      try await locationCoordinator.startSimulation(
        writerID: writerID, mode: .staticLocation(nil))
      try await locationCoordinator.updateLocation(
        latitude: dvt.latitude, longitude: dvt.longitude, writerID: writerID,
        mode: .staticLocation(SimulatedCoordinate(latitude: dvt.latitude, longitude: dvt.longitude)))
      dvtVerified = await verifier.waitForCoordinate(
        latitude: dvt.latitude, longitude: dvt.longitude, timeout: verificationTimeout) != nil

      let target = Self.richProbeCoordinate
      let coordinate = CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude)
      try await rich.start(
        DriveLocationTransportStartContext(
          sessionID: UUID(), writerID: writerID, initialCoordinate: coordinate))
      _ = try await rich.set(
        sample: RichDriveSample(
          latitude: target.latitude, longitude: target.longitude,
          speedMetersPerSecond: 0, courseDegrees: 0),
        writerID: writerID,
        mode: .staticLocation(SimulatedCoordinate(coordinate)),
        traceContext: nil, diagnostics: nil)
      richVerified = await verifier.waitForCoordinate(
        latitude: target.latitude, longitude: target.longitude, timeout: verificationTimeout) != nil
    } catch {
      // Any transport/runner failure leaves the verified flags false; the receipt reports it.
    }
    let stages = Set(tunnelClient.gate3XCTestStatus().events.map(\.stage))

    do {
      // Stops the runner and the DVT session and clears the simulated location.
      try await rich.stop(writerID: writerID, clearLocation: true)
      locationCleared = true
      sessionCleanedUp = true
    } catch {
      // A cleanup failure is represented in the receipt and can never become READY.
    }
    verifier.stop()

    let receipt = RichRuntimeProofInboxReceipt(
      schemaVersion: Self.schemaVersion,
      requestID: request.requestID,
      deviceUDIDHash: Self.hash(request.deviceUDID),
      teamIdentifier: request.teamIdentifier,
      releaseIdentity: request.releaseIdentity,
      artifactSetIdentity: request.artifactSetIdentity,
      profileSetIdentity: request.profileSetIdentity,
      pairingGeneration: request.pairingGeneration,
      developerServicesSession: request.developerServicesSession,
      developerSupportIdentity: request.developerSupportIdentity,
      runnerBundleIdentifier: request.runnerBundleIdentifier,
      testManagerControlReady: stages.contains(.testmanagerControlReady),
      runnerLaunched: stages.contains(.runnerLaunched),
      xctestHandshakeReady: stages.contains(.xctestHandshakeReady),
      testPlanStarted: stages.contains(.testPlanStarted),
      richLocationProbeCompleted: richVerified,
      dvtLocationVerified: dvtVerified,
      richLocationVerified: richVerified,
      locationCleared: locationCleared,
      sessionCleanedUp: sessionCleanedUp,
      completedAt: now()
    )
    try write(receipt, to: appSupportURL.appendingPathComponent("SetupInbox/rich-runtime-proof.receipt"))
    return receipt
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    #if os(iOS)
      try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
    #else
      try encoder.encode(value).write(to: url, options: [.atomic])
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #endif
  }

  private static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
