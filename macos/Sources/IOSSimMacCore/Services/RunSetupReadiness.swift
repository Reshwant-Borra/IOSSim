import CryptoKit
import Foundation

// Setup completion proved by the user's own Run Setup tap in the installed app.
// Veya writes the request into the app container over House Arrest (the same
// SetupInbox path the automatic pairing and LocalDevVPN steps already use) and
// then only reads. It never launches a setup run on the phone: the receipt it
// accepts is the result of the real product path the user started.

public struct RunSetupRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

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
    public static let currentSchemaVersion = 1

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
    public let locationVerified: Bool
    public let locationCleared: Bool
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
        locationVerified: Bool,
        locationCleared: Bool,
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
        self.locationVerified = locationVerified
        self.locationCleared = locationCleared
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
            && sessionEstablished && locationVerified && locationCleared
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

    /// Defaults wait about five minutes for the tap, reporting the result as soon
    /// as it lands. There is no fixed waiting period: a tap ends the wait.
    public init(
        service: any NativeApplicationServicing,
        pollCount: Int = 600,
        pollNanoseconds: UInt64 = 500_000_000,
        progress: (@Sendable (RunSetupProgress) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.pollCount = max(1, pollCount)
        self.pollNanoseconds = pollNanoseconds
        self.progress = progress
        self.now = now
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
        return request
    }

    /// Reads until the user's tap produces a bound success receipt. A reported
    /// failure is surfaced immediately through `progress` and kept as the reason
    /// the wait finally fails, while the user can still fix it and tap again.
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
