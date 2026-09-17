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
  public let locationCleared: Bool
  public let sessionCleanedUp: Bool
  public let completedAt: Date
}

/// Setup-only bounded Rich proof. It reuses the product's one location
/// coordinator and retained native XCTest path; it never starts a Drive route.
public actor RichRuntimeProofInboxController {
  public static let requestPath = "Library/Application Support/IOSSim/SetupInbox/rich-runtime-proof.request"
  public static let receiptPath = "Library/Application Support/IOSSim/SetupInbox/rich-runtime-proof.receipt"

  private let appSupportURL: URL
  private let locationCoordinator: LocationCoordinator
  private let tunnelClient: IdeviceOnDeviceTunnelClient
  private let now: @Sendable () -> Date

  public init(
    appSupportURL: URL? = nil,
    locationCoordinator: LocationCoordinator,
    tunnelClient: IdeviceOnDeviceTunnelClient,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.appSupportURL = appSupportURL ?? FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("IOSSim", isDirectory: true)
    self.locationCoordinator = locationCoordinator
    self.tunnelClient = tunnelClient
    self.now = now
  }

  public func reconcileIfRequested() async throws -> RichRuntimeProofInboxReceipt? {
    let requestURL = appSupportURL.appendingPathComponent("SetupInbox/rich-runtime-proof.request")
    guard FileManager.default.fileExists(atPath: requestURL.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let request = try decoder.decode(
      RichRuntimeProofInboxRequest.self, from: Data(contentsOf: requestURL))
    guard request.schemaVersion == 1,
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
    var stages = Set<Gate3XCTestRunnerStage>()
    var richProbeComplete = false
    var locationCleared = false
    var sessionCleanedUp = false

    do {
      try await locationCoordinator.startSimulation(
        writerID: writerID, mode: .staticLocation(nil))
      try await tunnelClient.startGate3OnDeviceXCTest(
        iosMajorVersion: UInt8(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
        timeoutSeconds: 90)
      for _ in 0..<480 {
        if Task.isCancelled { throw CancellationError() }
        let status = tunnelClient.gate3XCTestStatus()
        stages.formUnion(status.events.map(\.stage))
        if status.currentStage == .finished && !status.isRunning {
          richProbeComplete = status.firstErrorStage == nil
          break
        }
        if status.currentStage == .failed || status.firstErrorStage != nil { break }
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    } catch {
      stages.formUnion(tunnelClient.gate3XCTestStatus().events.map(\.stage))
    }

    await tunnelClient.stopGate3OnDeviceXCTest()
    do {
      try await locationCoordinator.stopSimulation(writerID: writerID, clearLocation: true)
      locationCleared = true
      sessionCleanedUp = true
    } catch {
      // A cleanup failure is represented in the receipt and can never become READY.
      locationCleared = false
      sessionCleanedUp = false
    }

    let receipt = RichRuntimeProofInboxReceipt(
      schemaVersion: 1,
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
      richLocationProbeCompleted: richProbeComplete,
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
