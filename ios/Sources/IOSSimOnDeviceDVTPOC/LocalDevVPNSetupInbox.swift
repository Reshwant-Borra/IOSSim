import Foundation

public struct LocalDevVPNSetupRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let appBundleIdentifier: String
    public let endpoint: DeveloperEndpoint
    public let createdAt: Date
    public let deviceUDID: String?
    public let teamIdentifier: String?
    public let releaseIdentity: String?

    public init(
        schemaVersion: Int = 1,
        requestID: String = UUID().uuidString,
        appBundleIdentifier: String,
        endpoint: DeveloperEndpoint = DeveloperEndpoint(),
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

public enum LocalDevVPNObservedState: String, Codable, Equatable, Sendable {
    case installed = "INSTALLED"
    case vpnPermissionRequired = "VPN_PERMISSION_REQUIRED"
    case configured = "CONFIGURED"
    case running = "RUNNING"
    case runtimeEndpointReachable = "RUNTIME_ENDPOINT_REACHABLE"
}

public struct LocalDevVPNSetupReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let status: String
    public let endpoint: DeveloperEndpoint
    public let interfaceVisible: Bool
    public let endpointReachable: Bool
    public let errorCode: String?
    public let timestamp: Date
    public let lifecycleState: LocalDevVPNObservedState?
    public let deviceUDID: String?
    public let teamIdentifier: String?
    public let releaseIdentity: String?

    public init(
        schemaVersion: Int = 1,
        requestID: String,
        status: String,
        endpoint: DeveloperEndpoint,
        interfaceVisible: Bool,
        endpointReachable: Bool,
        errorCode: String? = nil,
        timestamp: Date = .now,
        lifecycleState: LocalDevVPNObservedState? = nil,
        deviceUDID: String? = nil,
        teamIdentifier: String? = nil,
        releaseIdentity: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.status = status
        self.endpoint = endpoint
        self.interfaceVisible = interfaceVisible
        self.endpointReachable = endpointReachable
        self.errorCode = errorCode
        self.timestamp = timestamp
        self.lifecycleState = lifecycleState
        self.deviceUDID = deviceUDID; self.teamIdentifier = teamIdentifier
        self.releaseIdentity = releaseIdentity
    }
}

public enum LocalDevVPNSetupInboxError: Error, Equatable, Sendable {
    case malformedRequest
    case requestExpired
    case appBindingMismatch
    case unsafeInbox
}

/// Setup-only readiness gate for the externally installed LocalDevVPN app.
/// It reuses DeveloperRouteProbe's proven functional contract: successful TCP
/// reachability to 10.7.0.1:49152. It never creates a VPN configuration and
/// never opens RPPairing, RSD, TestManager, XCTest, or location services.
public struct LocalDevVPNSetupInboxController: @unchecked Sendable {
    public static let requestFile = "localdevvpn.request"
    public static let receiptFile = "localdevvpn.receipt"

    private let fileManager: FileManager
    private let applicationSupportDirectory: URL?
    private let routeProbe: DeveloperRouteProbe

    public init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        routeProbe: DeveloperRouteProbe = DeveloperRouteProbe()
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
        self.routeProbe = routeProbe
    }

    @discardableResult
    public func reconcileIfRequested(
        now: Date = .now,
        appBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        maxAttempts: Int = 24,
        delayNanoseconds: UInt64 = 500_000_000
    ) async throws -> LocalDevVPNSetupReceipt? {
        let inbox = try inboxURL()
        let requestURL = inbox.appendingPathComponent(Self.requestFile)
        guard fileManager.fileExists(atPath: requestURL.path) else { return nil }
        guard let request = try? JSONDecoder().decode(
            LocalDevVPNSetupRequest.self,
            from: Data(contentsOf: requestURL)
        ), request.schemaVersion == 1 else {
            throw LocalDevVPNSetupInboxError.malformedRequest
        }
        guard now.timeIntervalSince(request.createdAt) >= -60,
              now.timeIntervalSince(request.createdAt) <= 5 * 60 else {
            throw LocalDevVPNSetupInboxError.requestExpired
        }
        guard request.appBundleIdentifier == appBundleIdentifier else {
            throw LocalDevVPNSetupInboxError.appBindingMismatch
        }

        let receiptURL = inbox.appendingPathComponent(Self.receiptFile)
        let priorReceipt = (try? Data(contentsOf: receiptURL)).flatMap {
            try? JSONDecoder().decode(LocalDevVPNSetupReceipt.self, from: $0)
        }
        let previouslyConfigured = priorReceipt?.lifecycleState == .runtimeEndpointReachable
            || priorReceipt?.lifecycleState == .running
            || priorReceipt?.lifecycleState == .configured
        try writeProtected(
            try JSONEncoder().encode(LocalDevVPNSetupReceipt(
                requestID: request.requestID,
                status: "checking",
                endpoint: request.endpoint,
                interfaceVisible: false,
                endpointReachable: false,
                lifecycleState: .installed,
                deviceUDID: request.deviceUDID,
                teamIdentifier: request.teamIdentifier,
                releaseIdentity: request.releaseIdentity
            )),
            to: receiptURL
        )

        let backgroundKeeper = BackgroundSessionKeeper()
        backgroundKeeper.begin()
        defer { backgroundKeeper.end(reason: "LocalDevVPN setup readiness finished") }

        var lastResult: DeveloperRouteDiagnostics?
        for attempt in 0..<max(1, maxAttempts) {
            if Task.isCancelled { break }
            let result = await routeProbe.run(endpoint: request.endpoint, timeout: 1.0)
            lastResult = result
            if result.localDevVPNFunctionalReady {
                let receipt = LocalDevVPNSetupReceipt(
                    requestID: request.requestID,
                    status: "ready",
                    endpoint: request.endpoint,
                    interfaceVisible: result.localDevVPNInterfaceVisible,
                    endpointReachable: true,
                    lifecycleState: .runtimeEndpointReachable,
                    deviceUDID: request.deviceUDID,
                    teamIdentifier: request.teamIdentifier,
                    releaseIdentity: request.releaseIdentity
                )
                try writeProtected(try JSONEncoder().encode(receipt), to: receiptURL)
                try? fileManager.removeItem(at: requestURL)
                return receipt
            }
            if attempt + 1 < maxAttempts {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        let finalState: LocalDevVPNObservedState = if lastResult?.localDevVPNInterfaceVisible == true {
            .running
        } else if previouslyConfigured {
            .configured
        } else {
            .vpnPermissionRequired
        }
        let errorCode: String
        switch finalState {
        case .vpnPermissionRequired: errorCode = "LOCALDEVVPN_VPN_PERMISSION_REQUIRED"
        case .configured: errorCode = "LOCALDEVVPN_NOT_RUNNING"
        case .running: errorCode = "LOCALDEVVPN_ENDPOINT_UNAVAILABLE"
        default: errorCode = "LOCALDEVVPN_USER_ACTION_REQUIRED"
        }
        let receipt = LocalDevVPNSetupReceipt(
            requestID: request.requestID,
            status: "action_required",
            endpoint: request.endpoint,
            interfaceVisible: lastResult?.localDevVPNInterfaceVisible ?? false,
            endpointReachable: false,
            errorCode: errorCode,
            lifecycleState: finalState,
            deviceUDID: request.deviceUDID,
            teamIdentifier: request.teamIdentifier,
            releaseIdentity: request.releaseIdentity
        )
        try writeProtected(try JSONEncoder().encode(receipt), to: receiptURL)
        return receipt
    }

    private func inboxURL() throws -> URL {
        guard let support = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LocalDevVPNSetupInboxError.unsafeInbox
        }
        let inbox = support.appendingPathComponent(AutomaticPairingInboxController.directory, isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        #if os(macOS)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #else
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #endif
    }
}
