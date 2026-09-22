import BigInt
import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import ObjectiveC.runtime
import Security

// MARK: - Safe diagnostics

enum SetupStateTransition: String, Sendable {
    case authorizationResultReceived = "AUTHORIZATION_RESULT_RECEIVED"
    case authorizationStateUpdated = "AUTHORIZATION_STATE_UPDATED"
    case teamStateUpdated = "TEAM_STATE_UPDATED"
    case setupStepAdvanced = "SETUP_STEP_ADVANCED"
    case errorStateCleared = "ERROR_STATE_CLEARED"
    case uiStatePublished = "UI_STATE_PUBLISHED"
    case staleResultIgnored = "STALE_RESULT_IGNORED"
}

public struct ApplePersonalTeamDiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let checkpoint: String?
    public let stage: String
    public let safeErrorCode: String?
    public let httpStatus: Int?
    public let appleErrorCode: Int?
    public let retryAfterSeconds: Int?
    public let retryable: Bool
    public let reauthorizationRequired: Bool
    public let srpProtocol: String?
    public let srpVersion: String?
    public let structuralLengths: [String: Int]?
    public let requestFieldNames: [String]?
    public let challengeFieldNames: [String]?
    public let responseFieldNames: [String]?
    public let responseStatusCode: Int?
    public let fieldTypes: [String: String]?
    public let responseStatusFieldNames: [String]?
    public let nonSecretIntegers: [String: Int]?
    public let continuity: [String: Bool]?
    public let safeServerMessage: String?
    public let safeMessagePresent: Bool?
    public let deviceIdentifierSource: String?
    public let endpoint: String?
    public let httpMethod: String?
    public let generationID: UInt64?
    public let setupPhase: String?
    public let authorizationStage: String?
    public let sessionValid: Bool?
    public let personalTeamAvailable: Bool?
    public let errorPresent: Bool?
    public let currentGeneration: Bool?
    public let osStatus: Int?
    public let keyApplicationTagIdentifier: String?
    public let certificateFingerprintPrefix: String?
    public let responseContentType: String?
    public let responseBodyKind: String?
    public let serverIdentifier: String?
    public let requestIdentifier: String?

    public init(
        timestamp: Date,
        checkpoint: String?,
        stage: String,
        safeErrorCode: String?,
        httpStatus: Int?,
        appleErrorCode: Int?,
        retryAfterSeconds: Int?,
        retryable: Bool,
        reauthorizationRequired: Bool,
        srpProtocol: String? = nil,
        srpVersion: String? = nil,
        structuralLengths: [String: Int]? = nil,
        requestFieldNames: [String]? = nil,
        challengeFieldNames: [String]? = nil,
        responseFieldNames: [String]? = nil,
        responseStatusCode: Int? = nil,
        fieldTypes: [String: String]? = nil,
        responseStatusFieldNames: [String]? = nil,
        nonSecretIntegers: [String: Int]? = nil,
        continuity: [String: Bool]? = nil,
        safeServerMessage: String? = nil,
        safeMessagePresent: Bool? = nil,
        deviceIdentifierSource: String? = nil,
        endpoint: String? = nil,
        httpMethod: String? = nil,
        generationID: UInt64? = nil,
        setupPhase: String? = nil,
        authorizationStage: String? = nil,
        sessionValid: Bool? = nil,
        personalTeamAvailable: Bool? = nil,
        errorPresent: Bool? = nil,
        currentGeneration: Bool? = nil,
        osStatus: Int? = nil,
        keyApplicationTagIdentifier: String? = nil,
        certificateFingerprintPrefix: String? = nil,
        responseContentType: String? = nil,
        responseBodyKind: String? = nil,
        serverIdentifier: String? = nil,
        requestIdentifier: String? = nil
    ) {
        self.timestamp = timestamp
        self.checkpoint = checkpoint
        self.stage = stage
        self.safeErrorCode = safeErrorCode
        self.httpStatus = httpStatus
        self.appleErrorCode = appleErrorCode
        self.retryAfterSeconds = retryAfterSeconds
        self.retryable = retryable
        self.reauthorizationRequired = reauthorizationRequired
        self.srpProtocol = srpProtocol
        self.srpVersion = srpVersion
        self.structuralLengths = structuralLengths
        self.requestFieldNames = requestFieldNames
        self.challengeFieldNames = challengeFieldNames
        self.responseFieldNames = responseFieldNames
        self.responseStatusCode = responseStatusCode
        self.fieldTypes = fieldTypes
        self.responseStatusFieldNames = responseStatusFieldNames
        self.nonSecretIntegers = nonSecretIntegers
        self.continuity = continuity
        self.safeServerMessage = safeServerMessage
        self.safeMessagePresent = safeMessagePresent
        self.deviceIdentifierSource = deviceIdentifierSource
        self.endpoint = endpoint
        self.httpMethod = httpMethod
        self.generationID = generationID
        self.setupPhase = setupPhase
        self.authorizationStage = authorizationStage
        self.sessionValid = sessionValid
        self.personalTeamAvailable = personalTeamAvailable
        self.errorPresent = errorPresent
        self.currentGeneration = currentGeneration
        self.osStatus = osStatus
        self.keyApplicationTagIdentifier = keyApplicationTagIdentifier
        self.certificateFingerprintPrefix = certificateFingerprintPrefix
        self.responseContentType = responseContentType
        self.responseBodyKind = responseBodyKind
        self.serverIdentifier = serverIdentifier
        self.requestIdentifier = requestIdentifier
    }
}

public struct ApplePersonalTeamDiagnosticSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public let schemaVersion: Int
    public let adapterVersion: String
    public var events: [ApplePersonalTeamDiagnosticEvent]
    public var sessionValid: Bool
    public var personalTeamFound: Bool
    public var teamIdentifier: String?
    public var certificateFingerprint: String?
    public var deviceRegistrationStatus: String?
    public var derivedBundleIdentifiers: [String]
    public var profileIssuedAt: [String: Date]
    public var profileExpiresAt: [String: Date]
    public var profileValidation: String?

    public init(adapterVersion: String) {
        schemaVersion = Self.currentSchemaVersion
        self.adapterVersion = adapterVersion
        events = []
        sessionValid = false
        personalTeamFound = false
        derivedBundleIdentifiers = []
        profileIssuedAt = [:]
        profileExpiresAt = [:]
    }
}

public final class ApplePersonalTeamDiagnosticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("IOSSimMac", isDirectory: true)
            .appendingPathComponent("apple-personal-team-diagnostics.json")
    }

    public func load() -> ApplePersonalTeamDiagnosticSnapshot? {
        lock.withLock {
            guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ApplePersonalTeamDiagnosticSnapshot.self, from: data)
        }
    }

    public func update(
        adapterVersion: String,
        _ body: (inout ApplePersonalTeamDiagnosticSnapshot) -> Void
    ) {
        lock.withLock {
            var snapshot = loadUnlocked() ?? ApplePersonalTeamDiagnosticSnapshot(adapterVersion: adapterVersion)
            body(&snapshot)
            if snapshot.events.count > 200 { snapshot.events.removeFirst(snapshot.events.count - 200) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot), data.count <= 1_048_576 else { return }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                // NSFileProtection is an iOS data-protection facility. On macOS 27,
                // requesting it causes otherwise valid atomic writes to fail with
                // EPERM. Keep the macOS guarantees explicit: atomic replacement and
                // owner-only POSIX permissions.
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                return
            }
        }
    }

    func recordSetupTransition(
        _ transition: SetupStateTransition,
        adapterVersion: String,
        generationID: UInt64,
        setupPhase: SetupPhase,
        authorizationStage: AppleAuthorizationStage,
        sessionValid: Bool,
        personalTeamAvailable: Bool,
        errorPresent: Bool,
        currentGeneration: Bool,
        safeErrorCode: String? = nil
    ) {
        update(adapterVersion: adapterVersion) {
            $0.events.append(.init(
                timestamp: Date(),
                checkpoint: nil,
                stage: transition.rawValue,
                safeErrorCode: safeErrorCode,
                httpStatus: nil,
                appleErrorCode: nil,
                retryAfterSeconds: nil,
                retryable: false,
                reauthorizationRequired: false,
                generationID: generationID,
                setupPhase: setupPhase.rawValue,
                authorizationStage: authorizationStage.rawValue,
                sessionValid: sessionValid,
                personalTeamAvailable: personalTeamAvailable,
                errorPresent: errorPresent,
                currentGeneration: currentGeneration
            ))
        }
    }

    private func loadUnlocked() -> ApplePersonalTeamDiagnosticSnapshot? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ApplePersonalTeamDiagnosticSnapshot.self, from: data)
    }
}

// MARK: - Versioned protocol and bounded transport

public struct AppleHTTPResponse: @unchecked Sendable {
    public let url: URL
    public let statusCode: Int
    public let headers: [AnyHashable: Any]
    public let body: Data
}

public protocol AppleHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppleHTTPResponse
}

private enum AppleLiveTransportError: Error {
    case invalidDestination
    case redirectRejected
    case responseTooLarge
    case invalidResponse
    case network(AppleNetworkFailureCategory)
}

/// Streaming URLSession transport. It rejects unexpected redirects before
/// following them and cancels a task as soon as the configured body cap is hit.
public final class BoundedAppleHTTPTransport: NSObject, AppleHTTPTransport, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private struct Pending {
        let maximumBytes: Int
        let continuation: CheckedContinuation<AppleHTTPResponse, Error>
        var response: HTTPURLResponse?
        var data = Data()
        var failure: Error?
    }

    private let allowedHosts: Set<String>
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(allowedHosts: Set<String> = ["gsa.apple.com", "developerservices2.apple.com"]) {
        self.allowedHosts = allowedHosts
    }

    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> AppleHTTPResponse {
        guard let url = request.url, url.scheme == "https", allowedHosts.contains(url.host ?? ""),
              (1...8_388_608).contains(maximumBytes) else {
            throw AppleLiveTransportError.invalidDestination
        }
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.withLock {
                pending[task.taskIdentifier] = Pending(maximumBytes: maximumBytes, continuation: continuation)
            }
            task.resume()
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, url.scheme == "https", allowedHosts.contains(url.host ?? "") else {
            lock.withLock {
                pending[task.taskIdentifier]?.failure = AppleLiveTransportError.redirectRejected
            }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { pending[dataTask.taskIdentifier]?.failure = AppleLiveTransportError.invalidResponse }
            completionHandler(.cancel)
            return
        }
        let accepted = lock.withLock { () -> Bool in
            guard var item = pending[dataTask.taskIdentifier] else { return false }
            if response.expectedContentLength > Int64(item.maximumBytes) {
                item.failure = AppleLiveTransportError.responseTooLarge
                pending[dataTask.taskIdentifier] = item
                return false
            }
            item.response = http
            pending[dataTask.taskIdentifier] = item
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard var item = pending[dataTask.taskIdentifier] else { return true }
            guard item.data.count <= item.maximumBytes - data.count else {
                item.failure = AppleLiveTransportError.responseTooLarge
                pending[dataTask.taskIdentifier] = item
                return true
            }
            item.data.append(data)
            pending[dataTask.taskIdentifier] = item
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let item = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        guard let item else { return }
        if let failure = item.failure {
            item.continuation.resume(throwing: failure)
        } else if let error {
            item.continuation.resume(throwing: AppleLiveTransportError.network(
                AppleTransportFailureClassifier.category(for: error)
            ))
        } else if let response = item.response, let url = response.url {
            item.continuation.resume(returning: AppleHTTPResponse(
                url: url,
                statusCode: response.statusCode,
                headers: response.allHeaderFields,
                body: item.data
            ))
        } else {
            item.continuation.resume(throwing: AppleLiveTransportError.invalidResponse)
        }
    }
}

// MARK: - Local macOS machine identity

public protocol AppleMachineIdentityProviding: Sendable {
    func headers(for request: URLRequest) async throws -> [String: String]
}

@objc private protocol AOSKitUtilitiesProtocol {
    static var machineSerialNumber: String? { get }
    static var machineUDID: String? { get }
    static func retrieveOTPHeadersForDSID(_ dsid: String) -> [String: Any]?
}

/// Uses only AOSKit/AuthKit installed as part of macOS. No Apple binary or
/// Xcode account state is read, copied, or redistributed. AOSKit is preferred
/// because its local ADI path works without an app-specific AuthKit XPC grant.
public final class LocalMacAppleMachineIdentityProvider: AppleMachineIdentityProviding,
    @unchecked Sendable
{
    private let aosKitPath = "/System/Library/PrivateFrameworks/AOSKit.framework"
    private let frameworkPath = "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit"
    public init() {}

    public func headers(for request: URLRequest) async throws -> [String: String] {
        if let headers = aosKitHeaders(for: request) { return headers }
        return try await authKitHeaders(for: request)
    }

    private func aosKitHeaders(for request: URLRequest) -> [String: String]? {
        guard let bundle = Bundle(url: URL(fileURLWithPath: aosKitPath)),
              (try? bundle.loadAndReturnError()) != nil,
              let utilitiesClass = NSClassFromString("AOSUtilities"),
              utilitiesClass.responds(to: NSSelectorFromString("retrieveOTPHeadersForDSID:")),
              utilitiesClass.responds(to: NSSelectorFromString("machineUDID")),
              utilitiesClass.responds(to: NSSelectorFromString("machineSerialNumber")) else {
            return nil
        }
        let utilities = unsafeBitCast(utilitiesClass, to: AOSKitUtilitiesProtocol.Type.self)
        guard let raw = utilities.retrieveOTPHeadersForDSID("-2"),
              let oneTimePassword = raw["X-Apple-MD"] as? String, !oneTimePassword.isEmpty,
              let machineID = raw["X-Apple-MD-M"] as? String, !machineID.isEmpty,
              let rawUDID = utilities.machineUDID, !rawUDID.isEmpty else {
            return nil
        }
        let udid = rawUDID.uppercased()
        let localUserID = Data(udid.utf8).base64EncodedString()
        let serial = utilities.machineSerialNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let model = systemValue("hw.model") ?? "Mac"
        let build = systemValue("kern.osversion") ?? "unknown"
        var result = genericAuthKitHeaders(for: request)
        result["X-Apple-I-MD"] = oneTimePassword
        result["X-Apple-I-MD-M"] = machineID
        result["X-Apple-I-MD-LU"] = localUserID
        // AOSKit does not expose its production routing field. This value is
        // isolated in the versioned machine adapter and is classified as
        // VERSION_BOUND, based on maintained local-mac implementations.
        result["X-Apple-I-MD-RINFO"] = "84215040"
        result["X-Mme-Device-Id"] = udid
        result["X-Apple-I-SRL-NO"] = serial
        // Apple's GrandSlam edge began rejecting the Xcode bundle identifier
        // with HTTP 503 in September 2026. akd is the macOS process that owns
        // this system-provided AuthKit/AOSKit identity and is accepted by the
        // same endpoint. Developer Services still receives its Xcode audience
        // and version through X-Apple-App-Info and X-Xcode-Version.
        result["X-MMe-Client-Info"] = Self.grandSlamClientInformation(
            model: model,
            osVersion: osVersion,
            build: build
        )
        result["X-Apple-I-Client-Time"] = result["X-Apple-I-Client-Time"] ?? Self.clientTimestamp()
        result["X-Apple-Locale"] = result["X-Apple-I-Locale"] ?? Locale.current.identifier
        result["X-Apple-I-TimeZone"] = result["X-Apple-I-TimeZone"] ?? TimeZone.current.identifier
        return result
    }

    static func grandSlamClientInformation(model: String, osVersion: String, build: String) -> String {
        "<\(model)> <macOS;\(osVersion);\(build)> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    }

    private func genericAuthKitHeaders(for request: URLRequest) -> [String: String] {
        guard dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) != nil,
              let sessionClass = NSClassFromString("AKAppleIDSession") as? NSObject.Type else {
            return [:]
        }
        let session = sessionClass.init()
        let selector = NSSelectorFromString("appleIDHeadersForRequest:")
        guard session.responds(to: selector),
              let unmanaged = session.perform(selector, with: request as NSURLRequest),
              let dictionary = unmanaged.takeUnretainedValue() as? NSDictionary else {
            return [:]
        }
        return stringHeaders(dictionary)
    }

    private func authKitHeaders(for request: URLRequest) async throws -> [String: String] {
        guard dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) != nil,
              let sessionClass = NSClassFromString("AKAppleIDSession") as? NSObject.Type else {
            throw ExperimentalBackendError.localAnisetteUnavailable
        }
        try await provisionIfNecessary()
        let session = sessionClass.init()
        let selector = NSSelectorFromString("appleIDHeadersForRequest:")
        guard session.responds(to: selector),
              let unmanaged = session.perform(selector, with: request as NSURLRequest),
              let dictionary = unmanaged.takeUnretainedValue() as? NSDictionary else {
            throw ExperimentalBackendError.localAnisetteUnavailable
        }
        let result = stringHeaders(dictionary)
        let required = ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO"]
        guard required.allSatisfy({ result[$0]?.isEmpty == false }) else {
            throw ExperimentalBackendError.localAnisetteUnavailable
        }
        return result
    }

    private func stringHeaders(_ dictionary: NSDictionary) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            if let key = key as? String, let value = value as? String, value.count <= 16_384 {
                result[key] = value
            } else if let key = key as? String, let value = value as? NSNumber {
                result[key] = value.stringValue
            }
        }
        return result
    }

    private func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, (1...1_024).contains(size) else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    private static func clientTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private func provisionIfNecessary() async throws {
        guard let controllerClass = NSClassFromString("AKAnisetteProvisioningController") as? NSObject.Type else {
            throw ExperimentalBackendError.localAnisetteUnavailable
        }
        let controller = controllerClass.init()
        let selector = NSSelectorFromString("fetchAnisetteDataAndProvisionIfNecessary:withCompletion:")
        guard let method = class_getInstanceMethod(controllerClass, selector) else {
            throw ExperimentalBackendError.localAnisetteUnavailable
        }
        typealias Completion = @convention(block) (AnyObject?, NSError?) -> Void
        typealias Function = @convention(c) (AnyObject, Selector, Bool, Completion) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: Completion = { data, error in
                if data != nil && error == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExperimentalBackendError.localAnisetteUnavailable)
                }
            }
            function(controller, selector, true, completion)
        }
    }
}

@available(*, deprecated, renamed: "LocalMacAppleMachineIdentityProvider")
public typealias LocalMacAuthKitMachineIdentityProvider = LocalMacAppleMachineIdentityProvider

// MARK: - Apple SRP-6a

struct AppleSRPChallenge: Equatable {
    let scheme: String
    let salt: Data
    let iterations: Int
    let serverPublicKey: Data
    let cookie: String
}

struct AppleSRPProof {
    let clientProof: Data
    let sessionKey: Data
    let expectedServerProof: Data
    let structuralLengths: [String: Int]
}

#if DEBUG
/// Debug-only inspection material for deterministic interoperability checks.
/// Release builds cannot construct or expose this trace, and tests compare only
/// SHA-256 fingerprints and lengths of synthetic fixture values.
struct AppleSRPParityTrace {
    let bytes: [String: Data]
    let metadata: [String: String]
}
#endif

private struct AppleSRPComputation {
    let proof: AppleSRPProof
#if DEBUG
    let trace: AppleSRPParityTrace
#endif
}

struct AppleSRPClient {
    static let modulusHex =
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D" +
        "CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74" +
        "7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D" +
        "5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6" +
        "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"

    private let modulus = BigUInt(modulusHex, radix: 16)!
    private let generator = BigUInt(2)
    private let privateKey: BigUInt
    let clientPublicKey: Data

    init(randomBytes: Data? = nil) throws {
        var random = randomBytes ?? Data(count: 32)
        if randomBytes == nil {
            let status = random.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw ExperimentalBackendError.srpAuthFailed
            }
        }
        guard random.count == 32, random.contains(where: { $0 != 0 }) else {
            throw ExperimentalBackendError.srpAuthFailed
        }
        privateKey = BigUInt(random)
        clientPublicKey = Self.pad(generator.power(privateKey, modulus: modulus), to: 256)
        random.resetBytes(in: 0..<random.count)
    }

    static func parseChallenge(_ response: [String: Any]) throws -> AppleSRPChallenge {
        guard let scheme = response["sp"] as? String, ["s2k", "s2k_fo"].contains(scheme),
              let salt = response["s"] as? Data, (8...128).contains(salt.count),
              let serverKey = response["B"] as? Data, (1...256).contains(serverKey.count),
              serverKey.contains(where: { $0 != 0 }),
              let cookie = response["c"] as? String, !cookie.isEmpty, cookie.count <= 4_096,
              let iterations = Self.integer(response["i"]), (1...10_000_000).contains(iterations) else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        return AppleSRPChallenge(
            scheme: scheme,
            salt: salt,
            iterations: iterations,
            serverPublicKey: serverKey,
            cookie: cookie
        )
    }

    func proof(account: String, password: Data, challenge: AppleSRPChallenge) throws -> AppleSRPProof {
        try compute(account: account, password: password, challenge: challenge).proof
    }

#if DEBUG
    func parityTrace(account: String, password: Data, challenge: AppleSRPChallenge) throws -> AppleSRPParityTrace {
        try compute(account: account, password: password, challenge: challenge).trace
    }
#endif

    private func compute(
        account: String,
        password: Data,
        challenge: AppleSRPChallenge
    ) throws -> AppleSRPComputation {
        guard !account.isEmpty, account.utf8.count <= 1_024, !password.isEmpty, password.count <= 4_096 else {
            throw ExperimentalBackendError.srpAuthFailed
        }
        var digest = Data(SHA256.hash(data: password))
        var processed = challenge.scheme == "s2k" ? digest : Data(digest.hexLowercase.utf8)
        defer {
            digest.resetBytes(in: 0..<digest.count)
            processed.resetBytes(in: 0..<processed.count)
        }
        var derived = Data(count: 32)
        let derivedCount = derived.count
        let derivationStatus = processed.withUnsafeBytes { passwordBytes in
            challenge.salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        processed.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        challenge.salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(challenge.iterations),
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        derivedCount
                    )
                }
            }
        }
        guard derivationStatus == kCCSuccess else { throw ExperimentalBackendError.srpAuthFailed }
        defer { derived.resetBytes(in: 0..<derived.count) }

        let nData = Self.pad(modulus, to: 256)
        let gData = Self.pad(generator, to: 256)
        let multiplier = BigUInt(Data(SHA256.hash(data: nData + gData)))
        let server = BigUInt(challenge.serverPublicKey)
        guard server % modulus != 0 else { throw ExperimentalBackendError.srpAuthFailed }
        let scrambling = BigUInt(Data(SHA256.hash(data: clientPublicKey + Self.pad(server, to: 256))))
        guard scrambling != 0 else { throw ExperimentalBackendError.srpAuthFailed }

        // GrandSlam gives the PBKDF2 output to CoreCrypto as the SRP
        // "password" with noUsernameInX enabled. CoreCrypto still performs
        // RFC 5054 x derivation: x = H(s || H(":" || passwordKey)). Treating
        // the PBKDF2 output itself as x produces a different verifier and M1.
        var xInnerDigest = Data(SHA256.hash(data: Data([0x3A]) + derived))
        var xDigest = Data(SHA256.hash(data: challenge.salt + xInnerDigest))
        defer {
            xInnerDigest.resetBytes(in: 0..<xInnerDigest.count)
            xDigest.resetBytes(in: 0..<xDigest.count)
        }
        let x = BigUInt(xDigest)
        let verifier = generator.power(x, modulus: modulus)
        let multiplierTimesVerifier = multiplier * verifier
        let reducedMultiplierTimesVerifier = multiplierTimesVerifier % modulus
        let base = server.subtracting(reducedMultiplierTimesVerifier, modulus: modulus)
        let exponent = privateKey + scrambling * x
        let shared = base.power(exponent, modulus: modulus)
        let sharedEncoding = Self.pad(shared, to: 256)
        let sessionKey = Data(SHA256.hash(data: sharedEncoding))

        let nHash = Data(SHA256.hash(data: nData))
        // Corecrypto's default RFC 5054 variant hashes group elements at the
        // modulus width. Hashing the one-byte encoding of g here changes every
        // M1 proof and GrandSlam reports the mismatch as Status.ec = -22406.
        let gHash = Data(SHA256.hash(data: gData))
        var xor = nHash
        for index in xor.indices { xor[index] ^= gHash[index] }
        let userHash = Data(SHA256.hash(data: Data(account.utf8)))
        let paddedServer = Self.pad(server, to: 256)
        let proofInput = xor + userHash + challenge.salt + clientPublicKey + paddedServer + sessionKey
        let proof = Data(SHA256.hash(data: proofInput))
        let serverProofInput = clientPublicKey + proof + sessionKey
        let serverProof = Data(SHA256.hash(data: serverProofInput))
        let result = AppleSRPProof(
            clientProof: proof,
            sessionKey: sessionKey,
            expectedServerProof: serverProof,
            structuralLengths: [
                "modulus": nData.count,
                "paddedGenerator": gData.count,
                "paddedA": clientPublicKey.count,
                "paddedB": paddedServer.count,
                "passwordPreprocessing": processed.count,
                "pbkdf2Output": derived.count,
                "xDigest": xDigest.count,
                "sharedMinimal": shared.serialize().count,
                "sharedPadded": sharedEncoding.count,
                "sessionKey": sessionKey.count,
                "M1": proof.count,
                "M2": serverProof.count
            ]
        )
#if DEBUG
        return AppleSRPComputation(proof: result, trace: AppleSRPParityTrace(
            bytes: [
                "username_utf8": Data(account.utf8),
                "password_input": password,
                "password_sha256": digest,
                "password_preprocessing_output": processed,
                "pbkdf2_input": processed,
                "pbkdf2_salt": challenge.salt,
                "derived_password_key": derived,
                "N": nData,
                "g": generator.serialize(),
                "PAD_g": gData,
                "H_N": nHash,
                "H_PAD_g": gHash,
                "H_N_xor_H_PAD_g": xor,
                "k": multiplier.serialize(),
                "a": privateKey.serialize(),
                "A": clientPublicKey,
                "encoded_A": clientPublicKey,
                "decoded_B": server.serialize(),
                "padded_B": paddedServer,
                "u": scrambling.serialize(),
                "x_inner_hash": xInnerDigest,
                "x": xDigest,
                "g_pow_x": Self.pad(verifier, to: 256),
                "k_times_g_pow_x": multiplierTimesVerifier.serialize(),
                "B_minus_k_times_g_pow_x": Self.pad(base, to: 256),
                "exponent_a_plus_u_times_x": exponent.serialize(),
                "S": Self.pad(shared, to: 256),
                "S_encoding": sharedEncoding,
                "session_key_derivation_input": sharedEncoding,
                "K": sessionKey,
                "H_username": userHash,
                "M1_input": proofInput,
                "M1": proof,
                "M2_input": serverProofInput,
                "M2": serverProof
            ],
            metadata: [
                "username_before_normalization": account,
                "username_after_normalization": account,
                "scheme": challenge.scheme,
                "pbkdf2_iterations": String(challenge.iterations),
                "pbkdf2_prf": "HMAC-SHA256",
                "pbkdf2_output_length": String(derived.count),
                "N_byte_width": String(nData.count),
                "integer_encoding": "unsigned-big-endian",
                "group_element_encoding": "fixed-256-byte"
            ]
        ))
#else
        return AppleSRPComputation(proof: result)
#endif
    }

    static func verifyServerProof(_ received: Data, expected: Data) throws {
        guard serverProofMatches(received, expected: expected) else {
            throw ExperimentalBackendError.srpAuthFailed
        }
    }

    static func serverProofMatches(_ received: Data, expected: Data) -> Bool {
        guard received.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in received.indices { difference |= received[index] ^ expected[index] }
        return difference == 0
    }

    static func pad(_ value: BigUInt, to count: Int) -> Data {
        let serialized = value.serialize()
        precondition(serialized.count <= count, "SRP integer exceeds its fixed-width encoding")
        if serialized.count == count { return serialized }
        return Data(repeating: 0, count: count - serialized.count) + serialized
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

private extension BigUInt {
    func subtracting(_ other: BigUInt, modulus: BigUInt) -> BigUInt {
        self >= other ? (self - other) % modulus : (self + modulus - other) % modulus
    }
}

private extension Data {
    var hexLowercase: String { map { String(format: "%02x", $0) }.joined() }

    func hmacSHA256(message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: self)))
    }
}

// MARK: - Certificate, device, identifier, and profile operations

struct IOSSimIdentityMetadata: Codable, Equatable {
    let teamIdentifier: String
    let certificateFingerprint: String?
    let certificateSerial: String?
    let certificateExpiration: Date?
    let keyApplicationTag: Data
    let createdAt: Date
    let generatedByIOSSim: Bool
    /// Schema 2 fields. Every one is optional so a Build-1 or Build-2 record
    /// decodes unchanged -- the consumer's existing identity must survive an
    /// upgrade without being reissued.
    let schemaVersion: Int?
    /// Stable per-installation identifier, also sent to Apple as `machineId`
    /// and embedded in `machineName`. Lets a later run recognise a certificate
    /// as this installation's even if the local key is gone, and lets it
    /// recognise another Mac's certificate as *not* reclaimable.
    let installationIdentifier: String?
    /// Apple's own certificate request identifier, when the response carried one.
    let certificateRequestIdentifier: String?
    /// SHA-256 of the SubjectPublicKeyInfo the certificate was issued against.
    let publicKeyFingerprint: String?
    /// Veya-owned certificates this installation has superseded. Retained so a
    /// reclaim never targets the same serial twice and so support evidence
    /// shows what was retired.
    let retiredCertificates: [RetiredCertificateRecord]?

    static let currentSchemaVersion = 2

    init(
        teamIdentifier: String,
        certificateFingerprint: String?,
        certificateSerial: String?,
        certificateExpiration: Date?,
        keyApplicationTag: Data,
        createdAt: Date,
        generatedByIOSSim: Bool,
        schemaVersion: Int? = IOSSimIdentityMetadata.currentSchemaVersion,
        installationIdentifier: String? = nil,
        certificateRequestIdentifier: String? = nil,
        publicKeyFingerprint: String? = nil,
        retiredCertificates: [RetiredCertificateRecord]? = nil
    ) {
        self.teamIdentifier = teamIdentifier
        self.certificateFingerprint = certificateFingerprint
        self.certificateSerial = certificateSerial
        self.certificateExpiration = certificateExpiration
        self.keyApplicationTag = keyApplicationTag
        self.createdAt = createdAt
        self.generatedByIOSSim = generatedByIOSSim
        self.schemaVersion = schemaVersion
        self.installationIdentifier = installationIdentifier
        self.certificateRequestIdentifier = certificateRequestIdentifier
        self.publicKeyFingerprint = publicKeyFingerprint
        self.retiredCertificates = retiredCertificates
    }
}

/// A Veya-owned certificate this installation has retired.
struct RetiredCertificateRecord: Codable, Equatable {
    let serial: String?
    let fingerprint: String?
    let retiredAt: Date
    let reason: String
}

/// Persisted *before* an irreversible revocation so a crash or restart between
/// the revoke call and its confirmation can be reconciled against Apple's real
/// state instead of guessed at. Without this, a restart could revoke a second
/// certificate believing the first attempt never landed.
struct CertificateRecoveryIntent: Codable, Equatable {
    let teamIdentifier: String
    let targetSerial: String
    let targetFingerprint: String?
    let installationIdentifier: String
    let startedAt: Date
    var attempts: Int

    /// Hard ceiling on revocation attempts for one target across all restarts.
    /// Reaching it surfaces a recoverable error rather than revoking again.
    static let maximumAttempts = 2
}

/// How strongly Veya can prove a listed Apple Development certificate is its
/// own, and therefore whether revoking it is permitted. Ordered strongest
/// evidence first. Only `ownedLocalRecord` and `ownedRemoteMarker` may ever be
/// revoked; everything else fails closed.
enum CertificateOwnership: String, Equatable, Sendable {
    /// P1 -- this installation's persisted metadata names this exact serial or
    /// fingerprint, and that record was written by Veya against a canonical key tag.
    case ownedLocalRecord = "OWNED_LOCAL_RECORD"
    /// P2 -- Apple reports the certificate's `machineId` as this installation's
    /// own stable identifier.
    case ownedRemoteMarker = "OWNED_REMOTE_MARKER"
    /// P3 -- a private key held on this Mac matches it and can actually sign.
    /// Never revoked: this is a working identity.
    case activeUsable = "ACTIVE_USABLE"
    /// P4 -- carries Veya's structured machine name but a *different*
    /// installation identifier. Probably another Mac on the same Apple Account,
    /// and possibly live. Never revoked.
    case veyaOtherInstall = "VEYA_OTHER_INSTALL"
    /// P5 -- Xcode, another tool, or unattributable. Never revoked.
    case unknown = "UNKNOWN"

    /// Team ID alone, certificate name alone, "Apple Development", creation date
    /// alone and "newest certificate" are deliberately absent from this ladder.
    var isReclaimable: Bool { self == .ownedLocalRecord || self == .ownedRemoteMarker }
}

/// One listed certificate together with the ownership verdict reached for it.
struct ClassifiedDevelopmentCertificate {
    let raw: [String: Any]
    let serial: String?
    let fingerprint: String?
    let expiration: Date?
    let ownership: CertificateOwnership
}

struct ManagedPrivateKeyLookup {
    let key: SecKey?
    let status: OSStatus
}

protocol IOSSimManagedIdentityKeychain: Sendable {
    func load(teamIdentifier: String) throws -> IOSSimIdentityMetadata?
    func loadCandidate(teamIdentifier: String) throws -> IOSSimIdentityMetadata?
    func save(_ metadata: IOSSimIdentityMetadata) throws
    func saveCandidate(_ metadata: IOSSimIdentityMetadata) throws
    func promoteCandidate(teamIdentifier: String) throws
    /// Stable identifier for this Veya installation, created once on first use.
    /// Not derived from hardware or the user, and never secret.
    func installationIdentifier() throws -> String
    func loadRecoveryIntent(teamIdentifier: String) throws -> CertificateRecoveryIntent?
    func saveRecoveryIntent(_ intent: CertificateRecoveryIntent) throws
    func clearRecoveryIntent(teamIdentifier: String) throws
    func lookupPrivateKey(applicationTag: Data) -> ManagedPrivateKeyLookup
    func managedKeyTags(teamIdentifier: String) throws -> [Data]
    func persistentReference(applicationTag: Data) throws -> Data
    func createPrivateKey(applicationTag: Data) throws -> SecKey
    func authorizePrivateKeyForSigning(applicationTag: Data) throws
    func addCertificate(_ certificate: SecCertificate, teamIdentifier: String) throws
    func verifySigningKeyUsable(certificate: SecCertificate) throws
}

/// Installation V2 guard: the legacy Keychain identity store, refusing everything. Reaching it means a
/// v2 path called the Build 1-11 signer, which must fail instead of silently falling back.
struct RetiredLegacyIdentityKeychain: IOSSimManagedIdentityKeychain {
    private func refuse() -> Error { ExperimentalBackendError.adapterDisabled }
    func load(teamIdentifier: String) throws -> IOSSimIdentityMetadata? { throw refuse() }
    func loadCandidate(teamIdentifier: String) throws -> IOSSimIdentityMetadata? { throw refuse() }
    func save(_ metadata: IOSSimIdentityMetadata) throws { throw refuse() }
    func saveCandidate(_ metadata: IOSSimIdentityMetadata) throws { throw refuse() }
    func promoteCandidate(teamIdentifier: String) throws { throw refuse() }
    func installationIdentifier() throws -> String { throw refuse() }
    func loadRecoveryIntent(teamIdentifier: String) throws -> CertificateRecoveryIntent? { throw refuse() }
    func saveRecoveryIntent(_ intent: CertificateRecoveryIntent) throws { throw refuse() }
    func clearRecoveryIntent(teamIdentifier: String) throws { throw refuse() }
    func lookupPrivateKey(applicationTag: Data) -> ManagedPrivateKeyLookup { ManagedPrivateKeyLookup(key: nil, status: errSecNotAvailable) }
    func managedKeyTags(teamIdentifier: String) throws -> [Data] { throw refuse() }
    func persistentReference(applicationTag: Data) throws -> Data { throw refuse() }
    func createPrivateKey(applicationTag: Data) throws -> SecKey { throw refuse() }
    func authorizePrivateKeyForSigning(applicationTag: Data) throws { throw refuse() }
    func addCertificate(_ certificate: SecCertificate, teamIdentifier: String) throws { throw refuse() }
    func verifySigningKeyUsable(certificate: SecCertificate) throws { throw refuse() }
}

struct IOSSimSigningKeyAccessPolicy: Equatable, Sendable {
    static let codesignPath = "/usr/bin/codesign"

    let trustedExecutablePaths: [String]

    init(trustedExecutablePaths: [String]) {
        self.trustedExecutablePaths = trustedExecutablePaths
    }

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleExecutableName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
        fileManager: FileManager = .default
    ) {
        var candidates = [Self.codesignPath]
        let macOSDirectory = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        if let bundleExecutableName, !bundleExecutableName.isEmpty {
            candidates.append(macOSDirectory.appendingPathComponent(bundleExecutableName).path)
        }
        candidates.append(macOSDirectory.appendingPathComponent("IOSSimProvisioner").path)
        trustedExecutablePaths = candidates.reduce(into: []) { result, path in
            guard fileManager.isExecutableFile(atPath: path), !result.contains(path) else { return }
            result.append(path)
        }
    }
}

final class IOSSimIdentityMetadataStore: IOSSimManagedIdentityKeychain, @unchecked Sendable {
    private let service: String
    private let keyLabel: String
    private let signingAccessPolicy: IOSSimSigningKeyAccessPolicy
    private let signingKeychain: VeyaSigningKeychain
    private let metadataDirectory: URL
    private let fileManager: FileManager

    init(
        service: String = "com.iossim.mac.personal-team-signing",
        keyLabel: String = "IOSSim Personal Team Signing Key",
        signingAccessPolicy: IOSSimSigningKeyAccessPolicy = IOSSimSigningKeyAccessPolicy(),
        signingKeychain: VeyaSigningKeychain = VeyaSigningKeychain(),
        metadataDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.service = service
        self.keyLabel = keyLabel
        self.signingAccessPolicy = signingAccessPolicy
        self.signingKeychain = signingKeychain
        self.fileManager = fileManager
        self.metadataDirectory = metadataDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IOSSim/signing-metadata-v1", isDirectory: true)
    }

    /// Restricts a key query to the Veya signing Keychain. A key found anywhere
    /// else -- in particular one left in the login Keychain by a build that
    /// predates the partition-list fix -- is deliberately invisible here, so
    /// the reuse path treats it as missing and issues a fresh candidate rather
    /// than resurrecting a key `/usr/bin/codesign` can never use. Nothing in
    /// the login Keychain is read, modified or deleted.
    private func scopedToSigningKeychain(_ query: [String: Any]) -> [String: Any]? {
        guard let keychain = try? signingKeychain.open() else { return nil }
        var scoped = query
        scoped[kSecMatchSearchList as String] = [keychain] as CFArray
        return scoped
    }

    func load(teamIdentifier: String) throws -> IOSSimIdentityMetadata? {
        try load(account: teamIdentifier)
    }

    func loadCandidate(teamIdentifier: String) throws -> IOSSimIdentityMetadata? {
        try load(account: candidateAccount(teamIdentifier))
    }

    private func load(account: String) throws -> IOSSimIdentityMetadata? {
        if let data = try loadRaw(account: account) {
            return try PropertyListDecoder().decode(IOSSimIdentityMetadata.self, from: data)
        }
        if let legacy = legacyKeychainData(account: account) {
            try saveRaw(legacy, account: account)
            return try PropertyListDecoder().decode(IOSSimIdentityMetadata.self, from: legacy)
        }
        return nil
    }

    private func legacyKeychainData(account: String) -> Data? {
        var previous = DarwinBoolean(false)
        let changed = SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess
            && SecKeychainSetUserInteractionAllowed(false) == errSecSuccess
        defer {
            if changed {
                _ = SecKeychainSetUserInteractionAllowed(previous.boolValue)
            }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    func save(_ metadata: IOSSimIdentityMetadata) throws {
        try save(metadata, account: metadata.teamIdentifier)
    }

    func saveCandidate(_ metadata: IOSSimIdentityMetadata) throws {
        try save(metadata, account: candidateAccount(metadata.teamIdentifier))
    }

    func promoteCandidate(teamIdentifier: String) throws {
        guard let candidate = try loadCandidate(teamIdentifier: teamIdentifier) else {
            return
        }
        try save(candidate)
        try removeRaw(account: candidateAccount(teamIdentifier))
    }

    private func save(_ metadata: IOSSimIdentityMetadata, account: String) throws {
        let data = try PropertyListEncoder().encode(metadata)
        try saveRaw(data, account: account)
    }

    private func candidateAccount(_ teamIdentifier: String) -> String {
        "\(teamIdentifier).candidate"
    }

    private func recoveryAccount(_ teamIdentifier: String) -> String {
        "\(teamIdentifier).recovery"
    }

    private static let installationAccount = "installation-identifier"

    /// Created once and then stable for the life of the installation. Stored
    /// beside the identity metadata, so it survives a signing-key rotation and
    /// is readable even when the Veya Keychain holds no usable key.
    func installationIdentifier() throws -> String {
        if let existing = try loadRawString(account: Self.installationAccount) { return existing }
        let generated = UUID().uuidString.uppercased()
        try saveRaw(Data(generated.utf8), account: Self.installationAccount)
        return generated
    }

    private func loadRawString(account: String) throws -> String? {
        let data = try loadRaw(account: account) ?? legacyKeychainData(account: account)
        if let data, (try? loadRaw(account: account)) == nil {
            try? saveRaw(data, account: account)
        }
        guard let data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func saveRaw(_ data: Data, account: String) throws {
        try ensureMetadataDirectory()
        try data.write(to: metadataURL(account: account), options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL(account: account).path)
    }

    func loadRecoveryIntent(teamIdentifier: String) throws -> CertificateRecoveryIntent? {
        let account = recoveryAccount(teamIdentifier)
        guard let data = try loadRaw(account: account) ?? legacyKeychainData(account: account) else { return nil }
        if (try? loadRaw(account: account)) == nil {
            try? saveRaw(data, account: account)
        }
        return try? PropertyListDecoder().decode(CertificateRecoveryIntent.self, from: data)
    }

    func saveRecoveryIntent(_ intent: CertificateRecoveryIntent) throws {
        let data = try PropertyListEncoder().encode(intent)
        try saveRaw(data, account: recoveryAccount(intent.teamIdentifier))
    }

    func clearRecoveryIntent(teamIdentifier: String) throws {
        try removeRaw(account: recoveryAccount(teamIdentifier))
    }

    private func removeRaw(account: String) throws {
        do {
            try fileManager.removeItem(at: metadataURL(account: account))
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.fileNoSuchFile.rawValue {
            return
        } catch {
            throw ExperimentalBackendError.certificateRequestFailed
        }
    }

    private func ensureMetadataDirectory() throws {
        try fileManager.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: metadataDirectory.path)
    }

    private func loadRaw(account: String) throws -> Data? {
        let url = metadataURL(account: account)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func metadataURL(account: String) -> URL {
        let digest = SHA256.hash(data: Data("\(service)\u{0}\(account)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return metadataDirectory.appendingPathComponent("\(digest).plist", isDirectory: false)
    }

    func lookupPrivateKey(applicationTag: Data) -> ManagedPrivateKeyLookup {
        guard let query = scopedToSigningKeychain([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable as String: false,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) else {
            return ManagedPrivateKeyLookup(key: nil, status: errSecNoSuchKeychain)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let key = status == errSecSuccess && result != nil ? (result! as! SecKey) : nil
        return ManagedPrivateKeyLookup(key: key, status: status)
    }

    func managedKeyTags(teamIdentifier: String) throws -> [Data] {
        guard let query = scopedToSigningKeychain([
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]) else { return [] }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { return [] }
        let records: [[String: Any]]
        if let many = result as? [[String: Any]] {
            records = many
        } else if let one = result as? [String: Any] {
            records = [one]
        } else {
            records = []
        }
        var tags: [Data] = []
        for record in records {
            guard let tag = record[kSecAttrApplicationTag as String] as? Data,
                  canonicalManagedKeyTag(tag, teamIdentifier: teamIdentifier) != nil,
                  !tags.contains(tag) else { continue }
            tags.append(tag)
        }
        return tags
    }

    func persistentReference(applicationTag: Data) throws -> Data {
        guard let query = scopedToSigningKeychain([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrSynchronizable as String: false,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) else { throw ExperimentalBackendError.missingPrivateKey }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw ExperimentalBackendError.missingPrivateKey }
        return data
    }

    func createPrivateKey(applicationTag: Data) throws -> SecKey {
        let access = try signingKeyAccess()
        let keychain = try signingKeychain.open()
        signingKeychain.ensureInUserSearchList()
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
            // The key must live in a Keychain Veya owns. A login-Keychain key
            // created by a non-Apple-signed process is stamped
            // Partitions=[cdhash:<creator>], which /usr/bin/codesign can never
            // match and which cannot be rewritten without the login Keychain
            // password. Keys in a Veya-created Keychain receive no partition
            // ACL, so the trusted-application ACL below is what governs.
            kSecUseKeychain as String: keychain,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: applicationTag,
                kSecAttrLabel as String: keyLabel,
                kSecAttrSynchronizable as String: false,
            ],
            // kSecAttrAccess belongs at the top level. SecKeyCreateRandomKey
            // silently discards it from kSecPrivateKeyAttrs, which leaves the
            // key with the default ACL that trusts only its creating process.
            kSecAttrAccess as String: access,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw ExperimentalBackendError.certificateRequestFailed
        }
        try? signingKeychain.authorizeAppleSigningToolPartitions(label: keyLabel)
        return key
    }

    func authorizePrivateKeyForSigning(applicationTag: Data) throws {
        signingKeychain.ensureInUserSearchList()
        guard lookupPrivateKey(applicationTag: applicationTag).key != nil else {
            throw ExperimentalBackendError.missingPrivateKey
        }
        try? signingKeychain.authorizeAppleSigningToolPartitions(label: keyLabel)
    }

    private func signingKeyAccess() throws -> SecAccess {
        var trustedApplications: [SecTrustedApplication] = []
        var currentApplication: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &currentApplication) == errSecSuccess,
           let currentApplication {
            trustedApplications.append(currentApplication)
        }
        for path in signingAccessPolicy.trustedExecutablePaths {
            var application: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &application)
            guard status == errSecSuccess, let application else {
                if path == IOSSimSigningKeyAccessPolicy.codesignPath {
                    throw ExperimentalBackendError.certificateRequestFailed
                }
                continue
            }
            trustedApplications.append(application)
        }
        if trustedApplications.isEmpty {
            var codesign: SecTrustedApplication?
            guard SecTrustedApplicationCreateFromPath(
                IOSSimSigningKeyAccessPolicy.codesignPath,
                &codesign
            ) == errSecSuccess, let codesign else {
                throw ExperimentalBackendError.certificateRequestFailed
            }
            trustedApplications.append(codesign)
        }
        var access: SecAccess?
        guard SecAccessCreate(
            keyLabel as CFString,
            trustedApplications as CFArray,
            &access
        ) == errSecSuccess, let access else {
            throw ExperimentalBackendError.certificateRequestFailed
        }
        // SecAccessCreate leaves ChangeACL with an empty trusted-application
        // list, which makes every later access repair raise a Keychain dialog.
        // Grant it to the same executables that may sign, so IOSSim can repair
        // its own key without asking the consumer for anything.
        var aclList: CFArray?
        if SecAccessCopyACLList(access, &aclList) == errSecSuccess,
           let acls = aclList as? [SecACL] {
            for acl in acls {
                let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
                guard authorizations.contains(kSecACLAuthorizationChangeACL as String) else { continue }
                guard SecACLSetContents(
                    acl,
                    trustedApplications as CFArray,
                    keyLabel as CFString,
                    SecKeychainPromptSelector()
                ) == errSecSuccess else {
                    throw ExperimentalBackendError.certificateRequestFailed
                }
            }
        }
        return access
    }

    func addCertificate(_ certificate: SecCertificate, teamIdentifier: String) throws {
        // The certificate has to sit in the same Keychain as its private key,
        // otherwise no SecIdentity forms and codesign reports "no identity found".
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: "IOSSim Apple Development \(teamIdentifier)"
        ]
        if let keychain = try? signingKeychain.open() {
            attributes[kSecUseKeychain as String] = keychain
            signingKeychain.ensureInUserSearchList()
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw ExperimentalBackendError.certificateRequestFailed
        }
    }

    /// Proves the signing key is usable through the exact authorization path
    /// payload signing uses: a real `/usr/bin/codesign` invocation, in a
    /// separate process, against a disposable bundle that is verified and then
    /// deleted. A certificate and a key existing is not evidence that codesign
    /// can use them -- that is precisely the state the first physical
    /// validation shipped in.
    ///
    /// No key material is exported, and the probe bundle never leaves a
    /// per-call temporary directory.
    func verifySigningKeyUsable(certificate: SecCertificate) throws {
        signingKeychain.ensureInUserSearchList()
        let der = SecCertificateCopyData(certificate) as Data
        let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("iossim-signing-usability-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let app = root.appendingPathComponent("IOSSimSigningUsabilityProbe.app", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: app,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.iossim.signing-usability-probe",
                "CFBundleExecutable": "IOSSimSigningUsabilityProbe",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            ]
            try PropertyListSerialization
                .data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
            try fileManager.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: app.appendingPathComponent("IOSSimSigningUsabilityProbe")
            )
        } catch {
            throw ExperimentalBackendError.missingPrivateKey
        }
        guard runCodesign(["--force", "--sign", sha1, "--timestamp=none", app.path]),
              runCodesign(["--verify", "--deep", "--strict", app.path]) else {
            throw ExperimentalBackendError.missingPrivateKey
        }
    }

    private func runCodesign(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: IOSSimSigningKeyAccessPolicy.codesignPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // A consumer run must never sit behind a Keychain dialog. If the key is
        // not already authorized for codesign, fail fast so the caller can
        // repair access or issue a replacement candidate instead of hanging.
        process.environment = RuntimeProvisioning.deterministicEnvironment()
        do { try process.run() } catch { return false }
        // A blocked codesign means macOS raised a SecurityAgent dialog, i.e. the
        // key is not authorized. Treat that as failure rather than waiting on a
        // consumer to answer a prompt this product is designed never to show.
        let deadline = Date().addingTimeInterval(Self.codesignProbeTimeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static let codesignProbeTimeout: TimeInterval = 20
}

extension LiveApplePersonalTeamBackend {
    public func repairSigningIdentityAccess(team: ExperimentalAppleTeam) async throws {
        guard let owned = try identityKeychain.load(teamIdentifier: team.id),
              owned.generatedByIOSSim,
              canonicalManagedKeyTag(owned.keyApplicationTag, teamIdentifier: team.id) != nil else {
            throw ExperimentalBackendError.missingPrivateKey
        }
        try identityKeychain.authorizePrivateKeyForSigning(applicationTag: owned.keyApplicationTag)
    }

    public func activeSigningCertificateFingerprint(team: ExperimentalAppleTeam) async -> String? {
        guard let metadata = (try? identityKeychain.load(teamIdentifier: team.id)) ?? nil else { return nil }
        return metadata.certificateFingerprint
    }

    public func prepareIdentity(team: ExperimentalAppleTeam) async throws -> ExperimentalSigningIdentity {
        identityGeneration &+= 1
        let generation = identityGeneration
        recordIdentity(.signingIdentityLookupStarted, generation: generation)
        let response = try await developerRequest(
            operation: "ios/listAllDevelopmentCerts",
            parameters: ["teamId": team.id]
        )
        guard let certificates = response["certificates"] as? [[String: Any]], certificates.count <= 100 else {
            throw ExperimentalBackendError.responseChanged
        }
        let availableQuantity = integer(response["availableQuantity"])
        let activeOwned = try identityKeychain.load(teamIdentifier: team.id)
        let candidateOwned = try identityKeychain.loadCandidate(teamIdentifier: team.id)
        let owned = activeOwned ?? candidateOwned
        let usingCandidate = activeOwned == nil && candidateOwned != nil
        if let owned {
            recordIdentity(
                .managedIdentityMetadataFound,
                generation: generation,
                tag: owned.keyApplicationTag,
                counts: ["developmentCertificateCount": certificates.count]
            )
            guard owned.generatedByIOSSim,
                  canonicalManagedKeyTag(owned.keyApplicationTag, teamIdentifier: team.id) != nil else {
                recordIdentity(.managedIdentityStale, generation: generation)
                throw ExperimentalBackendError.missingPrivateKey
            }
            recordIdentity(.privateKeyLookupStarted, generation: generation, tag: owned.keyApplicationTag)
            let lookup = identityKeychain.lookupPrivateKey(applicationTag: owned.keyApplicationTag)
            if let key = lookup.key {
                // Re-apply the packaged app/helper/codesign ACL on every reuse.
                // This repairs keys produced by older IOSSim builds without
                // asking the consumer to edit Keychain access controls.
                do {
                    try identityKeychain.authorizePrivateKeyForSigning(applicationTag: owned.keyApplicationTag)
                } catch {
                    recordIdentity(.managedIdentityStale, generation: generation, tag: owned.keyApplicationTag)
                    try await ensureCertificateCapacity(
                        team: team,
                        generation: generation,
                        availableQuantity: availableQuantity,
                        certificates: certificates,
                        activeMetadata: activeOwned,
                        candidateMetadata: candidateOwned,
                        exhaustedError: .missingPrivateKey
                    )
                    recordIdentity(.managedIdentityRecoveryStarted, generation: generation, tag: owned.keyApplicationTag)
                    return try await createManagedIdentity(team: team, generation: generation, recovering: true)
                }
                // Existing state is not trusted merely because it exists. If the
                // reused key cannot actually be used by codesign, replace it with
                // a fresh candidate rather than carrying it into installation.
                if let remembered = rememberedCertificate(in: certificates, metadata: owned),
                   let certificate = certificateData(remembered)
                       .flatMap({ SecCertificateCreateWithData(nil, $0 as CFData) }) {
                    do {
                        try identityKeychain.verifySigningKeyUsable(certificate: certificate)
                        recordIdentity(
                            .signingKeyUsabilityVerified,
                            generation: generation,
                            tag: owned.keyApplicationTag
                        )
                    } catch {
                        recordIdentity(
                            .signingKeyUsabilityFailed,
                            generation: generation,
                            tag: owned.keyApplicationTag
                        )
                        recordIdentity(.managedIdentityStale, generation: generation, tag: owned.keyApplicationTag)
                        try await ensureCertificateCapacity(
                            team: team,
                            generation: generation,
                            availableQuantity: availableQuantity,
                            certificates: certificates,
                            activeMetadata: activeOwned,
                            candidateMetadata: candidateOwned,
                            exhaustedError: .missingPrivateKey
                        )
                        recordIdentity(
                            .managedIdentityRecoveryStarted,
                            generation: generation,
                            tag: owned.keyApplicationTag
                        )
                        return try await createManagedIdentity(team: team, generation: generation, recovering: true)
                    }
                }
                recordIdentity(
                    .privateKeyFound,
                    generation: generation,
                    tag: owned.keyApplicationTag,
                    osStatus: lookup.status
                )
                if let remembered = rememberedCertificate(in: certificates, metadata: owned) {
                    recordIdentity(
                        .certificateFound,
                        generation: generation,
                        tag: owned.keyApplicationTag,
                        fingerprint: certificateData(remembered).map(certificateFingerprint)
                    )
                    if let match = matchingCertificate(in: [remembered], key: key, teamIdentifier: team.id) {
                        recordIdentity(
                            .certificatePublicKeyMatch,
                            generation: generation,
                            tag: owned.keyApplicationTag,
                            fingerprint: match.fingerprint,
                            flags: ["certificatePublicKeyMatchesPrivateKey": true]
                        )
                        return try finishManagedIdentity(
                            match,
                            key: key,
                            tag: owned.keyApplicationTag,
                            createdAt: owned.createdAt,
                            team: team,
                            generation: generation,
                            reused: !usingCandidate,
                            pendingPromotion: usingCandidate,
                            recovered: false
                        )
                    }
                    recordIdentity(
                        .certificatePublicKeyMatch,
                        generation: generation,
                        tag: owned.keyApplicationTag,
                        flags: ["certificatePublicKeyMatchesPrivateKey": false]
                    )
                }
                if let match = matchingCertificate(in: certificates, key: key, teamIdentifier: team.id) {
                    recordIdentity(
                        .certificateFound,
                        generation: generation,
                        tag: owned.keyApplicationTag,
                        fingerprint: match.fingerprint
                    )
                    recordIdentity(
                        .certificatePublicKeyMatch,
                        generation: generation,
                        tag: owned.keyApplicationTag,
                        fingerprint: match.fingerprint,
                        flags: ["certificatePublicKeyMatchesPrivateKey": true]
                    )
                    return try finishManagedIdentity(
                        match,
                        key: key,
                        tag: owned.keyApplicationTag,
                        createdAt: owned.createdAt,
                        team: team,
                        generation: generation,
                        reused: !usingCandidate,
                        pendingPromotion: usingCandidate,
                        recovered: false
                    )
                }
                recordIdentity(.managedIdentityStale, generation: generation, tag: owned.keyApplicationTag)
                try await ensureCertificateCapacity(
                    team: team,
                    generation: generation,
                    availableQuantity: availableQuantity,
                    certificates: certificates,
                    activeMetadata: activeOwned,
                    candidateMetadata: candidateOwned,
                    exhaustedError: .certificateLimit
                )
                recordIdentity(.managedIdentityRecoveryStarted, generation: generation, tag: owned.keyApplicationTag)
                try identityKeychain.saveCandidate(owned)
                return try await requestDevelopmentIdentity(
                    key: key,
                    tag: owned.keyApplicationTag,
                    createdAt: owned.createdAt,
                    team: team,
                    generation: generation,
                    recovering: true,
                    pendingPromotion: true
                )
            }

            recordIdentity(
                .privateKeyMissing,
                generation: generation,
                tag: owned.keyApplicationTag,
                osStatus: lookup.status
            )
            recordIdentity(.managedIdentityStale, generation: generation, tag: owned.keyApplicationTag)
            guard lookup.status == errSecItemNotFound else {
                throw ExperimentalBackendError.missingPrivateKey
            }
            try await ensureCertificateCapacity(
                team: team,
                generation: generation,
                availableQuantity: availableQuantity,
                certificates: certificates,
                activeMetadata: activeOwned,
                candidateMetadata: candidateOwned,
                exhaustedError: .certificateLimit
            )
            recordIdentity(.managedIdentityRecoveryStarted, generation: generation, tag: owned.keyApplicationTag)
            return try await createManagedIdentity(team: team, generation: generation, recovering: true)
        }

        recordIdentity(
            .managedIdentityMetadataMissing,
            generation: generation,
            counts: ["developmentCertificateCount": certificates.count]
        )
        if let recovered = try recoverIdentityFromLocalSigningKeys(
            team: team,
            generation: generation,
            certificates: certificates
        ) {
            return recovered
        }
        try await ensureCertificateCapacity(
            team: team,
            generation: generation,
            availableQuantity: availableQuantity,
            certificates: certificates,
            activeMetadata: activeOwned,
            candidateMetadata: candidateOwned,
            exhaustedError: .certificateLimit
        )
        return try await createManagedIdentity(team: team, generation: generation, recovering: false)
    }

    private func recoverIdentityFromLocalSigningKeys(
        team: ExperimentalAppleTeam,
        generation: UInt64,
        certificates: [[String: Any]]
    ) throws -> ExperimentalSigningIdentity? {
        for tag in try identityKeychain.managedKeyTags(teamIdentifier: team.id) {
            recordIdentity(.privateKeyLookupStarted, generation: generation, tag: tag)
            let lookup = identityKeychain.lookupPrivateKey(applicationTag: tag)
            guard let key = lookup.key else { continue }
            try? identityKeychain.authorizePrivateKeyForSigning(applicationTag: tag)
            guard let match = matchingCertificate(in: certificates, key: key, teamIdentifier: team.id) else {
                continue
            }
            do {
                try identityKeychain.verifySigningKeyUsable(certificate: match.certificate)
            } catch {
                recordIdentity(
                    .signingKeyUsabilityFailed,
                    generation: generation,
                    tag: tag,
                    fingerprint: match.fingerprint
                )
                continue
            }
            recordIdentity(
                .certificatePublicKeyMatch,
                generation: generation,
                tag: tag,
                fingerprint: match.fingerprint,
                flags: ["certificatePublicKeyMatchesPrivateKey": true]
            )
            recordIdentity(
                .managedIdentityRecoverySucceeded,
                generation: generation,
                tag: tag,
                fingerprint: match.fingerprint
            )
            return try finishManagedIdentity(
                match,
                key: key,
                tag: tag,
                createdAt: Date(),
                team: team,
                generation: generation,
                reused: true,
                pendingPromotion: false,
                recovered: true
            )
        }
        return nil
    }

    static let defaultCapacityRetryDelay: TimeInterval = 2
    /// Bounded re-reads of Apple's certificate capacity after a revocation.
    static let capacityConfirmationAttempts = 3

    /// Guarantees a free Apple Development certificate slot, reclaiming exactly
    /// one certificate this installation can prove it owns when -- and only when
    /// -- capacity is what blocks progress.
    ///
    /// Returns normally when a slot is available. Throws, without mutating
    /// anything, when no certificate can be proven safe to revoke.
    private func ensureCertificateCapacity(
        team: ExperimentalAppleTeam,
        generation: UInt64,
        availableQuantity: Int?,
        certificates: [[String: Any]],
        activeMetadata: IOSSimIdentityMetadata?,
        candidateMetadata: IOSSimIdentityMetadata?,
        exhaustedError: ExperimentalBackendError
    ) async throws {
        // Invariant 4: only act when capacity is actually blocking. An unknown
        // quantity is treated as available, matching the prior behaviour.
        guard availableQuantity == 0 else { return }
        recordIdentity(
            .certificateCapacityExhausted,
            generation: generation,
            counts: ["developmentCertificateCount": certificates.count]
        )

        let installation = try identityKeychain.installationIdentifier()

        // A prior run may already have revoked. Reconcile against Apple's real
        // state before considering another irreversible action.
        if let intent = try identityKeychain.loadRecoveryIntent(teamIdentifier: team.id) {
            let stillListed = certificates.contains { certificateSerialNumber($0) == intent.targetSerial }
            if !stillListed {
                // The earlier revocation landed; capacity simply has not caught
                // up yet. Never revoke a second certificate for this.
                recordIdentity(
                    .certificateReclaimReconciled,
                    generation: generation,
                    counts: ["revocationAttempts": intent.attempts]
                )
                try await confirmCapacityReleased(team: team, generation: generation)
                try identityKeychain.clearRecoveryIntent(teamIdentifier: team.id)
                return
            }
            guard intent.attempts < CertificateRecoveryIntent.maximumAttempts else {
                recordIdentity(
                    .certificateReclaimUnavailable,
                    generation: generation,
                    counts: ["revocationAttempts": intent.attempts],
                    flags: ["attemptCeilingReached": true]
                )
                throw ExperimentalBackendError.certificateRevocationFailed
            }
        }

        // Invariant 2 input: a certificate backed by a key that can actually
        // sign is classified activeUsable and can never be selected.
        let usableFingerprints = usableCertificateFingerprints(
            in: certificates,
            metadata: [activeMetadata, candidateMetadata].compactMap { $0 }
        )
        let classified = certificates.map { certificate in
            ClassifiedDevelopmentCertificate(
                raw: certificate,
                serial: certificateSerialNumber(certificate),
                fingerprint: certificateData(certificate).map(certificateFingerprint),
                expiration: certificateData(certificate)
                    .flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
                    .flatMap(certificateExpiration),
                ownership: classifyDevelopmentCertificate(
                    certificate,
                    activeMetadata: activeMetadata,
                    candidateMetadata: candidateMetadata,
                    installationIdentifier: installation,
                    usableFingerprints: usableFingerprints
                )
            )
        }
        recordIdentity(
            .certificateOwnershipClassified,
            generation: generation,
            counts: [
                "reclaimableCount": classified.filter { $0.ownership.isReclaimable }.count,
                "activeUsableCount": classified.filter { $0.ownership == .activeUsable }.count,
                "otherInstallationCount": classified.filter { $0.ownership == .veyaOtherInstall }.count,
                "unknownCount": classified.filter { $0.ownership == .unknown }.count
            ]
        )

        // Invariants 1 and 5: only P1/P2, and a serial is required because the
        // revoke call is keyed on it. Anything else fails closed.
        let reclaimable = classified
            .filter { $0.ownership.isReclaimable && $0.serial != nil }
            .sorted { lhs, rhs in
                let left = lhs.expiration ?? .distantPast
                let right = rhs.expiration ?? .distantPast
                if left != right { return left < right }
                return (lhs.serial ?? "") < (rhs.serial ?? "")
            }
        guard let victim = reclaimable.first, let serial = victim.serial else {
            recordIdentity(.certificateReclaimUnavailable, generation: generation)
            throw exhaustedError
        }

        recordIdentity(
            .certificateOwnershipProven,
            generation: generation,
            fingerprint: victim.fingerprint,
            flags: ["ownershipLevel\(victim.ownership.rawValue)": true]
        )

        var intent = try identityKeychain.loadRecoveryIntent(teamIdentifier: team.id)
            ?? CertificateRecoveryIntent(
                teamIdentifier: team.id,
                targetSerial: serial,
                targetFingerprint: victim.fingerprint,
                installationIdentifier: installation,
                startedAt: Date(),
                attempts: 0
            )
        // Invariant 3: one certificate per recovery, and never a different one
        // than a prior attempt already targeted.
        guard intent.targetSerial == serial else {
            recordIdentity(.certificateReclaimUnavailable, generation: generation, flags: ["targetChanged": true])
            throw ExperimentalBackendError.certificateRevocationFailed
        }
        intent.attempts += 1
        // Persisted *before* the irreversible call, so a crash in the next few
        // milliseconds is still reconcilable.
        try identityKeychain.saveRecoveryIntent(intent)

        recordIdentity(
            .certificateReclaimStarted,
            generation: generation,
            fingerprint: victim.fingerprint,
            counts: ["revocationAttempts": intent.attempts]
        )

        do {
            _ = try await developerRequest(
                operation: "ios/revokeDevelopmentCert",
                parameters: ["teamId": team.id, "serialNumber": serial]
            )
        } catch {
            // Any rejected revoke is reported as exactly that, never collapsed
            // into the capacity error and never retried against a different
            // certificate. The recovery intent stays persisted, so a later
            // attempt reconciles this same serial against Apple's real state
            // instead of choosing a new target.
            //
            // A certificate Apple has already forgotten does not reach here: it
            // is absent from the listing, so the intent-reconciliation path
            // above handles it before any revoke is attempted.
            recordIdentity(.certificateRevocationFailed, generation: generation)
            throw ExperimentalBackendError.certificateRevocationFailed
        }

        recordIdentity(.certificateRevoked, generation: generation, fingerprint: victim.fingerprint)
        try recordRetiredCertificate(victim, team: team, reason: "CAPACITY_RECLAIM")
        try await confirmCapacityReleased(team: team, generation: generation)
        try identityKeychain.clearRecoveryIntent(teamIdentifier: team.id)
    }

    /// Bounded re-read of Apple's capacity after a revocation. Never spins, and
    /// never revokes a second certificate because the first has not propagated.
    private func confirmCapacityReleased(team: ExperimentalAppleTeam, generation: UInt64) async throws {
        for attempt in 1...Self.capacityConfirmationAttempts {
            let refreshed = try await developerRequest(
                operation: "ios/listAllDevelopmentCerts",
                parameters: ["teamId": team.id]
            )
            let quantity = integer(refreshed["availableQuantity"])
            if quantity != 0 {
                recordIdentity(
                    .certificateCapacityRestored,
                    generation: generation,
                    counts: ["capacityConfirmationAttempts": attempt]
                )
                return
            }
            recordIdentity(
                .certificateCapacityPropagating,
                generation: generation,
                counts: ["capacityConfirmationAttempts": attempt]
            )
            if attempt < Self.capacityConfirmationAttempts, certificateCapacityRetryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(certificateCapacityRetryDelay * 1_000_000_000))
            }
        }
        // The revocation is recorded and the intent is deliberately retained, so
        // Try Again reconciles instead of revoking again.
        recordIdentity(.certificateCapacityNotReleased, generation: generation)
        throw ExperimentalBackendError.certificateCapacityNotReleased
    }

    /// Fingerprints of listed certificates that a locally held key can actually
    /// sign with right now. Feeds invariant 2.
    private func usableCertificateFingerprints(
        in certificates: [[String: Any]],
        metadata: [IOSSimIdentityMetadata]
    ) -> Set<String> {
        var usable: Set<String> = []
        for record in metadata {
            guard let key = identityKeychain.lookupPrivateKey(applicationTag: record.keyApplicationTag).key else {
                continue
            }
            for certificate in certificates {
                guard let data = certificateData(certificate),
                      let materialized = SecCertificateCreateWithData(nil, data as CFData),
                      certificatePublicKeyMatchesPrivateKey(materialized, privateKey: key) else { continue }
                guard (try? identityKeychain.verifySigningKeyUsable(certificate: materialized)) != nil else { continue }
                usable.insert(certificateFingerprint(data))
            }
        }
        return usable
    }

    private func recordRetiredCertificate(
        _ certificate: ClassifiedDevelopmentCertificate,
        team: ExperimentalAppleTeam,
        reason: String
    ) throws {
        let record = RetiredCertificateRecord(
            serial: certificate.serial,
            fingerprint: certificate.fingerprint,
            retiredAt: Date(),
            reason: reason
        )
        guard let existing = try identityKeychain.load(teamIdentifier: team.id) else { return }
        var retired = existing.retiredCertificates ?? []
        guard !retired.contains(where: { $0.serial == record.serial && $0.serial != nil }) else { return }
        retired.append(record)
        try identityKeychain.save(IOSSimIdentityMetadata(
            teamIdentifier: existing.teamIdentifier,
            certificateFingerprint: existing.certificateFingerprint,
            certificateSerial: existing.certificateSerial,
            certificateExpiration: existing.certificateExpiration,
            keyApplicationTag: existing.keyApplicationTag,
            createdAt: existing.createdAt,
            generatedByIOSSim: existing.generatedByIOSSim,
            installationIdentifier: existing.installationIdentifier,
            certificateRequestIdentifier: existing.certificateRequestIdentifier,
            publicKeyFingerprint: existing.publicKeyFingerprint,
            retiredCertificates: retired
        ))
    }

    private func createManagedIdentity(
        team: ExperimentalAppleTeam,
        generation: UInt64,
        recovering: Bool
    ) async throws -> ExperimentalSigningIdentity {
        let tag = Data("com.iossim.personal-team.\(team.id).\(UUID().uuidString.uppercased())".utf8)
        let key = try identityKeychain.createPrivateKey(applicationTag: tag)
        recordIdentity(.keypairCreated, generation: generation, tag: tag)
        let createdAt = Date()
        try identityKeychain.saveCandidate(IOSSimIdentityMetadata(
            teamIdentifier: team.id,
            certificateFingerprint: nil,
            certificateSerial: nil,
            certificateExpiration: nil,
            keyApplicationTag: tag,
            createdAt: createdAt,
            generatedByIOSSim: true
        ))
        return try await requestDevelopmentIdentity(
            key: key,
            tag: tag,
            createdAt: createdAt,
            team: team,
            generation: generation,
            recovering: recovering,
            pendingPromotion: true
        )
    }

    private func requestDevelopmentIdentity(
        key: SecKey,
        tag: Data,
        createdAt: Date,
        team: ExperimentalAppleTeam,
        generation: UInt64,
        recovering: Bool,
        pendingPromotion: Bool
    ) async throws -> ExperimentalSigningIdentity {
        let csr = try createCertificateSigningRequest(key: key)
        let installationIdentifier = try identityKeychain.installationIdentifier()
        recordIdentity(.csrCreated, generation: generation, tag: tag)
        var submittedCertificate: [String: Any]?
        do {
            submittedCertificate = try await submitDevelopmentCSR(
                csr: csr,
                team: team,
                installationIdentifier: installationIdentifier
            )
        } catch let error as ExperimentalBackendError where error == .certificateLimit {
            // Some Developer Services responses do not report exhausted
            // capacity in listAllDevelopmentCerts, but later reject the CSR with
            // Apple's 7460 certificate-limit code. Treat that rejection as the
            // authoritative capacity signal and run the same ownership-proofed
            // reclaim ladder before retrying the identical CSR once.
            try await recoverCertificateCapacityAfterCSRLimit(team: team, generation: generation)
            submittedCertificate = try await submitDevelopmentCSRAfterReclaim(
                csr: csr,
                team: team,
                installationIdentifier: installationIdentifier,
                generation: generation
            )
        }
        var match = submittedCertificate.flatMap {
            matchingCertificate(in: [$0], key: key, teamIdentifier: team.id)
        }
        if let submittedCertificate, certificateData(submittedCertificate) != nil {
            recordIdentity(.certificateFound, generation: generation, tag: tag)
            recordIdentity(
                .certificatePublicKeyMatch,
                generation: generation,
                tag: tag,
                fingerprint: match?.fingerprint,
                flags: ["certificatePublicKeyMatchesPrivateKey": match != nil]
            )
        }
        if match == nil {
            let refreshed = try await developerRequest(
                operation: "ios/listAllDevelopmentCerts",
                parameters: ["teamId": team.id]
            )
            guard let refreshedCertificates = refreshed["certificates"] as? [[String: Any]],
                  refreshedCertificates.count <= 100 else {
                throw ExperimentalBackendError.certificateRequestFailed
            }
            match = matchingCertificate(in: refreshedCertificates, key: key, teamIdentifier: team.id)
        }
        guard let match else {
            throw ExperimentalBackendError.certificateRequestFailed
        }
        recordIdentity(
            .certificateFound,
            generation: generation,
            tag: tag,
            fingerprint: match.fingerprint
        )
        recordIdentity(
            .developmentCertificateCreated,
            generation: generation,
            tag: tag,
            fingerprint: match.fingerprint,
            flags: ["certificatePublicKeyMatchesPrivateKey": true]
        )
        return try finishManagedIdentity(
            match,
            key: key,
            tag: tag,
            createdAt: createdAt,
            team: team,
            generation: generation,
            reused: false,
            pendingPromotion: pendingPromotion,
            recovered: recovering
        )
    }

    private func submitDevelopmentCSR(
        csr: String,
        team: ExperimentalAppleTeam,
        installationIdentifier: String
    ) async throws -> [String: Any] {
        do {
            let submitted = try await developerRequest(
                operation: "ios/submitDevelopmentCSR",
                parameters: [
                    "teamId": team.id,
                    // Stable across every request from this installation, so a
                    // later run can attribute the certificate to this Mac even
                    // if the local key is gone -- and can recognise another
                    // Mac's certificate as not its own. Build 1 and Build 2 sent
                    // a fresh random UUID here, which threw that evidence away.
                    "machineId": installationIdentifier,
                    "machineName": veyaMachineName(installationIdentifier: installationIdentifier),
                    "csrContent": csr
                ]
            )
            guard let request = submitted["certRequest"] as? [String: Any],
                  certificateData(request) != nil
                    || !(certificateString(request, names: ["certRequestId", "requestId", "certificateId"]) ?? "").isEmpty else {
                throw ExperimentalBackendError.certificateRequestFailed
            }
            return request
        } catch let failure as AppleServiceFailure {
            if failure.error == .certificateLimit { throw ExperimentalBackendError.certificateLimit }
            throw ExperimentalBackendError.certificateRequestFailed
        }
    }

    private func submitDevelopmentCSRAfterReclaim(
        csr: String,
        team: ExperimentalAppleTeam,
        installationIdentifier: String,
        generation: UInt64
    ) async throws -> [String: Any] {
        for attempt in 1...Self.capacityConfirmationAttempts {
            do {
                return try await submitDevelopmentCSR(
                    csr: csr,
                    team: team,
                    installationIdentifier: installationIdentifier
                )
            } catch let error as ExperimentalBackendError where error == .certificateLimit {
                guard attempt < Self.capacityConfirmationAttempts else { throw error }
                recordIdentity(
                    .certificateCapacityPropagating,
                    generation: generation,
                    counts: ["capacityConfirmationAttempts": attempt]
                )
                if certificateCapacityRetryDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(certificateCapacityRetryDelay * 1_000_000_000))
                }
            }
        }
        throw ExperimentalBackendError.certificateLimit
    }

    private func recoverCertificateCapacityAfterCSRLimit(
        team: ExperimentalAppleTeam,
        generation: UInt64
    ) async throws {
        let refreshed = try await developerRequest(
            operation: "ios/listAllDevelopmentCerts",
            parameters: ["teamId": team.id]
        )
        guard let certificates = refreshed["certificates"] as? [[String: Any]], certificates.count <= 100 else {
            throw ExperimentalBackendError.certificateRequestFailed
        }
        let activeMetadata = try identityKeychain.load(teamIdentifier: team.id)
        let candidateMetadata = try identityKeychain.loadCandidate(teamIdentifier: team.id)
        try await ensureCertificateCapacity(
            team: team,
            generation: generation,
            availableQuantity: 0,
            certificates: certificates,
            activeMetadata: activeMetadata,
            candidateMetadata: candidateMetadata,
            exhaustedError: .certificateLimit
        )
    }

    private func finishManagedIdentity(
        _ match: MatchedDevelopmentCertificate,
        key: SecKey,
        tag: Data,
        createdAt: Date,
        team: ExperimentalAppleTeam,
        generation: UInt64,
        reused: Bool,
        pendingPromotion: Bool,
        recovered: Bool
    ) throws -> ExperimentalSigningIdentity {
        guard certificatePublicKeyMatchesPrivateKey(match.certificate, privateKey: key) else {
            recordIdentity(
                .certificatePublicKeyMatch,
                generation: generation,
                tag: tag,
                fingerprint: match.fingerprint,
                flags: ["certificatePublicKeyMatchesPrivateKey": false]
            )
            throw ExperimentalBackendError.certificateRequestFailed
        }
        try identityKeychain.addCertificate(match.certificate, teamIdentifier: team.id)
        // Signing-ready requires proof, not the presence of a certificate,
        // a profile and a key. This runs the same /usr/bin/codesign
        // authorization path that payload signing will use.
        do {
            try identityKeychain.verifySigningKeyUsable(certificate: match.certificate)
            recordIdentity(
                .signingKeyUsabilityVerified,
                generation: generation,
                tag: tag,
                fingerprint: match.fingerprint
            )
        } catch {
            recordIdentity(
                .signingKeyUsabilityFailed,
                generation: generation,
                tag: tag,
                fingerprint: match.fingerprint
            )
            throw ExperimentalBackendError.missingPrivateKey
        }
        // Schema-2 ownership evidence. Written on every completed identity so a
        // future run can prove this certificate is this installation's even if
        // the private key later becomes unreadable -- the exact situation that
        // stranded Build 1's certificate.
        let existing = (try? identityKeychain.load(teamIdentifier: team.id)) ?? nil
        let metadata = IOSSimIdentityMetadata(
            teamIdentifier: team.id,
            certificateFingerprint: match.fingerprint,
            certificateSerial: match.serial,
            certificateExpiration: match.expiration,
            keyApplicationTag: tag,
            createdAt: createdAt,
            generatedByIOSSim: true,
            installationIdentifier: try? identityKeychain.installationIdentifier(),
            certificateRequestIdentifier: match.requestIdentifier,
            publicKeyFingerprint: publicKeyFingerprint(key),
            retiredCertificates: existing?.retiredCertificates
        )
        let persistent = try identityKeychain.persistentReference(applicationTag: tag)
        if pendingPromotion {
            try identityKeychain.saveCandidate(metadata)
        } else {
            try identityKeychain.save(metadata)
        }
        record(reused ? .signingIdentityReused : .signingIdentityCreated, stage: "certificate")
        diagnostics.update(adapterVersion: adapter.version) { $0.certificateFingerprint = match.fingerprint }
        if recovered {
            recordIdentity(
                .managedIdentityRecoverySucceeded,
                generation: generation,
                tag: tag,
                fingerprint: match.fingerprint
            )
        }
        recordIdentity(
            .provisioningPreparationContinued,
            generation: generation,
            tag: tag,
            fingerprint: match.fingerprint
        )
        return ExperimentalSigningIdentity(
            certificateFingerprint: match.fingerprint,
            certificateExpiration: match.expiration,
            privateKeyPersistentReference: persistent,
            keyApplicationTagIdentifier: canonicalManagedKeyTag(tag, teamIdentifier: team.id),
            pendingPromotion: pendingPromotion,
            reused: reused
        )
    }

    public func registerDevice(
        _ request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam
    ) async throws {
        let generation = identityGeneration
        let teamMatches = authorizedTeamIdentifier == team.id
        guard teamMatches else {
            recordDeviceRegistration(
                .deviceRegistrationRejected,
                generation: generation,
                request: request,
                team: team,
                category: .invalidTeam,
                flags: ["authorizedTeamMatchesAddDeviceTeam": false]
            )
            throw ExperimentalBackendError.invalidTeam
        }
        let deviceNumber: String
        let deviceName: String
        do {
            deviceNumber = try validatedDeviceRegistrationIdentifier(
                request.selectedDeviceRegistrationIdentifier,
                source: request.deviceIdentifierSource
            )
            deviceName = try validatedDeviceName(request.selectedDeviceName)
        } catch let error as ExperimentalBackendError {
            let category: AppleDeviceRegistrationCategory = error == .invalidDeviceIdentifier
                ? .invalidDeviceIdentifier : .missingRequiredField
            recordDeviceRegistration(
                .deviceRegistrationRejected,
                generation: generation,
                request: request,
                team: team,
                category: category,
                safeMessage: error == .invalidDeviceIdentifier
                    ? "The physical device registration identifier is missing or has an invalid form."
                    : "A non-empty device name is required."
            )
            throw error
        }

        recordDeviceRegistration(
            .deviceRegistrationCheckStarted,
            generation: generation,
            request: request,
            team: team,
            flags: ["authorizedTeamMatchesDeviceListTeam": true]
        )
        var devices = try await listRegisteredDevices(teamID: team.id)
        recordDeviceRegistration(
            .registeredDeviceListReceived,
            generation: generation,
            request: request,
            team: team,
            counts: ["registeredDeviceCount": devices.count],
            flags: ["authorizedTeamMatchesDeviceListTeam": true]
        )
        var matched = devices.contains { registeredDeviceNumber($0).map {
            normalizedDeviceIdentifier($0) == normalizedDeviceIdentifier(deviceNumber)
        } ?? false }
        recordDeviceRegistration(
            .registeredDeviceMatchResult,
            generation: generation,
            request: request,
            team: team,
            flags: ["matched": matched]
        )
        if matched {
            finishDeviceRegistrationReuse(generation: generation, request: request, team: team)
            return
        }

        recordDeviceRegistration(
            .deviceRegistrationRequired,
            generation: generation,
            request: request,
            team: team
        )
        let requestContext = DeviceRegistrationDiagnosticContext(
            generation: generation,
            request: request,
            team: team,
            teamMatches: true,
            deviceName: deviceName,
            deviceNumber: deviceNumber
        )
        do {
            _ = try await developerRequest(
                operation: "ios/addDevice",
                parameters: ["teamId": team.id, "name": deviceName, "deviceNumber": deviceNumber],
                deviceRegistrationContext: requestContext
            )
        } catch let failure as AppleServiceFailure {
            let shouldReconcile = failure.deviceRegistrationCategory == .alreadyRegistered
                || failure.retryable || failure.error == .networkFailure
            if shouldReconcile {
                recordDeviceRegistration(
                    .deviceRegistrationReconciliationStarted,
                    generation: generation,
                    request: request,
                    team: team,
                    category: failure.deviceRegistrationCategory,
                    safeMessage: failure.safeMessage
                )
                devices = try await listRegisteredDevices(teamID: team.id)
                matched = devices.contains { registeredDeviceNumber($0).map {
                    normalizedDeviceIdentifier($0) == normalizedDeviceIdentifier(deviceNumber)
                } ?? false }
                recordDeviceRegistration(
                    .registeredDeviceListReceived,
                    generation: generation,
                    request: request,
                    team: team,
                    counts: ["registeredDeviceCount": devices.count],
                    flags: ["authorizedTeamMatchesDeviceListTeam": true]
                )
                recordDeviceRegistration(
                    .registeredDeviceMatchResult,
                    generation: generation,
                    request: request,
                    team: team,
                    flags: ["matched": matched]
                )
                if matched {
                    finishDeviceRegistrationReuse(generation: generation, request: request, team: team)
                    return
                }
            }
            recordDeviceRegistration(
                .deviceRegistrationRejected,
                generation: generation,
                request: request,
                team: team,
                category: failure.deviceRegistrationCategory ?? .otherAppleRejection,
                safeMessage: failure.safeMessage,
                httpStatus: failure.status,
                appleCode: failure.appleCode
            )
            if failure.error == .deviceLimit { throw ExperimentalBackendError.deviceLimit }
            if failure.error == .sessionExpired { throw ExperimentalBackendError.sessionExpired }
            if failure.error == .invalidDeviceIdentifier { throw ExperimentalBackendError.invalidDeviceIdentifier }
            if failure.error == .invalidTeam { throw ExperimentalBackendError.invalidTeam }
            if failure.error == .deviceNameRequired { throw ExperimentalBackendError.deviceNameRequired }
            throw ExperimentalBackendError.deviceRegistrationFailed
        }
        record(.deviceRegistered, stage: "deviceRegistration")
        recordDeviceRegistration(
            .deviceRegistrationSucceeded,
            generation: generation,
            request: request,
            team: team
        )
        recordDeviceRegistration(
            .provisioningDeviceReady,
            generation: generation,
            request: request,
            team: team
        )
        diagnostics.update(adapterVersion: adapter.version) { $0.deviceRegistrationStatus = "REGISTERED" }
    }

    private func listRegisteredDevices(teamID: String) async throws -> [[String: Any]] {
        guard authorizedTeamIdentifier == teamID else { throw ExperimentalBackendError.invalidTeam }
        let listed = try await developerRequest(operation: "ios/listDevices", parameters: ["teamId": teamID])
        guard let devices = listed["devices"] as? [[String: Any]], devices.count <= 500,
              devices.allSatisfy({
                  guard let number = registeredDeviceNumber($0) else { return false }
                  return !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw ExperimentalBackendError.responseChanged
        }
        return devices
    }

    private func finishDeviceRegistrationReuse(
        generation: UInt64,
        request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam
    ) {
        recordDeviceRegistration(
            .deviceAlreadyRegistered,
            generation: generation,
            request: request,
            team: team
        )
        recordDeviceRegistration(
            .provisioningDeviceReady,
            generation: generation,
            request: request,
            team: team
        )
        diagnostics.update(adapterVersion: adapter.version) {
            $0.deviceRegistrationStatus = "ALREADY_REGISTERED"
        }
    }

    public func registerIdentifiers(
        _ identifiers: PersonalTeamBundleIdentifierSet,
        team: ExperimentalAppleTeam
    ) async throws {
        guard authorizedTeamIdentifier == team.id else { throw ExperimentalBackendError.invalidTeam }
        let required: [(String, String, ApplePersonalTeamCheckpoint)] = [
            (identifiers.main, "IOSSim Main", .mainIDReady),
            (identifiers.uiTests, "IOSSim UI Tests", .uiTestIDReady),
            (identifiers.runner, "IOSSim Runner", .runnerIDReady)
        ]
        var listed = try await listAppIdentifiers(teamID: team.id)
        for (bundleIdentifier, name, checkpoint) in required {
            if let existing = listed.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                appIdentifierIDs[bundleIdentifier] = existing.identifier
                record(checkpoint, stage: "appIdentifiers")
                continue
            }
            if listed.availableQuantity == 0 { throw ExperimentalBackendError.appIDLimit }
            do {
                _ = try await developerRequest(operation: "ios/addAppId", parameters: [
                    "teamId": team.id,
                    "identifier": bundleIdentifier,
                    "name": name
                ])
            } catch let failure as AppleServiceFailure {
                if failure.error == .appIDLimit { throw ExperimentalBackendError.appIDLimit }
                if failure.error == .appIDCollision { throw ExperimentalBackendError.appIDCollision }
                throw ExperimentalBackendError.appIDRegistrationFailed
            }
            listed = try await listAppIdentifiers(teamID: team.id)
            guard let created = listed.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                throw ExperimentalBackendError.appIDRegistrationFailed
            }
            appIdentifierIDs[bundleIdentifier] = created.identifier
            record(checkpoint, stage: "appIdentifiers")
        }
        diagnostics.update(adapterVersion: adapter.version) {
            $0.derivedBundleIdentifiers = required.map(\.0).sorted()
        }
    }

    public func obtainProfiles(
        identifiers: PersonalTeamBundleIdentifierSet,
        identity: ExperimentalSigningIdentity,
        request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam
    ) async throws -> [ExperimentalProfile] {
        guard authorizedTeamIdentifier == team.id else { throw ExperimentalBackendError.invalidTeam }
        var profiles: [ExperimentalProfile] = []
        for (bundleIdentifier, checkpoint) in [
            (identifiers.main, ApplePersonalTeamCheckpoint.mainProfileReady),
            (identifiers.runner, ApplePersonalTeamCheckpoint.runnerProfileReady)
        ] {
            guard let appID = appIdentifierIDs[bundleIdentifier] else {
                throw ExperimentalBackendError.appIDRegistrationFailed
            }
            let response: [String: Any]
            do {
                response = try await developerRequest(
                    operation: "ios/downloadTeamProvisioningProfile",
                    parameters: ["teamId": team.id, "appIdId": appID]
                )
            } catch {
                throw ExperimentalBackendError.profileRequestFailed
            }
            let encoded = try AppleDeveloperResponseParser.encodedProfile(response)
            let profile = try decodeAndValidateProfile(
                encoded,
                expectedBundleIdentifier: bundleIdentifier,
                expectedTeamIdentifier: team.id,
                selectedDeviceIdentifier: request.selectedDeviceRegistrationIdentifier,
                certificateFingerprint: identity.certificateFingerprint
            )
            profiles.append(profile)
            record(checkpoint, stage: "profiles")
            diagnostics.update(adapterVersion: adapter.version) {
                $0.profileIssuedAt[bundleIdentifier] = profile.issuedAt
                $0.profileExpiresAt[bundleIdentifier] = profile.expiresAt
                $0.profileValidation = "VALID"
            }
        }
        record(.provisioningReady, stage: "provisioning")
        return profiles
    }

    public func signArtifacts(
        identifiers: PersonalTeamBundleIdentifierSet,
        identity: ExperimentalSigningIdentity,
        profiles: [ExperimentalProfile]
    ) async throws {
        throw ExperimentalBackendError.unavailable
    }

    public func installArtifacts(
        identifiers: PersonalTeamBundleIdentifierSet,
        request: ExperimentalProvisioningRequest
    ) async throws -> ExperimentalInstallInventory {
        throw ExperimentalBackendError.unavailable
    }

    public func preparePairing(for request: ExperimentalProvisioningRequest) async throws -> Bool {
        throw ExperimentalBackendError.unavailable
    }

    private struct AppIdentifierList: Sequence {
        struct Item {
            let identifier: String
            let bundleIdentifier: String
        }
        let items: [Item]
        let availableQuantity: Int
        func makeIterator() -> Array<Item>.Iterator { items.makeIterator() }
        func first(where predicate: (Item) throws -> Bool) rethrows -> Item? { try items.first(where: predicate) }
    }

    private func listAppIdentifiers(teamID: String) async throws -> AppIdentifierList {
        let response = try await developerRequest(operation: "ios/listAppIds", parameters: ["teamId": teamID])
        guard let raw = response["appIds"] as? [[String: Any]], raw.count <= 1_000 else {
            throw ExperimentalBackendError.responseChanged
        }
        let items = try raw.map { item -> AppIdentifierList.Item in
            guard let id = string(item["appIdId"] ?? item["identifierId"] ?? item["id"]),
                  let bundle = item["identifier"] as? String,
                  !id.isEmpty, !bundle.isEmpty, bundle.count <= 255 else {
                throw ExperimentalBackendError.responseChanged
            }
            return .init(identifier: id, bundleIdentifier: bundle)
        }
        return AppIdentifierList(
            items: items,
            availableQuantity: max(0, integer(response["availableQuantity"]) ?? Int.max)
        )
    }
}

func validatedDeviceName(_ value: String?) throws -> String {
    guard let value, !value.isEmpty,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ExperimentalBackendError.deviceNameRequired
    }
    let allowed = value.unicodeScalars.filter { CharacterSet.alphanumerics.union(.whitespaces).contains($0) }
    let result = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { throw ExperimentalBackendError.deviceNameRequired }
    return String(result.prefix(100))
}

func normalizedDeviceIdentifier(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .filter { $0 != "-" && !$0.isWhitespace }
        .uppercased()
}

func validatedDeviceRegistrationIdentifier(
    _ value: String,
    source: ExperimentalProvisioningRequest.DeviceIdentifierSource
) throws -> String {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard source != .coreDeviceIdentifier else { throw ExperimentalBackendError.invalidDeviceIdentifier }
    let pieces = candidate.split(separator: "-", omittingEmptySubsequences: false)
    let modern = pieces.count == 2 && pieces[0].count == 8 && pieces[1].count == 16
    let legacy = pieces.count == 1 && pieces[0].count == 40
    guard modern || legacy,
          candidate.unicodeScalars.allSatisfy({
              CharacterSet(charactersIn: "0123456789ABCDEF-").contains($0)
          }) else {
        throw ExperimentalBackendError.invalidDeviceIdentifier
    }
    return candidate
}

private func registeredDeviceNumber(_ value: [String: Any]) -> String? {
    if let number = value["deviceNumber"] as? String { return number }
    if let attributes = value["attributes"] as? [String: Any],
       let number = attributes["deviceNumber"] as? String { return number }
    return nil
}

private func appleDeveloperMessageCandidates(_ response: [String: Any]) -> [String] {
    let direct = ["userString", "statusString", "resultString"]
        .compactMap { response[$0] as? String }
    let validation = response["validationMessages"] as? [String] ?? []
    return (direct + validation).filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private func safeAppleDeveloperMessage(_ response: [String: Any]) -> String? {
    appleDeveloperMessageCandidates(response).first
        .map(Redactor.redact)
        .flatMap { $0.utf8.count <= 512 ? $0 : nil }
}

func classifyDeviceRegistrationRejection(
    code: Int,
    response: [String: Any]
) -> AppleDeviceRegistrationCategory {
    let message = appleDeveloperMessageCandidates(response).joined(separator: " ").lowercased()
    if message.contains("session") || message.contains("authenticate") || message.contains("token") {
        return .sessionRejected
    }
    if message.contains("maximum") || message.contains("capacity") || message.contains("limit") {
        return .deviceCapacityExceeded
    }
    if message.contains("team")
        && (message.contains("invalid") || message.contains("not found") || message.contains("access")) {
        return .invalidTeam
    }
    if message.contains("already")
        && (message.contains("register") || message.contains("added") || message.contains("exist")) {
        return .alreadyRegistered
    }
    if (message.contains("no value") || message.contains("missing") || message.contains("required"))
        && message.contains("parameter") {
        return .missingRequiredField
    }
    if message.contains("devicenumber")
        && (message.contains("invalid") || message.contains("format")) {
        return .invalidDeviceIdentifier
    }
    if message.contains("malformed") || message.contains("parameter") || message.contains("plist") {
        return .malformedRequest
    }
    _ = code // The numeric code is deliberately not treated as a universal mapping.
    return .otherAppleRejection
}

func certificateData(_ dictionary: [String: Any]) -> Data? {
    let attributes = dictionary["attributes"] as? [String: Any] ?? dictionary
    if let data = attributes["certContent"] as? Data { return data }
    if let data = attributes["certificateContent"] as? Data { return data }
    if let base64 = attributes["certificateContent"] as? String { return Data(base64Encoded: base64) }
    return nil
}

private func certificateString(_ dictionary: [String: Any], names: [String]) -> String? {
    let attributes = dictionary["attributes"] as? [String: Any] ?? dictionary
    for name in names {
        if let value = string(attributes[name]), !value.isEmpty { return value }
    }
    return nil
}

private struct MatchedDevelopmentCertificate {
    let certificate: SecCertificate
    let fingerprint: String
    let serial: String?
    let expiration: Date
    /// Apple's own identifier for the certificate request, when the response
    /// carried one. Persisted purely as additional ownership evidence.
    let requestIdentifier: String?
}

/// The structured machine name Veya sends to Apple from Build 3 onward. The
/// embedded short installation id is what lets a later run tell *this* Mac's
/// certificate apart from another Mac's on the same Apple Account.
func veyaMachineName(installationIdentifier: String) -> String {
    "Veya (\(installationShortIdentifier(installationIdentifier)))"
}

func installationShortIdentifier(_ identifier: String) -> String {
    String(identifier.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
}

/// Extracts the installation id from a Veya structured machine name, or nil if
/// the name was not written by a Build-3-or-later Veya. Build-1/Build-2 names
/// were the constant "IOSSim" and deliberately yield nil, so a legacy
/// certificate is never mistaken for another installation's.
func veyaInstallationShortIdentifier(fromMachineName name: String?) -> String? {
    guard let name, name.hasPrefix("Veya ("), name.hasSuffix(")") else { return nil }
    let inner = name.dropFirst("Veya (".count).dropLast()
    // Must match what `installationShortIdentifier` produces, which is
    // alphanumeric rather than strictly hexadecimal. Requiring hex here would
    // silently fail to recognise a real installation marker and, worse, would
    // classify another Mac's certificate as unknown instead of off-limits.
    guard !inner.isEmpty, inner.count <= 32,
          inner.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    return String(inner).uppercased()
}

func certificateMachineName(_ dictionary: [String: Any]) -> String? {
    certificateString(dictionary, names: ["machineName", "machineNameValue", "name"])
}

func certificateMachineIdentifier(_ dictionary: [String: Any]) -> String? {
    certificateString(dictionary, names: ["machineId", "machineIdentifier"])
}

func certificateRequestIdentifier(_ dictionary: [String: Any]) -> String? {
    certificateString(dictionary, names: ["certRequestId", "requestId", "certificateId"])
}

func certificateSerialNumber(_ dictionary: [String: Any]) -> String? {
    certificateString(dictionary, names: ["serialNumber", "serialNum"])
}

/// SHA-256 over the certificate's SubjectPublicKeyInfo. Non-secret, and stable
/// across reissue only when the same key is reused -- which is exactly the
/// property that makes it usable as ownership evidence.
func publicKeyFingerprint(_ key: SecKey) -> String? {
    guard let publicKey = SecKeyCopyPublicKey(key),
          let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
    return Data(SHA256.hash(data: bytes)).map { String(format: "%02X", $0) }.joined()
}

/// Decides how strongly a single listed certificate is attributable to this
/// installation.
///
/// Evaluation order is deliberate and is the multi-Mac safety property:
///
/// 1. `activeUsable` first, so a working identity can never be selected.
/// 2. `ownedLocalRecord` next, because this installation's own persisted serial
///    is the strongest evidence available and outranks any remote marker. A
///    Build-1 certificate reaches this rung even though it predates every
///    remote marker, which is what makes the dirty-Mac migration recoverable.
/// 3. `ownedRemoteMarker` next, for certificates this installation created after
///    Build 3 stamped a stable `machineId`.
/// 4. `veyaOtherInstall` next. Note this is only reachable when the *structured*
///    name names a different installation. Build-1/Build-2 wrote the constant
///    "IOSSim" and never reach this rung, so legacy certificates are not
///    misattributed to another Mac.
/// 5. `unknown` otherwise.
func classifyDevelopmentCertificate(
    _ certificate: [String: Any],
    activeMetadata: IOSSimIdentityMetadata?,
    candidateMetadata: IOSSimIdentityMetadata?,
    installationIdentifier: String,
    usableFingerprints: Set<String>
) -> CertificateOwnership {
    let serial = certificateSerialNumber(certificate)
    let fingerprint = certificateData(certificate).map(certificateFingerprint)

    if let fingerprint, usableFingerprints.contains(fingerprint) { return .activeUsable }

    let records = [activeMetadata, candidateMetadata].compactMap { $0 }
    let namesThisCertificate = records.contains { record in
        guard record.generatedByIOSSim,
              canonicalManagedKeyTag(record.keyApplicationTag, teamIdentifier: record.teamIdentifier) != nil else {
            return false
        }
        if let serial, let expected = record.certificateSerial, expected == serial { return true }
        if let fingerprint, let expected = record.certificateFingerprint, expected == fingerprint { return true }
        return false
    }
    if namesThisCertificate { return .ownedLocalRecord }

    if let machineIdentifier = certificateMachineIdentifier(certificate),
       machineIdentifier == installationIdentifier {
        return .ownedRemoteMarker
    }

    if let other = veyaInstallationShortIdentifier(fromMachineName: certificateMachineName(certificate)),
       other != installationShortIdentifier(installationIdentifier) {
        return .veyaOtherInstall
    }

    return .unknown
}

private func rememberedCertificate(
    in certificates: [[String: Any]],
    metadata: IOSSimIdentityMetadata
) -> [String: Any]? {
    certificates.first { certificate in
        if let expected = metadata.certificateSerial,
           certificateString(certificate, names: ["serialNumber", "serialNum"]) == expected {
            return true
        }
        guard let expected = metadata.certificateFingerprint else { return false }
        return certificateData(certificate).map(certificateFingerprint) == expected
    }
}

func canonicalManagedKeyTag(_ data: Data, teamIdentifier: String) -> String? {
    guard let value = String(data: data, encoding: .utf8), Data(value.utf8) == data else { return nil }
    let prefix = "com.iossim.personal-team.\(teamIdentifier)."
    guard value.hasPrefix(prefix), UUID(uuidString: String(value.dropFirst(prefix.count))) != nil else { return nil }
    return value
}

func certificatePublicKeyMatchesPrivateKey(_ certificate: SecCertificate, privateKey: SecKey) -> Bool {
    guard let localPublicKey = SecKeyCopyPublicKey(privateKey),
          let localBytes = SecKeyCopyExternalRepresentation(localPublicKey, nil) as Data?,
          let certificateKey = SecCertificateCopyKey(certificate),
          let certificateBytes = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? else {
        return false
    }
    return constantTimeEqual(localBytes, certificateBytes)
}

private func matchingCertificate(
    in certificates: [[String: Any]],
    key: SecKey,
    teamIdentifier: String
) -> MatchedDevelopmentCertificate? {
    for object in certificates {
        guard let der = certificateData(object), der.count <= 64 * 1_024,
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              certificateTeamIdentifiers(certificate).contains(teamIdentifier),
              certificatePublicKeyMatchesPrivateKey(certificate, privateKey: key),
              let expiration = certificateExpiration(certificate), expiration > Date() else { continue }
        return MatchedDevelopmentCertificate(
            certificate: certificate,
            fingerprint: certificateFingerprint(der),
            serial: certificateSerialNumber(object),
            expiration: expiration,
            requestIdentifier: certificateRequestIdentifier(object)
        )
    }
    return nil
}

func certificateTeamIdentifiers(_ certificate: SecCertificate) -> Set<String> {
    guard let values = SecCertificateCopyValues(
        certificate,
        [kSecOIDX509V1SubjectName] as CFArray,
        nil
    ) as? [CFString: Any],
    let property = values[kSecOIDX509V1SubjectName] as? [CFString: Any],
    let subject = property[kSecPropertyKeyValue] as? [Any] else { return [] }
    var teamIdentifiers: Set<String> = []
    for field in subject {
        guard let field = field as? [CFString: Any],
              let label = field[kSecPropertyKeyLabel] as? String,
              label == "2.5.4.11",
              let value = field[kSecPropertyKeyValue] as? String,
              !value.isEmpty else { continue }
        teamIdentifiers.insert(value)
    }
    return teamIdentifiers
}

private func certificateFingerprint(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).map { String(format: "%02X", $0) }.joined()
}

func certificateExpiration(_ certificate: SecCertificate) -> Date? {
    guard let values = SecCertificateCopyValues(
        certificate,
        [kSecOIDX509V1ValidityNotAfter] as CFArray,
        nil
    ) as? [CFString: Any],
    let property = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any] else { return nil }
    let value = property[kSecPropertyKeyValue]
    if let date = value as? Date { return date }
    if let absoluteTime = value as? NSNumber {
        return Date(timeIntervalSinceReferenceDate: absoluteTime.doubleValue)
    }
    return nil
}

func createCertificateSigningRequest(key: SecKey, teamIdentifier: String? = nil) throws -> String {
    guard let publicKey = SecKeyCopyPublicKey(key) else { throw ExperimentalBackendError.certificateRequestFailed }
    var error: Unmanaged<CFError>?
    guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
        throw ExperimentalBackendError.certificateRequestFailed
    }
    var subjectValues = [
        ASN1.set(ASN1.sequence([ASN1.oid([0x55, 0x04, 0x06]), ASN1.printable("US")])),
        ASN1.set(ASN1.sequence([ASN1.oid([0x55, 0x04, 0x0A]), ASN1.utf8("IOSSim")])),
    ]
    if let teamIdentifier {
        subjectValues.append(ASN1.set(ASN1.sequence([
            ASN1.oid([0x55, 0x04, 0x0B]), ASN1.utf8(teamIdentifier),
        ])))
    }
    subjectValues.append(ASN1.set(ASN1.sequence([
        ASN1.oid([0x55, 0x04, 0x03]), ASN1.utf8("IOSSim"),
    ])))
    let subject = ASN1.sequence(subjectValues)
    let algorithm = ASN1.sequence([ASN1.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), ASN1.null])
    let publicInfo = ASN1.sequence([algorithm, ASN1.bitString(pkcs1)])
    let requestInfo = ASN1.sequence([ASN1.integer(0), subject, publicInfo, Data([0xA0, 0x00])])
    guard let signature = SecKeyCreateSignature(
        key,
        .rsaSignatureMessagePKCS1v15SHA256,
        requestInfo as CFData,
        &error
    ) as Data? else { throw ExperimentalBackendError.certificateRequestFailed }
    let signatureAlgorithm = ASN1.sequence([
        ASN1.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]), ASN1.null
    ])
    let der = ASN1.sequence([requestInfo, signatureAlgorithm, ASN1.bitString(signature)])
    // Foundation adds no line ending after the final base64 line; RFC 7468 requires one before the footer.
    let encoded = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN CERTIFICATE REQUEST-----\n\(encoded)\n-----END CERTIFICATE REQUEST-----\n"
}

private enum ASN1 {
    static let null = Data([0x05, 0x00])
    static func sequence(_ values: [Data]) -> Data { item(0x30, values.reduce(Data(), +)) }
    static func set(_ value: Data) -> Data { item(0x31, value) }
    static func integer(_ value: UInt8) -> Data { item(0x02, Data([value])) }
    static func oid(_ bytes: [UInt8]) -> Data { item(0x06, Data(bytes)) }
    static func printable(_ string: String) -> Data { item(0x13, Data(string.utf8)) }
    static func utf8(_ string: String) -> Data { item(0x0C, Data(string.utf8)) }
    static func bitString(_ value: Data) -> Data { item(0x03, Data([0]) + value) }
    static func item(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }
    static func length(_ value: Int) -> Data {
        if value < 128 { return Data([UInt8(value)]) }
        var raw: [UInt8] = []
        var remaining = value
        while remaining > 0 { raw.insert(UInt8(remaining & 0xff), at: 0); remaining >>= 8 }
        return Data([0x80 | UInt8(raw.count)] + raw)
    }
}

/// Signature-checked CMS content of a provisioning profile (in process; never `security cms`).
func developmentProfileContent(_ encoded: Data) throws -> [String: Any] {
    var decoder: CMSDecoder?
    guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
          !encoded.isEmpty,
          encoded.withUnsafeBytes({ CMSDecoderUpdateMessage(decoder, $0.baseAddress!, encoded.count) }) == errSecSuccess,
          CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
        throw ExperimentalBackendError.invalidProfile
    }
    var signerStatus = CMSSignerStatus.unsigned
    var trust: SecTrust?
    var verificationStatus = errSecSuccess
    let policy = SecPolicyCreateBasicX509()
    guard CMSDecoderCopySignerStatus(decoder, 0, policy, false, &signerStatus, &trust, &verificationStatus) == errSecSuccess,
          signerStatus == .valid, verificationStatus == errSecSuccess else {
        throw ExperimentalBackendError.invalidProfile
    }
    var content: CFData?
    guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
          let plistData = content as Data?, plistData.count <= 1_048_576,
          let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
        throw ExperimentalBackendError.invalidProfile
    }
    return plist
}

private func decodeAndValidateProfile(
    _ encoded: Data,
    expectedBundleIdentifier: String,
    expectedTeamIdentifier: String,
    selectedDeviceIdentifier: String,
    certificateFingerprint expectedCertificateFingerprint: String,
    now: Date = Date()
) throws -> ExperimentalProfile {
    let plist = try developmentProfileContent(encoded)
    guard let team = (plist["TeamIdentifier"] as? [String])?.first, team == expectedTeamIdentifier,
          let prefix = (plist["ApplicationIdentifierPrefix"] as? [String])?.first, prefix == expectedTeamIdentifier,
          let entitlements = plist["Entitlements"] as? [String: Any],
          let applicationIdentifier = entitlements["application-identifier"] as? String,
          applicationIdentifier == "\(expectedTeamIdentifier).\(expectedBundleIdentifier)",
          entitlements["get-task-allow"] as? Bool == true,
          let devices = plist["ProvisionedDevices"] as? [String], devices.contains(selectedDeviceIdentifier),
          !devices.isEmpty,
          plist["ProvisionsAllDevices"] as? Bool != true,
          let issuedAt = plist["CreationDate"] as? Date,
          let expiresAt = plist["ExpirationDate"] as? Date,
          issuedAt <= now, expiresAt > now,
          let developerCertificates = plist["DeveloperCertificates"] as? [Data],
          developerCertificates.contains(where: { certificateFingerprint($0) == expectedCertificateFingerprint }) else {
        throw ExperimentalBackendError.invalidProfile
    }
    return ExperimentalProfile(
        bundleIdentifier: expectedBundleIdentifier,
        teamIdentifier: team,
        certificateFingerprint: expectedCertificateFingerprint,
        provisionedDeviceIdentifiers: Set(devices),
        applicationIdentifierEntitlement: applicationIdentifier,
        applicationIdentifierPrefix: prefix,
        getTaskAllow: true,
        profileType: "development",
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        profileData: encoded
    )
}

// MARK: - Live authentication and Developer Services backend

private struct LiveSessionEnvelope: Codable {
    let dsid: String
    let xcodeToken: String
    let tokenExpiresAt: Date?
}

private struct PendingTwoFactor {
    let account: String
    let password: SensitiveInput
    let dsid: String
    let idmsToken: String
    let method: AppleVerificationMethod
}

private struct AppleServiceFailure: Error {
    let error: ExperimentalBackendError
    let status: Int?
    let appleCode: Int?
    let retryAfter: Int?
    let retryable: Bool
    let reauthorizationRequired: Bool
    let safeMessage: String?
    let deviceRegistrationCategory: AppleDeviceRegistrationCategory?
    let responseMetadata: SafeAppleHTTPFailureMetadata?

    init(
        error: ExperimentalBackendError,
        status: Int?,
        appleCode: Int?,
        retryAfter: Int?,
        retryable: Bool,
        reauthorizationRequired: Bool,
        safeMessage: String? = nil,
        deviceRegistrationCategory: AppleDeviceRegistrationCategory? = nil,
        responseMetadata: SafeAppleHTTPFailureMetadata? = nil
    ) {
        self.error = error
        self.status = status
        self.appleCode = appleCode
        self.retryAfter = retryAfter
        self.retryable = retryable
        self.reauthorizationRequired = reauthorizationRequired
        self.safeMessage = safeMessage
        self.deviceRegistrationCategory = deviceRegistrationCategory
        self.responseMetadata = responseMetadata
    }
}

private struct SafeAppleHTTPFailureMetadata {
    let endpoint: String?
    let method: String?
    let contentType: String?
    let bodyKind: String
    let serverIdentifier: String?
    let requestIdentifier: String?
}

private struct DeviceRegistrationDiagnosticContext {
    let generation: UInt64
    let request: ExperimentalProvisioningRequest
    let team: ExperimentalAppleTeam
    let teamMatches: Bool
    let deviceName: String
    let deviceNumber: String

    init(
        generation: UInt64,
        request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam,
        teamMatches: Bool,
        deviceName: String,
        deviceNumber: String
    ) {
        self.generation = generation
        self.request = request
        self.team = team
        self.teamMatches = teamMatches
        self.deviceName = deviceName
        self.deviceNumber = deviceNumber
    }
}

enum AppleDeviceRegistrationCategory: String, Equatable, Sendable {
    case alreadyRegistered = "ALREADY_REGISTERED"
    case missingRequiredField = "MISSING_REQUIRED_FIELD"
    case invalidDeviceIdentifier = "INVALID_DEVICE_IDENTIFIER"
    case invalidTeam = "INVALID_TEAM"
    case deviceCapacityExceeded = "DEVICE_CAPACITY_EXCEEDED"
    case sessionRejected = "SESSION_REJECTED"
    case malformedRequest = "MALFORMED_REQUEST"
    case otherAppleRejection = "OTHER_APPLE_REJECTION"
}

enum AppleHTTPFailureClassifier {
    static func kind(status: Int, stage: String, bodyKind: String? = nil) -> AppleHTTPFailureKind {
        if status == 429 { return .rateLimited }
        if status == 503 {
            if stage.hasPrefix("srp") && bodyKind == "plist-or-xml" {
                return .clientMetadataRejected
            }
            return .serviceUnavailable
        }
        if stage == "validateVerification" && (400..<500).contains(status) { return .twoFactorRejected }
        if stage == "srpComplete" && (400..<500).contains(status) { return .srpProofRejected }
        if stage.hasPrefix("srp") && (400..<500).contains(status) { return .grandSlamChallengeRejected }
        return .httpServiceResponse
    }

    static func error(status: Int, stage: String) -> ExperimentalBackendError {
        if status == 429 { return .rateLimited }
        if stage == "xcodeScopedToken" { return .xcodeScopedTokenFailed }
        if stage.hasPrefix("developerServices/") { return .developerServicesFailed }
        if status == 503 { return .serviceUnavailable }
        return .networkFailure
    }
}

public enum AppleSRPInitializationDiagnosticResult: Equatable, Sendable {
    case success
    case http503
    case appleError(Int)
    case networkFailure
    case protocolFailure
    case responseParseFailure

    public var outputCode: String {
        switch self {
        case .success: return "SRP_INIT_SUCCESS"
        case .http503: return "SRP_INIT_HTTP_503"
        case .appleError(let code): return "SRP_INIT_APPLE_ERROR_\(code)"
        case .networkFailure: return "SRP_INIT_NETWORK_FAILURE"
        case .protocolFailure: return "SRP_INIT_PROTOCOL_FAILURE"
        case .responseParseFailure: return "SRP_INIT_RESPONSE_PARSE_FAILURE"
        }
    }
}

enum AppleDeveloperResponseParser {
    static func teams(_ response: [String: Any]) throws -> [ExperimentalAppleTeam] {
        guard let rawTeams = response["teams"] as? [[String: Any]],
              !rawTeams.isEmpty, rawTeams.count <= 100 else {
            throw ExperimentalBackendError.noTeam
        }
        return try rawTeams.map { item in
            guard let id = item["teamId"] as? String,
                  let name = item["name"] as? String, !name.isEmpty, name.count <= 512 else {
                throw ExperimentalBackendError.responseChanged
            }
            let type = (item["type"] as? String) ?? ""
            let memberships = item["memberships"] as? [[String: Any]] ?? []
            let membershipNames = memberships.compactMap { $0["name"] as? String }
                .joined(separator: " ").lowercased()
            let personal = type == "Individual" && membershipNames.contains("free")
            return ExperimentalAppleTeam(
                id: id,
                name: name,
                isPersonalTeam: personal,
                isPaidDeveloperTeam: (type == "Individual" && !personal) || type == "Company/Organization"
            )
        }
    }

    static func encodedProfile(_ response: [String: Any]) throws -> Data {
        guard let object = response["provisioningProfile"] as? [String: Any],
              let encoded = object["encodedProfile"] as? Data,
              !encoded.isEmpty, encoded.count <= 2_097_152 else {
            throw ExperimentalBackendError.profileRequestFailed
        }
        return encoded
    }
}

struct ParsedAppleAppToken: Equatable {
    let token: String
    let expiresAt: Date?
}

enum AppleTokenResponseParser {
    static func decryptedToken(_ data: Data, audience: String) throws -> ParsedAppleAppToken {
        guard let plist = try parseApplePlist(data),
              let tokens = plist["t"] as? [String: Any],
              let tokenInfo = tokens[audience] as? [String: Any],
              let token = tokenInfo["token"] as? String, !token.isEmpty, token.count <= 32_768 else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        let expiresAt = integer64(tokenInfo["expiry"])
            .map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        return ParsedAppleAppToken(token: token, expiresAt: expiresAt)
    }
}

enum AppleVerificationResponseParser {
    static func validate(_ root: [String: Any]) throws {
        let responseCode = integer(root["ec"] ?? (root["Response"] as? [String: Any])?["ec"]) ?? 0
        guard responseCode == 0 else {
            throw responseCode == -21669
                ? ExperimentalBackendError.verificationRejected
                : ExperimentalBackendError.verificationExpired
        }
    }
}

public actor LiveApplePersonalTeamBackend: ExperimentalPersonalTeamBackend {
    public nonisolated let method = AppleAuthorizationMethodCategory.privateGrandSlamSRP
    public nonisolated let clientIdentityVersion: String
    /// This is intentionally false until a human proves the full flow.
    public nonisolated let isPhysicallyQualified = false

    private let adapter: PrivateAppleProtocolAdapter
    private let transport: any AppleHTTPTransport
    private let machineIdentity: any AppleMachineIdentityProviding
    private let endpointResolver: any GrandSlamEndpointResolving
    private let sessionStore: any AppleAuthorizationSessionStoring
    private let diagnostics: ApplePersonalTeamDiagnosticsStore
    private let identityKeychain: any IOSSimManagedIdentityKeychain
    private let srpRandomBytesForTesting: Data?
    /// Backoff between the revoke call and re-reading Apple's certificate
    /// capacity. Apple's real propagation delay has never been physically
    /// measured, so this is a bounded estimate; the physical Build-3 run records
    /// the true timing. Overridden to zero in tests so no suite ever sleeps.
    private let certificateCapacityRetryDelay: TimeInterval
    private var session: LiveSessionEnvelope?
    private var pendingTwoFactor: PendingTwoFactor?
    private var appIdentifierIDs: [String: String] = [:]
    private var identityGeneration: UInt64 = 0
    private var authorizedTeamIdentifier: String?

    public init(
        adapter: PrivateAppleProtocolAdapter = .researched2026,
        transport: any AppleHTTPTransport = BoundedAppleHTTPTransport(),
        machineIdentity: any AppleMachineIdentityProviding = LocalMacAppleMachineIdentityProvider(),
        sessionStore: any AppleAuthorizationSessionStoring = KeychainAppleAuthorizationSessionStore(),
        diagnostics: ApplePersonalTeamDiagnosticsStore = ApplePersonalTeamDiagnosticsStore()
    ) {
        self.adapter = adapter
        self.transport = transport
        self.machineIdentity = machineIdentity
        endpointResolver = URLBagGrandSlamEndpointResolver(transport: transport)
        self.sessionStore = sessionStore
        self.diagnostics = diagnostics
        identityKeychain = IOSSimIdentityMetadataStore()
        srpRandomBytesForTesting = nil
        certificateCapacityRetryDelay = LiveApplePersonalTeamBackend.defaultCapacityRetryDelay
        clientIdentityVersion = adapter.version
    }

    init(
        adapter: PrivateAppleProtocolAdapter = .researched2026,
        transport: any AppleHTTPTransport,
        machineIdentity: any AppleMachineIdentityProviding,
        sessionStore: any AppleAuthorizationSessionStoring,
        diagnostics: ApplePersonalTeamDiagnosticsStore,
        srpRandomBytesForTesting: Data,
        identityKeychain: any IOSSimManagedIdentityKeychain = IOSSimIdentityMetadataStore(),
        endpointResolver: (any GrandSlamEndpointResolving)? = nil,
        certificateCapacityRetryDelay: TimeInterval = 0
    ) {
        self.adapter = adapter
        self.transport = transport
        self.machineIdentity = machineIdentity
        self.endpointResolver = endpointResolver ?? FixedGrandSlamEndpointResolver(adapter: adapter)
        self.sessionStore = sessionStore
        self.diagnostics = diagnostics
        self.identityKeychain = identityKeychain
        self.srpRandomBytesForTesting = srpRandomBytesForTesting
        self.certificateCapacityRetryDelay = certificateCapacityRetryDelay
        clientIdentityVersion = adapter.version
    }

    /// Installation V2: Developer Services and the v2 session store only. The Build 1-11 Keychain signing
    /// identity path (`prepareIdentity`, `/usr/bin/codesign` probes) refuses every call on this instance.
    /// `sessionStore` is injected only by isolated qualification roots; production uses the v2 store.
    public static func installationV2(
        diagnostics: ApplePersonalTeamDiagnosticsStore = ApplePersonalTeamDiagnosticsStore(),
        sessionStore: any AppleAuthorizationSessionStoring = KeychainAppleAuthorizationSessionStore()
    ) -> LiveApplePersonalTeamBackend {
        LiveApplePersonalTeamBackend(retiredIdentityKeychain: RetiredLegacyIdentityKeychain(), diagnostics: diagnostics,
                                     sessionStore: sessionStore)
    }

    private init(retiredIdentityKeychain: RetiredLegacyIdentityKeychain, diagnostics: ApplePersonalTeamDiagnosticsStore,
                 sessionStore: any AppleAuthorizationSessionStoring) {
        let adapter = PrivateAppleProtocolAdapter.researched2026
        let transport = BoundedAppleHTTPTransport()
        self.adapter = adapter
        self.transport = transport
        machineIdentity = LocalMacAppleMachineIdentityProvider()
        endpointResolver = URLBagGrandSlamEndpointResolver(transport: transport)
        self.sessionStore = sessionStore
        self.diagnostics = diagnostics
        identityKeychain = retiredIdentityKeychain
        srpRandomBytesForTesting = nil
        certificateCapacityRetryDelay = LiveApplePersonalTeamBackend.defaultCapacityRetryDelay
        clientIdentityVersion = adapter.version
    }

    public func resumeSession() async throws -> [ExperimentalAppleTeam]? {
        guard let stored = try sessionStore.load() else { return nil }
        defer { stored.clear() }
        let data = stored.withOpaquePayload { Data($0) }
        guard let envelope = try? PropertyListDecoder().decode(LiveSessionEnvelope.self, from: data),
              envelope.tokenExpiresAt.map({ $0 > Date() }) ?? true else {
            try? sessionStore.remove()
            throw ExperimentalBackendError.sessionExpired
        }
        session = envelope
        do {
            let teams = try await listTeams(using: envelope)
            let metadata = AppleAuthorizationSessionMetadata(
                accountFingerprint: stored.metadata.accountFingerprint,
                clientIdentityVersion: adapter.version,
                createdAt: stored.metadata.createdAt,
                lastValidatedAt: Date(),
                expiresAt: envelope.tokenExpiresAt
            )
            try saveSession(envelope, metadata: metadata)
            diagnostics.update(adapterVersion: adapter.version) { $0.sessionValid = true }
            return teams
        } catch let failure as AppleServiceFailure where !failure.reauthorizationRequired {
            diagnostics.update(adapterVersion: adapter.version) { $0.sessionValid = true }
            throw failure.error
        } catch let error as ExperimentalBackendError
            where [.networkFailure, .rateLimited, .serviceUnavailable, .developerServicesFailed].contains(error) {
            diagnostics.update(adapterVersion: adapter.version) { $0.sessionValid = true }
            throw error
        } catch let error as ExperimentalBackendError
            where [.authenticationProtocolMismatch, .responseChanged].contains(error) {
            // Preserve the protected session on response-shape drift. A newer
            // adapter can inspect or reuse it; destructive reauthorization is
            // neither safe nor useful for protocol incompatibility.
            diagnostics.update(adapterVersion: adapter.version) { $0.sessionValid = true }
            throw ExperimentalBackendError.authenticationProtocolMismatch
        } catch {
            session = nil
            authorizedTeamIdentifier = nil
            try? sessionStore.remove()
            diagnostics.update(adapterVersion: adapter.version) { $0.sessionValid = false }
            throw ExperimentalBackendError.sessionExpired
        }
    }

    public func beginAuthorization(
        account: String,
        password: SensitiveInput
    ) async throws -> ExperimentalAuthorizationResult {
        // GrandSlam looks up Apple Accounts case-insensitively during `init`,
        // but the selected account name participates in the SRP M1 proof.
        // Use Apple's canonical lowercase form for the entire exchange so a
        // mixed-case email cannot receive a challenge and then fail `complete`
        // with Status.ec = -22406 despite a correct password.
        let canonicalAccount = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard canonicalAccount.contains("@"), canonicalAccount.utf8.count <= 1_024, !password.isEmpty else {
            throw ExperimentalBackendError.authenticationRejected
        }
        record(.authStarted, stage: "startingAuthentication")
        var passwordData = password.withUnsafeBytes { Data($0) }
        defer { passwordData.resetBytes(in: 0..<passwordData.count) }
        do {
            let outcome = try await authenticate(account: canonicalAccount, password: passwordData)
            switch outcome {
            case .verification(let pending):
                pendingTwoFactor?.password.clear()
                pendingTwoFactor = pending
                record(.twoFactorRequired, stage: "verificationRequired")
                return .verificationRequired(.init(method: pending.method, safeDestinationHint: nil))
            case .session(let envelope):
                return try await establishSession(envelope, account: canonicalAccount)
            }
        } catch let failure as AppleServiceFailure {
            recordFailure(failure, stage: "authentication")
            throw failure.error
        } catch let failure as ExperimentalBackendError {
            recordFailure(.init(
                error: failure,
                status: nil,
                appleCode: nil,
                retryAfter: nil,
                retryable: failure == .networkFailure,
                reauthorizationRequired: true
            ), stage: "authentication")
            throw failure
        }
    }

    public func submitVerification(code: SensitiveInput) async throws -> ExperimentalAuthorizationResult {
        guard let pending = pendingTwoFactor else { throw ExperimentalBackendError.verificationExpired }
        var codeData = code.withUnsafeBytes { Data($0) }
        defer { codeData.resetBytes(in: 0..<codeData.count) }
        guard (4...8).contains(codeData.count), codeData.allSatisfy({ (48...57).contains($0) }) else {
            throw ExperimentalBackendError.verificationRejected
        }
        do {
            try await validateVerification(codeData, pending: pending)
            record(.twoFactorAccepted, stage: "verificationSubmitted")
            var passwordData = pending.password.withUnsafeBytes { Data($0) }
            defer {
                passwordData.resetBytes(in: 0..<passwordData.count)
                pending.password.clear()
                pendingTwoFactor = nil
            }
            let outcome = try await authenticate(account: pending.account, password: passwordData)
            guard case .session(let envelope) = outcome else {
                throw ExperimentalBackendError.verificationExpired
            }
            return try await establishSession(envelope, account: pending.account)
        } catch let failure as AppleServiceFailure {
            recordFailure(failure, stage: "verification")
            throw failure.error
        }
    }

    public func invalidateSession() async {
        pendingTwoFactor?.password.clear()
        pendingTwoFactor = nil
        session = nil
        authorizedTeamIdentifier = nil
        appIdentifierIDs = [:]
        try? sessionStore.remove()
        diagnostics.update(adapterVersion: adapter.version) { $0.sessionValid = false }
    }

    /// Performs only the credentials-free GrandSlam SRP initialization phase.
    /// The Apple Account name is sent directly to Apple and is neither logged
    /// nor persisted. No password or 2FA code is accepted by this probe.
    public func diagnoseSRPInitialization(account: String) async -> AppleSRPInitializationDiagnosticResult {
        let canonicalAccount = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard canonicalAccount.contains("@"), canonicalAccount.utf8.count <= 1_024 else {
            return .protocolFailure
        }
        do {
            let srp = try AppleSRPClient(randomBytes: srpRandomBytesForTesting)
            let machineHeaders = try await machineIdentity.headers(for: URLRequest(url: adapter.grandSlamService))
            let initial = try await grandSlam([
                "A2k": srp.clientPublicKey,
                "ps": ["s2k", "s2k_fo"],
                "cpd": clientProvidedData(machineHeaders),
                "u": canonicalAccount,
                "o": "init"
            ], machineHeaders: machineHeaders, stage: "srpInitDiagnostic")
            _ = try AppleSRPClient.parseChallenge(initial.response)
            return .success
        } catch let failure as AppleServiceFailure {
            if failure.status == 503 { return .http503 }
            if let code = failure.appleCode { return .appleError(code) }
            if failure.error == .networkFailure { return .networkFailure }
            return .protocolFailure
        } catch let error as ExperimentalBackendError {
            switch error {
            case .networkFailure: return .networkFailure
            case .authenticationProtocolMismatch, .responseChanged, .responseTooLarge,
                 .localAnisetteUnavailable, .srpAuthFailed:
                return .protocolFailure
            default:
                return .protocolFailure
            }
        } catch {
            return .responseParseFailure
        }
    }

    private enum AuthenticationOutcome {
        case verification(PendingTwoFactor)
        case session(LiveSessionEnvelope)
    }

    private func authenticate(account: String, password: Data) async throws -> AuthenticationOutcome {
        let srp = try AppleSRPClient(randomBytes: srpRandomBytesForTesting)
        let machineHeaders = try await machineIdentity.headers(for: URLRequest(url: adapter.grandSlamService))
        let cpd = clientProvidedData(machineHeaders)
        let initial = try await grandSlam([
            "A2k": srp.clientPublicKey,
            "ps": ["s2k", "s2k_fo"],
            "cpd": cpd,
            "u": account,
            "o": "init"
        ], machineHeaders: machineHeaders, stage: "srpInit")
        let challenge = try AppleSRPClient.parseChallenge(initial.response)
        record(.authChallengeReceived, stage: "challengeReceived")
        let proof = try srp.proof(account: account, password: password, challenge: challenge)
        recordSRPDerivation(proof: proof, challenge: challenge)
        let completed = try await grandSlam([
            "M1": proof.clientProof,
            "c": challenge.cookie,
            "cpd": cpd,
            "u": account,
            "o": "complete"
        ], machineHeaders: machineHeaders, stage: "srpComplete",
           srpProtocol: challenge.scheme, closeConnection: true)
        recordPostComplete(
            stage: "SRP_COMPLETE_ACCEPTED",
            response: completed.response,
            status: completed.status,
            flags: ["applicationStatusAccepted": true]
        )
        guard let serverProof = completed.response["M2"] as? Data else {
            recordPostComplete(
                stage: "M2_REJECTED",
                response: completed.response,
                status: completed.status,
                lengths: ["localM2": proof.expectedServerProof.count],
                flags: ["serverM2Present": false, "m2Match": false],
                safeErrorCode: ExperimentalBackendError.authenticationProtocolMismatch.safeCode
            )
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        recordPostComplete(
            stage: "M2_RECEIVED",
            response: completed.response,
            status: completed.status,
            lengths: ["serverM2": serverProof.count, "localM2": proof.expectedServerProof.count],
            flags: ["serverM2Present": true]
        )
        let m2Matches = AppleSRPClient.serverProofMatches(serverProof, expected: proof.expectedServerProof)
        recordPostComplete(
            stage: m2Matches ? "M2_VERIFIED" : "M2_REJECTED",
            response: completed.response,
            status: completed.status,
            lengths: ["serverM2": serverProof.count, "localM2": proof.expectedServerProof.count],
            flags: ["serverM2Present": true, "m2Match": m2Matches],
            safeErrorCode: m2Matches ? nil : ExperimentalBackendError.srpAuthFailed.safeCode
        )
        guard m2Matches else { throw ExperimentalBackendError.srpAuthFailed }
        guard let encrypted = completed.response["spd"] as? Data, encrypted.count <= 1_048_576 else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        recordPostComplete(
            stage: "NEGOTIATION_PROOF_RECEIVED",
            response: completed.response,
            status: completed.status,
            lengths: [
                "spdCiphertext": encrypted.count,
                "np": (completed.response["np"] as? Data)?.count ?? 0,
                "sc": (completed.response["sc"] as? Data)?.count ?? 0
            ],
            flags: [
                "spdPresent": true,
                "npPresent": completed.response["np"] is Data,
                "scPresent": completed.response["sc"] is Data
            ]
        )
        do {
            try validateNegotiationProof(
                response: completed.response,
                scheme: challenge.scheme,
                sessionKey: proof.sessionKey
            )
            recordPostComplete(
                stage: "NEGOTIATION_PROOF_VERIFIED",
                response: completed.response,
                status: completed.status,
                flags: ["npProcessingSucceeded": true]
            )
        } catch let error as ExperimentalBackendError {
            recordPostComplete(
                stage: "NEGOTIATION_PROOF_REJECTED",
                response: completed.response,
                status: completed.status,
                flags: ["npProcessingSucceeded": false],
                safeErrorCode: error.safeCode
            )
            throw error
        }
        recordPostComplete(
            stage: "SPD_DECRYPTION_STARTED",
            response: completed.response,
            status: completed.status,
            lengths: ["spdCiphertext": encrypted.count],
            flags: ["spdDecryptionAttempted": true]
        )
        var plaintext: Data
        do {
            plaintext = try decryptCBC(encrypted, sessionKey: proof.sessionKey)
        } catch let error as ExperimentalBackendError {
            recordPostComplete(
                stage: "SPD_DECRYPTION_FAILED",
                response: completed.response,
                status: completed.status,
                lengths: ["spdCiphertext": encrypted.count],
                flags: ["spdDecryptionAttempted": true, "spdDecryptionSucceeded": false],
                safeErrorCode: error.safeCode
            )
            throw error
        }
        recordPostComplete(
            stage: "SPD_DECRYPTION_SUCCEEDED",
            response: completed.response,
            status: completed.status,
            lengths: ["spdCiphertext": encrypted.count, "spdPlaintext": plaintext.count],
            flags: ["spdDecryptionAttempted": true, "spdDecryptionSucceeded": true]
        )
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let secret: [String: Any]
        do {
            guard let parsed = try parseApplePlist(plaintext) else {
                throw ExperimentalBackendError.authenticationProtocolMismatch
            }
            secret = parsed
        } catch {
            recordPostComplete(
                stage: "SPD_PARSE_FAILED",
                response: completed.response,
                status: completed.status,
                flags: ["spdPlistDecoded": false],
                safeErrorCode: ExperimentalBackendError.authenticationProtocolMismatch.safeCode
            )
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        recordPostComplete(
            stage: "SPD_PARSED",
            response: secret,
            status: completed.status,
            flags: ["spdPlistDecoded": true]
        )
        guard let dsid = string(secret["adsid"]), !dsid.isEmpty, dsid.count <= 128,
              let idmsToken = secret["GsIdmsToken"] as? String, !idmsToken.isEmpty,
              idmsToken.count <= 16_384 else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        record(.authPasswordAccepted, stage: "credentialsVerified")

        let action = completed.status["au"] as? String
        if let action, ["trustedDeviceSecondaryAuth", "secondaryAuth"].contains(action) {
            // Both current GrandSlam action values enter trusted-device
            // verification. SMS requires authoritative phone inventory and a
            // selected phone identifier; it is not guessed from this value.
            let method: AppleVerificationMethod = .trustedDevice
            let pendingPassword = SensitiveInput(data: password)
            let pending = PendingTwoFactor(
                account: account,
                password: pendingPassword,
                dsid: dsid,
                idmsToken: idmsToken,
                method: method
            )
            if method == .trustedDevice {
                try await requestTrustedDeviceCode(pending)
            }
            recordPostComplete(
                stage: "TWO_FACTOR_REQUIRED",
                response: completed.response,
                status: completed.status,
                flags: ["twoFactorRequired": true]
            )
            return .verification(pending)
        }

        guard let sk = secret["sk"] as? Data, sk.count == 32,
              let continuation = secret["c"] as? Data, !continuation.isEmpty else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        let envelope = try await fetchXcodeToken(
            dsid: dsid,
            idmsToken: idmsToken,
            continuation: continuation,
            appTokenKey: sk,
            cpd: cpd,
            machineHeaders: machineHeaders
        )
        recordPostComplete(
            stage: "AUTH_SESSION_CREATED",
            response: completed.response,
            status: completed.status,
            flags: ["authSessionCreated": true]
        )
        return .session(envelope)
    }

    private func establishSession(
        _ envelope: LiveSessionEnvelope,
        account: String
    ) async throws -> ExperimentalAuthorizationResult {
        session = envelope
        let created = Date()
        let metadata = AppleAuthorizationSessionMetadata(
            accountFingerprint: Data(SHA256.hash(data: Data(account.lowercased().utf8))).hexLowercase,
            clientIdentityVersion: adapter.version,
            createdAt: created,
            lastValidatedAt: created,
            expiresAt: envelope.tokenExpiresAt
        )
        try saveSession(envelope, metadata: metadata)
        record(.sessionReady, stage: "sessionEstablished")
        diagnostics.update(adapterVersion: adapter.version) { $0.sessionValid = true }
        let teams = try await listTeams(using: envelope)
        return .authorized(teams)
    }

    private func saveSession(
        _ envelope: LiveSessionEnvelope,
        metadata: AppleAuthorizationSessionMetadata
    ) throws {
        let payload = try PropertyListEncoder().encode(envelope)
        let wrapped = AppleAuthorizationSession(metadata: metadata, opaquePayload: payload)
        defer { wrapped.clear() }
        try sessionStore.save(wrapped)
    }

    private struct GrandSlamResponse {
        let response: [String: Any]
        let status: [String: Any]
    }

    private func grandSlam(
        _ parameters: [String: Any],
        machineHeaders: [String: String],
        stage: String,
        srpProtocol: String? = nil,
        closeConnection: Bool = false
    ) async throws -> GrandSlamResponse {
        let body = try serializePlist(["Header": ["Version": "1.0.1"], "Request": parameters])
        let normalizedHeaders = try GrandSlamRequestIdentity.normalizedMachineHeaders(machineHeaders)
        let endpoint = try await endpointResolver.endpoint(.gsService, machineHeaders: normalizedHeaders)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue(normalizedHeaders[caseInsensitive: "X-MMe-Client-Info"],
                         forHTTPHeaderField: "X-MMe-Client-Info")
        request.setValue("akd/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Xcode", forHTTPHeaderField: "X-Apple-Client-App-Name")
        for name in ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-RINFO", "X-Mme-Device-Id"] {
            if let value = normalizedHeaders[caseInsensitive: name] {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if closeConnection { request.setValue("close", forHTTPHeaderField: "Connection") }
        let http = try await send(request, maximumBytes: 2_097_152, stage: stage)
        guard let root = try parseApplePlist(http.body),
              let response = root["Response"] as? [String: Any],
              let status = response["Status"] as? [String: Any] else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        let code = integer(status["ec"]) ?? 0
        if stage.hasPrefix("srp") {
            recordSRPStructure(
                stage: stage,
                parameters: parameters,
                response: response,
                status: status,
                httpStatus: http.statusCode,
                protocolName: srpProtocol ?? response["sp"] as? String
            )
        }
        if code != 0 {
            let error: ExperimentalBackendError = code == -22406 ? .badPassword : .authenticationRejected
            throw AppleServiceFailure(
                error: error,
                status: http.statusCode,
                appleCode: code,
                retryAfter: retryAfter(http.headers),
                retryable: false,
                reauthorizationRequired: true
            )
        }
        return GrandSlamResponse(response: response, status: status)
    }

    private func fetchXcodeToken(
        dsid: String,
        idmsToken: String,
        continuation: Data,
        appTokenKey: Data,
        cpd: [String: Any],
        machineHeaders: [String: String]
    ) async throws -> LiveSessionEnvelope {
        let checksumMessage = Data("apptokens\(dsid)\(adapter.xcodeTokenAudience)".utf8)
        let checksum = appTokenKey.hmacSHA256(message: checksumMessage)
        let response: GrandSlamResponse
        do {
            response = try await grandSlam([
                "u": dsid,
                "app": [adapter.xcodeTokenAudience],
                "c": continuation,
                "t": idmsToken,
                "checksum": checksum,
                "cpd": cpd,
                "o": "apptokens"
            ], machineHeaders: machineHeaders, stage: "xcodeScopedToken", closeConnection: true)
        } catch let failure as AppleServiceFailure {
            throw AppleServiceFailure(
                error: .xcodeScopedTokenFailed,
                status: failure.status,
                appleCode: failure.appleCode,
                retryAfter: failure.retryAfter,
                retryable: failure.status == 503 || failure.status == 429,
                reauthorizationRequired: false
            )
        } catch {
            throw AppleServiceFailure(
                error: .xcodeScopedTokenFailed,
                status: nil,
                appleCode: nil,
                retryAfter: nil,
                retryable: true,
                reauthorizationRequired: false
            )
        }
        guard let encryptedToken = response.response["et"] as? Data else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        var decrypted = try decryptAppToken(encryptedToken, key: appTokenKey)
        defer { decrypted.resetBytes(in: 0..<decrypted.count) }
        let parsed = try AppleTokenResponseParser.decryptedToken(
            decrypted,
            audience: adapter.xcodeTokenAudience
        )
        return LiveSessionEnvelope(dsid: dsid, xcodeToken: parsed.token, tokenExpiresAt: parsed.expiresAt)
    }

    private func requestTrustedDeviceCode(_ pending: PendingTwoFactor) async throws {
        let identity = Data("\(pending.dsid):\(pending.idmsToken)".utf8).base64EncodedString()
        let machineHeaders = try await machineIdentity.headers(for: URLRequest(url: adapter.grandSlamService))
        let endpoint = try await endpointResolver.endpoint(.trustedDeviceSecondaryAuth, machineHeaders: machineHeaders)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(identity, forHTTPHeaderField: "X-Apple-Identity-Token")
        try await applyMachineAndServiceHeaders(to: &request, dsid: nil, token: nil)
        _ = try await send(request, maximumBytes: 1_048_576, stage: "requestTrustedDeviceCode", allowEmpty: true)
    }

    private func validateVerification(_ code: Data, pending: PendingTwoFactor) async throws {
        let identity = Data("\(pending.dsid):\(pending.idmsToken)".utf8).base64EncodedString()
        guard let codeString = String(data: code, encoding: .utf8) else {
            throw ExperimentalBackendError.verificationRejected
        }
        let machineHeaders = try await machineIdentity.headers(for: URLRequest(url: adapter.grandSlamService))
        let endpoint = try await endpointResolver.endpoint(.validateCode, machineHeaders: machineHeaders)
        var request = try GrandSlamVerificationRequestBuilder.trustedDeviceValidation(
            endpoint: endpoint,
            identityToken: identity,
            verificationCode: codeString
        )
        try await applyMachineAndServiceHeaders(to: &request, dsid: nil, token: nil)
        let http = try await send(request, maximumBytes: 1_048_576, stage: "validateVerification")
        guard let root = try parseApplePlist(http.body) else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        do {
            try AppleVerificationResponseParser.validate(root)
        } catch let error as ExperimentalBackendError {
            let code = integer(root["ec"] ?? (root["Response"] as? [String: Any])?["ec"])
            throw AppleServiceFailure(
                error: error,
                status: http.statusCode,
                appleCode: code,
                retryAfter: retryAfter(http.headers),
                retryable: false,
                reauthorizationRequired: false
            )
        }
    }

    private func listTeams(using session: LiveSessionEnvelope) async throws -> [ExperimentalAppleTeam] {
        let response = try await developerRequest(operation: "listTeams", parameters: [:], session: session)
        let teams = try AppleDeveloperResponseParser.teams(response)
        let validated = try ExperimentalConsumerProvisioningCoordinator.validateTeams(teams)
        let personal = validated.filter(\.isPersonalTeam)
        guard !personal.isEmpty else { throw ExperimentalBackendError.noTeam }
        if personal.count > 1 { throw ExperimentalBackendError.personalTeamAmbiguous }
        record(.personalTeamFound, stage: "teamDiscovery")
        diagnostics.update(adapterVersion: adapter.version) {
            $0.personalTeamFound = true
            $0.teamIdentifier = personal[0].id
        }
        authorizedTeamIdentifier = personal[0].id
        return validated
    }

    private func developerRequest(
        operation: String,
        parameters: [String: Any],
        session explicitSession: LiveSessionEnvelope? = nil,
        deviceRegistrationContext: DeviceRegistrationDiagnosticContext? = nil
    ) async throws -> [String: Any] {
        guard let active = explicitSession ?? session else { throw ExperimentalBackendError.sessionExpired }
        var url = try adapter.developerURL(operation: operation)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "clientId", value: adapter.xcodeClientIdentifier)]
        guard let resolved = components?.url else { throw ExperimentalBackendError.responseChanged }
        url = resolved
        var payload: [String: Any] = [
            "clientId": adapter.xcodeClientIdentifier,
            "protocolVersion": "QH65B2",
            "requestId": UUID().uuidString.uppercased(),
            "userLocale": [Locale.current.identifier]
        ]
        parameters.forEach { payload[$0.key] = $0.value }
        if let context = deviceRegistrationContext {
            recordDeviceRegistration(
                .deviceRegistrationRequestPrepared,
                generation: context.generation,
                request: context.request,
                team: context.team,
                counts: [
                    "deviceIdentifierLength": context.deviceNumber.utf8.count,
                    "deviceNameLength": context.deviceName.utf8.count
                ],
                flags: [
                    "authorizedTeamMatchesAddDeviceTeam": context.teamMatches,
                    "deviceNamePresent": !context.deviceName.isEmpty,
                    "deviceNameWhitespaceOnly": !context.deviceName.isEmpty
                        && context.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ],
                requestFields: payload
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try serializePlist(payload)
        try await applyMachineAndServiceHeaders(to: &request, dsid: active.dsid, token: active.xcodeToken)
        if let context = deviceRegistrationContext {
            recordDeviceRegistration(
                .deviceRegistrationRequestSent,
                generation: context.generation,
                request: context.request,
                team: context.team
            )
        }
        let http = try await send(request, maximumBytes: 8_388_608, stage: "developerServices/\(operation)")
        guard let response = try parseApplePlist(http.body) else { throw ExperimentalBackendError.responseChanged }
        let resultCode = integer(response["resultCode"] ?? response["statusCode"] ?? response["ec"]) ?? 0
        let safeMessage = safeAppleDeveloperMessage(response)
        let deviceCategory = operation == "ios/addDevice" && resultCode != 0
            ? classifyDeviceRegistrationRejection(code: resultCode, response: response) : nil
        if let context = deviceRegistrationContext {
            recordDeviceRegistration(
                .deviceRegistrationResponseReceived,
                generation: context.generation,
                request: context.request,
                team: context.team,
                category: deviceCategory,
                safeMessage: safeMessage,
                httpStatus: http.statusCode,
                appleCode: resultCode,
                responseFields: response
            )
        }
        guard resultCode == 0 else {
            let safeText = appleDeveloperMessageCandidates(response).joined(separator: " ").lowercased()
            let error: ExperimentalBackendError
            if operation.contains("submitDevelopmentCSR")
                // 7460 is Apple's documented "Maximum number of certificates
                // reached". The substring match stays as a fallback for message
                // drift, but the numeric code is authoritative when present.
                && (resultCode == 7460 || safeText.contains("maximum") || safeText.contains("limit")) {
                error = .certificateLimit
            } else if operation.contains("addDevice")
                && (safeText.contains("maximum") || safeText.contains("limit")) {
                error = .deviceLimit
            } else if operation.contains("addDevice") && deviceCategory == .invalidDeviceIdentifier {
                error = .invalidDeviceIdentifier
            } else if operation.contains("addDevice") && deviceCategory == .invalidTeam {
                error = .invalidTeam
            } else if operation.contains("addDevice") && deviceCategory == .missingRequiredField
                && safeText.contains("name") {
                error = .deviceNameRequired
            } else if operation.contains("addAppId") && resultCode == 9120 {
                error = .appIDLimit
            } else if operation.contains("addAppId") && resultCode == 9401 {
                error = .appIDCollision
            } else if safeText.contains("session") || safeText.contains("authenticate") || safeText.contains("token") {
                error = .sessionExpired
            } else {
                error = .developerServicesFailed
            }
            let failure = AppleServiceFailure(
                error: error,
                status: http.statusCode,
                appleCode: resultCode,
                retryAfter: retryAfter(http.headers),
                retryable: false,
                reauthorizationRequired: error == .sessionExpired,
                safeMessage: safeMessage,
                deviceRegistrationCategory: deviceCategory
            )
            recordFailure(failure, stage: "developerServices/\(operation)")
            throw failure
        }
        return response
    }

    private func applyMachineAndServiceHeaders(
        to request: inout URLRequest,
        dsid: String?,
        token: String?
    ) async throws {
        let headers = try await machineIdentity.headers(for: request)
        for (key, value) in headers where key.localizedCaseInsensitiveCompare("Cookie") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        request.setValue(adapter.authUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(adapter.xcodeTokenAudience, forHTTPHeaderField: "X-Apple-App-Info")
        request.setValue(adapter.xcodeVersionHeader, forHTTPHeaderField: "X-Xcode-Version")
        if let dsid { request.setValue(dsid, forHTTPHeaderField: "X-Apple-I-Identity-Id") }
        if let token { request.setValue(token, forHTTPHeaderField: "X-Apple-GS-Token") }
    }

    private func clientProvidedData(_ headers: [String: String]) -> [String: Any] {
        var cpd: [String: Any] = [
            "bootstrap": true,
            "icscrec": true,
            "loc": Locale.current.identifier,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud"
        ]
        let copied = [
            "X-Apple-I-Client-Time", "X-Apple-Locale", "X-Apple-I-TimeZone",
            "X-Apple-I-MD", "X-Apple-I-MD-LU", "X-Apple-I-MD-M", "X-Apple-I-MD-RINFO",
            "X-Mme-Device-Id", "X-Apple-I-SRL-NO"
        ]
        for key in copied {
            if let value = headers[caseInsensitive: key] { cpd[key] = value }
        }
        return cpd
    }

    private func send(
        _ request: URLRequest,
        maximumBytes: Int,
        stage: String,
        allowEmpty: Bool = false
    ) async throws -> AppleHTTPResponse {
        do {
            let response = try await transport.send(request, maximumBytes: maximumBytes)
            let contentType = response.headers.first { key, _ in
                String(describing: key).localizedCaseInsensitiveCompare("Content-Type") == .orderedSame
            }.map { String(describing: $0.value) }
            guard response.url.scheme == "https",
                  ["gsa.apple.com", "developerservices2.apple.com"].contains(response.url.host),
                  (200..<300).contains(response.statusCode),
                  response.body.count <= maximumBytes,
                  allowEmpty || !response.body.isEmpty else {
                let error = AppleHTTPFailureClassifier.error(status: response.statusCode, stage: stage)
                let responseMetadata = safeHTTPFailureMetadata(response: response, request: request)
                throw AppleServiceFailure(
                    error: error,
                    status: response.statusCode,
                    appleCode: nil,
                    retryAfter: retryAfter(response.headers),
                    retryable: response.statusCode == 429 || response.statusCode == 503,
                    reauthorizationRequired: false,
                    responseMetadata: responseMetadata
                )
            }
            if !allowEmpty {
                let normalized = contentType?.lowercased() ?? ""
                guard normalized.contains("plist") || normalized.contains("octet-stream") else {
                    throw ExperimentalBackendError.responseChanged
                }
            }
            return response
        } catch let failure as AppleServiceFailure {
            recordFailure(failure, stage: stage)
            throw failure
        } catch AppleLiveTransportError.responseTooLarge {
            let failure = AppleServiceFailure(error: .responseTooLarge, status: nil, appleCode: nil,
                                              retryAfter: nil, retryable: false, reauthorizationRequired: false)
            recordFailure(failure, stage: stage)
            throw failure
        } catch AppleLiveTransportError.redirectRejected, AppleLiveTransportError.invalidDestination {
            let failure = AppleServiceFailure(error: .redirectRejected, status: nil, appleCode: nil,
                                              retryAfter: nil, retryable: false, reauthorizationRequired: false)
            recordFailure(failure, stage: stage)
            throw failure
        } catch {
            let failure = AppleServiceFailure(error: .networkFailure, status: nil, appleCode: nil,
                                              retryAfter: nil, retryable: true, reauthorizationRequired: false)
            recordFailure(failure, stage: stage)
            throw failure
        }
    }

    private func record(_ checkpoint: ApplePersonalTeamCheckpoint, stage: String) {
        diagnostics.update(adapterVersion: adapter.version) {
            $0.events.append(.init(
                timestamp: Date(), checkpoint: checkpoint.rawValue, stage: stage,
                safeErrorCode: nil, httpStatus: nil, appleErrorCode: nil, retryAfterSeconds: nil,
                retryable: false, reauthorizationRequired: false
            ))
        }
    }

    private func recordIdentity(
        _ checkpoint: ApplePersonalTeamCheckpoint,
        generation: UInt64,
        tag: Data? = nil,
        fingerprint: String? = nil,
        osStatus: OSStatus? = nil,
        counts: [String: Int]? = nil,
        flags: [String: Bool]? = nil
    ) {
        let tagIdentifier = tag.flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.utf8.count <= 256 ? $0 : nil }
        diagnostics.update(adapterVersion: adapter.version) {
            $0.events.append(.init(
                timestamp: Date(),
                checkpoint: checkpoint.rawValue,
                stage: "managedSigningIdentity",
                safeErrorCode: nil,
                httpStatus: nil,
                appleErrorCode: nil,
                retryAfterSeconds: nil,
                retryable: false,
                reauthorizationRequired: false,
                nonSecretIntegers: counts,
                continuity: flags,
                generationID: generation,
                osStatus: osStatus.map(Int.init),
                keyApplicationTagIdentifier: tagIdentifier,
                certificateFingerprintPrefix: fingerprint.map { String($0.prefix(12)) }
            ))
        }
    }

    private func recordDeviceRegistration(
        _ checkpoint: ApplePersonalTeamCheckpoint,
        generation: UInt64,
        request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam,
        category: AppleDeviceRegistrationCategory? = nil,
        safeMessage: String? = nil,
        httpStatus: Int? = nil,
        appleCode: Int? = nil,
        counts: [String: Int] = [:],
        flags: [String: Bool] = [:],
        requestFields: [String: Any]? = nil,
        responseFields: [String: Any]? = nil
    ) {
        var safeCounts = counts
        safeCounts["deviceIdentifierLength"] = request.selectedDeviceRegistrationIdentifier.utf8.count
        safeCounts["deviceNameLength"] = request.selectedDeviceName.utf8.count
        var continuity = flags
        continuity["authorizedTeamMatchesCurrentTeam"] = authorizedTeamIdentifier == team.id
        continuity["deviceNamePresent"] = !request.selectedDeviceName.isEmpty
        continuity["deviceNameWhitespaceOnly"] = !request.selectedDeviceName.isEmpty
            && request.selectedDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        diagnostics.update(adapterVersion: adapter.version) {
            $0.events.append(.init(
                timestamp: Date(),
                checkpoint: checkpoint.rawValue,
                stage: checkpoint == .deviceRegistrationResponseReceived
                    ? "ADD_DEVICE_RESPONSE" : "deviceRegistration",
                safeErrorCode: category?.rawValue,
                httpStatus: httpStatus,
                appleErrorCode: appleCode,
                retryAfterSeconds: nil,
                retryable: false,
                reauthorizationRequired: category == .sessionRejected,
                structuralLengths: safeCounts,
                requestFieldNames: requestFields.map { safeFieldNames($0.keys) },
                responseFieldNames: responseFields.map { safeFieldNames($0.keys) },
                fieldTypes: requestFields.map(safeFieldTypes) ?? responseFields.map(safeFieldTypes),
                continuity: continuity,
                safeServerMessage: safeMessage,
                safeMessagePresent: httpStatus == nil ? nil : safeMessage != nil,
                deviceIdentifierSource: request.deviceIdentifierSource.rawValue,
                endpoint: requestFields == nil && responseFields == nil
                    ? nil : "developerServices/ios/addDevice",
                httpMethod: requestFields == nil && responseFields == nil ? nil : "POST",
                generationID: generation
            ))
        }
    }

    private func recordSRPStructure(
        stage: String,
        parameters: [String: Any],
        response: [String: Any],
        status: [String: Any],
        httpStatus: Int,
        protocolName: String?
    ) {
        var lengths: [String: Int] = [:]
        if let value = parameters["A2k"] as? Data { lengths["A"] = value.count }
        if let value = parameters["M1"] as? Data { lengths["M1"] = value.count }
        if let value = response["s"] as? Data { lengths["salt"] = value.count }
        if let value = response["B"] as? Data { lengths["B"] = value.count }
        let isChallenge = stage == "srpInit"
        var types: [String: String] = [:]
        safeFieldTypes(parameters).forEach { types["request.\($0.key)"] = $0.value }
        safeFieldTypes(response).forEach { types["response.\($0.key)"] = $0.value }
        safeFieldTypes(status).forEach { types["status.\($0.key)"] = $0.value }
        var nonSecretIntegers: [String: Int] = [:]
        if let iterations = integer(response["i"]) { nonSecretIntegers["iterations"] = iterations }
        var continuity: [String: Bool]?
        if stage == "srpComplete" {
            continuity = [
                "challengeTokenPresent": (parameters["c"] as? String)?.isEmpty == false,
                "cpdPresent": parameters["cpd"] is [String: Any],
                "cpdStable": true,
                "anisetteHeadersStable": true,
                "usernameStable": true,
                "srpInstanceStable": true,
                "ptxidSent": parameters["ptxid"] != nil,
                "httpCookiePersistenceEnabled": false
            ]
        }
        let safeMessage = (status["em"] as? String)
            .map(Redactor.redact)
            .flatMap { $0.utf8.count <= 512 ? $0 : nil }
        diagnostics.update(adapterVersion: adapter.version) {
            $0.events.append(.init(
                timestamp: Date(),
                checkpoint: nil,
                stage: stage,
                safeErrorCode: nil,
                httpStatus: httpStatus,
                appleErrorCode: integer(status["ec"]),
                retryAfterSeconds: nil,
                retryable: false,
                reauthorizationRequired: false,
                srpProtocol: protocolName,
                srpVersion: "1.0.1",
                structuralLengths: lengths.isEmpty ? nil : lengths,
                requestFieldNames: safeFieldNames(parameters.keys),
                challengeFieldNames: isChallenge ? safeFieldNames(response.keys) : nil,
                responseFieldNames: isChallenge ? nil : safeFieldNames(response.keys),
                responseStatusCode: integer(status["hsc"]),
                fieldTypes: types.isEmpty ? nil : types,
                responseStatusFieldNames: safeFieldNames(status.keys),
                nonSecretIntegers: nonSecretIntegers.isEmpty ? nil : nonSecretIntegers,
                continuity: continuity,
                safeServerMessage: safeMessage
            ))
        }
    }

    private func recordSRPDerivation(proof: AppleSRPProof, challenge: AppleSRPChallenge) {
        diagnostics.update(adapterVersion: adapter.version) {
            $0.events.append(.init(
                timestamp: Date(),
                checkpoint: nil,
                stage: "srpDerivation",
                safeErrorCode: nil,
                httpStatus: nil,
                appleErrorCode: nil,
                retryAfterSeconds: nil,
                retryable: false,
                reauthorizationRequired: false,
                srpProtocol: challenge.scheme,
                srpVersion: "1.0.1",
                structuralLengths: proof.structuralLengths,
                nonSecretIntegers: ["iterations": challenge.iterations]
            ))
        }
    }

    private func recordPostComplete(
        stage: String,
        response: [String: Any],
        status: [String: Any],
        lengths extraLengths: [String: Int] = [:],
        flags: [String: Bool] = [:],
        safeErrorCode: String? = nil
    ) {
        var lengths = extraLengths
        for name in ["M2", "np", "spd", "sc"] {
            if lengths[name] == nil, let data = response[name] as? Data {
                lengths[name] = data.count
            }
        }
        diagnostics.update(adapterVersion: adapter.version) {
            $0.events.append(.init(
                timestamp: Date(),
                checkpoint: nil,
                stage: stage,
                safeErrorCode: safeErrorCode,
                httpStatus: nil,
                appleErrorCode: integer(status["ec"]),
                retryAfterSeconds: nil,
                retryable: false,
                reauthorizationRequired: safeErrorCode != nil,
                srpVersion: "1.0.1",
                structuralLengths: lengths.isEmpty ? nil : lengths,
                responseFieldNames: safeFieldNames(response.keys),
                responseStatusCode: integer(status["hsc"]),
                fieldTypes: safeFieldTypes(response),
                responseStatusFieldNames: safeFieldNames(status.keys),
                continuity: flags.isEmpty ? nil : flags
            ))
        }
    }

    private func recordFailure(_ failure: AppleServiceFailure, stage: String) {
        diagnostics.update(adapterVersion: adapter.version) {
            $0.events.append(.init(
                timestamp: Date(), checkpoint: nil, stage: stage,
                safeErrorCode: failure.error.safeCode, httpStatus: failure.status,
                appleErrorCode: failure.appleCode, retryAfterSeconds: failure.retryAfter,
                retryable: failure.retryable, reauthorizationRequired: failure.reauthorizationRequired,
                safeServerMessage: failure.safeMessage,
                safeMessagePresent: failure.status == nil ? nil : failure.safeMessage != nil,
                endpoint: failure.responseMetadata?.endpoint,
                httpMethod: failure.responseMetadata?.method,
                responseContentType: failure.responseMetadata?.contentType,
                responseBodyKind: failure.responseMetadata?.bodyKind,
                serverIdentifier: failure.responseMetadata?.serverIdentifier,
                requestIdentifier: failure.responseMetadata?.requestIdentifier
            ))
        }
    }

    private func retryAfter(_ headers: [AnyHashable: Any]) -> Int? {
        headers.first { key, _ in
            String(describing: key).localizedCaseInsensitiveCompare("Retry-After") == .orderedSame
        }.flatMap { Int(String(describing: $0.value)) }
    }

    private func safeHTTPFailureMetadata(
        response: AppleHTTPResponse,
        request: URLRequest
    ) -> SafeAppleHTTPFailureMetadata {
        let contentType = safeHTTPHeader("Content-Type", in: response.headers, maximumLength: 128)?
            .lowercased()
        let server = safeHTTPHeader("Server", in: response.headers, maximumLength: 128)
        let requestIDNames = [
            "X-Apple-I-Retry-Request-UUID", "X-Apple-Request-UUID",
            "X-Apple-Request-ID", "X-Request-ID"
        ]
        let requestIdentifier = requestIDNames.lazy.compactMap {
            safeASCIIHTTPHeader($0, in: response.headers, maximumLength: 128)
        }.first.map(safeCorrelationFingerprint)
        return SafeAppleHTTPFailureMetadata(
            endpoint: response.url.host.map { $0 + response.url.path },
            method: request.httpMethod,
            contentType: contentType,
            bodyKind: safeResponseBodyKind(response.body, contentType: contentType),
            serverIdentifier: server,
            requestIdentifier: requestIdentifier
        )
    }
}

private func safeCorrelationFingerprint(_ value: String) -> String {
    let digest = Data(SHA256.hash(data: Data(value.utf8))).hexLowercase
    return "sha256:\(digest.prefix(16))"
}

private func safeHTTPHeader(
    _ name: String,
    in headers: [AnyHashable: Any],
    maximumLength: Int
) -> String? {
    safeASCIIHTTPHeader(name, in: headers, maximumLength: maximumLength).map(Redactor.redact)
}

private func safeASCIIHTTPHeader(
    _ name: String,
    in headers: [AnyHashable: Any],
    maximumLength: Int
) -> String? {
    guard let raw = headers.first(where: {
        String(describing: $0.key).localizedCaseInsensitiveCompare(name) == .orderedSame
    }).map({ String(describing: $0.value) }),
          !raw.isEmpty, raw.utf8.count <= maximumLength,
          raw.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }) else {
        return nil
    }
    return raw
}

private func safeResponseBodyKind(_ body: Data, contentType: String?) -> String {
    if body.isEmpty { return "empty" }
    let prefix = String(decoding: body.prefix(256), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    if contentType?.contains("plist") == true || prefix.hasPrefix("<?xml") { return "plist-or-xml" }
    if contentType?.contains("json") == true || prefix.hasPrefix("{") || prefix.hasPrefix("[") { return "json" }
    if contentType?.contains("html") == true || prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") {
        return "html"
    }
    if contentType?.hasPrefix("text/") == true { return "text" }
    return "binary-or-unknown"
}

private func safeFieldNames(_ names: Dictionary<String, Any>.Keys) -> [String] {
    names.compactMap { name -> String? in
        guard !name.isEmpty, name.utf8.count <= 64,
              name.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "_" || scalar == "-")
              }) else { return nil }
        return name
    }.sorted()
}

func safeFieldTypes(_ dictionary: [String: Any]) -> [String: String] {
    dictionary.reduce(into: [:]) { result, item in
        guard safeFieldNames([item.key: item.value].keys).count == 1 else { return }
        switch item.value {
        case is Data: result[item.key] = "Data"
        case is String: result[item.key] = "String"
        case let number as NSNumber:
            result[item.key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? "Bool" : "Number"
        case is [String]: result[item.key] = "Array<String>"
        case is [Any]: result[item.key] = "Array"
        case is [String: Any]: result[item.key] = "Dictionary"
        default: result[item.key] = "Other"
        }
    }
}

private extension PrivateAppleProtocolAdapter {
    var authUserAgent: String { "Xcode/\(xcodeBundleVersion)" }
}

private extension Dictionary where Key == String, Value == String {
    subscript(caseInsensitive key: String) -> String? {
        first { $0.key.localizedCaseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

private func serializePlist(_ value: Any) throws -> Data {
    guard PropertyListSerialization.propertyList(value, isValidFor: .xml) else {
        throw ExperimentalBackendError.responseChanged
    }
    return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

func parseApplePlist(_ data: Data) throws -> [String: Any]? {
    guard !data.isEmpty, data.count <= 8_388_608 else { throw ExperimentalBackendError.responseTooLarge }
    return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
}

func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

private func integer64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
}

private func string(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func validateNegotiationProof(
    response: [String: Any],
    scheme: String,
    sessionKey: Data
) throws {
    guard let spd = response["spd"] as? Data,
          let negotiation = response["np"] as? Data, negotiation.count == 32 else {
        throw ExperimentalBackendError.authenticationProtocolMismatch
    }
    let sc = response["sc"] as? Data
    // AppleIDAuthSupport retains the negotiation transcript incrementally:
    // one separator after the offered list and another before the selected
    // scheme. Omitting the empty field changes np even when M2 is valid.
    var transcript = Data("s2k,s2k_fo||\(scheme)|".utf8)
    transcript.appendLengthPrefixed(spd)
    transcript.append(Data("|".utf8))
    if let sc { transcript.appendLengthPrefixed(sc) }
    transcript.append(Data("|".utf8))
    let transcriptHash = Data(SHA256.hash(data: transcript))
    let hmacKey = sessionKey.hmacSHA256(message: Data("HMAC key:".utf8))
    let expected = hmacKey.hmacSHA256(message: transcriptHash)
    guard constantTimeEqual(negotiation, expected) else {
        throw ExperimentalBackendError.srpAuthFailed
    }
}

func decryptCBC(_ encrypted: Data, sessionKey: Data) throws -> Data {
    guard !encrypted.isEmpty, encrypted.count % kCCBlockSizeAES128 == 0 else {
        throw ExperimentalBackendError.authenticationProtocolMismatch
    }
    let key = sessionKey.hmacSHA256(message: Data("extra data key:".utf8))
    let iv = sessionKey.hmacSHA256(message: Data("extra data iv:".utf8)).prefix(kCCBlockSizeAES128)
    var output = Data(count: encrypted.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var outputLength = 0
    let status = output.withUnsafeMutableBytes { outputBytes in
        encrypted.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                        inputBytes.baseAddress, encrypted.count,
                        outputBytes.baseAddress, outputCapacity, &outputLength
                    )
                }
            }
        }
    }
    guard status == kCCSuccess, outputLength <= output.count else {
        throw ExperimentalBackendError.srpAuthFailed
    }
    output.removeSubrange(outputLength..<output.count)
    return output
}

private func decryptAppToken(_ encrypted: Data, key: Data) throws -> Data {
    guard key.count == 32, encrypted.count >= 35, encrypted.prefix(3) == Data("XYZ".utf8) else {
        throw ExperimentalBackendError.authenticationProtocolMismatch
    }
    let nonceData = encrypted.subdata(in: 3..<19)
    let ciphertext = encrypted.subdata(in: 19..<(encrypted.count - 16))
    let tag = encrypted.suffix(16)
    do {
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data("XYZ".utf8))
    } catch {
        throw ExperimentalBackendError.srpAuthFailed
    }
}

private func constantTimeEqual(_ first: Data, _ second: Data) -> Bool {
    guard first.count == second.count else { return false }
    var difference: UInt8 = 0
    for index in first.indices { difference |= first[index] ^ second[index] }
    return difference == 0
}

private extension Data {
    mutating func appendLengthPrefixed(_ value: Data) {
        var length = UInt32(value.count).littleEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(value)
    }
}

// MARK: - Installation V2 Developer Services boundary (M6)
//
// Stateless calls over the already-authenticated session. Certificate ownership, attempt limits and
// journaling live in `CertificateReconciler` and the engine domains; nothing here reads legacy identity
// metadata, the Keychain, or `machineId` markers.

extension LiveApplePersonalTeamBackend: AppleDeveloperServices {
    public func currentPersonalTeam() async throws -> ExperimentalAppleTeam {
        let teams: [ExperimentalAppleTeam]
        if let session {
            teams = try await listTeams(using: session)
        } else {
            guard let resumed = try await resumeSession() else { throw ExperimentalBackendError.sessionExpired }
            teams = resumed
        }
        guard let teamID = authorizedTeamIdentifier, let team = teams.first(where: { $0.id == teamID && $0.isPersonalTeam }) else {
            throw ExperimentalBackendError.noTeam
        }
        return team
    }

    public func listDevelopmentCertificates(teamID: String) async throws -> [AppleCertificateObservation] {
        let response = try await developerRequest(operation: "ios/listAllDevelopmentCerts", parameters: ["teamId": teamID])
        guard let certificates = response["certificates"] as? [[String: Any]], certificates.count <= 100 else {
            throw ExperimentalBackendError.responseChanged
        }
        // An entry without parseable DER can never be proven owned, so it can never be reused or revoked.
        return certificates.compactMap { entry in
            guard let serial = certificateSerialNumber(entry), let der = certificateData(entry) else { return nil }
            return AppleCertificateObservation(serial: serial, der: der)
        }
    }

    public func submitDevelopmentCSR(teamID: String, csrPEM: String) async throws -> AppleCertificateObservation? {
        let installation = VeyaSigningKeyStore.sha256(Data("veya-machine|\(teamID)".utf8))
        do {
            let submitted = try await developerRequest(operation: "ios/submitDevelopmentCSR", parameters: [
                "teamId": teamID,
                // Display-only: ownership is proven by SPKI, never by this marker.
                "machineId": String(installation.dropFirst(7).prefix(32)),
                "machineName": "Veya",
                "csrContent": csrPEM,
            ])
            guard let request = submitted["certRequest"] as? [String: Any] else { return nil }
            guard let serial = certificateSerialNumber(request), let der = certificateData(request) else { return nil }
            return AppleCertificateObservation(serial: serial, der: der)
        } catch let failure as AppleServiceFailure where failure.error == .certificateLimit {
            throw AppleCertificateServiceError.capacityReached
        } catch let failure as AppleServiceFailure {
            throw failure.error
        }
    }

    public func revokeDevelopmentCertificate(teamID: String, serial: String) async throws {
        do {
            _ = try await developerRequest(operation: "ios/revokeDevelopmentCert",
                                           parameters: ["teamId": teamID, "serialNumber": serial])
        } catch let failure as AppleServiceFailure {
            throw failure.error == .sessionExpired ? failure.error : ExperimentalBackendError.certificateRevocationFailed
        }
    }

    public func ensureDeviceRegistered(team: ExperimentalAppleTeam, udid: String, name: String) async throws {
        try await registerDevice(ExperimentalProvisioningRequest(
            selectedDeviceIdentifier: udid,
            selectedDeviceRegistrationIdentifier: udid,
            deviceIdentifierSource: .physicalUDID,
            selectedDeviceName: name,
            operation: .install
        ), team: team)
    }

    public func ensureAppIdentifiers(_ identifiers: PersonalTeamBundleIdentifierSet, team: ExperimentalAppleTeam) async throws {
        try await registerIdentifiers(identifiers, team: team)
    }

    public func downloadDevelopmentProfile(teamID: String, bundleIdentifier: String) async throws -> Data {
        guard authorizedTeamIdentifier == teamID else { throw ExperimentalBackendError.invalidTeam }
        let appID: String
        if let cached = appIdentifierIDs[bundleIdentifier] {
            appID = cached
        } else {
            guard let listed = try await listAppIdentifiers(teamID: teamID).first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                throw ExperimentalBackendError.appIDRegistrationFailed
            }
            appID = listed.identifier
        }
        let response: [String: Any]
        do {
            response = try await developerRequest(operation: "ios/downloadTeamProvisioningProfile",
                                                  parameters: ["teamId": teamID, "appIdId": appID])
        } catch let failure as AppleServiceFailure where failure.error == .sessionExpired {
            throw failure.error
        } catch {
            throw ExperimentalBackendError.profileRequestFailed
        }
        return try AppleDeveloperResponseParser.encodedProfile(response)
    }
}

/// Offline validation of an Apple development profile against the exact team, bundle, device and
/// certificate DER. Used by the `.profile` domain on every observation, so it never touches the network.
func validateDevelopmentProfile(
    _ encoded: Data,
    bundleIdentifier: String,
    teamIdentifier: String,
    deviceUDID: String,
    certificateDER: Data,
    now: Date
) throws -> ExperimentalProfile {
    try decodeAndValidateProfile(
        encoded,
        expectedBundleIdentifier: bundleIdentifier,
        expectedTeamIdentifier: teamIdentifier,
        selectedDeviceIdentifier: deviceUDID,
        certificateFingerprint: certificateFingerprint(certificateDER),
        now: now
    )
}
