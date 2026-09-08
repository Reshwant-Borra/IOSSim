import BigInt
import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import ObjectiveC.runtime
import Security

// MARK: - Safe diagnostics

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
}

public struct ApplePersonalTeamDiagnosticSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
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
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                return
            }
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
    case network
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
        } else if error != nil {
            item.continuation.resume(throwing: AppleLiveTransportError.network)
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
    private let xcodeBundleVersion: String

    public init(xcodeBundleVersion: String = PrivateAppleProtocolAdapter.researched2026.xcodeBundleVersion) {
        self.xcodeBundleVersion = xcodeBundleVersion
    }

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
        result["X-MMe-Client-Info"] =
            "<\(model)> <macOS;\(osVersion);\(build)> <com.apple.AuthKit/1 (com.apple.dt.Xcode/\(xcodeBundleVersion))>"
        result["X-Apple-I-Client-Time"] = result["X-Apple-I-Client-Time"] ?? Self.clientTimestamp()
        result["X-Apple-Locale"] = result["X-Apple-I-Locale"] ?? Locale.current.identifier
        result["X-Apple-I-TimeZone"] = result["X-Apple-I-TimeZone"] ?? TimeZone.current.identifier
        return result
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
        let x = BigUInt(derived)
        let verifier = generator.power(x, modulus: modulus)
        let base = server.subtracting(multiplier * verifier % modulus, modulus: modulus)
        let exponent = privateKey + scrambling * x
        let shared = base.power(exponent, modulus: modulus)
        let sessionKey = Data(SHA256.hash(data: Self.pad(shared, to: 256)))

        var xor = Data(SHA256.hash(data: nData))
        let gHash = Data(SHA256.hash(data: Data([2])))
        for index in xor.indices { xor[index] ^= gHash[index] }
        let userHash = Data(SHA256.hash(data: Data(account.utf8)))
        let proof = Data(SHA256.hash(
            data: xor + userHash + challenge.salt + clientPublicKey + Self.pad(server, to: 256) + sessionKey
        ))
        let serverProof = Data(SHA256.hash(data: clientPublicKey + proof + sessionKey))
        return AppleSRPProof(clientProof: proof, sessionKey: sessionKey, expectedServerProof: serverProof)
    }

    static func verifyServerProof(_ received: Data, expected: Data) throws {
        guard received.count == expected.count else { throw ExperimentalBackendError.srpAuthFailed }
        var difference: UInt8 = 0
        for index in received.indices { difference |= received[index] ^ expected[index] }
        guard difference == 0 else { throw ExperimentalBackendError.srpAuthFailed }
    }

    private static func pad(_ value: BigUInt, to count: Int) -> Data {
        let serialized = value.serialize()
        if serialized.count >= count { return serialized }
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

private struct IOSSimIdentityMetadata: Codable {
    let teamIdentifier: String
    let certificateFingerprint: String?
    let certificateSerial: String?
    let certificateExpiration: Date?
    let keyApplicationTag: Data
    let createdAt: Date
    let generatedByIOSSim: Bool
}

private final class IOSSimIdentityMetadataStore: @unchecked Sendable {
    private let service = "com.iossim.mac.personal-team-signing"

    func load(teamIdentifier: String) throws -> IOSSimIdentityMetadata? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: teamIdentifier,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExperimentalBackendError.missingPrivateKey
        }
        return try PropertyListDecoder().decode(IOSSimIdentityMetadata.self, from: data)
    }

    func save(_ metadata: IOSSimIdentityMetadata) throws {
        let data = try PropertyListEncoder().encode(metadata)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadata.teamIdentifier,
            kSecAttrSynchronizable as String: false
        ]
        let replacement: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, replacement as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            replacement.forEach { attributes[$0.key] = $0.value }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ExperimentalBackendError.certificateRequestFailed }
    }
}

extension LiveApplePersonalTeamBackend {
    public func prepareIdentity(team: ExperimentalAppleTeam) async throws -> ExperimentalSigningIdentity {
        let metadataStore = IOSSimIdentityMetadataStore()
        let response = try await developerRequest(
            operation: "ios/listAllDevelopmentCerts",
            parameters: ["teamId": team.id]
        )
        guard let certificates = response["certificates"] as? [[String: Any]], certificates.count <= 100 else {
            throw ExperimentalBackendError.responseChanged
        }
        if let owned = try metadataStore.load(teamIdentifier: team.id) {
            guard owned.generatedByIOSSim,
                  let key = keyReference(applicationTag: owned.keyApplicationTag) else {
                throw ExperimentalBackendError.missingPrivateKey
            }
            if let fingerprint = owned.certificateFingerprint,
               let expiration = owned.certificateExpiration,
               expiration > Date(),
               certificates.contains(where: { certificate in
                   let serial = certificateString(certificate, names: ["serialNumber", "serialNum"])
                   if let expected = owned.certificateSerial, serial == expected { return true }
                   return certificateData(certificate).map(certificateFingerprint) == fingerprint
               }) {
                let persistent = try keyPersistentReference(applicationTag: owned.keyApplicationTag)
                record(.signingIdentityReused, stage: "certificate")
                diagnostics.update(adapterVersion: adapter.version) {
                    $0.certificateFingerprint = fingerprint
                }
                return ExperimentalSigningIdentity(
                    certificateFingerprint: fingerprint,
                    certificateExpiration: expiration,
                    privateKeyPersistentReference: persistent,
                    reused: true
                )
            }
            if let match = matchingCertificate(in: certificates, key: key, teamIdentifier: team.id) {
                let finalized = IOSSimIdentityMetadata(
                    teamIdentifier: team.id,
                    certificateFingerprint: match.fingerprint,
                    certificateSerial: match.serial,
                    certificateExpiration: match.expiration,
                    keyApplicationTag: owned.keyApplicationTag,
                    createdAt: owned.createdAt,
                    generatedByIOSSim: true
                )
                try metadataStore.save(finalized)
                let persistent = try keyPersistentReference(applicationTag: owned.keyApplicationTag)
                record(.signingIdentityReused, stage: "certificate")
                diagnostics.update(adapterVersion: adapter.version) { $0.certificateFingerprint = match.fingerprint }
                return ExperimentalSigningIdentity(
                    certificateFingerprint: match.fingerprint,
                    certificateExpiration: match.expiration,
                    privateKeyPersistentReference: persistent,
                    reused: true
                )
            }
            // Never create another certificate behind stale IOSSim ownership
            // metadata; this avoids consuming account certificate slots.
            throw ExperimentalBackendError.missingPrivateKey
        }

        if integer(response["availableQuantity"]) == 0 {
            throw ExperimentalBackendError.certificateLimit
        }

        let tag = Data("com.iossim.personal-team.\(team.id).\(UUID().uuidString)".utf8)
        let key = try createSigningKey(applicationTag: tag)
        try metadataStore.save(IOSSimIdentityMetadata(
            teamIdentifier: team.id,
            certificateFingerprint: nil,
            certificateSerial: nil,
            certificateExpiration: nil,
            keyApplicationTag: tag,
            createdAt: Date(),
            generatedByIOSSim: true
        ))
        let csr = try createCertificateSigningRequest(key: key)
        var submittedCertificate: [String: Any]?
        do {
            let submitted = try await developerRequest(
                operation: "ios/submitDevelopmentCSR",
                parameters: [
                    "teamId": team.id,
                    "machineId": UUID().uuidString,
                    "machineName": "IOSSim",
                    "csrContent": csr
                ]
            )
            guard let request = submitted["certRequest"] as? [String: Any],
                  certificateData(request) != nil
                    || !(certificateString(request, names: ["certRequestId", "requestId", "certificateId"]) ?? "").isEmpty else {
                throw ExperimentalBackendError.certificateRequestFailed
            }
            submittedCertificate = request
        } catch let failure as AppleServiceFailure {
            if failure.error == .certificateLimit { throw ExperimentalBackendError.certificateLimit }
            throw ExperimentalBackendError.certificateRequestFailed
        }
        var match = submittedCertificate.flatMap {
            matchingCertificate(in: [$0], key: key, teamIdentifier: team.id)
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
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: match.certificate,
            kSecAttrLabel as String: "IOSSim Apple Development \(team.id)"
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw ExperimentalBackendError.certificateRequestFailed
        }
        let metadata = IOSSimIdentityMetadata(
            teamIdentifier: team.id,
            certificateFingerprint: match.fingerprint,
            certificateSerial: match.serial,
            certificateExpiration: match.expiration,
            keyApplicationTag: tag,
            createdAt: Date(),
            generatedByIOSSim: true
        )
        try metadataStore.save(metadata)
        let persistent = try keyPersistentReference(applicationTag: tag)
        record(.signingIdentityCreated, stage: "certificate")
        diagnostics.update(adapterVersion: adapter.version) { $0.certificateFingerprint = match.fingerprint }
        return ExperimentalSigningIdentity(
            certificateFingerprint: match.fingerprint,
            certificateExpiration: match.expiration,
            privateKeyPersistentReference: persistent,
            reused: false
        )
    }

    public func registerDevice(
        _ request: ExperimentalProvisioningRequest,
        team: ExperimentalAppleTeam
    ) async throws {
        let listed = try await developerRequest(operation: "ios/listDevices", parameters: ["teamId": team.id])
        guard let devices = listed["devices"] as? [[String: Any]], devices.count <= 500 else {
            throw ExperimentalBackendError.responseChanged
        }
        if devices.contains(where: { string($0["deviceNumber"]) == request.selectedDeviceIdentifier }) {
            record(.deviceAlreadyRegistered, stage: "deviceRegistration")
            diagnostics.update(adapterVersion: adapter.version) { $0.deviceRegistrationStatus = "ALREADY_REGISTERED" }
            return
        }
        do {
            _ = try await developerRequest(operation: "ios/addDevice", parameters: [
                "teamId": team.id,
                "name": sanitizedDeviceName(request.selectedDeviceName),
                "deviceNumber": request.selectedDeviceIdentifier
            ])
        } catch let failure as AppleServiceFailure {
            if failure.error == .deviceLimit { throw ExperimentalBackendError.deviceLimit }
            throw ExperimentalBackendError.deviceRegistrationFailed
        }
        record(.deviceRegistered, stage: "deviceRegistration")
        diagnostics.update(adapterVersion: adapter.version) { $0.deviceRegistrationStatus = "REGISTERED" }
    }

    public func registerIdentifiers(
        _ identifiers: PersonalTeamBundleIdentifierSet,
        team: ExperimentalAppleTeam
    ) async throws {
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
                selectedDeviceIdentifier: request.selectedDeviceIdentifier,
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

private func sanitizedDeviceName(_ value: String) -> String {
    let allowed = value.unicodeScalars.filter { CharacterSet.alphanumerics.union(.whitespaces).contains($0) }
    let result = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespacesAndNewlines)
    return String((result.isEmpty ? "IOSSim iPhone" : result).prefix(100))
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
}

private func matchingCertificate(
    in certificates: [[String: Any]],
    key: SecKey,
    teamIdentifier: String
) -> MatchedDevelopmentCertificate? {
    guard let localPublicKey = SecKeyCopyPublicKey(key),
          let localBytes = SecKeyCopyExternalRepresentation(localPublicKey, nil) as Data? else { return nil }
    for object in certificates {
        guard let der = certificateData(object), der.count <= 64 * 1_024,
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              certificateTeamIdentifiers(certificate).contains(teamIdentifier),
              let certificateKey = SecCertificateCopyKey(certificate),
              let certificateBytes = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              constantTimeEqual(localBytes, certificateBytes),
              let expiration = certificateExpiration(certificate), expiration > Date() else { continue }
        return MatchedDevelopmentCertificate(
            certificate: certificate,
            fingerprint: certificateFingerprint(der),
            serial: certificateString(object, names: ["serialNumber", "serialNum"]),
            expiration: expiration
        )
    }
    return nil
}

private func certificateTeamIdentifiers(_ certificate: SecCertificate) -> Set<String> {
    guard let values = SecCertificateCopyValues(
        certificate,
        [kSecOIDOrganizationalUnitName] as CFArray,
        nil
    ) as? [CFString: Any],
    let property = values[kSecOIDOrganizationalUnitName] else { return [] }
    var strings: Set<String> = []
    func collect(_ value: Any) {
        if let value = value as? String { strings.insert(value); return }
        if let array = value as? [Any] { array.forEach(collect); return }
        if let dictionary = value as? [CFString: Any] { dictionary.values.forEach(collect) }
    }
    collect(property)
    return strings
}

private func certificateFingerprint(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).map { String(format: "%02X", $0) }.joined()
}

private func certificateExpiration(_ certificate: SecCertificate) -> Date? {
    guard let values = SecCertificateCopyValues(
        certificate,
        [kSecOIDX509V1ValidityNotAfter] as CFArray,
        nil
    ) as? [CFString: Any],
    let property = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any] else { return nil }
    return property[kSecPropertyKeyValue] as? Date
}

private func keyReference(applicationTag: Data) -> SecKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: applicationTag,
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return (result as! SecKey)
}

private func keyPersistentReference(applicationTag: Data) throws -> Data {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: applicationTag,
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecReturnPersistentRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { throw ExperimentalBackendError.missingPrivateKey }
    return data
}

private func createSigningKey(applicationTag: Data) throws -> SecKey {
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 2_048,
        kSecPrivateKeyAttrs as String: [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrLabel as String: "IOSSim Personal Team Signing Key",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        throw ExperimentalBackendError.certificateRequestFailed
    }
    return key
}

private func createCertificateSigningRequest(key: SecKey) throws -> String {
    guard let publicKey = SecKeyCopyPublicKey(key) else { throw ExperimentalBackendError.certificateRequestFailed }
    var error: Unmanaged<CFError>?
    guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
        throw ExperimentalBackendError.certificateRequestFailed
    }
    let subject = ASN1.sequence([
        ASN1.set(ASN1.sequence([ASN1.oid([0x55, 0x04, 0x06]), ASN1.printable("US")])),
        ASN1.set(ASN1.sequence([ASN1.oid([0x55, 0x04, 0x0A]), ASN1.utf8("IOSSim")])),
        ASN1.set(ASN1.sequence([ASN1.oid([0x55, 0x04, 0x03]), ASN1.utf8("IOSSim")]))
    ])
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
    let encoded = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN CERTIFICATE REQUEST-----\n\(encoded)-----END CERTIFICATE REQUEST-----\n"
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

private func decodeAndValidateProfile(
    _ encoded: Data,
    expectedBundleIdentifier: String,
    expectedTeamIdentifier: String,
    selectedDeviceIdentifier: String,
    certificateFingerprint expectedCertificateFingerprint: String
) throws -> ExperimentalProfile {
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
          let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
          let team = (plist["TeamIdentifier"] as? [String])?.first, team == expectedTeamIdentifier,
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
          issuedAt <= Date(), expiresAt > Date(),
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
}

enum AppleHTTPFailureClassifier {
    static func error(status: Int, stage: String) -> ExperimentalBackendError {
        if status == 429 { return .rateLimited }
        if stage == "xcodeScopedToken" { return .xcodeScopedTokenFailed }
        if stage.hasPrefix("developerServices/") { return .developerServicesFailed }
        return .networkFailure
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
    private let sessionStore: any AppleAuthorizationSessionStoring
    private let diagnostics: ApplePersonalTeamDiagnosticsStore
    private var session: LiveSessionEnvelope?
    private var pendingTwoFactor: PendingTwoFactor?
    private var appIdentifierIDs: [String: String] = [:]

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
        self.sessionStore = sessionStore
        self.diagnostics = diagnostics
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
        } catch {
            session = nil
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
        appIdentifierIDs = [:]
        try? sessionStore.remove()
        diagnostics.update(adapterVersion: adapter.version) { $0.sessionValid = false }
    }

    private enum AuthenticationOutcome {
        case verification(PendingTwoFactor)
        case session(LiveSessionEnvelope)
    }

    private func authenticate(account: String, password: Data) async throws -> AuthenticationOutcome {
        let srp = try AppleSRPClient()
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
        let completed = try await grandSlam([
            "M1": proof.clientProof,
            "c": challenge.cookie,
            "cpd": cpd,
            "u": account,
            "o": "complete"
        ], machineHeaders: machineHeaders, stage: "srpComplete", closeConnection: true)
        guard let serverProof = completed.response["M2"] as? Data else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        try AppleSRPClient.verifyServerProof(serverProof, expected: proof.expectedServerProof)
        guard let encrypted = completed.response["spd"] as? Data, encrypted.count <= 1_048_576 else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        try validateNegotiationProof(
            response: completed.response,
            scheme: challenge.scheme,
            sessionKey: proof.sessionKey
        )
        var plaintext = try decryptCBC(encrypted, sessionKey: proof.sessionKey)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard let secret = try parseApplePlist(plaintext),
              let dsid = string(secret["adsid"]), !dsid.isEmpty, dsid.count <= 128,
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
            return .verification(pending)
        }

        guard let sk = secret["sk"] as? Data, sk.count == 32,
              let continuation = secret["c"] as? Data, !continuation.isEmpty else {
            throw ExperimentalBackendError.authenticationProtocolMismatch
        }
        return .session(try await fetchXcodeToken(
            dsid: dsid,
            idmsToken: idmsToken,
            continuation: continuation,
            appTokenKey: sk,
            cpd: cpd,
            machineHeaders: machineHeaders
        ))
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
        closeConnection: Bool = false
    ) async throws -> GrandSlamResponse {
        let body = try serializePlist(["Header": ["Version": "1.0.1"], "Request": parameters])
        var request = URLRequest(url: adapter.grandSlamService)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue(machineHeaders[caseInsensitive: "X-MMe-Client-Info"] ?? adapter.authUserAgent,
                         forHTTPHeaderField: "X-MMe-Client-Info")
        request.setValue(adapter.authUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Xcode", forHTTPHeaderField: "X-Apple-Client-App-Name")
        for name in ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-RINFO", "X-Mme-Device-Id"] {
            if let value = machineHeaders[caseInsensitive: name] {
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
        var request = URLRequest(url: adapter.trustedDeviceVerification)
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
        var request = URLRequest(url: adapter.verificationValidation)
        request.httpMethod = "POST"
        request.setValue(identity, forHTTPHeaderField: "X-Apple-Identity-Token")
        request.setValue(codeString, forHTTPHeaderField: "security-code")
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
        return validated
    }

    private func developerRequest(
        operation: String,
        parameters: [String: Any],
        session explicitSession: LiveSessionEnvelope? = nil
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try serializePlist(payload)
        try await applyMachineAndServiceHeaders(to: &request, dsid: active.dsid, token: active.xcodeToken)
        let http = try await send(request, maximumBytes: 8_388_608, stage: "developerServices/\(operation)")
        guard let response = try parseApplePlist(http.body) else { throw ExperimentalBackendError.responseChanged }
        let resultCode = integer(response["resultCode"]) ?? 0
        guard resultCode == 0 else {
            let safeText = [response["userString"] as? String, response["resultString"] as? String]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            let error: ExperimentalBackendError
            if operation.contains("submitDevelopmentCSR")
                && (safeText.contains("maximum") || safeText.contains("limit")) {
                error = .certificateLimit
            } else if operation.contains("addDevice")
                && (safeText.contains("maximum") || safeText.contains("limit")) {
                error = .deviceLimit
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
                reauthorizationRequired: error == .sessionExpired
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
                throw AppleServiceFailure(
                    error: error,
                    status: response.statusCode,
                    appleCode: nil,
                    retryAfter: retryAfter(response.headers),
                    retryable: response.statusCode == 429 || response.statusCode == 503,
                    reauthorizationRequired: false
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

    private func recordFailure(_ failure: AppleServiceFailure, stage: String) {
        diagnostics.update(adapterVersion: adapter.version) {
            $0.events.append(.init(
                timestamp: Date(), checkpoint: nil, stage: stage,
                safeErrorCode: failure.error.safeCode, httpStatus: failure.status,
                appleErrorCode: failure.appleCode, retryAfterSeconds: failure.retryAfter,
                retryable: failure.retryable, reauthorizationRequired: failure.reauthorizationRequired
            ))
        }
    }

    private func retryAfter(_ headers: [AnyHashable: Any]) -> Int? {
        headers.first { key, _ in
            String(describing: key).localizedCaseInsensitiveCompare("Retry-After") == .orderedSame
        }.flatMap { Int(String(describing: $0.value)) }
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

private func integer(_ value: Any?) -> Int? {
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

private func validateNegotiationProof(
    response: [String: Any],
    scheme: String,
    sessionKey: Data
) throws {
    guard let spd = response["spd"] as? Data,
          let negotiation = response["np"] as? Data, negotiation.count == 32 else {
        throw ExperimentalBackendError.authenticationProtocolMismatch
    }
    let sc = response["sc"] as? Data
    var transcript = Data("s2k,s2k_fo|\(scheme)|".utf8)
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

private func decryptCBC(_ encrypted: Data, sessionKey: Data) throws -> Data {
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
