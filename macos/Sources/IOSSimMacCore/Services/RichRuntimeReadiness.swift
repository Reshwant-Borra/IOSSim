import CryptoKit
import Foundation

public struct RichRuntimeProofRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
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

    public init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: String = UUID().uuidString,
        deviceUDID: String,
        teamIdentifier: String,
        releaseIdentity: String,
        artifactSetIdentity: String,
        profileSetIdentity: String,
        pairingGeneration: UInt64,
        developerServicesSession: String,
        developerSupportIdentity: String,
        runnerBundleIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.deviceUDID = deviceUDID
        self.teamIdentifier = teamIdentifier
        self.releaseIdentity = releaseIdentity
        self.artifactSetIdentity = artifactSetIdentity
        self.profileSetIdentity = profileSetIdentity
        self.pairingGeneration = pairingGeneration
        self.developerServicesSession = developerServicesSession
        self.developerSupportIdentity = developerSupportIdentity
        self.runnerBundleIdentifier = runnerBundleIdentifier
        self.createdAt = createdAt
    }
}

public struct RichRuntimeProofReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
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

    public var ready: Bool {
        schemaVersion == Self.currentSchemaVersion
            && deviceUDIDHash.count == 64
            && pairingGeneration > 0
            && testManagerControlReady && runnerLaunched && xctestHandshakeReady
            && testPlanStarted && richLocationProbeCompleted && locationCleared && sessionCleanedUp
    }

    public func validates(_ request: RichRuntimeProofRequest, now: Date = Date()) -> Bool {
        ready
            && request.schemaVersion == RichRuntimeProofRequest.currentSchemaVersion
            && requestID == request.requestID
            && deviceUDIDHash == Self.hash(request.deviceUDID)
            && teamIdentifier == request.teamIdentifier
            && releaseIdentity == request.releaseIdentity
            && artifactSetIdentity == request.artifactSetIdentity
            && profileSetIdentity == request.profileSetIdentity
            && pairingGeneration == request.pairingGeneration
            && developerServicesSession == request.developerServicesSession
            && developerSupportIdentity == request.developerSupportIdentity
            && runnerBundleIdentifier == request.runnerBundleIdentifier
            && completedAt >= request.createdAt.addingTimeInterval(-5)
            && completedAt <= now.addingTimeInterval(5)
            && now.timeIntervalSince(completedAt) <= 300
    }

    public func validates(manifest: ConsumerProvisioningManifest) -> Bool {
        ready
            && teamIdentifier == manifest.teamID
            && releaseIdentity == "\(manifest.appVersion):\(manifest.provisionerVersion)"
            && artifactSetIdentity == RichRuntimeProofIdentity.artifactSet(manifest: manifest)
            && profileSetIdentity == RichRuntimeProofIdentity.profiles(manifest: manifest)
            && runnerBundleIdentifier == manifest.installedRunnerBundleID
    }

    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RichRuntimeProofFailure: String, Error, Codable, Equatable, Sendable {
    case invalidRequest = "VEYA-RUNTIME-001"
    case receiptUnavailable = "VEYA-RUNTIME-002"
    case receiptInvalid = "VEYA-RUNTIME-003"
    case proofFailed = "VEYA-RUNTIME-004"
    case cleanupFailed = "VEYA-RUNTIME-005"
}

public actor RichRuntimeReadinessCoordinator {
    public static let requestPath = "Library/Application Support/IOSSim/SetupInbox/rich-runtime-proof.request"
    public static let receiptPath = "Library/Application Support/IOSSim/SetupInbox/rich-runtime-proof.receipt"

    private let service: any NativeApplicationServicing
    private let pollCount: Int
    private let pollNanoseconds: UInt64

    public init(
        service: any NativeApplicationServicing,
        pollCount: Int = 600,
        pollNanoseconds: UInt64 = 250_000_000
    ) {
        self.service = service
        self.pollCount = max(1, pollCount)
        self.pollNanoseconds = pollNanoseconds
    }

    public func prove(
        request: RichRuntimeProofRequest,
        device: IOSSimDeviceIdentity,
        appBundleIdentifier: String
    ) async throws -> RichRuntimeProofReceipt {
        guard request.schemaVersion == RichRuntimeProofRequest.currentSchemaVersion,
              request.deviceUDID == device.udid,
              request.pairingGeneration > 0,
              !request.releaseIdentity.isEmpty,
              NativeApplicationPathPolicy.isValidBundleIdentifier(request.runnerBundleIdentifier),
              NativeApplicationPathPolicy.isValidBundleIdentifier(appBundleIdentifier),
              Date().timeIntervalSince(request.createdAt) <= 60 else {
            throw RichRuntimeProofFailure.invalidRequest
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await service.writeContainer(
            bundleIdentifier: appBundleIdentifier,
            relativePath: Self.requestPath,
            data: try encoder.encode(request),
            on: device
        )
        try await service.launch(bundleIdentifier: appBundleIdentifier, on: device)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for _ in 0..<pollCount {
            if Task.isCancelled { throw CancellationError() }
            if let data = try? await service.readContainer(
                bundleIdentifier: appBundleIdentifier,
                relativePath: Self.receiptPath,
                on: device
            ), let receipt = try? decoder.decode(RichRuntimeProofReceipt.self, from: data),
               receipt.requestID == request.requestID {
                guard receipt.validates(request) else {
                    throw receipt.locationCleared ? RichRuntimeProofFailure.proofFailed : .cleanupFailed
                }
                return receipt
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        throw RichRuntimeProofFailure.receiptUnavailable
    }
}

public enum RichRuntimeProofIdentity {
    public static func artifactSet(manifest: ConsumerProvisioningManifest) -> String {
        hash([
            manifest.installedMainBundleID,
            manifest.installedRunnerBundleID,
            manifest.appVersion,
            manifest.provisionerVersion,
        ])
    }

    public static func profiles(manifest: ConsumerProvisioningManifest) -> String {
        hash([
            manifest.mainProfile.profileFingerprint ?? "missing-main-profile-fingerprint",
            manifest.runnerProfile.profileFingerprint ?? "missing-runner-profile-fingerprint",
        ])
    }

    private static func hash(_ values: [String]) -> String {
        let data = Data(values.joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
