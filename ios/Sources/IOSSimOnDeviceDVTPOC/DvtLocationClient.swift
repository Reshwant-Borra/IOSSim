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
    #endif

    public init(hostname: String = "IOSSimOnDeviceDVTPOC", recorder: SessionDiagnosticRecorder? = .shared) {
        self.hostname = hostname
        self.recorder = recorder
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

    public func connect(pairingData: Data, endpoint: DeveloperEndpoint = DeveloperEndpoint()) async throws {
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
            let error = POCError(.disconnected, "LocationSimulation is not connected.", stage: .setCommandSent)
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
                    "longitude": String(format: "%.6f", longitude)
                ]
            )
            try measure("location_simulation_set") {
                if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                    defer { idevice_error_free(err) }
                    throw POCError(.setCommandFailed, ffiMessage(err) ?? "location_simulation_set failed.", stage: .setCommandSent)
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
            let pocError = POCError(.setCommandFailed, String(describing: error), stage: .setCommandSent)
            recordError(pocError)
            await record(error: pocError, component: "LocationSimulation", newState: "failed")
            cleanup()
            throw pocError
        }
        #else
        let error = POCError(.ideviceBridgeUnavailable, "Set requires a build linked with idevice FFI.", stage: .setCommandSent)
        recordError(error)
        throw error
        #endif
    }

    public func clear() async throws {
        #if IOS_SIM_IDEVICE_FFI || canImport(idevice)
        guard let locationSimulation else {
            let error = POCError(.disconnected, "LocationSimulation is not connected.", stage: .clearCommandSent)
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
                    throw POCError(.clearCommandFailed, ffiMessage(err) ?? "location_simulation_clear failed.", stage: .clearCommandSent)
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
            let pocError = POCError(.clearCommandFailed, String(describing: error), stage: .clearCommandSent)
            recordError(pocError)
            await record(error: pocError, component: "LocationSimulation", newState: "failed")
            cleanup()
            throw pocError
        }
        #else
        let error = POCError(.ideviceBridgeUnavailable, "Clear requires a build linked with idevice FFI.", stage: .clearCommandSent)
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
            throw POCError(.invalidEndpoint, "Endpoint host must be an IPv4 address for this POC.", stage: .endpointReachable)
        }

        var pairingHandle: OpaquePointer?
        try measure("rp_pairing_file_read") {
            if let err = temporaryURL.path.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
                defer { idevice_error_free(err) }
                throw POCError(.pairingReadFailed, ffiMessage(err) ?? "rp_pairing_file_read failed.", stage: .pairingImported)
            }
        }
        guard let pairingHandle else {
            throw POCError(.pairingReadFailed, "rp_pairing_file_read returned no handle.", stage: .pairingImported)
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
                    throw POCError(.tlsPskFailed, ffiMessage(error) ?? "tunnel_create_rppairing failed.", stage: .tunnelEstablished)
                }
            }
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
                    throw POCError(.rsdFailed, ffiMessage(err) ?? "remote_server_connect_rsd failed.", stage: .rsdConnected)
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
                    throw POCError(.locationServiceFailed, ffiMessage(err) ?? "location_simulation_new failed.", stage: .locationSimulationConnected)
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
            throw POCError(.rsdFailed, "Remote server is missing before DeviceInfo warmup.", stage: .deviceInfoWarmup)
        }

        var deviceInfo: OpaquePointer?
        try measure("device_info_new") {
            if let err = device_info_new(remoteServer, &deviceInfo) {
                defer { idevice_error_free(err) }
                throw POCError(.deviceInfoWarmupFailed, ffiMessage(err) ?? "device_info_new failed.", stage: .deviceInfoWarmup)
            }
        }
        guard let deviceInfo else {
            throw POCError(.deviceInfoWarmupFailed, "device_info_new returned no handle.", stage: .deviceInfoWarmup)
        }
        defer { device_info_free(deviceInfo) }

        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: UInt = 0
        try measure("device_info_directory_listing_root") {
            if let err = "/".withCString({ device_info_directory_listing(deviceInfo, $0, &entries, &count) }) {
                defer { idevice_error_free(err) }
                throw POCError(.deviceInfoWarmupFailed, ffiMessage(err) ?? "device_info_directory_listing failed.", stage: .deviceInfoWarmup)
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

    private func cleanup() {
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

    private func ffiMessage(_ err: UnsafeMutablePointer<IdeviceFfiError>?) -> String? {
        guard let err else { return nil }
        if let message = err.pointee.message {
            return String(cString: message)
        }
        return "idevice error code=\(err.pointee.code) sub_code=\(err.pointee.sub_code)"
    }
    #endif

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
        timings.append(DvtOperationTiming(operation: operation, durationMs: Date().timeIntervalSince(start) * 1000))
        lock.unlock()
    }
}
