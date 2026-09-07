import Foundation

#if canImport(Darwin)
  import Darwin
#endif

#if IOS_SIM_IDEVICE_FFI
  import IOSSimIdeviceFFI
#elseif canImport(idevice)
  import idevice
#endif

public struct DvtOperationTiming: Codable, Equatable, Sendable {
  public let operation: String
  public let durationMs: Double

  public init(operation: String, durationMs: Double) {
    self.operation = operation
    self.durationMs = durationMs
  }
}

public struct DvtBridgeStatus: Codable, Equatable, Sendable {
  public let state: TunnelState
  public let endpoint: DeveloperEndpoint
  public let ideviceLinked: Bool
  public let timings: [DvtOperationTiming]
  public let lastError: POCError?

  public init(
    state: TunnelState,
    endpoint: DeveloperEndpoint,
    ideviceLinked: Bool,
    timings: [DvtOperationTiming],
    lastError: POCError?
  ) {
    self.state = state
    self.endpoint = endpoint
    self.ideviceLinked = ideviceLinked
    self.timings = timings
    self.lastError = lastError
  }
}

public enum Gate3XCTestRunnerStage: String, Codable, CaseIterable, Equatable, Sendable {
  case unknown = "UNKNOWN"
  case rsdReady = "RSD_READY"
  case testmanagerControlReady = "TESTMANAGER_CONTROL_READY"
  case testmanagerMainReady = "TESTMANAGER_MAIN_READY"
  case dvtReady = "DVT_READY"
  case runnerLaunched = "RUNNER_LAUNCHED"
  case pidAuthorized = "PID_AUTHORIZED"
  case xctestHandshakeReady = "XCTEST_HANDSHAKE_READY"
  case testPlanStarted = "TEST_PLAN_STARTED"
  case finished = "FINISHED"
  case failed = "FAILED"
}

public struct Gate3XCTestRunnerEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let stage: Gate3XCTestRunnerStage
  public let message: String?

  public init(
    id: UUID = UUID(), timestamp: Date = Date(), stage: Gate3XCTestRunnerStage,
    message: String? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.stage = stage
    self.message = message
  }
}

public struct Gate3XCTestRunnerStatus: Codable, Equatable, Sendable {
  public let currentStage: Gate3XCTestRunnerStage
  public let firstErrorStage: Gate3XCTestRunnerStage?
  public let firstErrorMessage: String?
  public let metadataSummary: String?
  public let events: [Gate3XCTestRunnerEvent]
  public let isRunning: Bool

  public init(
    currentStage: Gate3XCTestRunnerStage = .unknown,
    firstErrorStage: Gate3XCTestRunnerStage? = nil,
    firstErrorMessage: String? = nil,
    metadataSummary: String? = nil,
    events: [Gate3XCTestRunnerEvent] = [],
    isRunning: Bool = false
  ) {
    self.currentStage = currentStage
    self.firstErrorStage = firstErrorStage
    self.firstErrorMessage = firstErrorMessage
    self.metadataSummary = metadataSummary
    self.events = events
    self.isRunning = isRunning
  }
}

private struct Gate3XCTestRunnerMetadata {
  let runnerBundleID: String
  let runnerAppPath: String
  let runnerAppContainer: String
  let runnerBundleExecutable: String

  var summary: String {
    [
      "bundle_id=\(runnerBundleID)",
      "executable=\(runnerBundleExecutable)",
      "app_path=\(runnerAppPath)",
      "container=\(runnerAppContainer)",
    ].joined(separator: "\n")
  }
}

private final class Gate3XCTestCallbackContext: @unchecked Sendable {
  private weak var client: IdeviceOnDeviceTunnelClient?

  init(client: IdeviceOnDeviceTunnelClient) {
    self.client = client
  }

  func handle(stage: Gate3XCTestRunnerStage, message: String?) {
    client?.recordGate3XCTest(stage: stage, message: message)
  }
}

public struct Gate3XCTestRunnerBundleIdentifierResolver: Sendable {
  public static let defaultInstalledRunnerBundleID =
    "com.iossim.location-control-uitests.xctrunner"
  public static let environmentKey = "IOSSIM_GATE3_RUNNER_BUNDLE_ID"
  public static let infoDictionaryKey = "IOSSimGate3RunnerBundleIdentifier"
  public static let userDefaultsKey = "IOSSimGate3RunnerBundleIdentifier"

  public init() {}

  public func resolvedInstalledRunnerBundleID(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
    userDefaults: UserDefaults = .standard
  ) -> String {
    if let configured = Self.validConfiguredRunnerBundleID(environment[Self.environmentKey]) {
      return configured
    }
    if let configured = Self.validConfiguredRunnerBundleID(
      infoDictionary?[Self.infoDictionaryKey] as? String
    ) {
      userDefaults.set(configured, forKey: Self.userDefaultsKey)
      return configured
    }
    if let configured = Self.validConfiguredRunnerBundleID(
      userDefaults.string(forKey: Self.userDefaultsKey)
    ) {
      return configured
    }
    return Self.defaultInstalledRunnerBundleID
  }

  public static func validConfiguredRunnerBundleID(_ rawValue: String?) -> String? {
    guard let rawValue else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasSuffix(".xctrunner"),
      isValidAppleBundleIdentifier(value),
      !value.contains("$(")
    else {
      return nil
    }
    return value
  }

  public static func isValidAppleBundleIdentifier(_ value: String) -> Bool {
    guard value.count <= 255, value.contains(".") else { return false }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
    guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
    return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
      guard let first = component.first else { return false }
      return first.isLetter || first.isNumber
    }
  }
}

public enum XCTestRSDServiceDiagnostics {
  public static let testmanagerd = "com.apple.dt.testmanagerd.remote"
  public static let dtservicehub = "com.apple.instruments.dtservicehub"

  public static var requiredServiceSummary: String {
    "\(testmanagerd), \(dtservicehub)"
  }
}

public protocol OnDeviceTunnelClient: Sendable {
  func connect(pairingData: Data, endpoint: DeveloperEndpoint) async throws
  func set(latitude: Double, longitude: Double) async throws
  func clear() async throws
  func disconnect() async
  func status() async -> DvtBridgeStatus
}

public final class IdeviceOnDeviceTunnelClient: OnDeviceTunnelClient, @unchecked Sendable {
  private let hostname: String
  private let recorder: SessionDiagnosticRecorder?
  private let gate3RunnerBundleID: String
  private let pairingStore: RPPairingStore?
  private let lock = NSLock()
  private var state: TunnelState = .disconnected
  private var endpoint = DeveloperEndpoint()
  private var timings: [DvtOperationTiming] = []
  private var lastError: POCError?

  #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationSimulation: OpaquePointer?
    private var gate3XCTestRunner: OpaquePointer?
    private var gate3XCTestCallbackContext: UnsafeMutableRawPointer?
  #endif
  private var gate3XCTestSnapshot = Gate3XCTestRunnerStatus()

  public init(
    hostname: String = "IOSSimOnDeviceDVTPOC",
    recorder: SessionDiagnosticRecorder? = .shared,
    gate3RunnerBundleID: String? = nil,
    pairingStore: RPPairingStore? = nil
  ) {
    self.hostname = hostname
    self.recorder = recorder
    self.pairingStore = pairingStore
    self.gate3RunnerBundleID =
      Gate3XCTestRunnerBundleIdentifierResolver.validConfiguredRunnerBundleID(gate3RunnerBundleID)
      ?? Gate3XCTestRunnerBundleIdentifierResolver().resolvedInstalledRunnerBundleID()
    Task {
      await recorder?.record(
        category: "OBJECT_LIFETIME",
        component: "DeveloperTunnel",
        previousState: nil,
        newState: "initialized",
        message: "INIT Tunnel"
      )
    }
  }

  deinit {
    let recorder = recorder
    Task {
      await recorder?.record(
        category: "OBJECT_LIFETIME",
        component: "DeveloperTunnel",
        previousState: "initialized",
        newState: "deinitialized",
        message: "DEINIT Tunnel"
      )
    }
  }

  public func connect(pairingData: Data, endpoint: DeveloperEndpoint = DeveloperEndpoint())
    async throws
  {
    self.endpoint = endpoint
    setState(.connecting)
    await recorder?.record(
      category: "TUNNEL",
      component: "DeveloperTunnel",
      previousState: "disconnected",
      newState: "connecting",
      message: "developer tunnel connect requested",
      metadata: ["endpoint": "\(endpoint.host):\(endpoint.port)"]
    )
    do {
      #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
        try await connectWithIdevice(pairingData: pairingData, endpoint: endpoint)
      #else
        throw POCError(
          .ideviceBridgeUnavailable,
          "The IOSSim on-device DVT POC was built without the pinned idevice FFI static library.",
          stage: .tunnelEstablished
        )
      #endif
    } catch let error as POCError {
      recordError(error)
      throw error
    } catch {
      let pocError = POCError(.unknown, String(describing: error), stage: .tunnelEstablished)
      recordError(pocError)
      throw pocError
    }
  }

  public func set(latitude: Double, longitude: Double) async throws {
    #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
      guard let locationSimulation else {
        let error = POCError(
          .disconnected, "LocationSimulation is not connected.", stage: .setCommandSent)
        recordError(error)
        await record(error: error, component: "LocationSimulation", newState: "missing")
        throw error
      }

      do {
        await recorder?.record(
          category: "LOCATION_SET",
          component: "LocationSimulation",
          previousState: state.rawValue,
          newState: "setting",
          message: "location_simulation_set sending",
          metadata: [
            "latitude": String(format: "%.6f", latitude),
            "longitude": String(format: "%.6f", longitude),
          ]
        )
        try measure("location_simulation_set") {
          if let err = location_simulation_set(locationSimulation, latitude, longitude) {
            defer { idevice_error_free(err) }
            throw POCError(
              .setCommandFailed, ffiMessage(err) ?? "location_simulation_set failed.",
              stage: .setCommandSent)
          }
        }
        setState(.simulating)
        await recorder?.record(
          category: "LOCATION_SET",
          component: "LocationSimulation",
          previousState: "setting",
          newState: "set_succeeded",
          message: "location_simulation_set succeeded"
        )
      } catch let error as POCError {
        recordError(error)
        await record(error: error, component: "LocationSimulation", newState: "failed")
        cleanup()
        throw error
      } catch {
        let pocError = POCError(
          .setCommandFailed, String(describing: error), stage: .setCommandSent)
        recordError(pocError)
        await record(error: pocError, component: "LocationSimulation", newState: "failed")
        cleanup()
        throw pocError
      }
    #else
      let error = POCError(
        .ideviceBridgeUnavailable, "Set requires a build linked with idevice FFI.",
        stage: .setCommandSent)
      recordError(error)
      throw error
    #endif
  }

  public func clear() async throws {
    #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
      guard let locationSimulation else {
        let error = POCError(
          .disconnected, "LocationSimulation is not connected.", stage: .clearCommandSent)
        recordError(error)
        await record(error: error, component: "LocationSimulation", newState: "missing")
        throw error
      }

      do {
        await recorder?.record(
          category: "CLEAR",
          component: "LocationSimulation",
          previousState: state.rawValue,
          newState: "clearing",
          message: "location_simulation_clear sending"
        )
        try measure("location_simulation_clear") {
          if let err = location_simulation_clear(locationSimulation) {
            defer { idevice_error_free(err) }
            throw POCError(
              .clearCommandFailed, ffiMessage(err) ?? "location_simulation_clear failed.",
              stage: .clearCommandSent)
          }
        }
        await recorder?.record(
          category: "CLEAR",
          component: "LocationSimulation",
          previousState: "clearing",
          newState: "cleared",
          message: "location_simulation_clear succeeded"
        )
        cleanup()
      } catch let error as POCError {
        recordError(error)
        await record(error: error, component: "LocationSimulation", newState: "failed")
        cleanup()
        throw error
      } catch {
        let pocError = POCError(
          .clearCommandFailed, String(describing: error), stage: .clearCommandSent)
        recordError(pocError)
        await record(error: pocError, component: "LocationSimulation", newState: "failed")
        cleanup()
        throw pocError
      }
    #else
      let error = POCError(
        .ideviceBridgeUnavailable, "Clear requires a build linked with idevice FFI.",
        stage: .clearCommandSent)
      recordError(error)
      throw error
    #endif
  }

  public func disconnect() async {
    #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
      await recorder?.record(
        category: "TUNNEL",
        component: "DeveloperTunnel",
        previousState: state.rawValue,
        newState: "disconnect_requested",
        message: "explicit disconnect requested"
      )
      cleanup()
    #else
      setState(.disconnected)
    #endif
  }

  public func status() async -> DvtBridgeStatus {
    lockedStatus()
  }

  public func gate3XCTestStatus() -> Gate3XCTestRunnerStatus {
    lock.lock()
    defer { lock.unlock() }
    return gate3XCTestSnapshot
  }

  public func startGate3OnDeviceXCTest(iosMajorVersion: UInt8 = 17, timeoutSeconds: Double = 60)
    async throws
  {
    try await startOnDeviceXCTest(
      iosMajorVersion: iosMajorVersion,
      timeoutSeconds: timeoutSeconds,
      env: ["IOSSIM_GATE1_RICH_LOCATION_ONLY=1"],
      startReason: "Gate 3 on-device XCTest launch requested through retained RSD"
    )
  }

  public func startRichDriveOnDeviceXCTest(
    port: UInt16 = 31_337, iosMajorVersion: UInt8 = 17, timeoutSeconds: Double = 3_600
  ) async throws {
    try await startOnDeviceXCTest(
      iosMajorVersion: iosMajorVersion,
      timeoutSeconds: timeoutSeconds,
      env: [
        "IOSSIM_RICH_DRIVE_RUNNER=1",
        "IOSSIM_RICH_DRIVE_PORT=\(port)",
        "IOSSIM_RICH_DRIVE_TIMEOUT_SECONDS=\(Int(timeoutSeconds))",
      ],
      startReason: "Rich Drive long-lived XCTest runner launch requested through retained RSD"
    )
  }

  private func startOnDeviceXCTest(
    iosMajorVersion: UInt8,
    timeoutSeconds: Double,
    env: [String],
    startReason: String
  ) async throws {
    #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
      guard let adapter, let handshake else {
        let error = POCError(
          .xctestRunnerFailed,
          "Gate 3 requires the existing IOSSim developer connection to be connected before launch."
        )
        recordGate3Failure(error, firstStage: .rsdReady)
        throw error
      }

      let currentState = lockedStatus().state
      guard currentState == .locationSimulationConnected || currentState == .simulating else {
        let error = POCError(
          .xctestRunnerFailed,
          "Gate 3 requires a healthy retained RSD/LocationSimulation session. Current state: \(currentState.rawValue)."
        )
        recordGate3Failure(error, firstStage: .rsdReady)
        throw error
      }

      stopGate3XCTestLocked()
      resetGate3Status()
      await recorder?.record(
        category: "GATE3_XCTEST",
        component: "XCTestRunner",
        previousState: currentState.rawValue,
        newState: "starting",
        message: startReason,
        metadata: ["requested_runner_bundle_id": gate3RunnerBundleID]
      )

      let metadata: Gate3XCTestRunnerMetadata
      do {
        metadata = try lookupGate3RunnerMetadata(adapter: adapter, handshake: handshake)
      } catch let error as POCError {
        await recorder?.record(
          category: "GATE3_XCTEST",
          component: "XCTestRunner",
          previousState: "starting",
          newState: "metadata_lookup_failed",
          errorCode: error.code.rawValue,
          message: error.message,
          metadata: ["requested_runner_bundle_id": gate3RunnerBundleID]
        )
        throw error
      }
      updateGate3Metadata(metadata.summary)
      await recorder?.record(
        category: "GATE3_XCTEST",
        component: "XCTestRunner",
        previousState: "starting",
        newState: "metadata_resolved",
        message: "Gate 3 runner metadata resolved",
        metadata: [
          "requested_runner_bundle_id": gate3RunnerBundleID,
          "resolved_runner_bundle_id": metadata.runnerBundleID,
        ]
      )

      let context = Unmanaged.passRetained(Gate3XCTestCallbackContext(client: self)).toOpaque()
      var runner: OpaquePointer?
      let callback: XCTestRunnerStatusCallback = { context, status, message in
        guard let context else { return }
        let box = Unmanaged<Gate3XCTestCallbackContext>.fromOpaque(context).takeUnretainedValue()
        box.handle(
          stage: Gate3XCTestRunnerStage(status: status), message: message.map(String.init(cString:))
        )
      }

      if let err = xctest_runner_new_from_rsd(
        adapter, handshake, iosMajorVersion, callback, context, &runner)
      {
        defer { idevice_error_free(err) }
        Unmanaged<Gate3XCTestCallbackContext>.fromOpaque(context).release()
        let error = POCError(
          .xctestRunnerFailed,
          xctestFailureMessage(err, operation: "xctest_runner_new_from_rsd"))
        recordGate3Failure(error, firstStage: .rsdReady)
        throw error
      }
      guard let runner else {
        Unmanaged<Gate3XCTestCallbackContext>.fromOpaque(context).release()
        let error = POCError(.xctestRunnerFailed, "xctest_runner_new_from_rsd returned no handle.")
        recordGate3Failure(error, firstStage: .rsdReady)
        throw error
      }

      gate3XCTestRunner = runner
      gate3XCTestCallbackContext = context
      await recorder?.record(
        category: "OBJECT_LIFETIME",
        component: "XCTestRunner",
        previousState: nil,
        newState: "ffi_handle_retained",
        message: "INIT Gate 3 XCTest runner handle"
      )

      let args: [String] = []
      try withCStringArray(env) { envPointers in
        try withCStringArray(args) { argPointers in
          try metadata.runnerBundleID.withCString { runnerBundleID in
            try metadata.runnerAppPath.withCString { runnerAppPath in
              try metadata.runnerAppContainer.withCString { runnerAppContainer in
                try metadata.runnerBundleExecutable.withCString { runnerExecutable in
                  var config = XCTestRunnerConfig(
                    runner_bundle_id: runnerBundleID,
                    runner_app_path: runnerAppPath,
                    runner_app_container: runnerAppContainer,
                    runner_bundle_executable: runnerExecutable,
                    target_bundle_id: nil,
                    target_app_path: nil,
                    env_vars: envPointers.baseAddress,
                    env_vars_count: UInt(envPointers.count),
                    arguments: argPointers.baseAddress,
                    arguments_count: UInt(argPointers.count)
                  )
                  if let err = xctest_runner_start(runner, &config, timeoutSeconds) {
                    defer { idevice_error_free(err) }
                    let error = POCError(
                      .xctestRunnerFailed,
                      xctestFailureMessage(err, operation: "xctest_runner_start"))
                    recordGate3Failure(error, firstStage: .testmanagerControlReady)
                    stopGate3XCTestLocked()
                    throw error
                  }
                }
              }
            }
          }
        }
      }
    #else
      let error = POCError(
        .ideviceBridgeUnavailable, "Gate 3 XCTest requires a build linked with idevice FFI.")
      recordGate3Failure(error, firstStage: .rsdReady)
      throw error
    #endif
  }

  public func stopGate3OnDeviceXCTest() async {
    #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
      stopGate3XCTestLocked()
    #endif
    recordGate3XCTest(stage: .finished, message: "stopped")
  }

  private func lockedStatus() -> DvtBridgeStatus {
    lock.lock()
    defer { lock.unlock() }
    return DvtBridgeStatus(
      state: state,
      endpoint: endpoint,
      ideviceLinked: Self.ideviceLinked,
      timings: timings,
      lastError: lastError
    )
  }

  public static var ideviceLinked: Bool {
    #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
      return true
    #else
      return false
    #endif
  }

  #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
    private func connectWithIdevice(pairingData: Data, endpoint: DeveloperEndpoint) async throws {
      let temporaryURL = try writeTemporaryPairingFile(pairingData)
      defer {
        try? FileManager.default.removeItem(at: temporaryURL)
      }

      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = in_port_t(endpoint.port).bigEndian
      let inetResult = endpoint.host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
      guard inetResult == 1 else {
        throw POCError(
          .invalidEndpoint, "Endpoint host must be an IPv4 address for this POC.",
          stage: .endpointReachable)
      }

      var pairingHandle: OpaquePointer?
      try measure("rp_pairing_file_read") {
        if let err = temporaryURL.path.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
          defer { idevice_error_free(err) }
          throw POCError(
            .pairingReadFailed, ffiMessage(err) ?? "rp_pairing_file_read failed.",
            stage: .pairingImported)
        }
      }
      guard let pairingHandle else {
        throw POCError(
          .pairingReadFailed, "rp_pairing_file_read returned no handle.", stage: .pairingImported)
      }
      await recorder?.record(
        category: "PAIRING",
        component: "Pairing",
        previousState: nil,
        newState: "ffi_handle_ready",
        message: "RPPairing handle created from temporary protected file"
      )
      defer { rp_pairing_file_free(pairingHandle) }

      do {
        try measure("tunnel_create_rppairing") {
          let error = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              tunnel_create_rppairing(
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.stride),
                hostname,
                pairingHandle,
                nil,
                nil,
                &adapter,
                &handshake
              )
            }
          }
          if let error {
            defer { idevice_error_free(error) }
            throw POCError(
              .tlsPskFailed, ffiMessage(error) ?? "tunnel_create_rppairing failed.",
              stage: .tunnelEstablished)
          }
        }
        try persistUpdatedPairingHandle(
          pairingHandle,
          originalData: pairingData
        )
        setState(.tunnelEstablished)
        await recorder?.record(
          category: "TUNNEL",
          component: "DeveloperTunnel",
          previousState: "connecting",
          newState: "connected",
          message: "tunnel_create_rppairing succeeded"
        )
        await recorder?.record(
          category: "OBJECT_LIFETIME",
          component: "DeveloperTunnel",
          previousState: nil,
          newState: "ffi_adapter_retained",
          message: "INIT Tunnel adapter handle"
        )
        await recorder?.record(
          category: "OBJECT_LIFETIME",
          component: "RSD",
          previousState: nil,
          newState: "ffi_handshake_retained",
          message: "INIT RSD handshake handle"
        )

        try measure("remote_server_connect_rsd") {
          if let err = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            defer { idevice_error_free(err) }
            throw POCError(
              .rsdFailed, ffiMessage(err) ?? "remote_server_connect_rsd failed.",
              stage: .rsdConnected)
          }
        }
        setState(.rsdConnected)
        await recorder?.record(
          category: "RSD",
          component: "RSD",
          previousState: "connecting",
          newState: "connected",
          message: "remote_server_connect_rsd succeeded"
        )
        await recorder?.record(
          category: "OBJECT_LIFETIME",
          component: "RSD",
          previousState: nil,
          newState: "remote_server_retained",
          message: "INIT RSD remote server handle"
        )
        setState(.dvtConnected)
        await recorder?.record(
          category: "DVT",
          component: "DVT",
          previousState: "connecting",
          newState: "connected",
          message: "DVT remote server available"
        )

        try warmDeviceInfo()
        setState(.deviceInfoWarmed)
        await recorder?.record(
          category: "DVT",
          component: "DeviceInfo",
          previousState: "connecting",
          newState: "warmed",
          message: "DeviceInfo root directory listing succeeded"
        )

        try measure("location_simulation_new") {
          if let err = location_simulation_new(remoteServer, &locationSimulation) {
            defer { idevice_error_free(err) }
            throw POCError(
              .locationServiceFailed, ffiMessage(err) ?? "location_simulation_new failed.",
              stage: .locationSimulationConnected)
          }
        }
        await recorder?.record(
          category: "LOCATIONSIMULATION",
          component: "LocationSimulation",
          previousState: "connecting",
          newState: "connected",
          message: "location_simulation_new succeeded"
        )
        await recorder?.record(
          category: "OBJECT_LIFETIME",
          component: "LocationSimulation",
          previousState: nil,
          newState: "ffi_handle_retained",
          message: "INIT LocationSimulation handle"
        )
        remoteServer = nil
        await recorder?.record(
          category: "OBJECT_LIFETIME",
          component: "RSD",
          previousState: "remote_server_retained",
          newState: "remote_server_transferred",
          message: "RSD remote server ownership transferred to LocationSimulation channel"
        )
        setState(.locationSimulationConnected)
      } catch {
        await recorder?.record(
          category: "ERROR",
          component: "DeveloperTunnel",
          previousState: state.rawValue,
          newState: "failed",
          errorCode: (error as? POCError)?.code.rawValue,
          message: String(describing: error)
        )
        cleanup()
        throw error
      }
    }

    private func warmDeviceInfo() throws {
      guard let remoteServer else {
        throw POCError(
          .rsdFailed, "Remote server is missing before DeviceInfo warmup.", stage: .deviceInfoWarmup
        )
      }

      var deviceInfo: OpaquePointer?
      try measure("device_info_new") {
        if let err = device_info_new(remoteServer, &deviceInfo) {
          defer { idevice_error_free(err) }
          throw POCError(
            .deviceInfoWarmupFailed, ffiMessage(err) ?? "device_info_new failed.",
            stage: .deviceInfoWarmup)
        }
      }
      guard let deviceInfo else {
        throw POCError(
          .deviceInfoWarmupFailed, "device_info_new returned no handle.", stage: .deviceInfoWarmup)
      }
      defer { device_info_free(deviceInfo) }

      var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
      var count: UInt = 0
      try measure("device_info_directory_listing_root") {
        if let err = "/".withCString({
          device_info_directory_listing(deviceInfo, $0, &entries, &count)
        }) {
          defer { idevice_error_free(err) }
          throw POCError(
            .deviceInfoWarmupFailed, ffiMessage(err) ?? "device_info_directory_listing failed.",
            stage: .deviceInfoWarmup)
        }
      }
      if let entries {
        device_info_string_array_free(entries, count)
      }
    }

    private func writeTemporaryPairingFile(_ data: Data) throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iossim-rppairing-\(UUID().uuidString)")
        .appendingPathExtension("plist")
      try data.write(to: url, options: [.atomic, .completeFileProtection])
      return url
    }

    private func persistUpdatedPairingHandle(
      _ pairingHandle: OpaquePointer,
      originalData: Data
    ) throws {
      var bytes: UnsafeMutablePointer<UInt8>?
      var count: UInt = 0
      if let error = rp_pairing_file_to_bytes(pairingHandle, &bytes, &count) {
        defer { idevice_error_free(error) }
        throw POCError(
          .pairingStorageFailed,
          ffiMessage(error) ?? "Updated RPPairing serialization failed.",
          stage: .pairingImported)
      }
      guard let bytes, count > 0 else {
        throw POCError(
          .pairingStorageFailed,
          "Updated RPPairing serialization returned no data.",
          stage: .pairingImported)
      }
      defer { idevice_data_free(bytes, count) }
      let updatedData = Data(bytes: bytes, count: Int(count))
      let persisted = try RPPairingUpdatePersistence.persistIfChanged(
        updatedData,
        originalData: originalData,
        store: pairingStore
      )
      if persisted {
        Task {
          await recorder?.record(
            category: "PAIRING",
            component: "Pairing",
            previousState: "loaded",
            newState: "updated_and_persisted",
            message: "Updated device-verified RPPairing state persisted securely"
          )
        }
      }
    }

    private func cleanup() {
      stopGate3XCTestLocked()
      if let locationSimulation {
        Task {
          await recorder?.record(
            category: "OBJECT_LIFETIME",
            component: "LocationSimulation",
            previousState: "ffi_handle_retained",
            newState: "freed",
            message: "DEINIT LocationSimulation handle"
          )
        }
        location_simulation_free(locationSimulation)
        self.locationSimulation = nil
      }
      if let remoteServer {
        Task {
          await recorder?.record(
            category: "OBJECT_LIFETIME",
            component: "RSD",
            previousState: "remote_server_retained",
            newState: "freed",
            message: "DEINIT RSD remote server handle"
          )
        }
        remote_server_free(remoteServer)
        self.remoteServer = nil
      }
      if let handshake {
        Task {
          await recorder?.record(
            category: "OBJECT_LIFETIME",
            component: "RSD",
            previousState: "ffi_handshake_retained",
            newState: "freed",
            message: "DEINIT RSD handshake handle"
          )
        }
        rsd_handshake_free(handshake)
        self.handshake = nil
      }
      if let adapter {
        Task {
          await recorder?.record(
            category: "OBJECT_LIFETIME",
            component: "DeveloperTunnel",
            previousState: "ffi_adapter_retained",
            newState: "freed",
            message: "DEINIT Tunnel adapter handle"
          )
        }
        adapter_free(adapter)
        self.adapter = nil
      }
      setState(.disconnected)
    }

    private func lookupGate3RunnerMetadata(adapter: OpaquePointer, handshake: OpaquePointer) throws
      -> Gate3XCTestRunnerMetadata
    {
      var metadataPointer: UnsafeMutablePointer<XCTestRunnerMetadata>?
      if let err = gate3RunnerBundleID.withCString({ bundleID in
        xctest_runner_copy_metadata_from_rsd(adapter, handshake, bundleID, &metadataPointer)
      }) {
        defer { idevice_error_free(err) }
        throw POCError(
          .xctestRunnerFailed,
          xctestFailureMessage(err, operation: "xctest_runner_copy_metadata_from_rsd"))
      }
      guard let metadataPointer else {
        throw POCError(
          .xctestRunnerFailed, "xctest_runner_copy_metadata_from_rsd returned no metadata.")
      }
      defer { xctest_runner_metadata_free(metadataPointer) }
      let metadata = metadataPointer.pointee
      guard let runnerBundleID = metadata.runner_bundle_id,
        let runnerAppPath = metadata.runner_app_path,
        let runnerAppContainer = metadata.runner_app_container,
        let runnerBundleExecutable = metadata.runner_bundle_executable
      else {
        throw POCError(
          .xctestRunnerFailed, "xctest_runner_copy_metadata_from_rsd returned incomplete metadata.")
      }
      return Gate3XCTestRunnerMetadata(
        runnerBundleID: String(cString: runnerBundleID),
        runnerAppPath: String(cString: runnerAppPath),
        runnerAppContainer: String(cString: runnerAppContainer),
        runnerBundleExecutable: String(cString: runnerBundleExecutable)
      )
    }

    private func stopGate3XCTestLocked() {
      if let runner = gate3XCTestRunner {
        if let err = xctest_runner_stop(runner) {
          idevice_error_free(err)
        }
        xctest_runner_free(runner)
        gate3XCTestRunner = nil
        Task {
          await recorder?.record(
            category: "OBJECT_LIFETIME",
            component: "XCTestRunner",
            previousState: "ffi_handle_retained",
            newState: "freed",
            message: "DEINIT Gate 3 XCTest runner handle"
          )
        }
      }
      if let context = gate3XCTestCallbackContext {
        Unmanaged<Gate3XCTestCallbackContext>.fromOpaque(context).release()
        gate3XCTestCallbackContext = nil
      }
    }

    private func withCStringArray<R>(
      _ strings: [String],
      _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) throws -> R
    ) rethrows -> R {
      let rawStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
      defer {
        for rawString in rawStrings {
          free(rawString)
        }
      }
      let pointers: [UnsafePointer<CChar>?] = rawStrings.map { rawString in
        rawString.map { UnsafePointer<CChar>($0) }
      }
      return try pointers.withUnsafeBufferPointer(body)
    }

    private func ffiMessage(_ err: UnsafeMutablePointer<IdeviceFfiError>?) -> String? {
      guard let err else { return nil }
      if let message = err.pointee.message {
        return String(cString: message)
      }
      return "idevice error code=\(err.pointee.code) sub_code=\(err.pointee.sub_code)"
    }

    private func xctestFailureMessage(
      _ err: UnsafeMutablePointer<IdeviceFfiError>?,
      operation: String
    ) -> String {
      let base = ffiMessage(err) ?? "\(operation) failed."
      let lowercasedBase = base.lowercased()
      guard lowercasedBase.contains("servicenotfound")
        || lowercasedBase.contains("service not found")
      else {
        return base
      }
      return
        "\(base) Missing RSD service while starting XCTest via retained RSD. Required services: \(XCTestRSDServiceDiagnostics.requiredServiceSummary)."
    }
  #endif

  private func resetGate3Status() {
    lock.lock()
    gate3XCTestSnapshot = Gate3XCTestRunnerStatus(isRunning: true)
    lock.unlock()
  }

  private func updateGate3Metadata(_ summary: String) {
    lock.lock()
    gate3XCTestSnapshot = Gate3XCTestRunnerStatus(
      currentStage: gate3XCTestSnapshot.currentStage,
      firstErrorStage: gate3XCTestSnapshot.firstErrorStage,
      firstErrorMessage: gate3XCTestSnapshot.firstErrorMessage,
      metadataSummary: summary,
      events: gate3XCTestSnapshot.events,
      isRunning: gate3XCTestSnapshot.isRunning
    )
    lock.unlock()
  }

  fileprivate func recordGate3XCTest(stage: Gate3XCTestRunnerStage, message: String?) {
    lock.lock()
    let cleanMessage = message?.isEmpty == true ? nil : message
    let firstErrorStage = gate3XCTestSnapshot.firstErrorStage ?? (stage == .failed ? stage : nil)
    let firstErrorMessage =
      gate3XCTestSnapshot.firstErrorMessage ?? (stage == .failed ? cleanMessage : nil)
    var events = gate3XCTestSnapshot.events
    events.append(Gate3XCTestRunnerEvent(stage: stage, message: cleanMessage))
    gate3XCTestSnapshot = Gate3XCTestRunnerStatus(
      currentStage: stage,
      firstErrorStage: firstErrorStage,
      firstErrorMessage: firstErrorMessage,
      metadataSummary: gate3XCTestSnapshot.metadataSummary,
      events: Array(events.suffix(50)),
      isRunning: !(stage == .finished || stage == .failed)
    )
    lock.unlock()

    Task {
      await recorder?.record(
        category: "GATE3_XCTEST",
        component: "XCTestRunner",
        previousState: nil,
        newState: stage.rawValue,
        errorCode: stage == .failed ? POCErrorCode.xctestRunnerFailed.rawValue : nil,
        message: cleanMessage ?? stage.rawValue
      )
    }
  }

  private func recordGate3Failure(_ error: POCError, firstStage: Gate3XCTestRunnerStage) {
    lock.lock()
    var events = gate3XCTestSnapshot.events
    events.append(
      Gate3XCTestRunnerEvent(stage: .failed, message: "\(firstStage.rawValue): \(error.message)"))
    gate3XCTestSnapshot = Gate3XCTestRunnerStatus(
      currentStage: .failed,
      firstErrorStage: gate3XCTestSnapshot.firstErrorStage ?? firstStage,
      firstErrorMessage: gate3XCTestSnapshot.firstErrorMessage ?? error.message,
      metadataSummary: gate3XCTestSnapshot.metadataSummary,
      events: Array(events.suffix(50)),
      isRunning: false
    )
    lastError = error
    lock.unlock()
  }

  private func setState(_ state: TunnelState) {
    lock.lock()
    self.state = state
    lock.unlock()
  }

  private func recordError(_ error: POCError) {
    lock.lock()
    self.lastError = error
    self.state = .failed
    lock.unlock()
  }

  private func record(error: POCError, component: String, newState: String) async {
    await recorder?.record(
      category: "ERROR",
      component: component,
      previousState: state.rawValue,
      newState: newState,
      errorCode: error.code.rawValue,
      message: error.message
    )
  }

  private func measure(_ operation: String, _ body: () throws -> Void) throws {
    let start = Date()
    do {
      try body()
      appendTiming(operation, since: start)
    } catch {
      appendTiming(operation, since: start)
      throw error
    }
  }

  private func appendTiming(_ operation: String, since start: Date) {
    lock.lock()
    timings.append(
      DvtOperationTiming(operation: operation, durationMs: Date().timeIntervalSince(start) * 1000))
    lock.unlock()
  }
}

#if IOS_SIM_IDEVICE_FFI || canImport(idevice)
  extension Gate3XCTestRunnerStage {
    fileprivate init(status: XCTestRunnerStatus) {
      switch status {
      case XCTEST_RUNNER_STATUS_RSD_READY:
        self = .rsdReady
      case XCTEST_RUNNER_STATUS_TESTMANAGER_CONTROL_READY:
        self = .testmanagerControlReady
      case XCTEST_RUNNER_STATUS_TESTMANAGER_MAIN_READY:
        self = .testmanagerMainReady
      case XCTEST_RUNNER_STATUS_DVT_READY:
        self = .dvtReady
      case XCTEST_RUNNER_STATUS_RUNNER_LAUNCHED:
        self = .runnerLaunched
      case XCTEST_RUNNER_STATUS_PID_AUTHORIZED:
        self = .pidAuthorized
      case XCTEST_RUNNER_STATUS_XCTEST_HANDSHAKE_READY:
        self = .xctestHandshakeReady
      case XCTEST_RUNNER_STATUS_TEST_PLAN_STARTED:
        self = .testPlanStarted
      case XCTEST_RUNNER_STATUS_FINISHED:
        self = .finished
      case XCTEST_RUNNER_STATUS_FAILED:
        self = .failed
      default:
        self = .unknown
      }
    }
  }
#endif
