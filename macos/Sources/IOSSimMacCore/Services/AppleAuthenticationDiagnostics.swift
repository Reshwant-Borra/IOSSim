import Foundation

public enum AppleNetworkFailureCategory: String, Codable, Equatable, Sendable {
    case dns
    case tls
    case unreachable
    case timeout
    case connectionLost
    case cancelled
    case other
}

public enum AppleTransportFailureClassifier {
    public static func category(for error: Error) -> AppleNetworkFailureCategory {
        guard let error = error as? URLError else { return .other }
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired: return .tls
        case .notConnectedToInternet, .cannotConnectToHost,
             .networkConnectionLost, .internationalRoamingOff,
             .dataNotAllowed: return .unreachable
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        default: return .other
        }
    }
}

public enum AppleHTTPFailureKind: String, Codable, Equatable, Sendable {
    case rateLimited
    case serviceUnavailable
    case httpServiceResponse
    case malformedResponse
    case clientMetadataRejected
    case grandSlamChallengeRejected
    case srpProofRejected
    case twoFactorRequired
    case twoFactorRejected
}

public struct SafeAppleAuthenticationReport: Codable, Equatable, Sendable {
    public let phase: String
    public let endpointClass: String
    public let httpStatus: Int?
    public let responseContentType: String?
    public let requestFieldNames: [String]
    public let responseFieldNames: [String]
    public let byteLengths: [String: Int]
    public let clientIdentityClassification: String
    public let protocolVersion: String
    public let retryable: Bool
    public let retryAfterSeconds: Int?

    public init(
        phase: String,
        endpointClass: String,
        httpStatus: Int?,
        responseContentType: String?,
        requestFieldNames: [String],
        responseFieldNames: [String],
        byteLengths: [String: Int],
        clientIdentityClassification: String,
        protocolVersion: String,
        retryable: Bool,
        retryAfterSeconds: Int?
    ) {
        self.phase = phase
        self.endpointClass = endpointClass
        self.httpStatus = httpStatus
        self.responseContentType = responseContentType
        self.requestFieldNames = requestFieldNames.sorted()
        self.responseFieldNames = responseFieldNames.sorted()
        self.byteLengths = byteLengths
        self.clientIdentityClassification = clientIdentityClassification
        self.protocolVersion = protocolVersion
        self.retryable = retryable
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public enum GrandSlamVerificationRequestBuilder {
    public static func trustedDeviceValidation(
        endpoint: URL,
        identityToken: String,
        verificationCode: String
    ) throws -> URLRequest {
        guard endpoint.scheme == "https", endpoint.host == "gsa.apple.com",
              !identityToken.isEmpty, identityToken.utf8.count <= 32_768,
              verificationCode.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else {
            throw ExperimentalBackendError.verificationRejected
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(identityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
        request.setValue(verificationCode, forHTTPHeaderField: "security-code")
        return request
    }
}

public enum GrandSlamRequestIdentity {
    public static let akdToken = "<com.apple.AuthKit/1 (com.apple.akd/1.0)>"

    public static func normalizedClientInfo(_ value: String?) throws -> String {
        guard let value, value.utf8.count <= 768,
              !value.contains("\r"), !value.contains("\n") else {
            throw ExperimentalBackendError.localAnisetteUnavailable
        }
        let expression = try NSRegularExpression(
            pattern: #"^(<[^<>]{1,128}>)\s+(<[^<>]{1,256}>)\s+<[^<>]{1,256}>$"#
        )
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range), match.range == range,
              let hardwareRange = Range(match.range(at: 1), in: value),
              let systemRange = Range(match.range(at: 2), in: value) else {
            throw ExperimentalBackendError.localAnisetteUnavailable
        }
        return "\(value[hardwareRange]) \(value[systemRange]) \(akdToken)"
    }

    public static func normalizedMachineHeaders(_ input: [String: String]) throws -> [String: String] {
        var output: [String: String] = [:]
        for (name, value) in input {
            guard !name.isEmpty, name.utf8.count <= 128, value.utf8.count <= 16_384,
                  !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else {
                throw ExperimentalBackendError.localAnisetteUnavailable
            }
            guard name.localizedCaseInsensitiveCompare("Cookie") != .orderedSame,
                  name.localizedCaseInsensitiveCompare("Authorization") != .orderedSame else { continue }
            output[name] = value
        }
        let source = input.first {
            $0.key.localizedCaseInsensitiveCompare("X-MMe-Client-Info") == .orderedSame
        }?.value
        output = output.filter {
            $0.key.localizedCaseInsensitiveCompare("X-MMe-Client-Info") != .orderedSame
        }
        output["X-MMe-Client-Info"] = try normalizedClientInfo(source)
        return output
    }

    public static func classification(_ value: String?) -> String {
        guard let value else { return "missing" }
        if value.contains("com.apple.dt.Xcode") { return "rejected-xcode" }
        if value.hasSuffix(akdToken) { return "akd" }
        return "unknown"
    }
}

public enum GrandSlamEndpointKey: String, CaseIterable, Sendable {
    case gsService
    case trustedDeviceSecondaryAuth
    case validateCode
}

public struct GrandSlamEndpointBag: Equatable, Sendable {
    public let endpoints: [GrandSlamEndpointKey: URL]
    public let fetchedAt: Date
    public let expiresAt: Date

    public func endpoint(_ key: GrandSlamEndpointKey) throws -> URL {
        guard let value = endpoints[key] else { throw ExperimentalBackendError.responseChanged }
        return value
    }

    public static func parse(_ data: Data, now: Date = Date(), ttl: TimeInterval = 900) throws -> Self {
        guard !data.isEmpty, data.count <= 1_048_576, (60...3_600).contains(ttl),
              let root = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let urls = root["urls"] as? [String: Any] else {
            throw ExperimentalBackendError.responseChanged
        }
        var parsed: [GrandSlamEndpointKey: URL] = [:]
        for key in GrandSlamEndpointKey.allCases {
            guard let raw = urls[key.rawValue] as? String,
                  raw.utf8.count <= 2_048,
                  let url = URL(string: raw), url.scheme == "https",
                  url.host == "gsa.apple.com" else {
                throw ExperimentalBackendError.responseChanged
            }
            parsed[key] = url
        }
        return GrandSlamEndpointBag(endpoints: parsed, fetchedAt: now, expiresAt: now.addingTimeInterval(ttl))
    }
}

public protocol GrandSlamEndpointResolving: Sendable {
    func endpoint(_ key: GrandSlamEndpointKey, machineHeaders: [String: String]) async throws -> URL
    func invalidate() async
}

public actor URLBagGrandSlamEndpointResolver: GrandSlamEndpointResolving {
    public static let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!

    private let transport: any AppleHTTPTransport
    private let now: @Sendable () -> Date
    private var cached: GrandSlamEndpointBag?

    public init(
        transport: any AppleHTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    public func endpoint(_ key: GrandSlamEndpointKey, machineHeaders: [String: String]) async throws -> URL {
        let current = now()
        if let cached, cached.expiresAt > current { return try cached.endpoint(key) }
        let headers = try GrandSlamRequestIdentity.normalizedMachineHeaders(machineHeaders)
        var request = URLRequest(url: Self.lookupURL)
        request.httpMethod = "GET"
        request.setValue(headers["X-MMe-Client-Info"], forHTTPHeaderField: "X-MMe-Client-Info")
        request.setValue(headers.first {
            $0.key.localizedCaseInsensitiveCompare("X-Mme-Device-Id") == .orderedSame
        }?.value, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-I-Locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Apple-I-TimeZone")
        request.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "X-Apple-I-TimeZone-Offset")
        request.setValue("akd/1.0", forHTTPHeaderField: "User-Agent")
        let response: AppleHTTPResponse
        do {
            response = try await transport.send(request, maximumBytes: 1_048_576)
        } catch {
            throw ExperimentalBackendError.networkFailure
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 { throw ExperimentalBackendError.rateLimited }
            if response.statusCode == 503 { throw ExperimentalBackendError.serviceUnavailable }
            throw ExperimentalBackendError.responseChanged
        }
        let bag = try GrandSlamEndpointBag.parse(response.body, now: current)
        cached = bag
        return try bag.endpoint(key)
    }

    public func invalidate() { cached = nil }
}

public actor FixedGrandSlamEndpointResolver: GrandSlamEndpointResolving {
    private let adapter: PrivateAppleProtocolAdapter

    public init(adapter: PrivateAppleProtocolAdapter) { self.adapter = adapter }

    public func endpoint(_ key: GrandSlamEndpointKey, machineHeaders: [String: String]) throws -> URL {
        switch key {
        case .gsService: return adapter.grandSlamService
        case .trustedDeviceSecondaryAuth: return adapter.trustedDeviceVerification
        case .validateCode: return adapter.verificationValidation
        }
    }

    public func invalidate() {}
}
