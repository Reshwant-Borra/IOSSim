import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

public struct DeveloperEndpoint: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String = "10.7.0.1", port: UInt16 = 49152) {
        self.host = host
        self.port = port
    }
}

public struct NetworkInterfaceSnapshot: Codable, Equatable, Sendable {
    public let name: String
    public let address: String
    public let family: String

    public init(name: String, address: String, family: String) {
        self.name = name
        self.address = address
        self.family = family
    }
}

public struct TCPProbeResult: Codable, Equatable, Sendable {
    public let endpoint: DeveloperEndpoint
    public let connected: Bool
    public let latencyMs: Double?
    public let error: String?

    public init(endpoint: DeveloperEndpoint, connected: Bool, latencyMs: Double?, error: String?) {
        self.endpoint = endpoint
        self.connected = connected
        self.latencyMs = latencyMs
        self.error = error
    }
}

public struct DeveloperRouteDiagnostics: Codable, Equatable, Sendable {
    public let endpoint: DeveloperEndpoint
    public let interfaces: [NetworkInterfaceSnapshot]
    public let localDevVPNAppearsActive: Bool
    public let tcpResult: TCPProbeResult

    public var localDevVPNInterfaceVisible: Bool {
        localDevVPNAppearsActive
    }

    public var localDevVPNFunctionalReady: Bool {
        tcpResult.connected
    }
}

public protocol InterfaceSnapshotProvider: Sendable {
    func snapshots() -> [NetworkInterfaceSnapshot]
}

public protocol TCPProbing: Sendable {
    func probe(endpoint: DeveloperEndpoint, timeout: TimeInterval) async -> TCPProbeResult
}

public struct SystemInterfaceSnapshotProvider: InterfaceSnapshotProvider {
    public init() {}

    public func snapshots() -> [NetworkInterfaceSnapshot] {
        #if canImport(Darwin)
        var result: [NetworkInterfaceSnapshot] = []
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else {
            return []
        }
        defer { freeifaddrs(ifaddrPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let rawName = current.pointee.ifa_name, let addr = current.pointee.ifa_addr else {
                continue
            }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)

            let status = getnameinfo(
                addr,
                length,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            result.append(NetworkInterfaceSnapshot(
                name: String(cString: rawName),
                address: String(cString: hostBuffer),
                family: family == AF_INET ? "IPv4" : "IPv6"
            ))
        }
        return result
        #else
        return []
        #endif
    }
}

public struct NWConnectionTCPProber: TCPProbing {
    public init() {}

    public func probe(endpoint: DeveloperEndpoint, timeout: TimeInterval = 3.0) async -> TCPProbeResult {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            return TCPProbeResult(endpoint: endpoint, connected: false, latencyMs: nil, error: "invalid port")
        }

        let start = Date()
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let box = TCPProbeContinuationBox(connection: connection, start: start, continuation: continuation)

            @Sendable func finish(connected: Bool, error: String?) {
                box.finish(endpoint: endpoint, connected: connected, error: error)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(connected: true, error: nil)
                case .failed(let error):
                    finish(connected: false, error: String(describing: error))
                case .cancelled:
                    finish(connected: false, error: "cancelled")
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(connected: false, error: "timeout after \(timeout)s")
            }
        }
    }
}

private final class TCPProbeContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private let start: Date
    private let continuation: CheckedContinuation<TCPProbeResult, Never>
    private var resumed = false

    init(connection: NWConnection, start: Date, continuation: CheckedContinuation<TCPProbeResult, Never>) {
        self.connection = connection
        self.start = start
        self.continuation = continuation
    }

    func finish(endpoint: DeveloperEndpoint, connected: Bool, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        connection.cancel()
        continuation.resume(returning: TCPProbeResult(
            endpoint: endpoint,
            connected: connected,
            latencyMs: Date().timeIntervalSince(start) * 1000,
            error: error
        ))
    }
}

public struct DeveloperRouteProbe: Sendable {
    private let interfaceProvider: InterfaceSnapshotProvider
    private let tcpProber: TCPProbing

    public init(
        interfaceProvider: InterfaceSnapshotProvider = SystemInterfaceSnapshotProvider(),
        tcpProber: TCPProbing = NWConnectionTCPProber()
    ) {
        self.interfaceProvider = interfaceProvider
        self.tcpProber = tcpProber
    }

    public func run(endpoint: DeveloperEndpoint = DeveloperEndpoint(), timeout: TimeInterval = 3.0) async -> DeveloperRouteDiagnostics {
        let interfaces = interfaceProvider.snapshots()
        let routeVisible = Self.localDevVPNAppearsActive(in: interfaces)
        let tcp = await tcpProber.probe(endpoint: endpoint, timeout: timeout)
        return DeveloperRouteDiagnostics(
            endpoint: endpoint,
            interfaces: interfaces,
            localDevVPNAppearsActive: routeVisible,
            tcpResult: tcp
        )
    }

    public static func localDevVPNAppearsActive(in interfaces: [NetworkInterfaceSnapshot]) -> Bool {
        interfaces.contains { snapshot in
            snapshot.family == "IPv4" && (
                snapshot.address == "10.7.0.0" ||
                snapshot.address == "10.7.0.1" ||
                snapshot.address.hasPrefix("10.7.0.")
            )
        }
    }
}

public struct NetworkPathEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let status: String
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let availableInterfaces: [String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        status: String,
        isExpensive: Bool,
        isConstrained: Bool,
        availableInterfaces: [String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.availableInterfaces = availableInterfaces
    }
}

public final class NetworkPathRecorder: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.iossim.on-device-dvt-poc.path")
    private let lock = NSLock()
    private var capturedEvents: [NetworkPathEvent] = []

    public init() {}

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.record(path)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }

    public func events() -> [NetworkPathEvent] {
        lock.lock()
        defer { lock.unlock() }
        return capturedEvents
    }

    private func record(_ path: NWPath) {
        let status: String
        switch path.status {
        case .satisfied:
            status = "satisfied"
        case .unsatisfied:
            status = "unsatisfied"
        case .requiresConnection:
            status = "requiresConnection"
        @unknown default:
            status = "unknown"
        }

        let event = NetworkPathEvent(
            status: status,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            availableInterfaces: path.availableInterfaces.map { "\($0.type)" }
        )
        lock.lock()
        capturedEvents.append(event)
        lock.unlock()
    }
}
