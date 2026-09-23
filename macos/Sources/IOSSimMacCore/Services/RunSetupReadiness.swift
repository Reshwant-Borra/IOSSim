import CryptoKit
import Foundation

// Setup completion proved by the user's own Run Setup tap in the installed app.
// Veya writes the request into the app container over House Arrest (the same
// SetupInbox path the automatic pairing and LocalDevVPN steps already use) and
// then only reads. It never launches a setup run on the phone: the receipt it
// accepts is the result of the real product path the user started.

public struct RunSetupRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Matches `RunSetupInbox` on the phone: a request outlives one Veya run so a
    /// late tap still answers the request Veya is already holding.
    public static let lifetime: TimeInterval = 15 * 60

    public let schemaVersion: Int
    public let requestID: String
    public let deviceUDID: String
    public let teamIdentifier: String
    public let releaseIdentity: String
    public let appBundleIdentifier: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: String = UUID().uuidString,
        deviceUDID: String,
        teamIdentifier: String,
        releaseIdentity: String,
        appBundleIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier
        self.releaseIdentity = releaseIdentity
        self.appBundleIdentifier = appBundleIdentifier
        self.createdAt = createdAt
    }
}

public struct RunSetupReceipt: Codable, Equatable, Sendable {
    /// 2: the session proof is a read-only dtservicehub round-trip. Version 1 proved it by
    /// simulating a coordinate and clearing it, which moved the user's location during setup.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let requestID: String
    public let deviceUDIDHash: String
    public let teamIdentifier: String
    public let releaseIdentity: String
    public let appBundleIdentifier: String
    public let pairingIdentifier: String
    public let pairingPublicKeyFingerprint: String
    public let pairingReady: Bool
    public let localDevVPNReady: Bool
    public let endpointReachable: Bool
    public let sessionEstablished: Bool
    /// A real request reached dtservicehub on this session and the answer came back. Read-only:
    /// setup never changes the device's location.
    public let sessionProbed: Bool
    public let errorCode: String?
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: String,
        deviceUDIDHash: String,
        teamIdentifier: String,
        releaseIdentity: String,
        appBundleIdentifier: String,
        pairingIdentifier: String,
        pairingPublicKeyFingerprint: String,
        pairingReady: Bool,
        localDevVPNReady: Bool,
        endpointReachable: Bool,
        sessionEstablished: Bool,
        sessionProbed: Bool,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        completedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.deviceUDIDHash = deviceUDIDHash
        self.teamIdentifier = teamIdentifier
        self.releaseIdentity = releaseIdentity
        self.appBundleIdentifier = appBundleIdentifier
        self.pairingIdentifier = pairingIdentifier
        self.pairingPublicKeyFingerprint = pairingPublicKeyFingerprint
        self.pairingReady = pairingReady
        self.localDevVPNReady = localDevVPNReady
        self.endpointReachable = endpointReachable
        self.sessionEstablished = sessionEstablished
        self.sessionProbed = sessionProbed
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }

    /// Every stage of the real run reached, with no reported error.
    public var succeeded: Bool {
        schemaVersion == Self.currentSchemaVersion
            && deviceUDIDHash.count == 64
            && !pairingIdentifier.isEmpty
            && pairingPublicKeyFingerprint.count == 64
            && pairingReady && localDevVPNReady && endpointReachable
            && sessionEstablished && sessionProbed
            && errorCode == nil
    }

    /// Bound to this request, this device, this installed app, and the pairing
    /// record Veya delivered. A receipt from an earlier request, another device,
    /// or a pairing Veya does not own can never satisfy setup.
    public func satisfies(
        _ request: RunSetupRequest,
        appBundleIdentifier: String,
        pairingIdentifier expectedPairingIdentifier: String,
        pairingPublicKeyFingerprint expectedFingerprint: String,
        now: Date = Date()
    ) -> Bool {
        succeeded
            && request.schemaVersion == RunSetupRequest.currentSchemaVersion
            && requestID == request.requestID
            && deviceUDIDHash == Self.hash(request.deviceUDID)
            && teamIdentifier == request.teamIdentifier
            && releaseIdentity == request.releaseIdentity
            && self.appBundleIdentifier == appBundleIdentifier
            && pairingIdentifier == expectedPairingIdentifier
            && pairingPublicKeyFingerprint == expectedFingerprint
            && completedAt >= request.createdAt.addingTimeInterval(-5)
            && completedAt <= now.addingTimeInterval(5)
    }

    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RunSetupFailure: Error, Equatable, Sendable {
    /// Veya could not describe the run it is asking for (missing identity).
    case requestInvalid
    /// No receipt for this request: the user has not tapped Run Setup yet.
    case notTapped
    /// The phone reported a failed or partial run, with its own product error.
    case reportedOnPhone(code: String, message: String)
    /// A receipt exists but is not bound to this request, device, app or pairing.
    case receiptInvalid
}

/// What Veya is waiting on, so the UI can say it while the wait is in progress.
public enum RunSetupProgress: Equatable, Sendable {
    /// Veya has just placed a request the user has not seen yet: everything the Mac can
    /// do is done and the iPhone is the next step.
    case readyForSetup
    case waitingForRunSetupTap
    case failedOnPhone(code: String, message: String)
}

public actor RunSetupReadinessCoordinator {
    public static let requestPath = "Library/Application Support/IOSSim/SetupInbox/run-setup.request"
    public static let receiptPath = "Library/Application Support/IOSSim/SetupInbox/run-setup.receipt"

    private let service: any NativeApplicationServicing
    private let pollCount: Int
    private let pollNanoseconds: UInt64
    private let progress: (@Sendable (RunSetupProgress) -> Void)?
    private let now: @Sendable () -> Date
    /// Where Veya keeps the request it issued. The phone deletes its copy once a run
    /// succeeds, so without this the tap Veya asked for could never be verified.
    private let pendingRequestURL: URL?

    /// Defaults to a single read: Veya never blocks a run waiting for a human. A run
    /// that finds no receipt ends immediately as a user action, and the next one
    /// verifies the same request.
    public init(
        service: any NativeApplicationServicing,
        stateRoot: URL? = nil,
        pollCount: Int = 1,
        pollNanoseconds: UInt64 = 500_000_000,
        progress: (@Sendable (RunSetupProgress) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.pendingRequestURL = stateRoot?
            .appendingPathComponent("run-setup", isDirectory: true)
            .appendingPathComponent("pending-request.json")
        self.pollCount = max(1, pollCount)
        self.pollNanoseconds = pollNanoseconds
        self.progress = progress
        self.now = now
    }

    /// The request Veya already issued and the phone can still answer, or nil when
    /// there is none, it expired, or it describes another device, team, release or
    /// app. Reusing it is what makes a late tap count and a retry idempotent.
    public func pendingRequest(
        device: IOSSimDeviceIdentity,
        appBundleIdentifier: String,
        teamIdentifier: String,
        releaseIdentity: String
    ) async -> RunSetupRequest? {
        guard let url = pendingRequestURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let request = try? decoder.decode(RunSetupRequest.self, from: data),
              request.schemaVersion == RunSetupRequest.currentSchemaVersion,
              request.deviceUDID == device.udid, request.teamIdentifier == teamIdentifier,
              request.releaseIdentity == releaseIdentity, request.appBundleIdentifier == appBundleIdentifier else {
            return nil
        }
        let age = now().timeIntervalSince(request.createdAt)
        guard age >= -60, age <= RunSetupRequest.lifetime else { return nil }
        // The phone keeps the request until a run succeeds and then replaces it with the
        // receipt, so either one carrying this ID means the phone can still answer it.
        // Neither (reinstall, wiped container) means the request has to be reissued.
        if let onDevice: RunSetupRequest = try? await read(Self.requestPath, appBundleIdentifier, device, decoder),
           onDevice.requestID == request.requestID {
            return request
        }
        if let receipt: RunSetupReceipt = try? await read(Self.receiptPath, appBundleIdentifier, device, decoder),
           receipt.requestID == request.requestID {
            return request
        }
        return nil
    }

    private func read<T: Decodable>(
        _ path: String, _ appBundleIdentifier: String, _ device: IOSSimDeviceIdentity, _ decoder: JSONDecoder
    ) async throws -> T {
        try decoder.decode(T.self, from: try await service.readContainer(
            bundleIdentifier: appBundleIdentifier, relativePath: path, on: device))
    }

    private func store(_ request: RunSetupRequest) {
        guard let url = pendingRequestURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? (try? encoder.encode(request))?.write(to: url, options: [.atomic])
    }

    /// The phone retires a request once its run succeeds, so Veya drops its copy as
    /// soon as it has accepted the receipt; the next run asks for a fresh tap.
    private func retirePendingRequest() {
        guard let url = pendingRequestURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Places the request the user's tap will answer. This writes a file; it does
    /// not launch, foreground, or drive the app.
    public func requestSetup(
        device: IOSSimDeviceIdentity,
        appBundleIdentifier: String,
        teamIdentifier: String,
        releaseIdentity: String
    ) async throws -> RunSetupRequest {
        guard NativeApplicationPathPolicy.isValidBundleIdentifier(appBundleIdentifier),
              !device.udid.isEmpty, !teamIdentifier.isEmpty, !releaseIdentity.isEmpty else {
            throw RunSetupFailure.requestInvalid
        }
        let request = RunSetupRequest(
            deviceUDID: device.udid,
            teamIdentifier: teamIdentifier,
            releaseIdentity: releaseIdentity,
            appBundleIdentifier: appBundleIdentifier,
            createdAt: now()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await service.writeContainer(
            bundleIdentifier: appBundleIdentifier,
            relativePath: Self.requestPath,
            data: try encoder.encode(request),
            on: device
        )
        store(request)
        progress?(.readyForSetup)
        return request
    }

    /// Reads the result of the user's tap for this request. At the default
    /// `pollCount` this is a single read, so no Veya run ever blocks on a human:
    /// no receipt is `notTapped` (the caller reports the action and the next run
    /// verifies the same request), and a reported failure is surfaced through
    /// `progress` and kept as the reason, so the user can fix it and tap again.
    public func awaitRunSetup(
        request: RunSetupRequest,
        device: IOSSimDeviceIdentity,
        appBundleIdentifier: String,
        pairingIdentifier: String,
        pairingPublicKeyFingerprint: String
    ) async throws -> RunSetupReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var lastReported: RunSetupFailure?
        var announcedWaiting = false
        for attempt in 0..<pollCount {
            if Task.isCancelled { throw CancellationError() }
            if let data = try? await service.readContainer(
                bundleIdentifier: appBundleIdentifier,
                relativePath: Self.receiptPath,
                on: device
            ), let receipt = try? decoder.decode(RunSetupReceipt.self, from: data),
               receipt.requestID == request.requestID {
                if receipt.satisfies(
                    request,
                    appBundleIdentifier: appBundleIdentifier,
                    pairingIdentifier: pairingIdentifier,
                    pairingPublicKeyFingerprint: pairingPublicKeyFingerprint,
                    now: now()
                ) {
                    retirePendingRequest()
                    return receipt
                }
                let failure = Self.failure(for: receipt)
                if failure != lastReported {
                    lastReported = failure
                    if case .reportedOnPhone(let code, let message) = failure {
                        progress?(.failedOnPhone(code: code, message: message))
                    }
                }
            } else if !announcedWaiting {
                announcedWaiting = true
                progress?(.waitingForRunSetupTap)
            }
            if attempt + 1 < pollCount { try await Task.sleep(nanoseconds: pollNanoseconds) }
        }
        throw lastReported ?? .notTapped
    }

    /// A receipt that did not satisfy the binding: the phone's own error when it
    /// reported one, otherwise an unusable receipt.
    static func failure(for receipt: RunSetupReceipt) -> RunSetupFailure {
        guard let code = receipt.errorCode, !code.isEmpty else { return .receiptInvalid }
        return .reportedOnPhone(code: code, message: receipt.errorMessage ?? "")
    }
}
