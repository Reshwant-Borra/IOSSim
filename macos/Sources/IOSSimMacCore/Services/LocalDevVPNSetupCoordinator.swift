import Foundation

public enum LocalDevVPNSetupFailure: String, Error, Codable, Equatable, Sendable {
    case appMissing = "LOCALDEVVPN_MISSING"
    case unsupportedVersion = "LOCALDEVVPN_UNSUPPORTED_VERSION"
    case vpnPermissionRequired = "LOCALDEVVPN_VPN_PERMISSION_REQUIRED"
    case vpnNotRunning = "LOCALDEVVPN_NOT_RUNNING"
    case endpointUnavailable = "LOCALDEVVPN_ENDPOINT_UNAVAILABLE"
    case userActionRequired = "LOCALDEVVPN_USER_ACTION_REQUIRED" // schema-1 compatibility
    case receiptMissing = "LOCALDEVVPN_RECEIPT_MISSING"
    case receiptInvalid = "LOCALDEVVPN_RECEIPT_INVALID"
    case transportUnavailable = "LOCALDEVVPN_TRANSPORT_UNAVAILABLE"
    /// iOS refused to launch Veya because its Personal Team developer is not trusted yet.
    case developerTrustRequired = "LOCALDEVVPN_DEVELOPER_TRUST_REQUIRED"
}

public enum LocalDevVPNLifecycleState: String, Codable, Equatable, Sendable {
    case missing = "MISSING"
    case installedUnsupported = "INSTALLED_UNSUPPORTED"
    case installed = "INSTALLED"
    case vpnPermissionRequired = "VPN_PERMISSION_REQUIRED"
    case configured = "CONFIGURED"
    case running = "RUNNING"
    case runtimeEndpointReachable = "RUNTIME_ENDPOINT_REACHABLE"
}

public struct LocalDevVPNCompatibilityPolicy: Equatable, Sendable {
    public let supportedMajorVersion: Int
    public let minimumVersion: [Int]
    public let observedAppStoreVersion: String

    public init(supportedMajorVersion: Int = 1, minimumVersion: [Int] = [1, 0, 0],
                observedAppStoreVersion: String = "1.3.0") {
        self.supportedMajorVersion = supportedMajorVersion
        self.minimumVersion = minimumVersion
        self.observedAppStoreVersion = observedAppStoreVersion
    }

    public func supports(_ version: String?) -> Bool {
        guard let version else { return false }
        let components = version.split(separator: ".").compactMap { Int($0) }
        guard components.count >= 2, components.first == supportedMajorVersion else { return false }
        let normalized = components + Array(repeating: 0, count: max(0, 3 - components.count))
        return Array(normalized.prefix(3)).lexicographicallyPrecedes(minimumVersion) == false
    }
}

public struct LocalDevVPNSetupRequestPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let appBundleIdentifier: String
    public let endpoint: LocalDevVPNEndpoint
    public let createdAt: Date
    public let deviceUDID: String?
    public let teamIdentifier: String?
    public let releaseIdentity: String?

    public init(
        schemaVersion: Int = 1,
        requestID: String = UUID().uuidString,
        appBundleIdentifier: String,
        endpoint: LocalDevVPNEndpoint = LocalDevVPNEndpoint(),
        createdAt: Date = .now,
        deviceUDID: String? = nil,
        teamIdentifier: String? = nil,
        releaseIdentity: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.appBundleIdentifier = appBundleIdentifier
        self.endpoint = endpoint
        self.createdAt = createdAt
        self.deviceUDID = deviceUDID; self.teamIdentifier = teamIdentifier
        self.releaseIdentity = releaseIdentity
    }
}

public struct LocalDevVPNEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String = "10.7.0.1", port: UInt16 = 49152) {
        self.host = host
        self.port = port
    }
}

public struct LocalDevVPNSetupReceiptPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let status: String
    public let endpoint: LocalDevVPNEndpoint
    public let interfaceVisible: Bool
    public let endpointReachable: Bool
    public let errorCode: String?
    public let timestamp: Date
    public let lifecycleState: LocalDevVPNLifecycleState?
    public let deviceUDID: String?
    public let teamIdentifier: String?
    public let releaseIdentity: String?

    public init(schemaVersion: Int = 1, requestID: String, status: String,
                endpoint: LocalDevVPNEndpoint, interfaceVisible: Bool,
                endpointReachable: Bool, errorCode: String? = nil,
                timestamp: Date = .now, lifecycleState: LocalDevVPNLifecycleState? = nil,
                deviceUDID: String? = nil, teamIdentifier: String? = nil,
                releaseIdentity: String? = nil) {
        self.schemaVersion = schemaVersion; self.requestID = requestID; self.status = status
        self.endpoint = endpoint; self.interfaceVisible = interfaceVisible
        self.endpointReachable = endpointReachable; self.errorCode = errorCode
        self.timestamp = timestamp; self.lifecycleState = lifecycleState
        self.deviceUDID = deviceUDID; self.teamIdentifier = teamIdentifier
        self.releaseIdentity = releaseIdentity
    }
}

public actor LocalDevVPNSetupCoordinator {
    public static let localDevVPNBundleIdentifier = "com.jkcoxson.LocalDevVPN"
    public static let requestPath = "Library/Application Support/IOSSim/SetupInbox/localdevvpn.request"
    public static let receiptPath = "Library/Application Support/IOSSim/SetupInbox/localdevvpn.receipt"

    private let service: any NativeApplicationServicing
    private let initialProbeAttempts: Int
    private let readinessAttempts: Int
    private let delayNanoseconds: UInt64
    private let compatibilityPolicy: LocalDevVPNCompatibilityPolicy

    public init(
        service: any NativeApplicationServicing,
        initialProbeAttempts: Int = 4,
        readinessAttempts: Int = 48,
        delayNanoseconds: UInt64 = 500_000_000,
        compatibilityPolicy: LocalDevVPNCompatibilityPolicy = LocalDevVPNCompatibilityPolicy()
    ) {
        self.service = service
        self.initialProbeAttempts = initialProbeAttempts
        self.readinessAttempts = readinessAttempts
        self.delayNanoseconds = delayNanoseconds
        self.compatibilityPolicy = compatibilityPolicy
    }

    /// Activates IOSSim's setup-only route watcher, launches the separately
    /// installed LocalDevVPN app through the proven AppService path when the
    /// route is not already ready, and accepts only the existing functional
    /// readiness contract: TCP reachability to 10.7.0.1:49152.
    public func prepare(
        device: IOSSimDeviceIdentity,
        iosSimBundleIdentifier: String,
        teamIdentifier: String? = nil,
        releaseIdentity: String? = nil
    ) async throws -> LocalDevVPNSetupReceiptPayload {
        let request = LocalDevVPNSetupRequestPayload(
            appBundleIdentifier: iosSimBundleIdentifier,
            deviceUDID: device.udid,
            teamIdentifier: teamIdentifier,
            releaseIdentity: releaseIdentity
        )
        do {
            try await service.writeContainer(
                bundleIdentifier: iosSimBundleIdentifier,
                relativePath: Self.requestPath,
                data: try JSONEncoder().encode(request),
                on: device
            )
            try await service.launch(bundleIdentifier: iosSimBundleIdentifier, on: device)
        } catch {
            throw Self.mapTransport(error)
        }

        if let ready = try await poll(
            request: request,
            device: device,
            attempts: initialProbeAttempts,
            stopOnActionRequired: false
        ) {
            return ready
        }

        let inventory: [NativeInstalledApplication]
        do {
            inventory = try await service.inventory(on: device)
        } catch {
            throw Self.mapTransport(error)
        }
        guard let installed = inventory.first(where: { $0.bundleIdentifier == Self.localDevVPNBundleIdentifier }) else {
            throw LocalDevVPNSetupFailure.appMissing
        }
        guard compatibilityPolicy.supports(installed.version) else {
            throw LocalDevVPNSetupFailure.unsupportedVersion
        }

        do {
            try await service.launch(bundleIdentifier: Self.localDevVPNBundleIdentifier, on: device)
        } catch let bridge as NativeDeviceBridgeError {
            if case .applicationNotFound(_) = bridge { throw LocalDevVPNSetupFailure.appMissing }
            throw Self.mapTransport(bridge)
        } catch {
            throw LocalDevVPNSetupFailure.transportUnavailable
        }

        if let ready = try await poll(
            request: request,
            device: device,
            attempts: readinessAttempts,
            stopOnActionRequired: true
        ) {
            return ready
        }
        throw LocalDevVPNSetupFailure.vpnPermissionRequired
    }

    private func poll(
        request: LocalDevVPNSetupRequestPayload,
        device: IOSSimDeviceIdentity,
        attempts: Int,
        stopOnActionRequired: Bool
    ) async throws -> LocalDevVPNSetupReceiptPayload? {
        for attempt in 0..<max(1, attempts) {
            if Task.isCancelled { throw CancellationError() }
            if let data = try? await service.readContainer(
                bundleIdentifier: request.appBundleIdentifier,
                relativePath: Self.receiptPath,
                on: device
            ), let receipt = try? JSONDecoder().decode(LocalDevVPNSetupReceiptPayload.self, from: data),
               receipt.schemaVersion == 1, receipt.requestID == request.requestID {
                guard receipt.endpoint == request.endpoint else {
                    throw LocalDevVPNSetupFailure.receiptInvalid
                }
                guard receipt.deviceUDID == request.deviceUDID,
                      receipt.teamIdentifier == request.teamIdentifier,
                      receipt.releaseIdentity == request.releaseIdentity else {
                    throw LocalDevVPNSetupFailure.receiptInvalid
                }
                let state = receipt.lifecycleState ?? (receipt.status == "ready" ? .runtimeEndpointReachable : nil)
                if state == .runtimeEndpointReachable {
                    guard receipt.endpointReachable else {
                        throw LocalDevVPNSetupFailure.receiptInvalid
                    }
                    return receipt
                }
                if stopOnActionRequired {
                    switch state {
                    case .vpnPermissionRequired: throw LocalDevVPNSetupFailure.vpnPermissionRequired
                    case .configured: throw LocalDevVPNSetupFailure.vpnNotRunning
                    case .running: throw LocalDevVPNSetupFailure.endpointUnavailable
                    default: break
                    }
                }
                guard receipt.status == "checking" || receipt.status == "action_required" else {
                    throw LocalDevVPNSetupFailure.receiptInvalid
                }
            }
            if attempt + 1 < attempts {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        return nil
    }

    private static func mapTransport(_ error: Error) -> LocalDevVPNSetupFailure {
        guard let bridge = error as? NativeDeviceBridgeError else { return .transportUnavailable }
        switch bridge {
        case .applicationNotFound(_): return .appMissing
        case _ where bridge.isDeveloperTrustRejection: return .developerTrustRequired
        case .deviceNotFound, .deviceResolutionFailed(_), .deviceDisconnected, .timedOut,
             .deviceLocked, .trustRequired:
            return .transportUnavailable
        default:
            return .transportUnavailable
        }
    }
}
