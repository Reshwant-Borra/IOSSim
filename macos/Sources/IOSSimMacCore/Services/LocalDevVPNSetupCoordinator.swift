import CryptoKit
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
    case developerModeRequired = "LOCALDEVVPN_DEVELOPER_MODE_REQUIRED"
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

/// Secret-free diagnostics for one LocalDevVPN handshake. The correlation
/// value is a one-way hash; raw device, team, release, bundle, and request
/// identifiers are never written to this trace.
public struct LocalDevVPNTraceRecord: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let event: String
    public let value: String?
    public let bindingHash: String

    public init(timestamp: Date = .now, event: String, value: String? = nil, bindingHash: String) {
        self.timestamp = timestamp
        self.event = event
        self.value = value
        self.bindingHash = bindingHash
    }
}

public protocol LocalDevVPNTraceRecording: Sendable {
    func record(_ value: LocalDevVPNTraceRecord) async
}

public struct NoOpLocalDevVPNTraceRecorder: LocalDevVPNTraceRecording {
    public init() {}
    public func record(_ value: LocalDevVPNTraceRecord) async {}
}

/// JSON-lines trace retained beside installation state. Trace I/O is
/// diagnostic-only and can never change readiness or transition outcomes.
public actor FileLocalDevVPNTraceRecorder: LocalDevVPNTraceRecording {
    public static let fileName = "localdevvpn-transition-trace.jsonl"
    private let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func record(_ value: LocalDevVPNTraceRecord) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(value)
            data.append(0x0A)
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            return
        }
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
    private let traceRecorder: any LocalDevVPNTraceRecording

    public init(
        service: any NativeApplicationServicing,
        initialProbeAttempts: Int = 4,
        readinessAttempts: Int = 48,
        delayNanoseconds: UInt64 = 500_000_000,
        compatibilityPolicy: LocalDevVPNCompatibilityPolicy = LocalDevVPNCompatibilityPolicy(),
        traceRecorder: any LocalDevVPNTraceRecording = NoOpLocalDevVPNTraceRecorder()
    ) {
        self.service = service
        self.initialProbeAttempts = initialProbeAttempts
        self.readinessAttempts = readinessAttempts
        self.delayNanoseconds = delayNanoseconds
        self.compatibilityPolicy = compatibilityPolicy
        self.traceRecorder = traceRecorder
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
            await trace("vpn.requestWritten", request: request)
        } catch {
            let failure = Self.mapTransport(error)
            await trace("vpn.failed", value: failure.rawValue, request: request)
            throw failure
        }
        do {
            try await service.launch(bundleIdentifier: iosSimBundleIdentifier, on: device)
            await trace("vpn.veyaLaunchSucceeded", request: request)
        } catch {
            let failure = Self.mapTransport(error)
            await trace("vpn.veyaLaunchFailed", value: failure.rawValue, request: request)
            await trace("vpn.failed", value: failure.rawValue, request: request)
            throw failure
        }

        do {
            if let ready = try await poll(
                request: request,
                device: device,
                attempts: initialProbeAttempts,
                stopOnActionRequired: false
            ) {
                await trace("vpn.completed", request: request)
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
                await trace("vpn.localDevVPNLaunchSucceeded", request: request)
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
                await trace("vpn.completed", request: request)
                return ready
            }
            throw LocalDevVPNSetupFailure.receiptMissing
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as LocalDevVPNSetupFailure {
            await trace("vpn.failed", value: failure.rawValue, request: request)
            throw failure
        } catch {
            let failure = Self.mapTransport(error)
            await trace("vpn.failed", value: failure.rawValue, request: request)
            throw failure
        }
    }

    private func poll(
        request: LocalDevVPNSetupRequestPayload,
        device: IOSSimDeviceIdentity,
        attempts: Int,
        stopOnActionRequired: Bool
    ) async throws -> LocalDevVPNSetupReceiptPayload? {
        var rejectedReceipt = false
        var lastTraceSignature: String?
        var receiptObserved = false
        for attempt in 0..<max(1, attempts) {
            if Task.isCancelled { throw CancellationError() }
            let data: Data
            do {
                data = try await service.readContainer(
                    bundleIdentifier: request.appBundleIdentifier,
                    relativePath: Self.receiptPath,
                    on: device
                )
            } catch NativeDeviceBridgeError.containerFileNotFound {
                if lastTraceSignature != "read:fileAbsent" {
                    await trace("vpn.receiptReadUnavailable", value: "fileAbsent", request: request)
                    lastTraceSignature = "read:fileAbsent"
                }
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: delayNanoseconds) }
                continue
            } catch {
                let category = Self.transportCategory(error)
                if lastTraceSignature != "read:\(category)" {
                    await trace("vpn.receiptReadUnavailable", value: category, request: request)
                    lastTraceSignature = "read:\(category)"
                }
                throw Self.mapTransport(error)
            }

            if !receiptObserved {
                await trace("vpn.receiptObserved", request: request)
                receiptObserved = true
            }
            guard let receipt = try? JSONDecoder().decode(LocalDevVPNSetupReceiptPayload.self, from: data) else {
                rejectedReceipt = true
                if lastTraceSignature != "reject:malformed" {
                    await trace("vpn.receiptRejected", value: "malformed", request: request)
                    lastTraceSignature = "reject:malformed"
                }
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: delayNanoseconds) }
                continue
            }
            guard receipt.schemaVersion == 1 else {
                rejectedReceipt = true
                if lastTraceSignature != "reject:schemaVersion" {
                    await trace("vpn.receiptRejected", value: "schemaVersion", request: request)
                    lastTraceSignature = "reject:schemaVersion"
                }
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: delayNanoseconds) }
                continue
            }
            guard receipt.requestID == request.requestID else {
                rejectedReceipt = true
                if lastTraceSignature != "reject:requestIDMismatch" {
                    await trace("vpn.receiptRejected", value: "requestIDMismatch", request: request)
                    lastTraceSignature = "reject:requestIDMismatch"
                }
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: delayNanoseconds) }
                continue
            }
            guard receipt.endpoint == request.endpoint else {
                rejectedReceipt = true
                if lastTraceSignature != "reject:endpointMismatch" {
                    await trace("vpn.receiptRejected", value: "endpointMismatch", request: request)
                    lastTraceSignature = "reject:endpointMismatch"
                }
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: delayNanoseconds) }
                continue
            }
            guard receipt.deviceUDID == request.deviceUDID,
                  receipt.teamIdentifier == request.teamIdentifier,
                  receipt.releaseIdentity == request.releaseIdentity else {
                rejectedReceipt = true
                if lastTraceSignature != "reject:bindingMismatch" {
                    await trace("vpn.receiptRejected", value: "bindingMismatch", request: request)
                    lastTraceSignature = "reject:bindingMismatch"
                }
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: delayNanoseconds) }
                continue
            }

            let state = receipt.lifecycleState ?? (receipt.status == "ready" ? .runtimeEndpointReachable : nil)
            let signature = "state:\(state?.rawValue ?? "unknown"):\(receipt.interfaceVisible):\(receipt.endpointReachable)"
            if signature != lastTraceSignature {
                await trace("vpn.receiptState", value: state?.rawValue ?? "UNKNOWN", request: request)
                await trace("vpn.interfaceVisible", value: String(receipt.interfaceVisible), request: request)
                await trace("vpn.endpointReachable", value: String(receipt.endpointReachable), request: request)
                lastTraceSignature = signature
            }
            if state == .runtimeEndpointReachable {
                guard receipt.endpointReachable else {
                    await trace("vpn.receiptRejected", value: "readyWithoutEndpoint", request: request)
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
                await trace("vpn.receiptRejected", value: "status", request: request)
                throw LocalDevVPNSetupFailure.receiptInvalid
            }
            if attempt + 1 < attempts {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        if stopOnActionRequired, rejectedReceipt {
            throw LocalDevVPNSetupFailure.receiptInvalid
        }
        return nil
    }

    private func trace(_ event: String, value: String? = nil, request: LocalDevVPNSetupRequestPayload) async {
        await traceRecorder.record(LocalDevVPNTraceRecord(
            event: event,
            value: value,
            bindingHash: Self.bindingHash(request)
        ))
    }

    /// Observation and transition share the same secret-free binding hash, so
    /// a physical trace can show whether a fresh receipt absence advanced into
    /// the request/launch/probe handshake. Trace failure remains non-fatal in
    /// the recorder implementation.
    public func recordObservation(
        _ event: String,
        value: String? = nil,
        device: IOSSimDeviceIdentity,
        appBundleIdentifier: String,
        teamIdentifier: String?,
        releaseIdentity: String?
    ) async {
        let request = LocalDevVPNSetupRequestPayload(
            requestID: "observation",
            appBundleIdentifier: appBundleIdentifier,
            deviceUDID: device.udid,
            teamIdentifier: teamIdentifier,
            releaseIdentity: releaseIdentity
        )
        await trace(event, value: value, request: request)
    }

    private static func bindingHash(_ request: LocalDevVPNSetupRequestPayload) -> String {
        let material = [
            request.deviceUDID ?? "none",
            request.teamIdentifier ?? "none",
            request.releaseIdentity ?? "none",
            request.appBundleIdentifier,
            request.endpoint.host,
            String(request.endpoint.port),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func transportCategory(_ error: Error) -> String {
        guard let bridge = error as? NativeDeviceBridgeError else { return "other" }
        switch bridge {
        case .deviceNotFound, .deviceResolutionFailed(_): return "deviceUnavailable"
        case .deviceDisconnected: return "deviceDisconnected"
        case .timedOut: return "timedOut"
        case .deviceLocked: return "deviceLocked"
        case .trustRequired, .trustPromptPending, .trustDenied: return "deviceTrustRequired"
        case .containerUnavailable(_): return "containerUnavailable"
        case .containerFileNotFound(_): return "fileAbsent"
        case .developerModeRequired: return "developerModeRequired"
        case _ where bridge.isDeveloperTrustRejection: return "developerTrustRequired"
        default: return "bridgeUnavailable"
        }
    }

    private static func mapTransport(_ error: Error) -> LocalDevVPNSetupFailure {
        guard let bridge = error as? NativeDeviceBridgeError else { return .transportUnavailable }
        switch bridge {
        case .applicationNotFound(_): return .appMissing
        case _ where bridge.isDeveloperTrustRejection: return .developerTrustRequired
        case .developerModeRequired: return .developerModeRequired
        case .deviceNotFound, .deviceResolutionFailed(_), .deviceDisconnected, .timedOut,
             .deviceLocked, .trustRequired:
            return .transportUnavailable
        default:
            return .transportUnavailable
        }
    }
}
