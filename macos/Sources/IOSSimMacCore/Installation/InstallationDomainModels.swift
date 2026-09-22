import Foundation

public struct Generation: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let initial = Generation(rawValue: 0)

    public static func < (lhs: Generation, rhs: Generation) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func advanced() throws -> Generation {
        guard rawValue < UInt64.max else { throw InstallationStateFailure.generationOverflow }
        return Generation(rawValue: rawValue + 1)
    }
}

public struct RunID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum InstallationDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case artifact
    case authorization
    case team
    case signingKey
    case certificate
    case profile
    case payload
    case application
    case developerSupport
    case pairing
    case vpn
    case runtime
    case migration
}

public enum ResourceLifecycle: String, Codable, Sendable {
    case candidate
    case active
    case retiring
    case retired
    case invalid
}

public enum OwnershipLevel: String, Codable, Comparable, Sendable {
    case unknown
    case metadataClaim
    case historicalReceipt
    case privateKeyControl
    case activePayloadCorroboration

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .metadataClaim: return 1
        case .historicalReceipt: return 2
        case .privateKeyControl: return 3
        case .activePayloadCorroboration: return 4
        }
    }

    public static func < (lhs: OwnershipLevel, rhs: OwnershipLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct ResourceIdentity: Codable, Equatable, Hashable, Sendable {
    public let domain: InstallationDomain
    public let resourceID: String
    public let digest: String?

    public init(domain: InstallationDomain, resourceID: String, digest: String? = nil) throws {
        try InstallationSafeValue.validate(resourceID, field: "resourceID", maximumLength: 256)
        if let digest {
            try InstallationSafeValue.validateDigest(digest)
        }
        self.domain = domain
        self.resourceID = resourceID
        self.digest = digest
    }
}

public struct Evidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let generation: Generation
    public let subject: ResourceIdentity
    public let capturedAt: Date
    public let validUntil: Date?
    /// Non-nil for device-connection-bound proof; such evidence is void after reconnect.
    public let connectionGeneration: UInt64?
    public let provenance: String
    public let attributes: [String: String]

    public init(
        id: String,
        kind: String,
        generation: Generation,
        subject: ResourceIdentity,
        capturedAt: Date,
        validUntil: Date? = nil,
        connectionGeneration: UInt64? = nil,
        provenance: String,
        attributes: [String: String] = [:]
    ) throws {
        try InstallationSafeValue.validateDigest(id)
        try InstallationSafeValue.validate(kind, field: "evidence kind", maximumLength: 96)
        try InstallationSafeValue.validate(provenance, field: "provenance", maximumLength: 128)
        try InstallationSafeValue.validate(attributes: attributes)
        self.id = id
        self.kind = kind
        self.generation = generation
        self.subject = subject
        self.capturedAt = capturedAt
        self.validUntil = validUntil
        self.connectionGeneration = connectionGeneration
        self.provenance = provenance
        self.attributes = attributes
    }

    public func isFresh(at date: Date) -> Bool {
        validUntil.map { $0 > date } ?? true
    }
}

public struct ResourceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let identity: ResourceIdentity
    public var lifecycle: ResourceLifecycle
    public let generation: Generation
    public let ownership: OwnershipLevel
    public let createdAt: Date
    public var observedAt: Date
    public let expiresAt: Date?
    public let relativeLocation: String?
    public var evidenceIDs: [String]
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString.lowercased(),
        identity: ResourceIdentity,
        lifecycle: ResourceLifecycle,
        generation: Generation,
        ownership: OwnershipLevel,
        createdAt: Date,
        observedAt: Date,
        expiresAt: Date? = nil,
        relativeLocation: String? = nil,
        evidenceIDs: [String] = [],
        metadata: [String: String] = [:]
    ) throws {
        try InstallationSafeValue.validate(id, field: "record ID", maximumLength: 128)
        if let relativeLocation {
            try InstallationSafeValue.validateRelativePath(relativeLocation)
        }
        for evidenceID in evidenceIDs { try InstallationSafeValue.validateDigest(evidenceID) }
        try InstallationSafeValue.validate(attributes: metadata)
        self.id = id
        self.identity = identity
        self.lifecycle = lifecycle
        self.generation = generation
        self.ownership = ownership
        self.createdAt = createdAt
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.relativeLocation = relativeLocation
        self.evidenceIDs = evidenceIDs
        self.metadata = metadata
    }
}

public struct ActiveCandidate<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var active: Value?
    public var candidate: Value?

    public init(active: Value? = nil, candidate: Value? = nil) {
        self.active = active
        self.candidate = candidate
    }
}

enum InstallationSafeValue {
    private static let secretMarkers = [
        "password", "privatekey", "private_key", "token", "cookie", "escrowbag", "2fa"
    ]

    static func validate(_ value: String, field: String, maximumLength: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumLength,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw InstallationStateFailure.unsafeValue(field)
        }
    }

    static func validateDigest(_ value: String) throws {
        guard value.hasPrefix("sha256:"), value.dropFirst(7).count == 64,
              value.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw InstallationStateFailure.unsafeValue("digest")
        }
    }

    static func validateRelativePath(_ value: String) throws {
        try validate(value, field: "relative location", maximumLength: 512)
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.hasPrefix("/"), !components.contains(".."), !components.contains("") else {
            throw InstallationStateFailure.unsafeValue("relative location")
        }
    }

    static func validate(attributes: [String: String]) throws {
        guard attributes.count <= 64 else { throw InstallationStateFailure.unsafeValue("attributes") }
        for (key, value) in attributes {
            try validate(key, field: "attribute key", maximumLength: 96)
            let normalizedKey = key.lowercased().replacingOccurrences(of: "-", with: "_")
            guard !secretMarkers.contains(where: normalizedKey.contains) else {
                throw InstallationStateFailure.secretMaterialRejected("attribute key")
            }
            try validate(value, field: "attribute value", maximumLength: 512)
        }
    }
}
