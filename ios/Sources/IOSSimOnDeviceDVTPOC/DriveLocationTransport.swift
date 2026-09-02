import CoreLocation
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

public enum DriveLocationOutputMode: String, CaseIterable, Codable, Equatable, Sendable,
  Identifiable
{
  case dvtBaseline
  case richXCUILocationExperimental

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .dvtBaseline:
      return "DVT Baseline"
    case .richXCUILocationExperimental:
      return "Rich XCUILocation Experimental"
    }
  }

  public static let defaultMode: DriveLocationOutputMode = .dvtBaseline
}

public struct DriveLocationTransportStartContext: Sendable {
  public let sessionID: UUID
  public let writerID: String
  public let initialCoordinate: CLLocationCoordinate2D

  public init(sessionID: UUID, writerID: String, initialCoordinate: CLLocationCoordinate2D) {
    self.sessionID = sessionID
    self.writerID = writerID
    self.initialCoordinate = initialCoordinate
  }
}

public struct DriveLocationTransportSetResult: Sendable {
  public let transportName: String
  public let connectionGeneration: Int
  public let sendMonotonicTime: TimeInterval?
  public let ackMonotonicTime: TimeInterval?
  public let ackLatencyMs: Double?
  public let droppedOrReplacedSamples: Int

  public init(
    transportName: String,
    connectionGeneration: Int,
    sendMonotonicTime: TimeInterval? = nil,
    ackMonotonicTime: TimeInterval? = nil,
    ackLatencyMs: Double? = nil,
    droppedOrReplacedSamples: Int = 0
  ) {
    self.transportName = transportName
    self.connectionGeneration = connectionGeneration
    self.sendMonotonicTime = sendMonotonicTime
    self.ackMonotonicTime = ackMonotonicTime
    self.ackLatencyMs = ackLatencyMs
    self.droppedOrReplacedSamples = droppedOrReplacedSamples
  }
}

public protocol DriveLocationTransport: Sendable {
  var transportName: String { get }

  func start(_ context: DriveLocationTransportStartContext) async throws
  func set(
    sample: RichDriveSample, writerID: String, mode: SimulationMode,
    traceContext: DriveTraceContext?, diagnostics: DriveDiagnostics?
  ) async throws -> DriveLocationTransportSetResult
  func stop(writerID: String, clearLocation: Bool) async throws
  func reconnectIfNeeded() async
  func currentConnectionGeneration() async -> Int
  func setReconnectRestoreProvider(
    writerID: String, provider: (@Sendable () async -> RichDriveSample?)?) async
}

public final class DVTDriveLocationTransport: DriveLocationTransport, @unchecked Sendable {
  public let transportName = "DVT Baseline"

  private let coordinator: LocationCoordinator

  public init(locationCoordinator: LocationCoordinator) {
    self.coordinator = locationCoordinator
  }

  public func start(_ context: DriveLocationTransportStartContext) async throws {
    try await coordinator.startSimulation(
      writerID: context.writerID,
      mode: .drive(
        sessionID: context.sessionID, current: SimulatedCoordinate(context.initialCoordinate))
    )
  }

  public func set(
    sample: RichDriveSample,
    writerID: String,
    mode: SimulationMode,
    traceContext: DriveTraceContext?,
    diagnostics: DriveDiagnostics?
  ) async throws -> DriveLocationTransportSetResult {
    try await coordinator.updateLocation(
      latitude: sample.latitude,
      longitude: sample.longitude,
      writerID: writerID,
      mode: mode,
      traceContext: traceContext,
      driveDiagnostics: diagnostics
    )
    return DriveLocationTransportSetResult(
      transportName: transportName,
      connectionGeneration: await coordinator.currentConnectionGeneration()
    )
  }

  public func stop(writerID: String, clearLocation: Bool) async throws {
    try await coordinator.stopSimulation(writerID: writerID, clearLocation: clearLocation)
  }

  public func reconnectIfNeeded() async {
    await coordinator.reconnectIfNeeded()
  }

  public func currentConnectionGeneration() async -> Int {
    await coordinator.currentConnectionGeneration()
  }

  public func setReconnectRestoreProvider(
    writerID: String,
    provider: (@Sendable () async -> RichDriveSample?)?
  ) async {
    await coordinator.setReconnectRestoreProvider(writerID: writerID) {
      guard let sample = await provider?() else { return nil }
      return SimulatedCoordinate(latitude: sample.latitude, longitude: sample.longitude)
    }
  }
}

public final class XCTestRichDriveLocationTransport: DriveLocationTransport, @unchecked Sendable {
  public let transportName = "Rich XCUILocation Experimental"

  private let coordinator: LocationCoordinator
  private let runnerClient: IdeviceOnDeviceTunnelClient
  private let tcpClient: RichDriveTCPClient
  private let port: UInt16
  private let runnerTimeoutSeconds: Double
  private var sessionID: String?

  public init(
    locationCoordinator: LocationCoordinator,
    runnerClient: IdeviceOnDeviceTunnelClient,
    port: UInt16 = 31_337,
    runnerTimeoutSeconds: Double = 3_600
  ) {
    self.coordinator = locationCoordinator
    self.runnerClient = runnerClient
    self.tcpClient = RichDriveTCPClient(port: port)
    self.port = port
    self.runnerTimeoutSeconds = runnerTimeoutSeconds
  }

  public func start(_ context: DriveLocationTransportStartContext) async throws {
    sessionID = context.sessionID.uuidString
    try await coordinator.startSimulation(
      writerID: context.writerID,
      mode: .drive(
        sessionID: context.sessionID, current: SimulatedCoordinate(context.initialCoordinate))
    )
    try await runnerClient.startRichDriveOnDeviceXCTest(
      port: port, timeoutSeconds: runnerTimeoutSeconds)
    try await tcpClient.connect(timeoutSeconds: 8)
    _ = try await tcpClient.send(
      RichDriveIPCMessage(
        type: .startSession, sequence: 0, sessionID: context.sessionID.uuidString),
      ackTimeoutSeconds: 1
    )
  }

  public func set(
    sample: RichDriveSample,
    writerID: String,
    mode: SimulationMode,
    traceContext: DriveTraceContext?,
    diagnostics: DriveDiagnostics?
  ) async throws -> DriveLocationTransportSetResult {
    let generation = await coordinator.currentConnectionGeneration()
    let result = try await tcpClient.setLocation(
      sample: sample, sessionID: sessionID, ackTimeoutSeconds: 0.2)
    return DriveLocationTransportSetResult(
      transportName: transportName,
      connectionGeneration: generation,
      sendMonotonicTime: result.sendMonotonicTime,
      ackMonotonicTime: result.ackMonotonicTime,
      ackLatencyMs: result.ackLatencyMs,
      droppedOrReplacedSamples: result.droppedOrReplacedSamples
    )
  }

  public func stop(writerID: String, clearLocation: Bool) async throws {
    _ = try? await tcpClient.send(
      RichDriveIPCMessage(type: .stopSession, sequence: -1, sessionID: sessionID),
      ackTimeoutSeconds: 1
    )
    await tcpClient.disconnect()
    await runnerClient.stopGate3OnDeviceXCTest()
    try await coordinator.stopSimulation(writerID: writerID, clearLocation: clearLocation)
  }

  public func reconnectIfNeeded() async {
    await tcpClient.disconnect()
    await runnerClient.stopGate3OnDeviceXCTest()
    await coordinator.reconnectIfNeeded()
    do {
      try await runnerClient.startRichDriveOnDeviceXCTest(
        port: port, timeoutSeconds: runnerTimeoutSeconds)
      try await tcpClient.connect(timeoutSeconds: 8)
    } catch {
      // The next scheduler send records the concrete failure.
    }
  }

  public func currentConnectionGeneration() async -> Int {
    await coordinator.currentConnectionGeneration()
  }

  public func setReconnectRestoreProvider(
    writerID: String,
    provider: (@Sendable () async -> RichDriveSample?)?
  ) async {
    await coordinator.setReconnectRestoreProvider(writerID: writerID) {
      guard let sample = await provider?() else { return nil }
      return SimulatedCoordinate(latitude: sample.latitude, longitude: sample.longitude)
    }
  }
}

public struct RichDriveTCPSendResult: Sendable {
  public let sendMonotonicTime: TimeInterval
  public let ackMonotonicTime: TimeInterval?
  public let ackLatencyMs: Double?
  public let droppedOrReplacedSamples: Int
}

public actor RichDriveTCPClient {
  private let host: String
  private let port: UInt16
  private var socketFD: Int32 = -1
  private var sequence = 0
  private var readBuffer = Data()

  public init(host: String = "127.0.0.1", port: UInt16 = 31_337) {
    self.host = host
    self.port = port
  }

  public func connect(timeoutSeconds: TimeInterval) async throws {
    #if canImport(Darwin)
      if socketFD >= 0 { return }
      let deadline = Date().addingTimeInterval(timeoutSeconds)
      var lastError: String = "not attempted"
      while Date() < deadline {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
          lastError = errnoDescription()
          try await Task.sleep(nanoseconds: 100_000_000)
          continue
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        let inetResult = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else {
          Darwin.close(fd)
          throw POCError(.invalidEndpoint, "Rich Drive IPC host must be an IPv4 address.")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
          }
        }
        if connected == 0 {
          socketFD = fd
          return
        }
        lastError = errnoDescription()
        Darwin.close(fd)
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      throw POCError(
        .xctestRunnerFailed,
        "Timed out connecting to Rich Drive runner IPC on \(host):\(port): \(lastError)")
    #else
      throw POCError(.xctestRunnerFailed, "Rich Drive IPC requires Darwin sockets.")
    #endif
  }

  @discardableResult
  public func setLocation(
    sample: RichDriveSample, sessionID: String?, ackTimeoutSeconds: TimeInterval
  ) async throws -> RichDriveTCPSendResult {
    sequence += 1
    let message = RichDriveIPCMessage(
      type: .setLocation, sequence: sequence, sessionID: sessionID, sample: sample)
    return try await send(message, ackTimeoutSeconds: ackTimeoutSeconds)
  }

  @discardableResult
  public func send(_ message: RichDriveIPCMessage, ackTimeoutSeconds: TimeInterval) async throws
    -> RichDriveTCPSendResult
  {
    #if canImport(Darwin)
      guard socketFD >= 0 else {
        throw POCError(.disconnected, "Rich Drive IPC is not connected.")
      }
      let sendTime = ProcessInfo.processInfo.systemUptime
      let line = try RichDriveIPCCodec.encodeLine(message)
      try writeAll(line)
      let ack = try readAck(sequence: message.sequence, timeoutSeconds: ackTimeoutSeconds)
      let ackTime = ack == nil ? nil : ProcessInfo.processInfo.systemUptime
      return RichDriveTCPSendResult(
        sendMonotonicTime: sendTime,
        ackMonotonicTime: ackTime,
        ackLatencyMs: ackTime.map { max(0, $0 - sendTime) * 1000 },
        droppedOrReplacedSamples: 0
      )
    #else
      throw POCError(.xctestRunnerFailed, "Rich Drive IPC requires Darwin sockets.")
    #endif
  }

  public func disconnect() {
    #if canImport(Darwin)
      if socketFD >= 0 {
        Darwin.close(socketFD)
        socketFD = -1
      }
      readBuffer.removeAll(keepingCapacity: true)
    #endif
  }

  #if canImport(Darwin)
    private func writeAll(_ data: Data) throws {
      try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < data.count {
          let result = Darwin.send(socketFD, base.advanced(by: sent), data.count - sent, 0)
          if result <= 0 {
            throw POCError(.disconnected, "Rich Drive IPC send failed: \(errnoDescription())")
          }
          sent += result
        }
      }
    }

    private func readAck(sequence expectedSequence: Int, timeoutSeconds: TimeInterval) throws
      -> RichDriveIPCAcknowledgement?
    {
      guard timeoutSeconds > 0 else { return nil }
      let deadline = Date().addingTimeInterval(timeoutSeconds)
      while Date() < deadline {
        if let line = nextBufferedLine(),
          let ack = try? RichDriveIPCCodec.decodeAcknowledgementLine(line),
          ack.sequence == expectedSequence
        {
          return ack
        }

        let remaining = max(0, deadline.timeIntervalSinceNow)
        var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, Int32(remaining * 1000))
        if ready < 0 {
          throw POCError(.disconnected, "Rich Drive IPC ACK poll failed: \(errnoDescription())")
        }
        if ready == 0 {
          return nil
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(socketFD, &buffer, buffer.count, 0)
        if count <= 0 {
          throw POCError(.disconnected, "Rich Drive IPC ACK read failed: \(errnoDescription())")
        }
        readBuffer.append(buffer, count: count)
      }
      return nil
    }

    private func nextBufferedLine() -> Data? {
      guard let newline = readBuffer.firstIndex(of: 0x0A) else { return nil }
      let line = readBuffer[..<newline]
      readBuffer.removeSubrange(...newline)
      return Data(line)
    }

    private func errnoDescription() -> String {
      String(cString: strerror(errno))
    }
  #endif
}
